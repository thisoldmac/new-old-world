import XCTest

@testable import Host

final class ScriptedChatProcessRunner: ChatSubprocessRunning,
    @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[String]]
    private(set) var requests: [ChatSubprocessRequest] = []

    init(_ scripts: [[String]]) { self.scripts = scripts }

    func stdoutLines(_ request: ChatSubprocessRequest)
        -> AsyncThrowingStream<String, Error> {
        let lines = lock.withLock { () -> [String] in
            requests.append(request)
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream(bufferingPolicy: .unbounded) {
            continuation in
            for line in lines { continuation.yield(line) }
            continuation.finish()
        }
    }
}

final class ClaudeCodeClientTests: XCTestCase {
    private let executable = URL(fileURLWithPath: "/usr/bin/true")

    func testStatusReadsPrettyPrintedSubscriptionDocument() async throws {
        let runner = ScriptedChatProcessRunner([[
            "{",
            "  \"loggedIn\": true,",
            "  \"authMethod\": \"claude.ai\",",
            "  \"email\": \"person@example.test\",",
            "  \"subscriptionType\": \"max\",",
            "  \"accessToken\": \"must-not-be-decoded\"",
            "}",
        ]])
        let client = ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:])

        guard case .success(let status) = await client.status() else {
            return XCTFail("expected status")
        }
        XCTAssertTrue(status.isSubscription)
        XCTAssertEqual(status.email, "person@example.test")
        XCTAssertEqual(status.subscriptionType, "max")
        XCTAssertEqual(runner.requests.first?.arguments,
                       ["auth", "status", "--json"])
    }

    func testSubscriptionProviderDoesNotAcceptAPIKeyAuth() async {
        let runner = ScriptedChatProcessRunner([[
            "{\"loggedIn\":true,\"authMethod\":\"api_key\"}",
        ]])
        let provider = ClaudeCodeChatProvider(client: ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:]))

        let entry = await provider.entry()
        XCTAssertEqual(entry.state, "unavailable")
        XCTAssertTrue(entry.detail.contains("api_key"))
    }

    func testLockedDownArgumentsAndPromptStayOffCommandLine() {
        let completion = ChatCompletionRequest(
            model: "sonnet", system: "Be concise",
            turns: [.user("private prompt")], tools: [], maxTokens: 100)
        let arguments = ClaudeCodeClient.arguments(model: completion.model)

        XCTAssertTrue(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--no-session-persistence"))
        XCTAssertEqual(arguments.value(after: "--tools"), "")
        XCTAssertEqual(arguments.value(after: "--setting-sources"), "")
        XCTAssertFalse(arguments.joined().contains("private prompt"))
        XCTAssertTrue(ClaudeCodeClient.prompt(completion)
            .contains("private prompt"))
    }

    func testStreamTranslatesTextAndOneFinish() async throws {
        let runner = ScriptedChatProcessRunner([[
            "{\"type\":\"stream_event\",\"event\":{"
                + "\"type\":\"content_block_delta\",\"delta\":{"
                + "\"type\":\"text_delta\",\"text\":\"Hel\"}}}",
            "{\"type\":\"stream_event\",\"event\":{"
                + "\"type\":\"content_block_delta\",\"delta\":{"
                + "\"type\":\"text_delta\",\"text\":\"lo\"}}}",
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}",
        ]])
        let client = ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:])
        let completion = ChatCompletionRequest(
            model: "sonnet", system: "", turns: [.user("hi")],
            tools: [], maxTokens: 100)

        var text = ""
        var finishes = 0
        for try await event in client.stream(completion) {
            switch event {
            case .textDelta(let part): text += part
            case .finished: finishes += 1
            }
        }
        XCTAssertEqual(text, "Hello")
        XCTAssertEqual(finishes, 1)
        XCTAssertEqual(runner.requests.first?.standardInput,
                       Data(ClaudeCodeClient.prompt(completion).utf8))
    }

    func testSystemRunnerDrainsFastProcessOutputBeforeExit() async throws {
        let runner = SystemChatSubprocessRunner()
        let request = ChatSubprocessRequest(
            executable: URL(fileURLWithPath: "/usr/bin/seq"),
            arguments: ["1", "20000"], standardInput: nil, timeout: 10,
            environment: ChatSubprocessEnvironment.minimal(),
            workingDirectory: nil)
        var lines: [String] = []

        for try await line in runner.stdoutLines(request) {
            lines.append(line)
        }

        XCTAssertEqual(lines.count, 20_000)
        XCTAssertEqual(lines.first, "1")
        XCTAssertEqual(lines.last, "20000")
    }

    func testMinimalEnvironmentStripsProviderSecrets() {
        let environment = ChatSubprocessEnvironment.minimal(from: [
            "HOME": "/tmp/home", "PATH": "/usr/bin",
            "ANTHROPIC_API_KEY": "secret-a", "OPENAI_API_KEY": "secret-o",
            "CODEX_HOME": "/tmp/codex", "CLAUDE_CONFIG_DIR": "/tmp/claude",
            "UNRELATED_SECRET": "secret-u",
        ])

        XCTAssertEqual(environment["HOME"], "/tmp/home")
        XCTAssertEqual(environment["CODEX_HOME"], "/tmp/codex")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/claude")
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["UNRELATED_SECRET"])
    }

    func testMinimalEnvironmentMakesFallbackRuntimeDependenciesVisible() {
        let environment = ChatSubprocessEnvironment.minimal(from: [
            "HOME": "/tmp/home", "PATH": "/usr/bin:/bin",
        ])
        let paths = environment["PATH"]?.split(separator: ":").map(String.init)

        XCTAssertEqual(paths?.prefix(2), ["/usr/bin", "/bin"])
        XCTAssertTrue(paths?.contains("/opt/homebrew/bin") == true)
        XCTAssertTrue(paths?.contains("/usr/local/bin") == true)
    }
}

private extension Array where Element == String {
    func value(after flag: String) -> String? {
        guard let index = firstIndex(of: flag), index + 1 < count else {
            return nil
        }
        return self[index + 1]
    }
}
