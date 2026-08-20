import Foundation

struct ClaudeRuntimeStatus: Equatable, Sendable {
    let loggedIn: Bool
    let authMethod: String?
    let email: String?
    let subscriptionType: String?

    var isSubscription: Bool {
        loggedIn && authMethod == "claude.ai"
    }
}

final class ClaudeCodeClient: @unchecked Sendable {
    private let runner: ChatSubprocessRunning
    private let executable: URL?
    private let environment: [String: String]
    private let lanes: ChatWorkspaceLaneStore
    /// This app's own binary, for the MCP server a lane runtime is
    /// handed. Injected so a test can assert the configuration without
    /// depending on where the test bundle happens to live.
    private let hostExecutable: URL?

    init(
        runner: ChatSubprocessRunning = SystemChatSubprocessRunner(),
        executable: URL? = ChatRuntimeLocator.executable(named: "claude"),
        environment: [String: String] = ChatSubprocessEnvironment.minimal(),
        lanes: ChatWorkspaceLaneStore = ChatWorkspaceLaneStore(),
        hostExecutable: URL? = Bundle.main.executableURL
    ) {
        self.runner = runner
        self.executable = executable
        self.environment = environment
        self.lanes = lanes
        self.hostExecutable = hostExecutable
    }

    /// The lane as it stands right now. Asked per turn and per popup
    /// draw, never remembered: a person can point it somewhere else
    /// while the app is open.
    func laneState() -> ChatWorkspaceLaneState { lanes.state() }

    func status() async -> Result<ClaudeRuntimeStatus, ChatFault> {
        guard let executable else {
            return .failure(.refuse(
                code: "unreachable", reason: "Claude Code is not installed"))
        }
        do {
            var document = Data()
            for try await line in runner.stdoutLines(ChatSubprocessRequest(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                standardInput: nil, timeout: 10,
                environment: environment, workingDirectory: nil
            )) {
                document.append(contentsOf: line.utf8)
                document.append(0x0A)
                guard document.count <= 65_536 else {
                    throw ChatFault.refuse(
                        code: "provider-error",
                        reason: "Claude returned an invalid authentication status")
                }
            }
            guard !document.isEmpty,
                let object = try JSONSerialization.jsonObject(with: document)
                    as? [String: Any] else {
                throw ChatFault.refuse(
                    code: "provider-error",
                    reason: "Claude returned no authentication status")
            }
            return .success(ClaudeRuntimeStatus(
                loggedIn: object["loggedIn"] as? Bool ?? false,
                authMethod: object["authMethod"] as? String,
                email: object["email"] as? String,
                subscriptionType: object["subscriptionType"] as? String))
        } catch let fault as ChatFault {
            return .failure(fault)
        } catch {
            return .failure(.refuse(
                code: "unreachable",
                reason: "Claude authentication status is unavailable"))
        }
    }

