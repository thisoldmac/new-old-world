import Foundation
import Network
import XCTest

@testable import Host
@testable import NOWAgentIntegration

/// The chat.* family over a real loopback wire: a guest asks this
/// Mac's model harness and the answers stream back down the connection
/// that asked. The model is a scripted fake — what only a live
/// provider can prove is ledgered, not claimed here.
@MainActor
final class ChatServingTests: XCTestCase {
    private var listener: GuestListener!
    /// Held strongly here: the listener's reference is weak on purpose.
    private var chatService: ChatWireService!
    private var provider: WireScriptedProvider!

    override func setUp() async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func tearDown() async throws {
        if let storeRoot { try? FileManager.default.removeItem(at: storeRoot) }
        store = nil
        storeRoot = nil
        listener.stop()
        listener = nil
        chatService = nil
        provider = nil
    }

    /// A store in a throwaway directory, so a serving test never writes
    /// into the real Application Support — and nil where a test wants
    /// the store-less behaviour on purpose.
    private var store: ChatStore?
    private var storeRoot: URL?

    private func makeStore() -> ChatStore {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-chats-\(UUID().uuidString)")
        storeRoot = root
        // swiftlint:disable:next force_try
        let store = try! ChatStore(root: root)
        self.store = store
        return store
    }

    private func installChat(
        script: [[ChatStreamEvent]], hangsWhenDry: Bool = false,
        heartbeatInterval: TimeInterval = ChatWireService.heartbeat,
        providers: [ChatCatalogProvider] = [
            ChatCatalogProvider(
                provider: "fake", label: "Fake", state: "serving",
                detail: nil)
        ],
        models: [String: [ChatModel]] = [
            "fake": [ChatModel(providerID: "fake", modelID: "m",
                               displayName: "m")]
        ]
    ) {
        _ = makeStore()
        let scripted = WireScriptedProvider(script)
        scripted.hangsWhenDry = hangsWhenDry
        provider = scripted
        let registry = ChatProviderRegistry()
        registry.register(scripted)
        let harness = ChatHarness(
            registry: registry,
            makeClient: { _ in NoHostChatClient() },
            audit: NoOpAuditSink())
        chatService = ChatWireService(
            harness: harness,
            providers: { providers },
            models: { models[$0] },
            store: store,
            heartbeatInterval: heartbeatInterval)
        listener.chatService = chatService
    }

    private func roster(on guest: FakeGuest, id: Int) async throws
        -> ChatRoster {
        try await waitUntil("roster \(id)") {
            guest.received.contains {
                if case .chatRoster(let r) = $0 { return r.id == id }
                return false
            }
        }
        for frame in guest.received.reversed() {
            if case .chatRoster(let r) = frame, r.id == id { return r }
        }
        throw WaitTimeout(what: "roster \(id)")
    }

    private func transcriptPage(on guest: FakeGuest, id: Int) async throws
        -> ChatTranscript {
        try await waitUntil("transcript \(id)") {
            guest.received.contains {
                if case .chatTranscript(let t) = $0 { return t.id == id }
                return false
            }
        }
        for frame in guest.received.reversed() {
            if case .chatTranscript(let t) = frame, t.id == id { return t }
        }
        throw WaitTimeout(what: "transcript \(id)")
    }

    private func projectRoster(on guest: FakeGuest, id: Int) async throws
        -> ChatProjectRoster {
        try await waitUntil("projects \(id)") {
            guest.received.contains {
                if case .chatProjectRoster(let r) = $0 { return r.id == id }
                return false
            }
        }
        for frame in guest.received.reversed() {
            if case .chatProjectRoster(let r) = frame, r.id == id { return r }
        }
        throw WaitTimeout(what: "projects \(id)")
    }

    private struct WaitTimeout: Error { let what: String }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           _ condition: @escaping () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                XCTFail("timed out waiting for \(what)")
                throw WaitTimeout(what: what)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func connectedGuest() async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision,
                                    side: "guest", version: "0.1.0",
                                    name: "PowerBook 1400", os: "9.1",
                                    chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    /// One models page for `provider`, as a guest would ask it.
    private func modelsPage(
        on guest: FakeGuest, provider: String = "fake",
        cursor: Int? = nil, id: Int
    ) async throws -> ChatCatalog {
        try guest.send(.chatModels(ChatModels(
            id: id, provider: provider, cursor: cursor)))
        try await waitUntil("models page #\(id)") {
            guest.received.contains {
                if case .chatCatalog(let c) = $0 { return c.id == id }
                return false
            }
        }
        guard case .chatCatalog(let page)? = guest.received.last(where: {
            if case .chatCatalog(let c) = $0 { return c.id == id }
            return false
        }) else {
            XCTFail("no models page")
            throw WaitTimeout(what: "models page")
        }
        return page
    }

