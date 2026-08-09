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
            ChatOAuthTokens.self, from: XCTUnwrap(store.read(
                .anthropicOAuth, interaction: .allow).data))
        XCTAssertEqual(back, tokens)
        try store.delete(.anthropicOAuth)
        XCTAssertEqual(
            store.read(.anthropicOAuth, interaction: .allow), .missing)
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

    func testOperationCacheReadsOnlyUsedCredentialsAndOnlyOnce() {
        let source = RecordingChatCredentialStore(values: [
            .anthropicOAuth: .value(Data("oauth".utf8)),
        ])
        let cache = OperationChatCredentialStore(
            source: source, interaction: .forbid)

        XCTAssertTrue(source.reads.isEmpty)
        XCTAssertEqual(
            cache.read(.anthropicOAuth, interaction: .allow),
            .value(Data("oauth".utf8)))
        XCTAssertEqual(
            cache.read(.anthropicOAuth, interaction: .forbid),
            .value(Data("oauth".utf8)))
        XCTAssertEqual(source.reads.count, 1)
        XCTAssertEqual(source.reads.first?.0, .anthropicOAuth)
        XCTAssertEqual(source.reads.first?.1, .forbid)
    }

    func testAuthorizationRequirementIsNotCollapsedIntoMissingCredential() {
        let source = RecordingChatCredentialStore(values: [
            .anthropicOAuth: .authorizationRequired,
        ])
        let cache = OperationChatCredentialStore(
            source: source, interaction: .forbid)

        XCTAssertEqual(
            cache.read(.anthropicOAuth, interaction: .forbid),
            .authorizationRequired)
        XCTAssertFalse(cache.read(.anthropicOAuth, interaction: .forbid)
            .isAvailable)
    }
}

final class RecordingChatCredentialStore: ChatCredentialStore,
    @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ChatCredentialKey: ChatCredentialRead]
    private var recordedReads: [
        (ChatCredentialKey, ChatCredentialInteraction)
    ] = []

    var reads: [(ChatCredentialKey, ChatCredentialInteraction)] {
        lock.withLock { recordedReads }
    }

    init(values: [ChatCredentialKey: ChatCredentialRead] = [:]) {
        self.values = values
    }

    func read(_ key: ChatCredentialKey, interaction: ChatCredentialInteraction)
        -> ChatCredentialRead {
        lock.withLock {
            recordedReads.append((key, interaction))
            return values[key] ?? .missing
        }
    }

    func write(_ key: ChatCredentialKey, _ data: Data) throws {
        lock.withLock { values[key] = .value(data) }
    }

    func delete(_ key: ChatCredentialKey) throws {
        lock.withLock { values[key] = .missing }
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

final class ChatWireTextTests: XCTestCase {
    func testLabelsLeaveConvertedAndBounded() {
        XCTAssertEqual(ChatWireText.label("Claude Opus 5"), "Claude Opus 5")
        XCTAssertLessThanOrEqual(
            ChatWireText.label(String(repeating: "x", count: 60)).count, 31)
    }
}
