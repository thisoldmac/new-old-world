import XCTest

@testable import Host

/* The providers against a scripted transport: request bodies in each
   dialect and stream assembly back out of each dialect. No network. */

final class FakeChatTransport: ChatHTTPTransport, @unchecked Sendable {
    struct Scripted {
        var status = 200
        var data = Data()
        var lines: [String] = []
    }

    private let lock = NSLock()
    private var script: [Scripted]
    private(set) var requests: [URLRequest] = []

    init(_ script: [Scripted]) {
        self.script = script
    }

    private func next(_ request: URLRequest) -> Scripted {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
        return script.isEmpty ? Scripted() : script.removeFirst()
    }

    private func response(_ request: URLRequest, _ scripted: Scripted)
        -> HTTPURLResponse {
        HTTPURLResponse(
            url: request.url!, statusCode: scripted.status,
            httpVersion: nil, headerFields: nil)!
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let scripted = next(request)
        return (scripted.data, response(request, scripted))
    }

    func streamLines(_ request: URLRequest) async throws
        -> (lines: AsyncThrowingStream<String, Error>, response: HTTPURLResponse) {
        let scripted = next(request)
        let stream = AsyncThrowingStream<String, Error> { continuation in
            for line in scripted.lines { continuation.yield(line) }
            continuation.finish()
        }
        return (stream, response(request, scripted))
    }
}

private func collect(
    _ stream: AsyncThrowingStream<ChatStreamEvent, Error>
) async throws -> (text: String, finish: ChatFinish?) {
    var text = ""
    var finish: ChatFinish?
    for try await event in stream {
        switch event {
        case .textDelta(let part): text += part
        case .activity: break
        case .finished(let f): finish = f
        }
    }
    return (text, finish)
}

final class AnthropicProviderTests: XCTestCase {
    private func provider(_ transport: FakeChatTransport)
        -> (AnthropicChatProvider, InMemoryChatCredentialStore) {
        let store = InMemoryChatCredentialStore()
        try? store.writeString(.anthropicAPIKey, "sk-test")
        return (
            AnthropicChatProvider(store: store, transport: transport), store
        )
    }