    /// The full ask-then-send dance: mint a ref the way a guest earns
    /// one, because a send without a catalog ask is not a flow the
    /// wire has.
    private func mintedRef(on guest: FakeGuest, id: Int = 1000)
        async throws -> String {
        let page = try await modelsPage(on: guest, id: id)
        guard let ref = page.models?.first?.ref else {
            XCTFail("no model rows to send with")
            throw WaitTimeout(what: "a ref")
        }
        return ref
    }

    private func result(on guest: FakeGuest, id: Int) async throws
        -> ChatResult {
        try await waitUntil("chat.result #\(id)") {
            guest.received.contains {
                if case .chatResult(let r) = $0 { return r.id == id }
                return false
            }
        }
        return guest.received.compactMap {
            if case .chatResult(let r) = $0, r.id == id { return r }
            return nil
        }.last!
    }

    // MARK: - Discovery

    func testProvidersAnswerWithStatesNotModels() async throws {
        installChat(
            script: [],
            providers: [
                ChatCatalogProvider(
                    provider: "fake", label: "Fake", state: "serving",
                    detail: nil),
                ChatCatalogProvider(
                    provider: "omlx", label: "oMLX", state: "unavailable",
                    detail: "Nothing answering at localhost:8000"),
            ])
        let guest = try await connectedGuest()
        try guest.send(.chatModels(ChatModels(id: 7)))
        try await waitUntil("providers catalog") {
            guest.received.contains {
                if case .chatCatalog(let c) = $0 { return c.id == 7 }
                return false
            }
        }
        guard case .chatCatalog(let catalog)? = guest.received.last(where: {
            if case .chatCatalog(let c) = $0 { return c.id == 7 }
            return false
        }) else { return XCTFail("no catalog") }
        XCTAssertEqual(catalog.providers?.map(\.provider),
                       ["fake", "omlx"])
        XCTAssertEqual(catalog.providers?.last?.state, "unavailable")
        XCTAssertNil(catalog.models, "the providers shape carries no models")
    }

    func testModelPagesMintRefsAndTheNameNeverCrosses() async throws {
        // The metal shape: model names longer than any classic buffer.
        let longNames = (0..<20).map {
            "Qwen3.5-122B-A10B-Heretic-v2-MLX-mixed-6bit-variant-\($0)"
        }
        installChat(
            script: [],
            models: ["fake": longNames.map {
                ChatModel(providerID: "fake", modelID: $0, displayName: $0)
            }])
        let guest = try await connectedGuest()

        let first = try await modelsPage(on: guest, id: 20)
        XCTAssertEqual(first.provider, "fake")
        XCTAssertEqual(first.models?.count, 16, "the frame bound")
        XCTAssertEqual(first.more, true)
        let second = try await modelsPage(on: guest, cursor: 16, id: 21)
        XCTAssertEqual(second.models?.count, 4)
        XCTAssertEqual(second.more, false)

        let rows = (first.models ?? []) + (second.models ?? [])
        XCTAssertEqual(Set(rows.map(\.ref)).count, rows.count,
                       "refs never collide")
        for row in rows {
            XCTAssertLessThanOrEqual(row.ref.utf8.count, 8,
                                     "a ref fits any classic buffer")
            XCTAssertLessThanOrEqual(row.label.utf8.count, 31)
        }
        // The provider's own name is nowhere in any served frame.
        for frame in guest.received {
            guard case .chatCatalog = frame else { continue }
            let encoded = try ControlMessageCodec.encode(frame)
            XCTAssertFalse(
                String(decoding: encoded, as: UTF8.self)
                    .contains("Heretic-v2-MLX-mixed-6bit-variant-0"))
        }
    }

