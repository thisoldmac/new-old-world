import Foundation

/* One implementation, four registrations: OpenAI itself (API key),
   and the local runtimes that speak its dialect — Ollama, LM Studio,
   and oMLX. A local runtime's entry() probes its port with a short
   deadline: "serving (12 models)" or "nothing answering at
   localhost:11434" is a report, not an error, and the probe is what
   makes configuration zero. */

final class OpenAICompatibleChatProvider: ChatProvider, @unchecked Sendable {
    enum Auth: Sendable {
        /// Key read from the credential store per request; a provider
        /// with an empty key reports itself unavailable.
        case storedKey(ChatCredentialKey)
        /// Fixed token some local runtimes expect (oMLX ships with
        /// "omlx-api" — a default, not a secret).
        case fixedBearer(String)
        case none
    }

    let id: String
    let label: String
    private let base: URL
    private let auth: Auth
    /// Local runtimes get probed; remote services with keys do not
    /// (an entry() that costs a network round trip to a paid API on
    /// every page draw would be rude).
    private let probes: Bool
    private let store: ChatCredentialStore
    private let transport: ChatHTTPTransport

    init(
        id: String, label: String, base: URL, auth: Auth, probes: Bool,
        store: ChatCredentialStore,
        transport: ChatHTTPTransport = URLSessionChatTransport()
    ) {
        self.id = id
        self.label = label
        self.base = base
        self.auth = auth
        self.probes = probes
        self.store = store
        self.transport = transport
    }

    static func openAI(store: ChatCredentialStore, transport: ChatHTTPTransport)
        -> OpenAICompatibleChatProvider {
        OpenAICompatibleChatProvider(
            id: "openai", label: "OpenAI",
            base: URL(string: "https://api.openai.com/v1")!,
            auth: .storedKey(.openAIAPIKey), probes: false,
            store: store, transport: transport)
    }

    static func ollama(store: ChatCredentialStore, transport: ChatHTTPTransport)
        -> OpenAICompatibleChatProvider {
        OpenAICompatibleChatProvider(
            id: "ollama", label: "Ollama",
            base: URL(string: "http://127.0.0.1:11434/v1")!,
            auth: .none, probes: true, store: store, transport: transport)
    }

    static func lmStudio(store: ChatCredentialStore, transport: ChatHTTPTransport)
        -> OpenAICompatibleChatProvider {
        OpenAICompatibleChatProvider(
            id: "lmstudio", label: "LM Studio",
            base: URL(string: "http://127.0.0.1:1234/v1")!,
            auth: .none, probes: true, store: store, transport: transport)
    }

    static func oMLX(store: ChatCredentialStore, transport: ChatHTTPTransport)
        -> OpenAICompatibleChatProvider {
        OpenAICompatibleChatProvider(
            id: "omlx", label: "oMLX",
            base: URL(string: "http://127.0.0.1:8000/v1")!,
            auth: .fixedBearer("omlx-api"), probes: true,
            store: store, transport: transport)
    }

    private func authorize(_ request: inout URLRequest) throws {
        switch auth {
        case .storedKey(let key):
            guard let value = store.readString(key), !value.isEmpty else {
                throw ChatFault.refuse(code: "no-credentials", reason: "No API key")
            }
            request.setValue("Bearer \(value)", forHTTPHeaderField: "Authorization")
        case .fixedBearer(let token):
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        case .none:
            break
        }
    }

    func entry() async -> ChatProviderEntry {
        if case .storedKey(let key) = auth {
            let hasKey = !(store.readString(key) ?? "").isEmpty
            return ChatProviderEntry(
                id: id, label: label,
                state: hasKey ? "serving" : "unavailable",
                detail: hasKey ? "Using an API key" : "No API key")
        }
        guard probes else {
            return ChatProviderEntry(
                id: id, label: label, state: "serving", detail: "")
        }
        do {
            let models = try await listModels()
            let count = models.count == 1 ? "1 model" : "\(models.count) models"
            return ChatProviderEntry(
                id: id, label: label, state: "serving",
                detail: "Running at \(hostPort) (\(count))")
        } catch {
            return ChatProviderEntry(
                id: id, label: label, state: "unavailable",
                detail: "Nothing answering at \(hostPort)")
        }
    }

    private var hostPort: String {
        "\(base.host ?? "localhost"):\(base.port.map(String.init) ?? "443")"
    }

    func listModels() async throws -> [ChatModel] {
        var request = URLRequest(url: base.appendingPathComponent("models"))
        // A probe must answer fast: a page draw is waiting on it.
        request.timeoutInterval = 2
        try authorize(&request)
        let (data, response) = try await transport.send(request)
        guard response.statusCode == 200 else {
            throw ChatFault.refuse(
                code: response.statusCode == 401 ? "auth-expired" : "provider-error",
                reason: "\(label) answered \(response.statusCode)")
        }
        guard
            let object = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            let rows = object["data"] as? [[String: Any]]
        else {
            throw ChatFault.refuse(
                code: "provider-error", reason: "Unreadable model list")
        }
        return rows.compactMap { row in
            guard let modelID = row["id"] as? String else { return nil }
            return ChatModel(
                providerID: id, modelID: modelID, displayName: modelID)
        }
    }

