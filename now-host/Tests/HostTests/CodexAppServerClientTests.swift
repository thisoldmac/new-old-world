import XCTest

@testable import Host

final class ScriptedCodexTransport: CodexAppServerTransport,
    @unchecked Sendable {
    private let lock = NSLock()
    private var receiver: (@Sendable (String) -> Void)?
    private var responses: [String: [[String: Any]]]
    private(set) var messages: [[String: Any]] = []
    private(set) var stopped = false

    init(responses: [String: [[String: Any]]] = [:]) {
        self.responses = responses
    }

    func start(
        receive: @escaping @Sendable (String) -> Void,
        terminated: @escaping @Sendable () -> Void
    ) throws {
        lock.withLock { receiver = receive }
    }

    func send(_ data: Data) throws {
        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let response: [String: Any]? = lock.withLock {
            messages.append(object)
            guard let method = object["method"] as? String,
                let id = object["id"] as? Int else { return nil }
            let result = responses[method]?.isEmpty == false
                ? responses[method]!.removeFirst() : [:]
            return ["id": id, "result": result]
        }
        if let response { emit(response) }
    }

    func stop() { lock.withLock { stopped = true } }

    func emit(_ object: [String: Any]) {
        let callback = lock.withLock { receiver }
        let data = try! JSONSerialization.data(withJSONObject: object)
        callback?(String(decoding: data, as: UTF8.self))
    }
}

final class CodexAppServerClientTests: XCTestCase {
    // `Any` erases Sendable; this immutable test fixture has JSON leaves only.
    private nonisolated(unsafe) static let account: [String: Any] = [
        "account": [
            "type": "chatgpt", "email": "person@example.test",
            "planType": "plus",
        ],
        "requiresOpenaiAuth": true,
    ]