    /* The contract obliges the HOST to keep deltas or status flowing
       while a turn is open, and entitles the guest to kill a silent
       turn at sixty seconds. Every tool the harness runs answers in
       seconds, so nothing ever tested it. A workspace lane's single
       `Bash` call is a cross-compile: minutes inside one tool, with the
       runtime saying nothing until it returns — a build dying at sixty
       seconds for looking dead. */
    func testASilentTurnStillSpeaksBeforeTheGuestsDeadline() async throws {
        /* The turn is held open the way a real one is: the provider
           says what it is doing, asks for a tool, and the next round
           never answers — a runtime inside a long `Bash`. */
        installChat(
            script: [[
                .activity("Bash scripts/build-guests"),
                .finished(.toolUse([ChatToolCall(
                    id: "c1", name: "now_machine_facts",
                    argumentsJSON: "{}")])),
            ]],
            hangsWhenDry: true, heartbeatInterval: 0.15)
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)

        try guest.send(.chatSend(ChatSend(id: 40, ref: ref, prompt: "build")))
        try await waitUntil("a repeat of the last thing seen") {
            guest.received.filter {
                if case .chatStatus(let s) = $0 {
                    return s.id == 40 && s.text.hasPrefix("Still:")
                }
                return false
            }.count >= 2
        }