    func testStreamAssemblesTextAndWholeToolCalls() async throws {
        let transport = FakeChatTransport([
            .init(lines: [
                "event: message_start",
                "data: {\"type\":\"message_start\"}",
                "",
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Look\"}}",
                "",
                "event: content_block_start",
                "data: {\"type\":\"content_block_start\",\"index\":1,\"content_block\":{\"type\":\"tool_use\",\"id\":\"tu_1\",\"name\":\"now_observe_elements\"}}",
                "",
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"{\\\"scope\\\":\"}}",
                "",
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":1,\"delta\":{\"type\":\"input_json_delta\",\"partial_json\":\"\\\"front\\\"}\"}}",
                "",
                "event: message_delta",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"tool_use\"}}",
                "",
                "event: message_stop",
                "data: {\"type\":\"message_stop\"}",
                "",
            ])
        ])
        let (provider, _) = provider(transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "claude-opus-5", system: "s", turns: [.user("hi")],
            tools: [], maxTokens: 1024)))
        XCTAssertEqual(out.text, "Look")
        guard case .toolUse(let calls) = out.finish else {
            return XCTFail("expected toolUse, got \(String(describing: out.finish))")
        }
        XCTAssertEqual(calls.count, 1)
        XCTAssertEqual(calls[0].id, "tu_1")
        XCTAssertEqual(calls[0].name, "now_observe_elements")
        XCTAssertEqual(calls[0].argumentsJSON, "{\"scope\":\"front\"}")
    }

    func testAnthropicChunksWithoutBlankLinesStillStream() async throws {
        // The same tolerance as the OpenAI dialect: a proxy or runtime
        // that drops the blank-line dispatch must not silence a turn.
        let transport = FakeChatTransport([
            .init(lines: [
                "event: content_block_delta",
                "data: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi.\"}}",
                "event: message_delta",
                "data: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}",
            ])
        ])
        let (provider, _) = provider(transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "claude-opus-5", system: "", turns: [.user("hey")],
            tools: [], maxTokens: 64)))
        XCTAssertEqual(out.text, "Hi.")
    }

    func testRequestBodyCarriesTheAnthropicDialect() throws {
        let schema = try JSONSerialization.data(withJSONObject: [
            "type": "object", "properties": ["x": ["type": "string"]],
        ])
        let body = AnthropicChatProvider.body(for: ChatCompletionRequest(
            model: "claude-opus-5", system: "be brief",
            turns: [
                .user("hello"),
                ChatTurn(role: .assistant, content: [
                    .text("checking"),
                    .toolCall(ChatToolCall(
                        id: "tu_9", name: "now_capture_screen",
                        argumentsJSON: "{\"display\":1}")),
                ]),
                ChatTurn(role: .tool, content: [
                    .toolResult(id: "tu_9", text: "ok", imagePNG: Data([1]), isError: false)
                ]),
            ],
            tools: [ChatToolDescriptor(
                name: "now_capture_screen", description: "capture",
                inputSchemaJSON: schema)],
            maxTokens: 2048))
        XCTAssertEqual(body["system"] as? String, "be brief")
        XCTAssertEqual(body["stream"] as? Bool, true)
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 3)
        // The tool turn rides a user message with a tool_result block
        // whose content carries the image.
        XCTAssertEqual(messages[2]["role"] as? String, "user")
        let resultBlock = try XCTUnwrap(
            (messages[2]["content"] as? [[String: Any]])?.first)
        XCTAssertEqual(resultBlock["type"] as? String, "tool_result")
        XCTAssertEqual(resultBlock["tool_use_id"] as? String, "tu_9")
        let inner = try XCTUnwrap(resultBlock["content"] as? [[String: Any]])
        XCTAssertEqual(inner.count, 2)
        XCTAssertEqual(inner[1]["type"] as? String, "image")
        // Tool definitions carry input_schema in this dialect.
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertNotNil(tools[0]["input_schema"])
    }

    func testAuthPrefersAPIKeyAndSendsVersionHeader() async throws {
        let transport = FakeChatTransport([
            .init(data: try JSONSerialization.data(withJSONObject: [
                "data": [["id": "claude-opus-5", "display_name": "Claude Opus 5"]]
            ]))
        ])
        let (provider, _) = provider(transport)
        let models = try await provider.listModels()
        XCTAssertEqual(models.first?.wireID, "anthropic/claude-opus-5")
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    }

    func testLegacyOAuthIsNeverReadWhenAPIKeyWorks() async throws {
        let store = RecordingChatCredentialStore(values: [
            .anthropicOAuth: .authorizationRequired,
            .anthropicAPIKey: .value(Data("sk-fallback".utf8)),
        ])
        let transport = FakeChatTransport([
            .init(data: try JSONSerialization.data(withJSONObject: ["data": []]))
        ])
        let provider = AnthropicChatProvider(store: store, transport: transport)

        _ = try await provider.listModels()
        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(
            request.value(forHTTPHeaderField: "x-api-key"), "sk-fallback")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        let entry = await provider.entry()
        XCTAssertEqual(entry.state, "serving")
        XCTAssertTrue(entry.detail.contains("API key"))
        XCTAssertEqual(store.reads.map(\.0), [
            .anthropicAPIKey, .anthropicAPIKey,
        ])
    }

    func testErrorBodiesSurfaceTheProvidersOwnSentence() async throws {
        let errorJSON = """
            {"type":"error","error":{"type":"invalid_request_error",\
            "message":"This credential is only authorized for use with X"}}
            """
        let transport = FakeChatTransport([
            .init(status: 400, lines: [errorJSON])
        ])
        let store = InMemoryChatCredentialStore()
        try store.writeString(.anthropicAPIKey, "sk-test")
        let provider = AnthropicChatProvider(store: store, transport: transport)
        do {
            _ = try await collect(provider.stream(ChatCompletionRequest(
                model: "m", system: "", turns: [.user("t")],
                tools: [], maxTokens: 64)))
            XCTFail("expected a refusal")
        } catch {
            let (code, reason) = ChatFault.from(error)
            XCTAssertEqual(code, "provider-error")
            XCTAssertTrue(reason.contains("only authorized"),
                          "got: \(reason)")
        }
    }

    func testStatusMapping() {
        func code(_ status: Int) -> String? {
            do {
                try AnthropicChatProvider.checkStatus(HTTPURLResponse(
                    url: URL(string: "https://x")!, statusCode: status,
                    httpVersion: nil, headerFields: nil)!)
                return nil
            } catch {
                return ChatFault.from(error).code
            }
        }
        XCTAssertNil(code(200))
        XCTAssertEqual(code(401), "auth-expired")
        XCTAssertEqual(code(429), "rate-limited")
        XCTAssertEqual(code(529), "provider-error")
    }
}

