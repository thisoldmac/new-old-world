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
        XCTAssertFalse(arguments.contains("--mcp-config"))
        XCTAssertFalse(arguments.joined().contains("private prompt"))
        let prompt = ClaudeCodeClient.prompt(completion)
        XCTAssertTrue(prompt.contains("private prompt"))
        XCTAssertTrue(prompt.contains("Do not use tools"))
    }

    // MARK: - The workspace lane

    private func lane(
        _ permission: ChatWorkspaceLane.Permission = .acceptEdits,
        attaches: Bool = true
    ) -> ChatWorkspaceLane {
        ChatWorkspaceLane(
            root: URL(fileURLWithPath: "/tmp/now-lane", isDirectory: true),
            permission: permission, attachesNOWTools: attaches, timeout: 900)
    }

    func testALaneUnclampsTheRuntimeAndNamesTheWorkspace() {
        let arguments = ClaudeCodeClient.arguments(
            model: "sonnet", lane: lane(.bypassPermissions),
            mcpConfig: ChatWorkspaceMCPConfig.json(
                executable: URL(fileURLWithPath: "/Apps/New Old World"),
                workspaceRoot: URL(fileURLWithPath: "/tmp/now-lane",
                                   isDirectory: true)))

        XCTAssertEqual(arguments.value(after: "--tools"), "default")
        XCTAssertEqual(arguments.value(after: "--permission-mode"),
                       "bypassPermissions")
        XCTAssertEqual(arguments.value(after: "--add-dir"), "/tmp/now-lane")
        // The chosen folder's own policy applies; the person's global
        // configuration is not the lane's business.
        XCTAssertEqual(arguments.value(after: "--setting-sources"),
                       "project,local")
        XCTAssertFalse(arguments.contains("--safe-mode"))
        XCTAssertTrue(arguments.contains("--strict-mcp-config"))
        let config = arguments.value(after: "--mcp-config") ?? ""
        XCTAssertTrue(config.contains("--mcp-stdio"), config)
        XCTAssertTrue(config.contains("/Apps/New Old World"), config)
    }

    func testALaneTurnIsNotToldToAvoidTools() {
        let completion = ChatCompletionRequest(
            model: "sonnet", system: "Be concise",
            turns: [.user("build it")], tools: [], maxTokens: 100)

        XCTAssertFalse(ClaudeCodeClient.prompt(completion, lane: lane())
            .contains("Do not use tools"))
    }

    func testTheLaneDecidesTheWorkingDirectoryAndTheDeadline() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        defaults.set(root.path, forKey: ChatWorkspaceLaneStore.rootKey)
        let runner = ScriptedChatProcessRunner([[
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}",
        ]])
        let client = ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:],
            lanes: ChatWorkspaceLaneStore(defaults: defaults),
            hostExecutable: URL(fileURLWithPath: "/Apps/New Old World"))

        for try await _ in client.stream(ChatCompletionRequest(
            model: "sonnet", system: "", turns: [.user("hi")], tools: [],
            maxTokens: 100)) {}

        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.workingDirectory?.standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(request.timeout, ChatWorkspaceLaneStore.defaultTimeout)
        XCTAssertEqual(request.arguments.value(after: "--tools"), "default")
    }

    func testAMissingWorkspaceFolderIsUnusableAndNamesItself() {
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        let store = ChatWorkspaceLaneStore(defaults: defaults)
        XCTAssertEqual(store.state(), .off)

        defaults.set("/nowhere/at/all", forKey: ChatWorkspaceLaneStore.rootKey)
        guard case .unusable(let reason) = store.state() else {
            return XCTFail("a missing folder is not a lane")
        }
        XCTAssertTrue(reason.contains("/nowhere/at/all"), reason)
    }

    /* Recorded from a real `claude -p --output-format stream-json` run on
       2026-08-18, not composed here: a test that writes the lines it then
       parses tests one half twice. */
    func testRecordedToolUseBecomesOneReadableLineEach() throws {
        let glob = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_01\","
            + "\"name\":\"Glob\",\"input\":{\"pattern\":\"**/note.txt\"}}]}}"
        let read = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"tool_use\",\"id\":\"toolu_02\","
            + "\"name\":\"Read\",\"input\":{\"file_path\":"
            + "\"/now/now-guest-ppc/src/chat/chat_module.c\"}}]}}"
        let text = "{\"type\":\"assistant\",\"message\":{\"role\":\"assistant\","
            + "\"content\":[{\"type\":\"text\",\"text\":\"done\"}]}}"

        XCTAssertEqual(try ClaudeCodeClient.events(line: glob).activityLines,
                       ["Glob **/note.txt"])
        XCTAssertEqual(try ClaudeCodeClient.events(line: read).activityLines,
                       ["Read chat_module.c"])
        /* The whole-message copy of an answer must NOT arrive as text:
           the partial deltas already carried it, and a second copy is
           the answer said twice. */
        XCTAssertTrue(try ClaudeCodeClient.events(line: text).isEmpty)
    }

    /* Both lines recorded from a real lane run on 2026-08-18, driving
       `claude` with exactly the argument vector `arguments(model:lane:
       mcpConfig:)` builds, against a stub MCP server standing in for
       this app. The mangled name and the deferred tool search are what
       the runtime actually emits, not what this side expected. */
    func testNOWCapabilitiesKeepTheirOwnNamesThroughMCP() throws {
        let call = "{\"type\":\"assistant\",\"message\":{\"model\":"
            + "\"claude-sonnet-5\",\"role\":\"assistant\",\"content\":"
            + "[{\"type\":\"tool_use\",\"id\":\"toolu_01SSzz\",\"name\":"
            + "\"mcp__now__now_list_processes\",\"input\":{},"
            + "\"caller\":{\"type\":\"direct\"}}]}}"
        let search = "{\"type\":\"assistant\",\"message\":{\"role\":"
            + "\"assistant\",\"content\":[{\"type\":\"tool_use\",\"id\":"
            + "\"toolu_01WMP6\",\"name\":\"ToolSearch\",\"input\":{\"query\":"
            + "\"select:mcp__now__now_list_processes\",\"max_results\":1}}]}}"

        XCTAssertEqual(try ClaudeCodeClient.events(line: call).activityLines,
                       ["Using now_list_processes"])
        XCTAssertEqual(try ClaudeCodeClient.events(line: search).activityLines,
                       ["ToolSearch mcp__now__now_list_processes"])
        XCTAssertEqual(
            ClaudeCodeClient.activity(
                tool: "Bash", input: ["command": "scripts/build-guests --ppc"]),
            "Bash scripts/build-guests")
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
            case .activity: break
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

    /// A lane spawns this app's own MCP companion under the runtime,
    /// and that companion finds its host by this suffix. Dropped, it
    /// silently reaches whichever host owns the default socket.
    func testMinimalEnvironmentCarriesTheAgentSocketSuffix() {
        let environment = ChatSubprocessEnvironment.minimal(from: [
            "HOME": "/tmp/home", "PATH": "/usr/bin",
            "NOW_AGENT_SOCKET_SUFFIX": "lane-under-test",
        ])

        XCTAssertEqual(environment["NOW_AGENT_SOCKET_SUFFIX"],
                       "lane-under-test")
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

private extension Array where Element == ChatStreamEvent {
    var activityLines: [String] {
        compactMap { if case .activity(let line) = $0 { return line }
                     else { return nil } }
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
