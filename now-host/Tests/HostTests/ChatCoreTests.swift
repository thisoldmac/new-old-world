import XCTest

@testable import Host

/* The chat harness's pure parts: the SSE parser, the credential
   store's seam, and the registry's wire-id arithmetic. Each guard here
   was watched to fail first by breaking the thing it names. */

final class ChatSSEParserTests: XCTestCase {
    private func events(_ lines: [String]) -> [ServerSentEvent] {
        var parser = ServerSentEventParser()
        return lines.compactMap { parser.feed($0) }
    }

    func testAnthropicShapedEventStreamParses() {
        let out = events([
            "event: message_start",
            "data: {\"type\":\"message_start\"}",
            "",
            "event: content_block_delta",
            "data: {\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"Hi\"}}",
            "",
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(out[0].event, "message_start")
        XCTAssertEqual(out[1].event, "content_block_delta")
        XCTAssertTrue(out[1].data.contains("text_delta"))
    }

    func testOpenAIShapedDataOnlyStreamParses() {
        let out = events([
            "data: {\"choices\":[{\"delta\":{\"content\":\"He\"}}]}",
            "",
            "data: [DONE]",
            "",
        ])
        XCTAssertEqual(out.count, 2)
        XCTAssertNil(out[0].event)
        XCTAssertEqual(out[1].data, "[DONE]")
    }

    func testMultiLineDataJoinsWithNewline() {
        let out = events(["data: first", "data: second", ""])
        XCTAssertEqual(out, [ServerSentEvent(event: nil, data: "first\nsecond")])
    }

    func testCommentAndBlankLinesDispatchNothing() {
        XCTAssertEqual(events([": ping", "", "", ": keepalive"]), [])
    }

    func testCarriageReturnsAreStripped() {
        let out = events(["data: hello\r", "\r"])
        XCTAssertEqual(out, [ServerSentEvent(event: nil, data: "hello")])
    }

    func testNoSpaceAfterColonIsLegal() {
        let out = events(["data:tight", ""])
        XCTAssertEqual(out.first?.data, "tight")
    }
}

final class ChatCredentialStoreTests: XCTestCase {
    func testOAuthBlobRoundTripsThroughTheStore() throws {
        let store = InMemoryChatCredentialStore()
        let tokens = ChatOAuthTokens(
            accessToken: "at", refreshToken: "rt",
            expiresAt: Date(timeIntervalSince1970: 2_000_000_000))
        try store.write(.anthropicOAuth, JSONEncoder().encode(tokens))
        let back = try JSONDecoder().decode(
            ChatOAuthTokens.self, from: XCTUnwrap(store.read(.anthropicOAuth)))
        XCTAssertEqual(back, tokens)
        store.delete(.anthropicOAuth)
        XCTAssertNil(store.read(.anthropicOAuth))
    }

    func testExpiryHasAMinuteOfSlack() {
        let live = ChatOAuthTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(3600))
        let nearlyOut = ChatOAuthTokens(
            accessToken: "a", refreshToken: "r",
            expiresAt: Date().addingTimeInterval(30))
        XCTAssertFalse(live.isExpired)
        XCTAssertTrue(nearlyOut.isExpired)
    }
}

final class ChatProviderRegistryTests: XCTestCase {
    private final class StubProvider: ChatProvider, @unchecked Sendable {
        let id: String
        let label: String
        init(id: String) {
            self.id = id
            self.label = id
        }
        func entry() async -> ChatProviderEntry {
            ChatProviderEntry(id: id, label: label, state: "serving", detail: "")
        }
        func listModels() async throws -> [ChatModel] { [] }
        func stream(_ request: ChatCompletionRequest)
            -> AsyncThrowingStream<ChatStreamEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
    }

    func testWireIDSplitsOnTheFirstSlashOnly() throws {
        let registry = ChatProviderRegistry()
        registry.register(StubProvider(id: "ollama"))
        let hit = try XCTUnwrap(registry.resolve(wireID: "ollama/library/llama3:8b"))
        XCTAssertEqual(hit.modelID, "library/llama3:8b")
    }

    func testUnknownProviderAndEmptyModelResolveToNothing() {
        let registry = ChatProviderRegistry()
        registry.register(StubProvider(id: "openai"))
        XCTAssertNil(registry.resolve(wireID: "anthropic/claude-opus-5"))
        XCTAssertNil(registry.resolve(wireID: "openai/"))
        XCTAssertNil(registry.resolve(wireID: "no-slash"))
    }

    func testWireIDRoundTripsThroughChatModel() {
        let model = ChatModel(
            providerID: "anthropic", modelID: "claude-opus-5",
            displayName: "Claude Opus 5")
        XCTAssertEqual(model.wireID, "anthropic/claude-opus-5")
    }
}