final class OpenAICompatibleProviderTests: XCTestCase {
    func testStreamAssemblesFragmentedToolCalls() async throws {
        let transport = FakeChatTransport([
            .init(lines: [
                "data: {\"choices\":[{\"delta\":{\"content\":\"On it. \"}}]}",
                "",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"call_a\",\"function\":{\"name\":\"now_list_processes\",\"arguments\":\"{\"}}]}}]}",
                "",
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"function\":{\"arguments\":\"}\"}}]}}]}",
                "",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}",
                "",
                "data: [DONE]",
                "",
            ])
        ])
        let provider = OpenAICompatibleChatProvider.ollama(
            store: InMemoryChatCredentialStore(), transport: transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "llama3", system: "", turns: [.user("ps")],
            tools: [], maxTokens: 512)))
        XCTAssertEqual(out.text, "On it. ")
        guard case .toolUse(let calls) = out.finish else {
            return XCTFail("expected toolUse")
        }
        XCTAssertEqual(calls, [ChatToolCall(
            id: "call_a", name: "now_list_processes", argumentsJSON: "{}")])
    }

    func testStopWithAssembledCallsStillFinishesAsToolUse() async throws {
        // Some local runtimes emit tool calls and then say "stop".
        let transport = FakeChatTransport([
            .init(lines: [
                "data: {\"choices\":[{\"delta\":{\"tool_calls\":[{\"index\":0,\"id\":\"c1\",\"function\":{\"name\":\"f\",\"arguments\":\"{}\"}}]}}]}",
                "",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
                "",
                "data: [DONE]",
                "",
            ])
        ])
        let provider = OpenAICompatibleChatProvider.oMLX(
            store: InMemoryChatCredentialStore(), transport: transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "m", system: "", turns: [.user("x")], tools: [], maxTokens: 64)))
        guard case .toolUse = out.finish else {
            return XCTFail("assembled calls must not be dropped on stop")
        }
    }

    func testBodyCarriesTheOpenAIDialect() throws {
        let body = OpenAICompatibleChatProvider.body(for: ChatCompletionRequest(
            model: "gpt-x", system: "sys",
            turns: [
                .user("hi"),
                ChatTurn(role: .assistant, content: [
                    .toolCall(ChatToolCall(
                        id: "c9", name: "f", argumentsJSON: "{\"a\":1}"))
                ]),
                ChatTurn(role: .tool, content: [
                    .toolResult(id: "c9", text: "done", imagePNG: Data([9]), isError: true)
                ]),
            ],
            tools: [ChatToolDescriptor(
                name: "f", description: "d",
                inputSchemaJSON: try JSONSerialization.data(
                    withJSONObject: ["type": "object"]))],
            maxTokens: 128))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[2]["role"] as? String, "assistant")
        let calls = try XCTUnwrap(messages[2]["tool_calls"] as? [[String: Any]])
        XCTAssertEqual(
            (calls[0]["function"] as? [String: Any])?["arguments"] as? String,
            "{\"a\":1}")
        // Tool results are their own wire messages; images degrade to
        // a note in this dialect.
        XCTAssertEqual(messages[3]["role"] as? String, "tool")
        XCTAssertEqual(messages[3]["tool_call_id"] as? String, "c9")
        XCTAssertTrue(
            (messages[3]["content"] as? String)?.contains("image result omitted")
                == true)
        let tools = try XCTUnwrap(body["tools"] as? [[String: Any]])
        XCTAssertEqual(tools[0]["type"] as? String, "function")
    }

    func testLocalProbeReportsServingWithModelCountOrNothingAnswering() async throws {
        let serving = FakeChatTransport([
            .init(data: try JSONSerialization.data(withJSONObject: [
                "data": [["id": "llama3"], ["id": "qwen"]]
            ]))
        ])
        let up = OpenAICompatibleChatProvider.ollama(
            store: InMemoryChatCredentialStore(), transport: serving)
        let live = await up.entry()
        XCTAssertEqual(live.state, "serving")
        XCTAssertTrue(live.detail.contains("2 models"))
        XCTAssertTrue(live.detail.contains("11434"))

        let dead = OpenAICompatibleChatProvider.lmStudio(
            store: InMemoryChatCredentialStore(),
            transport: FakeChatTransport([.init(status: 502)]))
        let down = await dead.entry()
        XCTAssertEqual(down.state, "unavailable")
        XCTAssertTrue(down.detail.contains("1234"))
    }

    func testNonSSEWholeBodyAnswerStillArrives() async throws {
        // A runtime that ignores stream:true and answers one JSON body
        // (metal, 2026-08-02: oMLX spun the GPU and nothing arrived).
        let whole = """
            {"choices":[{"message":{"content":"Hello from a whole body"},\
            "finish_reason":"stop"}]}
            """
        let transport = FakeChatTransport([.init(lines: [whole])])
        let provider = OpenAICompatibleChatProvider.oMLX(
            store: InMemoryChatCredentialStore(), transport: transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "qwen", system: "", turns: [.user("hi")],
            tools: [], maxTokens: 64)))
        XCTAssertEqual(out.text, "Hello from a whole body")
        guard case .endTurn = out.finish else {
            return XCTFail("expected endTurn")
        }
    }

    func testAnAnswerWithNothingReadableIsAnError() async throws {
        let transport = FakeChatTransport([
            .init(lines: ["this is not json and not sse"])
        ])
        let provider = OpenAICompatibleChatProvider.ollama(
            store: InMemoryChatCredentialStore(), transport: transport)
        do {
            _ = try await collect(provider.stream(ChatCompletionRequest(
                model: "m", system: "", turns: [.user("x")],
                tools: [], maxTokens: 64)))
            XCTFail("expected provider-error")
        } catch {
            let (code, reason) = ChatFault.from(error)
            XCTAssertEqual(code, "provider-error")
            // The refusal quotes what actually arrived.
            XCTAssertTrue(reason.contains("not json and not sse"),
                          "got: \(reason)")
        }
    }

    func testChunksWithoutBlankLineSeparatorsStillStream() async throws {
        // oMLX streams data lines with NO blank-line dispatch and
        // interleaves keepalive chunks (metal, 2026-08-02 - copied
        // from the error the raw-snippet diagnostics captured).
        let transport = FakeChatTransport([
            .init(lines: [
                "data: {\"object\":\"chat.completion.chunk\",\"model\":\"keepalive\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"\"},\"finish_reason\":null}]}",
                "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Hel\"},\"finish_reason\":null}]}",
                "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{\"content\":\"lo.\"},\"finish_reason\":null}]}",
                "data: {\"object\":\"chat.completion.chunk\",\"choices\":[{\"index\":0,\"delta\":{},\"finish_reason\":\"stop\"}]}",
                "data: [DONE]",
            ])
        ])
        let provider = OpenAICompatibleChatProvider.oMLX(
            store: InMemoryChatCredentialStore(), transport: transport)
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "qwen", system: "", turns: [.user("hi")],
            tools: [], maxTokens: 64)))
        XCTAssertEqual(out.text, "Hello.")
        guard case .endTurn = out.finish else {
            return XCTFail("expected endTurn")
        }
    }

    func testAnEmptyAnswerWithToolsRetriesOnceWithoutThem() async throws {
        // A local model that returns an empty message when handed tool
        // schemas gets one retry with the tools stripped (metal,
        // 2026-08-02: oMLX's whole answer was "").
        let empty = """
            {"choices":[{"message":{"content":""},"finish_reason":"stop"}]}
            """
        let transport = FakeChatTransport([
            .init(lines: [empty]),
            .init(lines: [
                "data: {\"choices\":[{\"delta\":{\"content\":\"Second try.\"}}]}",
                "",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
                "",
                "data: [DONE]",
                "",
            ]),
        ])
        let provider = OpenAICompatibleChatProvider.oMLX(
            store: InMemoryChatCredentialStore(), transport: transport)
        let schema = try JSONSerialization.data(
            withJSONObject: ["type": "object"])
        let out = try await collect(provider.stream(ChatCompletionRequest(
            model: "qwen", system: "", turns: [.user("hi")],
            tools: [ChatToolDescriptor(
                name: "f", description: "d", inputSchemaJSON: schema)],
            maxTokens: 64)))
        XCTAssertEqual(out.text, "Second try.")
        XCTAssertEqual(transport.requests.count, 2)
        let retryBody = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: XCTUnwrap(transport.requests[1].httpBody))
                as? [String: Any])
        XCTAssertNil(retryBody["tools"], "the retry strips the tools")
    }

    func testStoredKeyIsReadOnceAcrossToolFallbackRetry() async throws {
        let empty = """
            {"choices":[{"message":{"content":""},"finish_reason":"stop"}]}
            """
        let transport = FakeChatTransport([
            .init(lines: [empty]),
            .init(lines: [
                "data: {\"choices\":[{\"delta\":{\"content\":\"Second try.\"}}]}",
                "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}",
                "data: [DONE]",
            ]),
        ])
        let store = RecordingChatCredentialStore(values: [
            .openAIAPIKey: .value(Data("sk-test".utf8)),
        ])
        let provider = OpenAICompatibleChatProvider.openAI(
            store: store, transport: transport)
        let schema = try JSONSerialization.data(
            withJSONObject: ["type": "object"])

        _ = try await collect(provider.stream(ChatCompletionRequest(
            model: "gpt", system: "", turns: [.user("hi")],
            tools: [ChatToolDescriptor(
                name: "f", description: "d", inputSchemaJSON: schema)],
            maxTokens: 64)))

        XCTAssertEqual(store.reads.count, 1)
        XCTAssertEqual(store.reads.first?.0, .openAIAPIKey)
        XCTAssertEqual(store.reads.first?.1, .forbid)
        XCTAssertTrue(transport.requests.allSatisfy {
            $0.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test"
        })
    }

    func testUnreadableAnswersQuoteThemselvesAndFastAPIDetails() async throws {
        // Without tools there is nothing to retry: the refusal quotes
        // what actually arrived.
        let transport = FakeChatTransport([
            .init(lines: ["<html>proxy said what</html>"])
        ])
        let provider = OpenAICompatibleChatProvider.ollama(
            store: InMemoryChatCredentialStore(), transport: transport)
        do {
            _ = try await collect(provider.stream(ChatCompletionRequest(
                model: "m", system: "", turns: [.user("x")],
                tools: [], maxTokens: 64)))
            XCTFail("expected provider-error")
        } catch {
            XCTAssertTrue(ChatFault.from(error).reason.contains("proxy said what"))
        }
        // FastAPI's {"detail":[{"msg":...}]} is a sentence, not noise.
        XCTAssertEqual(
            AnthropicChatProvider.errorMessage(in: Data("""
                {"detail":[{"msg":"max_tokens too large","loc":["body"]}]}
                """.utf8)),
            "max_tokens too large")
        XCTAssertEqual(
            AnthropicChatProvider.errorMessage(
                in: Data("{\"detail\":\"model not loaded\"}".utf8)),
            "model not loaded")
    }

    func testOMLXSendsItsStockBearer() async throws {
        let transport = FakeChatTransport([
            .init(data: try JSONSerialization.data(withJSONObject: ["data": []]))
        ])
        let provider = OpenAICompatibleChatProvider.oMLX(
            store: InMemoryChatCredentialStore(), transport: transport)
        _ = try await provider.listModels()
        XCTAssertEqual(
            transport.requests.first?.value(forHTTPHeaderField: "Authorization"),
            "Bearer omlx-api")
    }

    func testOpenAIWithoutKeyReportsAndRefusesLocally() async {
        let provider = OpenAICompatibleChatProvider.openAI(
            store: InMemoryChatCredentialStore(), transport: FakeChatTransport([]))
        let entry = await provider.entry()
        XCTAssertEqual(entry.state, "unavailable")
        do {
            _ = try await provider.listModels()
            XCTFail("expected no-credentials")
        } catch {
            XCTAssertEqual(ChatFault.from(error).code, "no-credentials")
        }
    }
}