    func testInitializationAndAccountReadUseDocumentedMethods() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]], "account/read": [Self.account],
        ])
        let client = CodexAppServerClient(transport: transport)

        let account = try await client.account()
        XCTAssertEqual(account?.email, "person@example.test")
        XCTAssertEqual(account?.planType, "plus")
        XCTAssertEqual(transport.messages.compactMap { $0["method"] as? String }, [
            "initialize", "initialized", "account/read",
        ])
    }

    func testModelListMapsVisibleModels() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]],
            "model/list": [["data": [
                ["model": "gpt-5.4", "displayName": "GPT-5.4",
                 "hidden": false],
                ["model": "old", "displayName": "Old", "hidden": true],
            ]]],
        ])
        let models = try await CodexAppServerClient(
            transport: transport).models()
        XCTAssertEqual(models.map(\.wireID), ["codex/gpt-5.4"])
    }

    func testLoginWaitsForMatchingCallbackNotification() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]],
            "account/login/start": [[
                "type": "chatgpt", "loginId": "login-1",
                "authUrl": "https://auth.openai.test/start",
            ]],
        ])
        let client = CodexAppServerClient(transport: transport)
        let login = try await client.beginLogin()
        XCTAssertEqual(login.loginID, "login-1")

        let waiting = Task { try await client.waitForLogin(login.loginID) }
        await Task.yield()
        transport.emit([
            "method": "account/login/completed",
            "params": ["loginId": "login-1", "success": true],
        ])
        try await waiting.value
    }

    func testTextTurnRoutesDeltaAndCompletion() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]],
            "account/read": [Self.account],
            "thread/start": [["thread": ["id": "thread-1"]]],
            "turn/start": [["turn": ["id": "turn-1"]]],
        ])
        let client = CodexAppServerClient(transport: transport)
        let stream = client.stream(ChatCompletionRequest(
            model: "gpt-5.4", system: "Be concise",
            turns: [.user("Hello")], tools: [], maxTokens: 100))
        let collecting = Task { () throws -> (String, Int) in
            var text = ""
            var finishes = 0
            for try await event in stream {
                switch event {
                case .textDelta(let part): text += part
                case .activity: break
                case .finished: finishes += 1
                }
            }
            return (text, finishes)
        }
        try await waitUntil {
            transport.messages.contains {
                $0["method"] as? String == "turn/start"
            }
        }
        transport.emit([
            "method": "item/agentMessage/delta",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1",
                "itemId": "item-1", "delta": "Hello",
            ],
        ])
        transport.emit([
            "method": "turn/completed",
            "params": [
                "threadId": "thread-1",
                "turn": ["id": "turn-1", "status": "completed"],
            ],
        ])
        let result = try await collecting.value
        XCTAssertEqual(result.0, "Hello")
        XCTAssertEqual(result.1, 1)
        let start = try XCTUnwrap(transport.messages.first {
            $0["method"] as? String == "thread/start"
        })
        let params = try XCTUnwrap(start["params"] as? [String: Any])
        XCTAssertEqual(params["approvalPolicy"] as? String, "never")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
    }

    func testBurstNotificationsPreserveTransportOrder() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]],
            "account/read": [Self.account],
            "thread/start": [["thread": ["id": "thread-1"]]],
            "turn/start": [["turn": ["id": "turn-1"]]],
        ])
        let stream = CodexAppServerClient(transport: transport).stream(
            ChatCompletionRequest(
                model: "gpt-5.4", system: "", turns: [.user("Hello")],
                tools: [], maxTokens: 100))
        let collecting = Task { () throws -> String in
            var text = ""
            for try await event in stream {
                if case .textDelta(let part) = event { text += part }
            }
            return text
        }
        try await waitUntil {
            transport.messages.contains {
                $0["method"] as? String == "turn/start"
            }
        }
        for index in 0..<100 {
            transport.emit([
                "method": "item/agentMessage/delta",
                "params": [
                    "threadId": "thread-1", "turnId": "turn-1",
                    "itemId": "item-1", "delta": "\(index),",
                ],
            ])
        }
        transport.emit([
            "method": "turn/completed",
            "params": [
                "threadId": "thread-1",
                "turn": ["id": "turn-1", "status": "completed"],
            ],
        ])

        let result = try await collecting.value
        XCTAssertEqual(result, (0..<100).map { "\($0)," }.joined())
    }

    func testToolItemFailsTheTextOnlyTurn() async throws {
        let transport = ScriptedCodexTransport(responses: [
            "initialize": [[:]], "account/read": [Self.account],
            "thread/start": [["thread": ["id": "thread-1"]]],
            "turn/start": [["turn": ["id": "turn-1"]]],
            "turn/interrupt": [[:]],
        ])
        let stream = CodexAppServerClient(transport: transport).stream(
            ChatCompletionRequest(
                model: "gpt-5.4", system: "", turns: [.user("read a file")],
                tools: [], maxTokens: 100))
        let collecting = Task {
            for try await _ in stream {}
        }
        try await waitUntil {
            transport.messages.contains {
                $0["method"] as? String == "turn/start"
            }
        }
        transport.emit([
            "method": "item/started",
            "params": [
                "threadId": "thread-1", "turnId": "turn-1",
                "item": ["id": "cmd-1", "type": "commandExecution"],
            ],
        ])
        do {
            try await collecting.value
            XCTFail("expected refusal")
        } catch {
            XCTAssertEqual(ChatFault.from(error).reason,
                           "Codex attempted a disabled tool")
        }
    }

    func testLaunchProfileDisablesAgentTools() {
        let arguments = SystemCodexAppServerTransport.arguments
        for feature in [
            "shell_tool", "apps", "browser_use", "in_app_browser",
            "image_generation", "computer_use", "view_image", "multi_agent",
            "skill_search", "hooks",
        ] {
            XCTAssertTrue(arguments.contains(feature), "missing \(feature)")
        }
        XCTAssertTrue(arguments.contains("mcp_servers={}"))
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool,
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<100 where !predicate() {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(predicate(), file: file, line: line)
    }
}