    func stream(_ completion: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.run(completion, into: continuation)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// An answer that produced no text, no calls and no finish. Kept
    /// internal: run() turns it into a retry or a spoken refusal.
    private struct NothingReadable: Error {
        let raw: String
    }

    private func run(
        _ completion: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        do {
            try await attempt(completion, into: continuation)
        } catch let empty as NothingReadable {
            /* Some local models answer NOTHING when handed thirty tool
               schemas their template cannot hold (metal, 2026-08-02:
               oMLX spun the GPU and returned an empty message). One
               retry with the tools stripped rescues the conversation;
               the turn just cannot use tools. */
            guard !completion.tools.isEmpty else {
                throw ChatFault.refuse(
                    code: "provider-error",
                    reason: Self.unreadableReason(label: label, raw: empty.raw))
            }
            let bare = ChatCompletionRequest(
                model: completion.model, system: completion.system,
                turns: completion.turns, tools: [],
                maxTokens: completion.maxTokens)
            do {
                try await attempt(bare, into: continuation)
            } catch let stillEmpty as NothingReadable {
                throw ChatFault.refuse(
                    code: "provider-error",
                    reason: Self.unreadableReason(
                        label: label, raw: stillEmpty.raw))
            }
        }
    }

    /// The refusal a person can act on: the provider's own sentence
    /// when the body carries one, else the first stretch of whatever
    /// it DID answer — "nothing readable" alone taught nobody anything.
    static func unreadableReason(label: String, raw: String) -> String {
        if let said = AnthropicChatProvider.errorMessage(in: Data(raw.utf8)) {
            return "\(label): \(said)"
        }
        let collapsed = raw.replacingOccurrences(
            of: "[\\s]+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else {
            return "\(label) answered an empty body"
        }
        return "\(label) answered something unreadable: "
            + String(collapsed.prefix(160))
    }

    private func attempt(
        _ completion: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        var request = URLRequest(
            url: base.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try authorize(&request)
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.body(for: completion))

        let (lines, response) = try await transport.streamLines(request)
        guard response.statusCode == 200 else {
            var body = ""
            for try await line in lines {
                body += line
                if body.count > 4096 { break }
            }
            let said = AnthropicChatProvider.errorMessage(in: Data(body.utf8))
            throw ChatFault.refuse(
                code: response.statusCode == 401 || response.statusCode == 403
                    ? "auth-expired"
                    : response.statusCode == 429 ? "rate-limited" : "provider-error",
                reason: said.map { "\(label): \($0)" }
                    ?? "\(label) answered \(response.statusCode)")
        }

        var parser = ServerSentEventParser()
        var accumulator = OpenAIToolCallAccumulator()
        var finishReason: String?
        var yieldedText = false
        /* Some runtimes ignore stream:true and answer one JSON body.
           Everything is kept (bounded) so a stream that produced no SSE
           events can be re-read as that body — metal, 2026-08-02: oMLX
           accepted a turn, spun the GPU, and nothing arrived, because
           the whole answer was one line no SSE parser would touch. */
        var raw = ""

        for try await line in lines {
            if raw.count < 1_048_576 {
                raw += line
                raw += "\n"
            }
            guard let event = parser.feed(line) else { continue }
            if event.data == "[DONE]" { break }
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: Data(event.data.utf8)) as? [String: Any],
                let choices = object["choices"] as? [[String: Any]],
                let choice = choices.first
            else { continue }
            if let reason = choice["finish_reason"] as? String {
                finishReason = reason
            }
            guard let delta = choice["delta"] as? [String: Any] else { continue }
            if let text = delta["content"] as? String, !text.isEmpty {
                yieldedText = true
                continuation.yield(.textDelta(text))
            }
            if let fragments = delta["tool_calls"] as? [[String: Any]] {
                for fragment in fragments {
                    accumulator.feed(fragment)
                }
            }
        }

        var calls = accumulator.calls()
        if !yieldedText && calls.isEmpty {
            let (text, wholeCalls, reason) = Self.wholeBodyCompletion(raw)
            if let text, !text.isEmpty {
                yieldedText = true
                continuation.yield(.textDelta(text))
            }
            if !wholeCalls.isEmpty {
                calls = wholeCalls
            }
            if reason != nil {
                finishReason = reason
            }
            if !yieldedText && calls.isEmpty {
                /* An empty message with a finish_reason counts too: a
                   model that "finished" saying nothing has answered
                   nothing a person can read. */
                throw NothingReadable(raw: raw)
            }
        }

        switch finishReason {
        case "tool_calls":
            continuation.yield(.finished(.toolUse(calls)))
        case "length":
            continuation.yield(.finished(.truncated("the model hit its output limit")))
        default:
            // Some runtimes say "stop" even after emitting tool calls.
            continuation.yield(.finished(
                calls.isEmpty ? .endTurn : .toolUse(calls)))
        }
    }