        let lines = guest.received.compactMap { frame -> String? in
            if case .chatStatus(let s) = frame { return s.text }
            return nil
        }
        // The first line is what it is doing; the repeats say the same
        // thing rather than inventing a new claim about the machine.
        XCTAssertEqual(lines.first, "Bash scripts/build-guests")
        XCTAssertTrue(lines.contains { $0.hasPrefix("Still: ") }, "\(lines)")
        // A repeat, never a new claim about the machine.
        for line in lines where line.hasPrefix("Still: ") {
            XCTAssertTrue(
                lines.contains(String(line.dropFirst("Still: ".count))),
                "the heartbeat invented \(line)")
        }
        _ = try? guest.send(.chatCancel(ChatCancel(id: 40)))
    }

    // MARK: - Sessions, lazily

    /// The regression this slice answers: a guest conversation used to
    /// live in a dictionary and die with the link.
    func testAGuestTurnIsSavedAndListedWithItsOrigin() async throws {
        installChat(script: [[.textDelta("hello back"), .finished(.endTurn)]])
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)

        try guest.send(.chatSend(ChatSend(
            id: 50, ref: ref, prompt: "hello from the classic Mac")))
        _ = try await result(on: guest, id: 50)

        try guest.send(.chatChats(ChatChats(id: 51)))
        let roster = try await roster(on: guest, id: 51)
        XCTAssertEqual(roster.chats.count, 1)
        let row = try XCTUnwrap(roster.chats.first)
        XCTAssertEqual(row.origin, "guest")
        XCTAssertEqual(row.current, true)
        XCTAssertEqual(row.label, "hello from the classic Mac")
        // Metadata only: not one byte of what was said.
        let encoded = try ControlMessageCodec.encode(.chatRoster(roster))
        XCTAssertFalse(String(decoding: encoded, as: UTF8.self)
            .contains("hello back"))
    }

    /// A chat typed at the modern Mac is listed to the guest — the
    /// widening decided 2026-08-18 — and it is marked as such.
    func testAHostChatIsListedToTheGuestAndSaysWhereItWasTyped() async throws {
        installChat(script: [])
        let store = try XCTUnwrap(store)
        _ = try store.createChat(title: "typed upstairs", origin: .host)
        let guest = try await connectedGuest()

        try guest.send(.chatChats(ChatChats(id: 60)))
        let roster = try await roster(on: guest, id: 60)

        XCTAssertEqual(roster.chats.map(\.origin), ["host"])
        XCTAssertEqual(roster.chats.first?.label, "typed upstairs")
    }

    /// Opening pushes NOTHING; history pages from the end.
    func testOpeningAChatSendsNoTranscriptAndHistoryPagesFromTheEnd()
        async throws {
        installChat(script: [])
        let store = try XCTUnwrap(store)
        let saved = try store.createChat(title: "long one", origin: .host)
        var transcript = StoredChatTranscript()
        for index in 0..<60 {
            transcript.rows.append(StoredChatRow(
                kind: index.isMultiple(of: 2) ? .person : .model,
                text: "line \(index)", toolName: nil, toolOK: nil))
        }
        _ = try store.saveTranscript(transcript, for: saved.id)
        let guest = try await connectedGuest()
        try guest.send(.chatChats(ChatChats(id: 70)))
        let roster = try await roster(on: guest, id: 70)
        let ref = try XCTUnwrap(roster.chats.first?.ref)

        try guest.send(.chatOpen(ChatOpen(id: 71, ref: ref)))
        let opened = try await result(on: guest, id: 71)
        XCTAssertTrue(opened.ok)
        XCTAssertFalse(
            guest.received.contains { if case .chatTranscript = $0 {
                return true } else { return false } },
            "an open pushed a transcript nobody asked for")

        try guest.send(.chatHistory(ChatHistory(id: 72)))
        let first = try await transcriptPage(on: guest, id: 72)
        XCTAssertEqual(first.rows.count, ChatWireService.historyRows)
        XCTAssertEqual(first.rows.last?.text, "line 59",
                       "the newest page comes first")
        XCTAssertTrue(first.more)

        try guest.send(.chatHistory(ChatHistory(
            id: 73, cursor: first.rows.count)))
        let second = try await transcriptPage(on: guest, id: 73)
        XCTAssertEqual(second.rows.last?.text, "line 35")
    }

    /// The question this product exists to ask must not be answered by
    /// a default.
    func testCreatingAProjectWithoutSayingWhereItLivesIsRefused()
        async throws {
        installChat(script: [])
        let guest = try await connectedGuest()

        try guest.send(.chatProject(ChatProject(
            id: 80, op: "create", name: "Beeper")))
        let refused = try await result(on: guest, id: 80)

        XCTAssertFalse(refused.ok)
        XCTAssertTrue(refused.message?.contains("modern") == true,
                      refused.message ?? "no message")
        XCTAssertEqual(try store?.listProjects().count, 0,
                       "a refused create still made a project")
    }

    func testCreatingAProjectFilesTheChatAndRemembersItsHome() async throws {
        installChat(script: [])
        let guest = try await connectedGuest()

        try guest.send(.chatProject(ChatProject(
            id: 81, op: "create", name: "Beeper", home: "guest")))
        let made = try await result(on: guest, id: 81)
        XCTAssertTrue(made.ok)

        try guest.send(.chatProjects(ChatProjects(id: 82)))
        let projects = try await projectRoster(on: guest, id: 82)
        XCTAssertEqual(projects.projects.map(\.label), ["Beeper"])
        XCTAssertEqual(projects.projects.first?.home, "guest")
        XCTAssertEqual(projects.projects.first?.current, true)
    }

    /* The guest's mode popup is a promise, and it can only be honest if
       the reach crosses. Before this, a text-only provider looked
       identical on the wire to one with the whole catalog, and the page
       offered Build for both (metal, 2026-08-19). */
    func testTheProviderCatalogCarriesEachProvidersReach() async throws {
        installChat(script: [], providers: [
            ChatCatalogProvider(
                provider: "fake", label: "Fake", state: "serving",
                detail: nil, tools: "none"),
        ])
        let guest = try await connectedGuest()

        try guest.send(.chatModels(ChatModels(id: 90)))
        try await waitUntil("providers catalog") {
            guest.received.contains {
                if case .chatCatalog(let c) = $0 { return c.id == 90 }
                return false
            }
        }
        guard case .chatCatalog(let catalog)? = guest.received.last(where: {
            if case .chatCatalog(let c) = $0 { return c.id == 90 }
            return false
        }) else { return XCTFail("no catalog") }

        XCTAssertEqual(catalog.providers?.first?.tools, "none")
    }

    /// The spelling the contract uses, from the type the harness reads.
    func testEveryReachHasOneWireSpelling() {
        XCTAssertEqual(ChatModuleModel.wireReach(.harness), "full")
        XCTAssertEqual(
            ChatModuleModel.wireReach(.workspace(summary: "anything")),
            "workspace")
        XCTAssertEqual(ChatModuleModel.wireReach(.none(reason: "why")), "none")
    }

    func testARefRidesBackToTheRealModelID() async throws {
        installChat(script: [[
            .textDelta("hey"), .finished(.endTurn),
        ]])
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)
        try guest.send(.chatSend(ChatSend(id: 30, ref: ref, prompt: "hi")))
        let answer = try await result(on: guest, id: 30)
        XCTAssertTrue(answer.ok)
        XCTAssertEqual(provider.requests.first?.model, "m",
                       "the send resolved the ref to the provider's own id")
    }

    func testNoServiceWiredMeansPreFamilySilence() async throws {
        // No installChat: the honest answer to a host that predates
        // the family is nothing at all.
        let guest = try await connectedGuest()
        try guest.send(.chatModels(ChatModels(id: 3)))
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(guest.received.contains {
            if case .chatCatalog = $0 { return true }
            if case .chatResult = $0 { return true }
            return false
        })
    }

    // MARK: - A streamed turn

    func testSendStreamsDeltasThenOneTerminalResult() async throws {
        installChat(script: [[
            .textDelta("Hello from"),
            .textDelta(" the model."),
            .finished(.endTurn),
        ]])
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)
        try guest.send(.chatSend(ChatSend(id: 9, ref: ref, prompt: "hi")))
        let result = try await result(on: guest, id: 9)
        XCTAssertTrue(result.ok)
        XCTAssertNil(result.code)

        let deltas = guest.received.compactMap {
            if case .chatDelta(let d) = $0 { return d }
            return nil
        }
        XCTAssertFalse(deltas.isEmpty)
        XCTAssertEqual(deltas.map(\.seq), Array(0..<deltas.count),
                       "seq is 0-based and contiguous")
        XCTAssertEqual(deltas.map(\.text).joined(), "Hello from the model.")
        XCTAssertTrue(deltas.allSatisfy { $0.id == 9 })
        // The provider was asked with the guest's turn and the wire
        // origin's system prompt.
        XCTAssertEqual(provider.requests.count, 1)
        XCTAssertTrue(provider.requests[0].system.contains("Plain text only"))
        // The empty status that clears the line arrived by the end.
        XCTAssertTrue(guest.received.contains {
            if case .chatStatus(let s) = $0 { return s.text.isEmpty }
            return false
        })
    }

    func testSecondSendIsBusyAndCancelAnswersTheFirst() async throws {
        installChat(script: [], hangsWhenDry: true)
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)
        try guest.send(.chatSend(ChatSend(id: 1, ref: ref, prompt: "a")))
        try await waitUntil("first turn streaming") {
            self.provider.requests.count == 1
        }
        try guest.send(.chatSend(ChatSend(id: 2, ref: ref, prompt: "b")))
        let busy = try await result(on: guest, id: 2)
        XCTAssertEqual(busy.code, "busy")

        try guest.send(.chatCancel(ChatCancel(id: 1)))
        let cancelled = try await result(on: guest, id: 1)
        XCTAssertFalse(cancelled.ok)
        XCTAssertEqual(cancelled.code, "cancelled")
    }

    func testCancelForNothingIsAlwaysAnswered() async throws {
        installChat(script: [])
        let guest = try await connectedGuest()
        try guest.send(.chatCancel(ChatCancel(id: 99)))
        let answer = try await result(on: guest, id: 99)
        XCTAssertEqual(answer.code, "not-running")
    }

    func testOverlongPromptIsRefusedNotTruncated() async throws {
        installChat(script: [])
        let guest = try await connectedGuest()
        let long = String(repeating: "x", count: 600)
        try guest.send(.chatSend(ChatSend(id: 4, ref: "m1", prompt: long)))
        let answer = try await result(on: guest, id: 4)
        XCTAssertEqual(answer.code, "too-long")
        XCTAssertTrue(provider.requests.isEmpty, "nothing reached a model")
    }

    func testUnknownModelIsAWellFormedRefusal() async throws {
        installChat(script: [])
        let guest = try await connectedGuest()
        // Never minted on this connection - stale from a past life.
        try guest.send(.chatSend(ChatSend(id: 5, ref: "m9", prompt: "hi")))
        let answer = try await result(on: guest, id: 5)
        XCTAssertEqual(answer.code, "unknown-model")
    }

    func testResetForgetsTheConversation() async throws {
        installChat(script: [
            [.textDelta("one"), .finished(.endTurn)],
            [.textDelta("two"), .finished(.endTurn)],
        ])
        let guest = try await connectedGuest()
        let ref = try await mintedRef(on: guest)
        try guest.send(.chatSend(ChatSend(id: 10, ref: ref, prompt: "a")))
        _ = try await result(on: guest, id: 10)
        try guest.send(.chatReset(ChatReset(id: 11)))
        let reset = try await result(on: guest, id: 11)
        XCTAssertTrue(reset.ok)
        try guest.send(.chatSend(ChatSend(id: 12, ref: ref, prompt: "b")))
        _ = try await result(on: guest, id: 12)
        // The second turn started from a blank conversation: one user
        // turn, no history from before the reset.
        XCTAssertEqual(provider.requests.count, 2)
        XCTAssertEqual(provider.requests[1].turns.count, 1)
    }
}

