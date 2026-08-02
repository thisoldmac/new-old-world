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
        listener.stop()
        listener = nil
        chatService = nil
        provider = nil
    }

    private func installChat(
        script: [[ChatStreamEvent]], hangsWhenDry: Bool = false,
        catalog: [ChatCatalogEntry] = []
    ) {
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
            harness: harness, catalog: { catalog })
        listener.chatService = chatService
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

    func testTheCatalogAnswersAndTrimsToSixteen() async throws {
        let entries = (0..<20).map {
            ChatCatalogEntry(
                model: "fake/m\($0)", label: "Model \($0)",
                state: "serving", detail: nil)
        }
        installChat(script: [], catalog: entries)
        let guest = try await connectedGuest()
        try guest.send(.chatModels(ChatModels(id: 7)))
        try await waitUntil("chat.catalog") {
            guest.received.contains {
                if case .chatCatalog = $0 { return true }
                return false
            }
        }
        guard case .chatCatalog(let catalog)? = guest.received.last(where: {
            if case .chatCatalog = $0 { return true }
            return false
        }) else { return XCTFail("no catalog") }
        XCTAssertEqual(catalog.id, 7)
        XCTAssertEqual(catalog.models.count, 16, "maxItems 16, by trimming")
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
        try guest.send(.chatSend(ChatSend(
            id: 9, model: "fake/m", prompt: "hi")))
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
        try guest.send(.chatSend(ChatSend(id: 1, model: "fake/m", prompt: "a")))
        try await waitUntil("first turn streaming") {
            self.provider.requests.count == 1
        }
        try guest.send(.chatSend(ChatSend(id: 2, model: "fake/m", prompt: "b")))
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
        try guest.send(.chatSend(ChatSend(id: 4, model: "fake/m", prompt: long)))
        let answer = try await result(on: guest, id: 4)
        XCTAssertEqual(answer.code, "too-long")
        XCTAssertTrue(provider.requests.isEmpty, "nothing reached a model")
    }

    func testUnknownModelIsAWellFormedRefusal() async throws {
        installChat(script: [])
        let guest = try await connectedGuest()
        try guest.send(.chatSend(ChatSend(
            id: 5, model: "elsewhere/m", prompt: "hi")))
        let answer = try await result(on: guest, id: 5)
        XCTAssertEqual(answer.code, "unknown-model")
    }

    func testResetForgetsTheConversation() async throws {
        installChat(script: [
            [.textDelta("one"), .finished(.endTurn)],
            [.textDelta("two"), .finished(.endTurn)],
        ])
        let guest = try await connectedGuest()
        try guest.send(.chatSend(ChatSend(id: 10, model: "fake/m", prompt: "a")))
        _ = try await result(on: guest, id: 10)
        try guest.send(.chatReset(ChatReset(id: 11)))
        let reset = try await result(on: guest, id: 11)
        XCTAssertTrue(reset.ok)
        try guest.send(.chatSend(ChatSend(id: 12, model: "fake/m", prompt: "b")))
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
