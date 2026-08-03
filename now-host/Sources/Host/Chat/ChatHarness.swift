import Foundation
import NOWAgentIntegration

/* The agentic loop: stream a completion, run the tools the model asked
   for through the projection dispatch, feed the results back, repeat
   until the model is done talking or the turn ceiling stops it. One
   conversation runs at a time per key - the answer sink is one
   transcript, the exec-busy rule - and every tool call goes through
   HostProjectionDispatch with the chat face, so the person's log and
   the Agent page show the model's hands exactly as they show the
   MCP's. */

enum ChatHarnessEvent: Sendable {
    case delta(String)
    case toolStarted(name: String)
    case toolFinished(name: String, ok: Bool)
    case finished(ChatChatOutcome)
}

/// How a turn ended, plus the turns to append to the conversation the
/// caller keeps. `code` uses the contract's chat.result vocabulary.
struct ChatChatOutcome: Sendable {
    let ok: Bool
    let code: String?
    let message: String?
    let appended: [ChatTurn]
}

actor ChatHarness {
    private let registry: ChatProviderRegistry
    private let projections: HostProjectionRegistry
    private let makeClient: @Sendable (String?) -> AgentIntegrationClient
    private let audit: any HostProjectionAuditSink
    private let maxToolTurns: Int
    private let maxTokens: Int
    private var running: [String: Task<Void, Never>] = [:]

    init(
        registry: ChatProviderRegistry,
        projections: HostProjectionRegistry = .hostFaces,
        makeClient: @escaping @Sendable (String?) -> AgentIntegrationClient,
        audit: any HostProjectionAuditSink,
        /* Real work is many rounds: finding an application means paging
           the whole apps inventory, then launching by exact name — and
           12 rounds cut exactly that off on metal (2026-08-02). Each
           round is bounded by the tools themselves; the ceiling is a
           runaway stop, not a budget. */
        maxToolTurns: Int = 40,
        maxTokens: Int = 4096
    ) {
        self.registry = registry
        self.projections = projections
        self.makeClient = makeClient
        self.audit = audit
        self.maxToolTurns = maxToolTurns
        self.maxTokens = maxTokens
    }

    /// Starts one turn. False means a turn is already streaming for
    /// this conversation — the caller's busy refusal, decided here so
    /// the check and the table cannot drift apart.
    @discardableResult
    func run(
        conversation: String,
        wireModelID: String,
        transcript: [ChatTurn],
        addressing selector: String?,
        origin: ChatSystemPrompt.Origin,
        events: @escaping @Sendable (ChatHarnessEvent) -> Void
    ) -> Bool {
        guard running[conversation] == nil else { return false }
        let task = Task {
            await self.turn(
                wireModelID: wireModelID, transcript: transcript,
                selector: selector, origin: origin, events: events)
            await self.finished(conversation)
        }
        running[conversation] = task
        return true
    }

    /// True if a turn was actually cancelled; false is "not-running".
    func cancel(conversation: String) -> Bool {
        guard let task = running.removeValue(forKey: conversation) else {
            return false
        }
        task.cancel()
        return true
    }

    func isRunning(conversation: String) -> Bool {
        running[conversation] != nil
    }

    private func finished(_ conversation: String) {
        running[conversation] = nil
    }

    /// One line per fact, in the person's log — the Logs page is where
    /// a turn that "failed silently" stops being silent (metal,
    /// 2026-08-02: a turn died with nothing anywhere a person looks).
    private nonisolated func log(
        _ level: HostLog.LogLevel, _ message: String
    ) {
        Task { @MainActor in
            HostLog.shared.write(level, "chat", message)
        }
    }

    private func turn(
        wireModelID: String,
        transcript: [ChatTurn],
        selector: String?,
        origin: ChatSystemPrompt.Origin,
        events: @escaping @Sendable (ChatHarnessEvent) -> Void
    ) async {
        guard let (provider, modelID) = registry.resolve(wireID: wireModelID)
        else {
            log(.warn, "turn refused: no provider serves \(wireModelID)")
            events(.finished(ChatChatOutcome(
                ok: false, code: "unknown-model",
                message: "No provider serves \(wireModelID)", appended: [])))
            return
        }
        log(.info, "turn begins: \(wireModelID), "
            + "\(transcript.count) turn(s) of history")
        let client = makeClient(selector)
        let system = ChatSystemPrompt.compose(
            health: await client.sessionHealth(), origin: origin)
        let tools = ChatToolRendering.descriptors(registry: projections)
        let dispatch = HostProjectionDispatch(
            face: .chat, registry: projections, audit: audit)

        var working = transcript
        var appended: [ChatTurn] = []

        for _ in 0..<maxToolTurns {
            var text = ""
            var finish: ChatFinish?
            do {
                let stream = provider.stream(ChatCompletionRequest(
                    model: modelID, system: system, turns: working,
                    tools: tools, maxTokens: maxTokens))
                for try await event in stream {
                    switch event {
                    case .textDelta(let part):
                        text += part
                        events(.delta(part))
                    case .finished(let f):
                        finish = f
                    }
                }
            } catch is CancellationError {
                log(.info, "turn cancelled")
                events(.finished(ChatChatOutcome(
                    ok: false, code: "cancelled", message: nil,
                    appended: appended)))
                return
            } catch {
                let (code, reason) = ChatFault.from(error)
                log(.warn, "turn failed: \(code) - \(reason)")
                events(.finished(ChatChatOutcome(
                    ok: false, code: code, message: reason,
                    appended: appended)))
                return
            }

            /* Cancelling the consumer ends an AsyncThrowingStream
               cleanly rather than by throwing — a cancelled turn must
               not dress up as a finished one. */
            if Task.isCancelled {
                events(.finished(ChatChatOutcome(
                    ok: false, code: "cancelled", message: nil,
                    appended: appended)))
                return
            }

            switch finish {
            case .toolUse(let calls) where !calls.isEmpty:
                var content: [ChatContent] = []
                if !text.isEmpty { content.append(.text(text)) }
                content.append(contentsOf: calls.map { .toolCall($0) })
                let assistant = ChatTurn(role: .assistant, content: content)
                working.append(assistant)
                appended.append(assistant)

                var results: [ChatContent] = []
                for call in calls {
                    if Task.isCancelled {
                        log(.info, "turn cancelled between tools")
                        events(.finished(ChatChatOutcome(
                            ok: false, code: "cancelled", message: nil,
                            appended: appended)))
                        return
                    }
                    events(.toolStarted(name: call.name))
                    let result = await invoke(
                        call, dispatch: dispatch, selector: selector,
                        through: client)
                    if case .toolResult(_, _, _, let isError) = result {
                        log(.info,
                            "tool \(call.name): \(isError ? "declined" : "answered")")
                        events(.toolFinished(name: call.name, ok: !isError))
                    }
                    results.append(result)
                }
                let toolTurn = ChatTurn(role: .tool, content: results)
                working.append(toolTurn)
                appended.append(toolTurn)
                continue

            case .truncated(let reason):
                events(.delta("\n[\(reason)]"))
                fallthrough
            default:
                // endTurn, toolUse with no calls, or a stream that
                // ended without a finish (treated as done).
                if !text.isEmpty {
                    let assistant = ChatTurn(
                        role: .assistant, content: [.text(text)])
                    appended.append(assistant)
                }
                log(.info, "turn done: \(text.count) chars of answer")
                events(.finished(ChatChatOutcome(
                    ok: true, code: nil, message: nil, appended: appended)))
                return
            }
        }

        log(.warn, "turn stopped at the tool ceiling (\(maxToolTurns))")
        events(.finished(ChatChatOutcome(
            ok: false, code: "turn-limit",
            message: "The model kept asking for tools past the ceiling",
            appended: appended)))
    }

    private func invoke(
        _ call: ChatToolCall,
        dispatch: HostProjectionDispatch,
        selector: String?,
        through client: AgentIntegrationClient
    ) async -> ChatContent {
        // A model's JSON is a claim, not a fact: unparseable arguments
        // are a tool error the model reads, never a crash or a dispatch.
        let raw: Any?
        if call.argumentsJSON.isEmpty {
            raw = [String: Any]()
        } else if let object = try? JSONSerialization.jsonObject(
            with: Data(call.argumentsJSON.utf8)) {
            raw = object
        } else {
            return .toolResult(
                id: call.id,
                text: "The tool arguments were not valid JSON",
                imagePNG: nil, isError: true)
        }
        let outcome = await dispatch.invoke(
            call.name,
            arguments: .init(raw: raw),
            guest: selector,
            through: client)
        return ChatToolRendering.toolResult(id: call.id, outcome: outcome)
    }
}

/// The chat face's audit destination: the person's log and the Agent
/// page, through the same one-call composition the local server uses —
/// so the model's tool use is readable exactly where the MCP's is.
struct ChatAuditSink: HostProjectionAuditSink {
    let adapter: AgentIntegrationHostAdapter
    let activity: AgentActivityModel?

    func record(_ event: HostProjectionAuditEvent) async {
        await MainActor.run {
            AgentIntegrationAuditLog.record(
                event,
                drivenGuest: adapter.activeReference()?.id,
                stream: activity)
        }
    }
}