/// Every emitted frame fits the control cap by MEASURED encode, and
/// nothing is lost splitting. Fed hostile text on purpose: escaping is
/// what inflates a frame past a naive byte count.
final class ChatDeltaChunkingTests: XCTestCase {
    func testHostileTextSplitsIntoFittingFramesLosslessly() throws {
        let nasty = String(
            repeating: "quote \" backslash \\ newline \n tab \t bullet - ",
            count: 400)
        let frames = ChatDeltaChunking.frames(id: 3, firstSeq: 5, text: nasty)
        XCTAssertGreaterThan(frames.count, 1)
        for frame in frames {
            let encoded = try ControlMessageCodec.encode(.chatDelta(frame))
            XCTAssertLessThanOrEqual(
                encoded.count, ChatDeltaChunking.controlCap)
        }
        XCTAssertEqual(frames.map(\.text).joined(), nasty)
        XCTAssertEqual(frames.map(\.seq),
                       Array(5..<(5 + frames.count)))
    }

    func testTheCodecDoesNotEscapeSlashes() throws {
        // Foundation writes "/" as "\/" by default; a guest reading a
        // KEY with its non-decoding reader then sends the backslash
        // back (metal, 2026-08-02: "anthropic\\/claude-opus-5").
        let encoded = try ControlMessageCodec.encode(.chatCatalog(
            ChatCatalog(id: 1, provider: "omlx", models: [
                ChatCatalogModel(
                    ref: "m1", label: "qwen/qwen-3.5", detail: nil)
            ], more: false)))
        let text = String(decoding: encoded, as: UTF8.self)
        XCTAssertTrue(text.contains("qwen/qwen-3.5"))
        XCTAssertFalse(text.contains("\\/"))
    }