    /// One non-streamed chat.completions body, read the whole-message
    /// way: choices[0].message {content, tool_calls}.
    static func wholeBodyCompletion(_ raw: String)
        -> (text: String?, calls: [ChatToolCall], finishReason: String?) {
        guard
            let object = try? JSONSerialization.jsonObject(
                with: Data(raw.utf8)) as? [String: Any],
            let choices = object["choices"] as? [[String: Any]],
            let choice = choices.first
        else { return (nil, [], nil) }
        let message = choice["message"] as? [String: Any] ?? [:]
        let calls = (message["tool_calls"] as? [[String: Any]] ?? [])
            .enumerated().map { index, call -> ChatToolCall in
                let function = call["function"] as? [String: Any] ?? [:]
                return ChatToolCall(
                    id: call["id"] as? String ?? "call_\(index)",
                    name: function["name"] as? String ?? "",
                    argumentsJSON: function["arguments"] as? String ?? "{}")
            }
        return (
            message["content"] as? String,
            calls,
            choice["finish_reason"] as? String
                ?? (calls.isEmpty ? "stop" : "tool_calls")
        )
    }

    // MARK: - Dialect translation

    static func body(for completion: ChatCompletionRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !completion.system.isEmpty {
            messages.append(["role": "system", "content": completion.system])
        }
        for turn in completion.turns {
            messages.append(contentsOf: self.messages(for: turn))
        }
        var body: [String: Any] = [
            "model": completion.model,
            "stream": true,
            "max_tokens": completion.maxTokens,
            "messages": messages,
        ]
        if !completion.tools.isEmpty {
            body["tools"] = completion.tools.map { tool -> [String: Any] in
                [
                    "type": "function",
                    "function": [
                        "name": tool.name,
                        "description": tool.description,
                        "parameters": (try? JSONSerialization.jsonObject(
                            with: tool.inputSchemaJSON)) ?? ["type": "object"],
                    ],
                ]
            }
        }
        return body
    }

    private static func messages(for turn: ChatTurn) -> [[String: Any]] {
        switch turn.role {
        case .user:
            let text = turn.content.compactMap { content -> String? in
                if case .text(let text) = content { return text }
                return nil
            }.joined()
            return [["role": "user", "content": text]]
        case .assistant:
            var text = ""
            var calls: [[String: Any]] = []
            for content in turn.content {
                switch content {
                case .text(let part):
                    text += part
                case .toolCall(let call):
                    calls.append([
                        "id": call.id,
                        "type": "function",
                        "function": [
                            "name": call.name,
                            "arguments": call.argumentsJSON,
                        ],
                    ])
                case .toolResult:
                    break  // never on an assistant turn
                }
            }
            var message: [String: Any] = ["role": "assistant"]
            message["content"] = text.isEmpty ? NSNull() : text
            if !calls.isEmpty { message["tool_calls"] = calls }
            return [message]
        case .tool:
            // One wire message per result; images degrade to a note —
            // this dialect cannot carry them in a tool role.
            return turn.content.compactMap { content -> [String: Any]? in
                guard case .toolResult(let id, let text, let image, _) = content
                else { return nil }
                let suffix = image == nil
                    ? "" : "\n[image result omitted - this provider cannot show images]"
                return [
                    "role": "tool",
                    "tool_call_id": id,
                    "content": text + suffix,
                ]
            }
        }
    }
}

/// The OpenAI dialect fragments tool calls as indexed deltas: the
/// first fragment for an index carries id and name, the rest append
/// argument text.
struct OpenAIToolCallAccumulator {
    private struct Partial {
        var id: String
        var name: String
        var json: String
    }
    private var partials: [Int: Partial] = [:]

    mutating func feed(_ fragment: [String: Any]) {
        let index = fragment["index"] as? Int ?? partials.count
        let function = fragment["function"] as? [String: Any]
        if partials[index] == nil {
            partials[index] = Partial(
                id: fragment["id"] as? String ?? "call_\(index)",
                name: function?["name"] as? String ?? "",
                json: "")
        } else if let id = fragment["id"] as? String, !id.isEmpty {
            partials[index]?.id = id
        }
        if let name = function?["name"] as? String, !name.isEmpty,
            partials[index]?.name.isEmpty == true {
            partials[index]?.name = name
        }
        if let arguments = function?["arguments"] as? String {
            partials[index]?.json += arguments
        }
    }

    func calls() -> [ChatToolCall] {
        partials.sorted { $0.key < $1.key }.map { _, partial in
            ChatToolCall(
                id: partial.id, name: partial.name,
                argumentsJSON: partial.json.isEmpty ? "{}" : partial.json)
        }
    }
}
