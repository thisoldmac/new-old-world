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
            hostExecutable: URL(fileURLWithPath: "/Apps/New Old World"),
            httpEndpoint: { (port: 5254, token: "feedface") })

        for try await _ in client.stream(ChatCompletionRequest(
            model: "sonnet", system: "", turns: [.user("hi")], tools: [],
            maxTokens: 100)) {}

        let request = try XCTUnwrap(runner.requests.first)
        XCTAssertEqual(request.workingDirectory?.standardizedFileURL,
                       root.standardizedFileURL)
        XCTAssertEqual(request.timeout, ChatWorkspaceLaneStore.defaultTimeout)
        XCTAssertEqual(request.arguments.value(after: "--tools"), "default")
        /* The lane rides the HTTP MCP — stdio is sunset. One server, in
           the running host, Bearer-gated; no second app copy, no unix
           socket to stomp. */
        let config = request.arguments.value(after: "--mcp-config") ?? ""
        XCTAssertTrue(config.contains("http://127.0.0.1:5254/mcp"), config)
        XCTAssertTrue(config.contains(
            "Bearer ${\(ChatWorkspaceMCPConfig.bearerEnvironmentKey)}"),
            config)
        XCTAssertTrue(config.contains(
            MCPHTTPWorkspaceGrantAuthority.headerName), config)
        XCTAssertFalse(config.contains("feedface"),
                       "the bearer must not be exposed in argv")
        let grant = try XCTUnwrap(request.environment[
            ChatWorkspaceMCPConfig.workspaceGrantEnvironmentKey])
        XCTAssertFalse(config.contains(grant),
                       "the workspace grant must not be exposed in argv")
        XCTAssertEqual(request.environment[
            ChatWorkspaceMCPConfig.bearerEnvironmentKey], "feedface")
        XCTAssertFalse(config.contains("--mcp-stdio"), config)
    }

    /// A filed conversation works in ITS project's subfolder — one
    /// shared workspace let a turn reuse another project's artifacts
    /// (2026-08-19) — and the root's staged skills stay discoverable
    /// there through the linked .claude.
    func testAProjectTurnWorksInItsOwnSubfolderWithSkillsLinked() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".claude/skills"),
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let lane = ChatWorkspaceLane(
            root: root, permission: .bypassPermissions,
            attachesNOWTools: true, timeout: 900)

        let cwd = ClaudeCodeClient.workingDirectory(
            lane: lane, sub: "test 3")
        XCTAssertEqual(cwd.lastPathComponent, "test 3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cwd.path))
        let linked = cwd.appendingPathComponent(".claude/skills")
        XCTAssertTrue(FileManager.default.fileExists(atPath: linked.path),
                      "the staged skills must reach the subfolder")
        // No subfolder means the root, unchanged.
        XCTAssertEqual(
            ClaudeCodeClient.workingDirectory(lane: lane, sub: nil), root)
        // And the name is made filesystem-safe deterministically.
        XCTAssertEqual(
            ChatHarness.workspaceSubdirectory(for: "a/b:c\0d"), "a-b-c-d")
    }

    /// A CHOSEN folder gets the skills too — the prompt tells every
    /// workspace turn they are staged and to load them itself — but
    /// never by replacing a tree that is already there. That folder is
    /// the person's, and it may be a repository with its own.
    func testAChosenFolderIsStagedOnlyWhenNothingIsThere() throws {
        let manager = FileManager.default
        let mine = manager.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        try manager.createDirectory(at: mine, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: mine) }
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        defaults.set(mine.path, forKey: ChatWorkspaceLaneStore.rootKey)

        _ = ChatWorkspaceLaneStore(defaults: defaults).state()

        let staged = mine.appendingPathComponent(".claude/skills")
        XCTAssertTrue(manager.fileExists(atPath: staged.path),
                      "a chosen folder is promised skills too")

        // Somebody else's tree is theirs: present means left alone.
        let theirs = manager.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        let theirSkills = theirs.appendingPathComponent(".claude/skills")
        try manager.createDirectory(at: theirSkills,
                                    withIntermediateDirectories: true)
        let keepsake = theirSkills.appendingPathComponent("their-own.md")
        try Data("theirs".utf8).write(to: keepsake)
        defer { try? manager.removeItem(at: theirs) }
        let otherDefaults = UserDefaults(
            suiteName: "now.lane.\(UUID().uuidString)")!
        otherDefaults.set(theirs.path, forKey: ChatWorkspaceLaneStore.rootKey)

        _ = ChatWorkspaceLaneStore(defaults: otherDefaults).state()

        XCTAssertEqual(try String(contentsOf: keepsake, encoding: .utf8),
                       "theirs",
                       "NOW replaced a tree it does not own")
    }

    /// A lane turn that will spawn a companion asks for the agent
    /// bridge FIRST — the launch toggle is not a prohibition, and a
    /// desk with it off had every companion answer notSent (2026-08-19).
    func testALaneSpawnAsksForTheAgentBridge() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        defaults.set(root.path, forKey: ChatWorkspaceLaneStore.rootKey)
        let asked = expectation(
            forNotification: ChatWorkspaceMCPConfig.bridgeWanted,
            object: nil)
        let runner = ScriptedChatProcessRunner([[
            "{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false}",
        ]])
        let client = ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:],
            lanes: ChatWorkspaceLaneStore(defaults: defaults),
            httpEndpoint: { (port: 5254, token: "feedface") })

        for try await _ in client.stream(ChatCompletionRequest(
            model: "sonnet", system: "", turns: [.user("hi")], tools: [],
            maxTokens: 100)) {}

        await fulfillment(of: [asked], timeout: 2)
    }

    func testAMissingWorkspaceFolderIsUnusableAndNamesItself() {
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        let store = ChatWorkspaceLaneStore(defaults: defaults)
        /* Explicitly off: with no keys at all the lane self-provisions
           now (the 2026-08-19 default flip); this test is about the
           chosen-folder path. */
        store.setGranted(false)
        XCTAssertEqual(store.state(), .off)

        defaults.set("/nowhere/at/all", forKey: ChatWorkspaceLaneStore.rootKey)
        guard case .unusable(let reason) = store.state() else {
            return XCTFail("a missing folder is not a lane")
        }
        XCTAssertTrue(reason.contains("/nowhere/at/all"), reason)
    }

    /// The frictionless default: OUT OF THE BOX, no folder chosen and
    /// no click given, the lane self-provisions NOW's own workspace at
    /// full tier — the owner's 2026-08-19 decision, overruling the
    /// one-click grant this began as. Only an explicit Turn Off is off.
    func testTheGrantAloneProvisionsTheDefaultWorkspaceAtFullTier() throws {
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        let store = ChatWorkspaceLaneStore(
            defaults: defaults,
            provision: { ChatWorkspaceDefault.provision(support: temporary) })

        guard case .ready = store.state() else {
            return XCTFail("out of the box, the lane provisions itself")
        }

        store.setGranted(false)
        XCTAssertEqual(store.state(), .off,
                       "an explicit Turn Off is the one off there is")

        store.setGranted(true)
        guard case .ready(let lane) = store.state() else {
            return XCTFail("the grant alone must provision the lane")
        }
        XCTAssertEqual(lane.permission, .bypassPermissions,
                       "the grant's sentence is 'build software'")
        XCTAssertTrue(lane.attachesNOWTools)
        XCTAssertEqual(lane.root.lastPathComponent,
                       ChatWorkspaceDefault.folderName)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: lane.root.appendingPathComponent("CLAUDE.md").path),
            "the starter instructions are part of provisioning")

        /* A person's chosen tier still wins over the default. */
        store.setPermission(.acceptEdits)
        guard case .ready(let lowered) = store.state() else {
            return XCTFail("the lane survived a tier change")
        }
        XCTAssertEqual(lowered.permission, .acceptEdits)

        /* An explicit folder wins over the default entirely. */
        defaults.set(temporary.path, forKey: ChatWorkspaceLaneStore.rootKey)
        guard case .ready(let chosen) = store.state() else {
            return XCTFail("an explicit folder is a lane")
        }
        XCTAssertEqual(chosen.root.standardizedFileURL.path,
                       URL(fileURLWithPath: temporary.path).standardizedFileURL.path)
    }

    /// Provisioning stages the shipped skills where the runtime reads
    /// them natively, once per app version, and never rewrites a
    /// CLAUDE.md the person edited.
    func testProvisioningStagesSkillsAndKeepsThePersonsEdits() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-lane-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }

        let root = try XCTUnwrap(
            ChatWorkspaceDefault.provision(support: temporary))
        let staged = root.appendingPathComponent(".claude/skills")
        XCTAssertTrue(FileManager.default.fileExists(atPath: staged.path),
                      "the shipped skills reach the runtime natively")
        let skills = try FileManager.default.contentsOfDirectory(atPath: staged.path)
            .filter { !$0.hasPrefix(".") }
        XCTAssertFalse(skills.isEmpty, "an empty staging is a broken copy")

        let claudeMD = root.appendingPathComponent("CLAUDE.md")
        try "the person's own words".data(using: .utf8)!.write(to: claudeMD)
        _ = ChatWorkspaceDefault.provision(support: temporary)
        XCTAssertEqual(try String(contentsOf: claudeMD, encoding: .utf8),
                       "the person's own words",
                       "re-provisioning must not rewrite edited instructions")
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
        /* Lane explicitly off: since the 2026-08-19 default flip, a
           store with no keys provisions the real default workspace, and
           this test is about the text-only translation. */
        let defaults = UserDefaults(suiteName: "now.lane.\(UUID().uuidString)")!
        defaults.set(false, forKey: ChatWorkspaceLaneStore.grantKey)
        let client = ClaudeCodeClient(
            runner: runner, executable: executable, environment: [:],
            lanes: ChatWorkspaceLaneStore(defaults: defaults))
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
