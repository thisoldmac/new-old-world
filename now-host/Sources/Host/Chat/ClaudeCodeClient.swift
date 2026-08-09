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

    init(
        runner: ChatSubprocessRunning = SystemChatSubprocessRunner(),
        executable: URL? = ChatRuntimeLocator.executable(named: "claude"),
        environment: [String: String] = ChatSubprocessEnvironment.minimal()
    ) {
        self.runner = runner
        self.executable = executable
        self.environment = environment
    }

    func status() async -> Result<ClaudeRuntimeStatus, ChatFault> {
        guard let executable else {
            return .failure(.refuse(
                code: "unreachable", reason: "Claude Code is not installed"))
        }
        do {
            var object: [String: Any]?
            for try await line in runner.stdoutLines(ChatSubprocessRequest(
                executable: executable,
                arguments: ["auth", "status", "--json"],
                standardInput: nil, timeout: 10,
                environment: environment, workingDirectory: nil
            )) where !line.isEmpty {
                object = try JSONSerialization.jsonObject(
                    with: Data(line.utf8)) as? [String: Any]
            }
            guard let object else {
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
        let request = ChatSubprocessRequest(
            executable: executable,
            arguments: Self.arguments(model: completion.model),
            standardInput: Data(Self.prompt(completion).utf8),
            timeout: 180,
            environment: environment,
            workingDirectory: FileManager.default.temporaryDirectory)
        let source = runner.stdoutLines(request)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var finished = false
                do {
                    for try await line in source where !line.isEmpty {
                        switch try Self.event(line: line) {
                        case .some(.finished):
                            guard !finished else { continue }
                            finished = true
                            continuation.yield(.finished(.endTurn))
                        case .some(let event):
                            continuation.yield(event)
                        case .none:
                            break
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

    static func arguments(model: String) -> [String] {
        [
            "-p", "--output-format", "stream-json", "--verbose",
            "--include-partial-messages", "--safe-mode", "--tools", "",
            "--permission-mode", "dontAsk", "--no-session-persistence",
            "--setting-sources", "", "--model", model,
        ]
    }

    static func prompt(_ completion: ChatCompletionRequest) -> String {
        var sections = [
            "<system>\n\(completion.system)\n</system>",
            "Answer as a text-only chat assistant. Do not use tools.",
        ]
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

    static func event(line: String) throws -> ChatStreamEvent? {
        guard let object = try JSONSerialization.jsonObject(
            with: Data(line.utf8)) as? [String: Any],
            let type = object["type"] as? String
        else { return nil }
        if type == "stream_event",
            let event = object["event"] as? [String: Any],
            event["type"] as? String == "content_block_delta",
            let delta = event["delta"] as? [String: Any],
            delta["type"] as? String == "text_delta",
            let text = delta["text"] as? String, !text.isEmpty {
            return .textDelta(text)
        }
        if type == "result" {
            if object["is_error"] as? Bool == true {
                throw ChatFault.refuse(
                    code: "provider-error", reason: "Claude could not complete")
            }
            return .finished(.endTurn)
        }
        return nil
    }
}