    func testSmallTextIsOneFrame() {
        let frames = ChatDeltaChunking.frames(id: 1, firstSeq: 0, text: "hi")
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].text, "hi")
    }

    func testEmptyTextEmitsNothing() {
        XCTAssertTrue(
            ChatDeltaChunking.frames(id: 1, firstSeq: 0, text: "").isEmpty)
    }
}

// MARK: - Test doubles

private final class WireScriptedProvider: ChatProvider, @unchecked Sendable {
    let id = "fake"
    let label = "Fake"
    var toolReach = ChatToolReach.harness
    private let lock = NSLock()
    private var script: [[ChatStreamEvent]]
    private(set) var requests: [ChatCompletionRequest] = []
    var hangsWhenDry = false

    init(_ script: [[ChatStreamEvent]]) {
        self.script = script
    }

    func entry() async -> ChatProviderEntry {
        ChatProviderEntry(id: id, label: label, state: "serving", detail: "")
    }

    func listModels() async throws -> [ChatModel] {
        [ChatModel(providerID: id, modelID: "m", displayName: "m")]
    }

    func stream(_ request: ChatCompletionRequest)
        -> AsyncThrowingStream<ChatStreamEvent, Error> {
        lock.lock()
        requests.append(request)
        let events = script.isEmpty ? nil : script.removeFirst()
        let hang = hangsWhenDry
        lock.unlock()
        return AsyncThrowingStream { continuation in
            if let events {
                for event in events { continuation.yield(event) }
                continuation.finish()
                return
            }
            if hang {
                let task = Task {
                    try? await Task.sleep(nanoseconds: 60_000_000_000)
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            } else {
                continuation.yield(.finished(.endTurn))
                continuation.finish()
            }
        }
    }
}

private struct NoOpAuditSink: HostProjectionAuditSink {
    func record(_ event: HostProjectionAuditEvent) async {}
}

private struct NoHostChatClient: AgentIntegrationClient {
    func addressing(_ selector: String?) -> AgentIntegrationClient { self }
    func sessionHealth() async -> AgentIntegrationSessionHealthResult {
        .unavailable(.host)
    }
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult {
        .unavailable(.host)
    }
    func listProcesses() async -> AgentIntegrationProcessListResult {
        .unavailable(.host)
    }
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult {
        .unavailable(.host)
    }
    func requestQuit(reference: String) async -> AgentIntegrationQuitResult {
        .unavailable(.host)
    }
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        .unavailable(.host)
    }
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult {
        .hostUnavailable(.host)
    }
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult {
        .hostUnavailable(.host)
    }
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult {
        .hostUnavailable(.host)
    }
}