    func stream(_ completion: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        guard let executable else {
            return AsyncThrowingStream { continuation in
                continuation.finish(throwing: ChatFault.refuse(
                    code: "unreachable", reason: "Claude Code is not installed"))
            }
        }
        let lane = lanes.state().lane
        if lane?.attachesNOWTools == true {
            /* Before the spawn, not after the first refusal: the
               companion's very first ToolSearch can be the turn's first
               action, and a bridge that comes up behind it has already
               cost the turn. */
            NotificationCenter.default.post(
                name: ChatWorkspaceMCPConfig.bridgeWanted, object: nil)
        }
        let request = ChatSubprocessRequest(
            executable: executable,
            arguments: Self.arguments(
                model: completion.model, lane: lane,
                mcpConfig: lane?.attachesNOWTools == true
                    ? ChatWorkspaceMCPConfig.json(
                        executable: hostExecutable,
                        workspaceRoot: lane?.root)
                    : nil),
            standardInput: Data(Self.prompt(completion, lane: lane).utf8),
            timeout: lane?.timeout ?? 180,
            environment: environment,
            /* The lane's directory IS the working directory, so the
               runtime discovers whatever instructions live there the
               same way a person running it in that folder would. Without
               a lane it stays in a temporary directory with nothing in
               it — a text-only turn has no business anywhere else. */
            workingDirectory: lane?.root
                ?? FileManager.default.temporaryDirectory)
        let source = runner.stdoutLines(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var finished = false
                do {
                    for try await line in source where !line.isEmpty {
                        for event in try Self.events(line: line) {
                            if case .finished = event {
                                guard !finished else { continue }
                                finished = true
                                continuation.yield(.finished(.endTurn))
                            } else {
                                continuation.yield(event)
                            }
                        }
                    }
                    guard finished else {
                        throw ChatFault.refuse(
                            code: "provider-error",
                            reason: "Claude ended without a result")
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Without a lane this is the locked-down relay it has always been:
    /// no tools, no customizations, nothing of the person's own
    /// configuration reaching the child.
    ///
    /// With one, the clamps come off DELIBERATELY and one at a time.
    /// `--tools default` gives the runtime its own file and shell tools;
    /// the permission mode is the person's chosen tier, spelled by them
    /// rather than by this file; `--setting-sources project,local` lets
    /// the chosen directory's OWN policy apply — a repository's hooks
    /// are the protection you want here, and the person's global
    /// settings are not the lane's business. `--strict-mcp-config` keeps
    /// every MCP server that is not New Old World out of the turn.
    static func arguments(
        model: String,
        lane: ChatWorkspaceLane? = nil,
        mcpConfig: String? = nil
    ) -> [String] {
        var arguments = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--no-session-persistence",
            "--model", model,
        ]
        guard let lane else {
            arguments += [
                "--safe-mode", "--tools", "", "--permission-mode", "dontAsk",
                "--setting-sources", "",
            ]
            return arguments
        }
        arguments += [
            "--tools", "default",
            "--permission-mode", lane.permission.rawValue,
            "--setting-sources", "project,local",
            "--add-dir", lane.root.path,
        ]
        if let mcpConfig {
            arguments += ["--mcp-config", mcpConfig, "--strict-mcp-config"]
        }
        return arguments
    }

    static func prompt(
        _ completion: ChatCompletionRequest,
        lane: ChatWorkspaceLane? = nil
    ) -> String {
        var sections = ["<system>\n\(completion.system)\n</system>"]
        if lane == nil {
            sections.append(
                "Answer as a text-only chat assistant. Do not use tools.")
        }
        sections.append(contentsOf: completion.turns.map { turn in
            let text = turn.content.compactMap { content -> String? in
                switch content {
                case .text(let text): return text
                case .toolResult(_, let text, _, _): return text
                case .toolCall: return nil
                }
            }.joined(separator: "\n")
            return "<\(turn.role.rawValue)>\n\(text)\n</\(turn.role.rawValue)>"
        })
        return sections.joined(separator: "\n\n")
    }

    /// One line of the runtime's stream-json, in harness vocabulary.
    ///
    /// A list rather than one event because a single assistant message
    /// can carry several tool calls, and a lane turn is mostly tool
    /// calls — they are the only sign of life a person gets while a
    /// build runs. Text arrives ONLY through the partial `stream_event`
    /// deltas; the whole-message copy that follows is deliberately
    /// ignored, or every answer would be said twice.
    static func events(line: String) throws -> [ChatStreamEvent] {
        guard let object = try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return [] }
        if type == "stream_event",
            let event = object["event"] as? [String: Any],
            event["type"] as? String == "content_block_delta",
            let delta = event["delta"] as? [String: Any],
            delta["type"] as? String == "text_delta",
            let text = delta["text"] as? String, !text.isEmpty {
            return [.textDelta(text)]
        }
        if type == "assistant",
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]] {
            return content.compactMap { block in
                guard block["type"] as? String == "tool_use",
                    let name = block["name"] as? String else { return nil }
                return .activity(activity(
                    tool: name, input: block["input"] as? [String: Any]))
            }
        }
        if type == "result" {
            if object["is_error"] as? Bool == true {
                throw ChatFault.refuse(
                    code: "provider-error", reason: "Claude could not complete")
            }
            return [.finished(.endTurn)]
        }
        return []
    }

    /// One line a person reads while it happens. The classic machine
    /// draws this on ONE line of a small screen, so it names the verb
    /// and the nearest thing to a subject the call has — a file's own
    /// name, not its path; a command's first word, not its flags.
    static func activity(tool: String, input: [String: Any]?) -> String {
        /* A New Old World capability arrived through MCP and is named
           `mcp__now__now_list_processes`. The person already knows what
           those are called — this is the same vocabulary the harness
           face shows, and showing the mangled form would make one act
           look like two different things depending on the provider. */
        let mcpPrefix = "mcp__\(ChatWorkspaceMCPConfig.serverName)__"
        if tool.hasPrefix(mcpPrefix) {
            let capability = String(tool.dropFirst(mcpPrefix.count))
            return "Using \(capability.isEmpty ? tool : capability)"
        }
        let subject: String?
        switch tool {
        case "Read", "Edit", "Write", "NotebookEdit":
            subject = (input?["file_path"] as? String).map {
                URL(fileURLWithPath: $0).lastPathComponent
            }
        case "Bash":
            subject = (input?["command"] as? String)?
                .split(separator: " ").first.map(String.init)
        case "Grep", "Glob":
            subject = input?["pattern"] as? String
        /* Measured 2026-08-18 rather than guessed: the runtime hands a
           lane turn its MCP tools DEFERRED, so the first sign of life on
           the guest's status line is the model searching for the
           capability it is about to use. Nameless, that reads as a
           stall on a one-line display. */
        case "ToolSearch":
            subject = (input?["query"] as? String)?
                .replacingOccurrences(of: "select:", with: "")
        default:
            subject = nil
        }
        guard let subject, !subject.isEmpty else { return tool }
        return "\(tool) \(subject)"
    }
}
