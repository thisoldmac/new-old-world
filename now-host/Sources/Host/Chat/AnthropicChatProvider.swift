import Foundation

/* Anthropic over its own Messages API. Auth is an API key or the
   subscription sign-in (AnthropicOAuth); when both exist the key wins
   and the entry says which is active. All dialect translation — turns
   to content blocks, SSE events back to harness events — lives here
   and nowhere else. */

final class AnthropicChatProvider: ChatProvider, @unchecked Sendable {
    let id = "anthropic"
    let label = "Anthropic"

    private let store: ChatCredentialStore
    private let transport: ChatHTTPTransport
    private let refresher: AnthropicTokenRefresher
    private let base: URL

    init(
        store: ChatCredentialStore,
        transport: ChatHTTPTransport = URLSessionChatTransport(),
        base: URL = URL(string: "https://api.anthropic.com/v1")!
    ) {
        self.store = store
        self.transport = transport
        self.refresher = AnthropicTokenRefresher(store: store)
        self.base = base
    }

    private enum Auth {
        case apiKey(String)
        case oauth(String)
    }

    private func auth() async throws -> Auth {
        if let key = store.readString(.anthropicAPIKey), !key.isEmpty {
            return .apiKey(key)
        }
        let tokens = try await refresher.liveTokens(transport: transport)
        return .oauth(tokens.accessToken)
    }

    private func request(path: String, auth: Auth) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        switch auth {
        case .apiKey(let key):
            request.setValue(key, forHTTPHeaderField: "x-api-key")
        case .oauth(let token):
            request.setValue(
                "Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(
                AnthropicOAuth.betaHeader, forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    func entry() async -> ChatProviderEntry {
        if let key = store.readString(.anthropicAPIKey), !key.isEmpty {
            return ChatProviderEntry(
                id: id, label: label, state: "serving", detail: "Using an API key")
        }
        if store.read(.anthropicOAuth) != nil {
            return ChatProviderEntry(
                id: id, label: label, state: "serving",
                detail: "Signed in with a Claude subscription")
        }
        return ChatProviderEntry(
            id: id, label: label, state: "unavailable",
            detail: "No API key and not signed in")
    }

    func listModels() async throws -> [ChatModel] {
        let auth = try await auth()
        let (data, response) = try await transport.send(
            request(path: "models", auth: auth))
        try Self.checkStatus(response)
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
                providerID: id, modelID: modelID,
                displayName: row["display_name"] as? String ?? modelID)
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

    private func run(
        _ completion: ChatCompletionRequest,
        into continuation: AsyncThrowingStream<ChatStreamEvent, Error>.Continuation
    ) async throws {
        let auth = try await auth()
        var request = request(path: "messages", auth: auth)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(
            withJSONObject: Self.body(for: completion))

        let (lines, response) = try await transport.streamLines(request)
        try Self.checkStatus(response)

        var parser = ServerSentEventParser()
        var accumulator = ToolCallAccumulator()
        var stopReason: String?

        for try await line in lines {
            guard let event = parser.feed(line) else { continue }
            guard
                let object = try? JSONSerialization.jsonObject(
                    with: Data(event.data.utf8)) as? [String: Any],
                let type = object["type"] as? String
            else { continue }
            switch type {
            case "content_block_start":
                if let index = object["index"] as? Int,
                    let block = object["content_block"] as? [String: Any],
                    block["type"] as? String == "tool_use" {
                    accumulator.begin(
                        index: index,
                        id: block["id"] as? String ?? "",
                        name: block["name"] as? String ?? "")
                }
            case "content_block_delta":
                guard let delta = object["delta"] as? [String: Any] else { break }
                switch delta["type"] as? String {
                case "text_delta":
                    if let text = delta["text"] as? String, !text.isEmpty {
                        continuation.yield(.textDelta(text))
                    }
                case "input_json_delta":
                    if let index = object["index"] as? Int,
                        let part = delta["partial_json"] as? String {
                        accumulator.append(index: index, fragment: part)
                    }
                default:
                    break
                }
            case "message_delta":
                if let delta = object["delta"] as? [String: Any],
                    let reason = delta["stop_reason"] as? String {
                    stopReason = reason
                }
            case "error":
                let message =
                    ((object["error"] as? [String: Any])?["message"] as? String)
                    ?? "provider mid-stream error"
                throw ChatFault.refuse(code: "provider-error", reason: message)
            default:
                break  // message_start, content_block_stop, ping, message_stop
            }
        }

        continuation.yield(.finished(Self.finish(
            stopReason: stopReason, calls: accumulator.calls())))
    }

    static func finish(stopReason: String?, calls: [ChatToolCall]) -> ChatFinish {
        switch stopReason {
        case "tool_use":
            return .toolUse(calls)
        case "max_tokens":
            return .truncated("the model hit its output limit")
        case "refusal":
            return .truncated("the model declined to continue")
        default:
            // A dropped stream with tool calls half-assembled still
            // must not invent a tool_use finish.
            return .endTurn
        }
    }

    static func checkStatus(_ response: HTTPURLResponse) throws {
        switch response.statusCode {
        case 200: return
        case 401, 403:
            throw ChatFault.refuse(
                code: "auth-expired",
                reason: "Anthropic rejected the credentials - sign in again")
        case 429:
            throw ChatFault.refuse(
                code: "rate-limited", reason: "Anthropic is rate limiting - try later")
        default:
            throw ChatFault.refuse(
                code: "provider-error",
                reason: "Anthropic answered \(response.statusCode)")
        }
    }

    // MARK: - Dialect translation

    static func body(for completion: ChatCompletionRequest) -> [String: Any] {
        var body: [String: Any] = [
            "model": completion.model,
            "max_tokens": completion.maxTokens,
            "stream": true,
            "messages": completion.turns.map(message(for:)),
        ]
        if !completion.system.isEmpty {
            body["system"] = completion.system
        }
        if !completion.tools.isEmpty {
            body["tools"] = completion.tools.map { tool -> [String: Any] in
                [
                    "name": tool.name,
                    "description": tool.description,
                    "input_schema": (try? JSONSerialization.jsonObject(
                        with: tool.inputSchemaJSON)) ?? ["type": "object"],
                ]
            }
        }
        return body
    }

    private static func message(for turn: ChatTurn) -> [String: Any] {
        // Tool results ride a user message in this dialect.
        let role = turn.role == .tool ? "user" : turn.role.rawValue
        let blocks = turn.content.map { content -> [String: Any] in
            switch content {
            case .text(let text):
                return ["type": "text", "text": text]
            case .toolCall(let call):
                return [
                    "type": "tool_use",
                    "id": call.id,
                    "name": call.name,
                    "input": (try? JSONSerialization.jsonObject(
                        with: Data(call.argumentsJSON.utf8))) ?? [:],
                ]
            case .toolResult(let id, let text, let imagePNG, let isError):
                var inner: [[String: Any]] = [["type": "text", "text": text]]
                if let png = imagePNG {
                    // The one dialect that can show the model a capture.
                    inner.append([
                        "type": "image",
                        "source": [
                            "type": "base64",
                            "media_type": "image/png",
                            "data": png.base64EncodedString(),
                        ],
                    ])
                }
                return [
                    "type": "tool_result",
                    "tool_use_id": id,
                    "content": inner,
                    "is_error": isError,
                ]
            }
        }
        return ["role": role, "content": blocks]
    }
}

/// Assembles fragmented tool-call input JSON by block index. Both
/// dialects fragment differently; each provider owns its own copy of
/// this small amount of state.
struct ToolCallAccumulator {
    private struct Partial {
        var id: String
        var name: String
        var json: String
    }
    private var partials: [Int: Partial] = [:]

    mutating func begin(index: Int, id: String, name: String) {
        partials[index] = Partial(id: id, name: name, json: "")
    }

    mutating func append(index: Int, fragment: String) {
        partials[index]?.json += fragment
    }

    func calls() -> [ChatToolCall] {
        partials.sorted { $0.key < $1.key }.map { _, partial in
            ChatToolCall(
                id: partial.id, name: partial.name,
                argumentsJSON: partial.json.isEmpty ? "{}" : partial.json)
        }
    }
}
