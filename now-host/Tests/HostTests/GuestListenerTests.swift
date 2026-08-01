import XCTest
import Network
import Combine
@testable import Host
import NOWAgentIntegration

/// A scripted guest: dials the listener over loopback, sends frames, and
/// collects decoded control replies.
@MainActor
final class FakeGuest {
    let connection: NWConnection
    private let decoder = FrameDecoder()
    private(set) var received: [ControlMessage] = []
    /// Bulk payload the host has sent us — the guest side of a put.
    private(set) var bulkReceived = Data()
    var onMessage: ((ControlMessage) -> Void)?
    private(set) var wasClosed = false
    var onClose: (() -> Void)?

    init(port: UInt16) {
        connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            Task { @MainActor in
                if case .failed = state { self?.markClosed() }
                if case .cancelled = state { self?.markClosed() }
            }
        }
        connection.start(queue: .main)
        receiveLoop()
    }

    private func markClosed() {
        guard !wasClosed else { return }
        wasClosed = true
        onClose?()
    }

    func send(_ message: ControlMessage) throws {
        let payload = try ControlMessageCodec.encode(message)
        let frame = try FrameCodec.encode(channel: .control, payload: payload)
        connection.send(content: frame, completion: .idempotent)
    }

    func sendRaw(_ data: Data) {
        connection.send(content: data, completion: .idempotent)
    }

    private func receiveLoop() {
        connection.receive(minimumIncompleteLength: 1,
                           maximumLength: 65536) { [weak self] data, _, done, _ in
            Task { @MainActor in
                guard let self else { return }
                if let data, !data.isEmpty,
                   let frames = try? self.decoder.feed(data) {
                    for frame in frames {
                        if frame.header.channel == .bulk {
                            self.bulkReceived.append(frame.payload)
                            continue
                        }
                        if let message = try? ControlMessageCodec.decode(
                            frame.payload) {
                            self.received.append(message)
                            self.onMessage?(message)
                        }
                    }
                }
                if done { self.markClosed() } else { self.receiveLoop() }
            }
        }
    }
}

@MainActor
final class GuestListenerTests: XCTestCase {
    private var listener: GuestListener!

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

    private func guestHello(
        name: String = "PowerBook 1400",
        contract: Int = Contract.revision,
        build: String? = nil,
        agent: AgentIntegrationGuestAccess? = nil) -> ControlMessage {
        .hello(Hello(contract: contract, side: "guest", version: "0.1.0",
                     build: build, agent: agent, name: name, os: "9.1",
                     chunk: 8192))
    }

    /// The answer a machine gives at hello reaches the record the host
    /// keeps about it, and the roster row beside it.
    ///
    /// A vote nobody carries is a vote nobody counted. This is the whole
    /// job of this slice: the guest states a position and the host holds
    /// it — enforcement is elsewhere and deliberately not here.
    func testHelloAgentAccessReachesTheHealthRecord() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(agent: .readOnly))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        XCTAssertEqual(
            listener.health?.guestAgentAccess, .readOnly,
            "The machine answered and the host dropped it on the floor.")
        XCTAssertEqual(listener.guests.first?.agentAccess, .readOnly,
                       "the roster row carries it too")
    }

    /// A tier changed mid-session reaches the host on the link already up.
    ///
    /// The defect this closes: `hello` is sent once per connection and
    /// nothing revised it, so a person who set Read Only while connected
    /// went on being driven at Full Access until the link was rebuilt — the
    /// one place in this product where being out of date has a safety edge.
    ///
    /// ORDERED, and that is the point of the first wait rather than a
    /// politeness. Both values are asserted on the same field, so a test
    /// that sent the revision without first establishing `.fullAccess`
    /// would pass against a host that ignored `agent.access` entirely,
    /// having measured a barrier it never watched arrive.
    func testATierChangedMidSessionReachesTheHost() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(agent: .fullAccess))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        /* The starting position, established before the revision is sent:
           without this, the assertion below cannot tell "the host applied
           the revision" from "the host was already there". */
        XCTAssertEqual(listener.health?.guestAgentAccess, .fullAccess,
                       "precondition: the connect-time answer landed")

        try guest.send(.agentAccess(AgentAccess(agent: .readOnly)))
        try await waitUntil("the revision to land") {
            self.listener.health?.guestAgentAccess == .readOnly
        }

        XCTAssertEqual(
            listener.health?.guestAgentAccess, .readOnly,
            "The machine withdrew Full Access and the host kept enforcing "
                + "it — the stale belief this message exists to prevent.")
        XCTAssertEqual(listener.guests.first?.agentAccess, .readOnly,
                       "and the roster row the MCP pane renders follows it")
    }

    /// The revision can also WIDEN, and the host must not treat the
    /// connect-time answer as a ceiling it may never rise above.
    ///
    /// Worth its own case because "only ever narrows" is a plausible thing
    /// to implement and would be wrong: this field is the machine's
    /// position, not a budget it spends down. A person who set Read Only
    /// to do something carefully and then set Full Access back expects the
    /// second decision to count as much as the first.
    func testARevisionMayWidenAndNotOnlyNarrow() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(agent: .readOnly))
        try await waitUntil("host hello") { !guest.received.isEmpty }
        XCTAssertEqual(listener.health?.guestAgentAccess, .readOnly,
                       "precondition: the narrower answer landed first")

        try guest.send(.agentAccess(AgentAccess(agent: .fullAccess)))
        try await waitUntil("the widening to land") {
            self.listener.health?.guestAgentAccess == .fullAccess
        }
        XCTAssertEqual(listener.health?.guestAgentAccess, .fullAccess)
    }

    /// A guest that said nothing at hello and then speaks is ANSWERING.
    ///
    /// Absence means "predates the field", never consent — so a first
    /// `agent.access` from such a machine is the only answer the host has
    /// ever been given, and must replace the silence rather than being
    /// discarded for having no earlier value to revise.
    func testAnAnswerAfterSilenceIsTakenAsTheAnswer() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello())
        try await waitUntil("host hello") { !guest.received.isEmpty }
        XCTAssertNil(listener.health?.guestAgentAccess,
                     "precondition: this machine said nothing at hello")

        try guest.send(.agentAccess(AgentAccess(agent: .disabled)))
        try await waitUntil("the first answer to land") {
            self.listener.health?.guestAgentAccess == .disabled
        }
        XCTAssertEqual(listener.health?.guestAgentAccess, .disabled)
    }

    /// A machine that refuses is held as a refusal.
    ///
    /// `disabled` is the state the whole three-state design turns on: it is
    /// what an installer that omitted the agent features sends, and what a
    /// flipped switch sends, and it must not arrive looking like the
    /// silence of a guest that predates the field.
    func testAMachineThatRefusesIsHeldAsARefusalNotAsSilence() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(agent: .disabled))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        XCTAssertEqual(listener.health?.guestAgentAccess, .disabled)
        XCTAssertNotNil(
            listener.health?.guestAgentAccess,
            "A refusal that reaches the host as nil is indistinguishable "
                + "from a guest that never heard the question — and absence "
                + "currently fails open, so it would be read as a yes.")
    }

    /// A guest that never answers leaves it absent.
    ///
    /// NOW-68K sends no `agent` and neither does any machine deployed
    /// before this field. Absence has to survive as absence: filling it in
    /// with a tier would be the host inventing consent on behalf of a
    /// machine that was never asked.
    func testAGuestThatNeverAnswersLeavesAgentAccessAbsent() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(name: "now-68k"))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        XCTAssertNil(listener.health?.guestAgentAccess)
        XCTAssertNil(listener.guests.first?.agentAccess)
        XCTAssertEqual(listener.health?.guestVersion, "0.1.0",
                       "the rest of the hello is still there")
    }

    /// The build a guest reports at hello reaches the health record.
    ///
    /// That string is the only thing distinguishing two builds of one
    /// hand-edited version, and it is what a host needs to answer "is this
    /// the build I just deployed" — the question that went unanswered on the
    /// 1400c on 2026-07-30.
    func testHelloBuildReachesTheHealthRecord() async throws {
        let stamp = "Jul 30 2026 01:02:58"
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(build: stamp))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        XCTAssertEqual(
            listener.health?.guestBuild, stamp,
            "The guest named its build and the host dropped it.")
        XCTAssertEqual(listener.health?.guestVersion, "0.1.0")
        XCTAssertEqual(listener.guests.first?.build, stamp,
                       "the roster row carries it too")
    }

    /// A guest that reports no build leaves it absent.
    ///
    /// `build` is optional and NOW-68K sends none, so absence has to survive
    /// as absence. Backfilling it from `version` would reproduce exactly the
    /// failure the field exists to fix.
    func testAGuestThatReportsNoBuildLeavesItAbsent() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(name: "now-68k"))
        try await waitUntil("host hello") { !guest.received.isEmpty }

        XCTAssertNil(listener.health?.guestBuild)
        XCTAssertEqual(listener.health?.guestVersion, "0.1.0",
                       "the version is still there; only the build is not")
    }

    func testHelloHandshakeConnectsAndAnswersWithHostHello() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello())
        try await waitUntil("host hello") { !guest.received.isEmpty }
        guard case .hello(let hostHello) = guest.received[0] else {
            return XCTFail("expected hello, got \(guest.received)")
        }
        XCTAssertEqual(hostHello.side, "host")
        XCTAssertEqual(hostHello.contract, Contract.revision)
        XCTAssertEqual(hostHello.chunk, 8192)
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 1400"))
    }

    /// The symmetric census family: the guest may ask the host for a
    /// census too, and the host answers a well-formed refusal (not a
    /// protocol error) until it grows its own. Proves the whole path -
    /// decode census.request, serve, encode census.report - end to end.
    func testGuestCensusRequestIsAnsweredWithARefusal() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello())
        try await waitUntil("host hello") { !guest.received.isEmpty }

        try guest.send(.censusRequest(
            CensusRequest(id: 42, probe: "gestalt", cursor: nil)))
        try await waitUntil("census report") {
            guest.received.contains {
                if case .censusReport = $0 { return true }
                return false
            }
        }
        let report = guest.received.compactMap { msg -> CensusReport? in
            if case .censusReport(let r) = msg { return r }
            return nil
        }.first
        XCTAssertEqual(report?.id, 42, "echoes the request id")
        XCTAssertEqual(report?.outcome, "refused",
                       "a refusal, never a protocol error")
        XCTAssertEqual(report?.rows.count, 0)
        XCTAssertNotNil(report?.note, "says why it refused")
    }

    func testRevisionMismatchIsRefusedWithReason() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello(contract: 99))
        try await waitUntil("refusal") { !guest.received.isEmpty }
        guard case .refuse(let refuse) = guest.received[0] else {
            return XCTFail("expected refuse, got \(guest.received)")
        }
        XCTAssertTrue(refuse.reason.contains("99"))
        if case .connected = listener.state { XCTFail("must not connect") }
    }

    /// The refusal that DID NOT survive: two machines calling themselves
    /// the same thing.
    ///
    /// Identity used to be the folded hello name, so this second dial was
    /// refused `busy` and a real second Mac on the desk could not be
    /// served. Identity is the connection now, so both are served, both
    /// appear in the roster, and they are told apart by their host-assigned
    /// machine ids. The name is still shown — it is just no longer the
    /// thing that decides.
    func testTwoMacsOfTheSameNameAreTwoGuestsAndNotABusyRefusal()
        async throws {
        let first = FakeGuest(port: listener.boundPort!)
        first.start()
        try first.send(guestHello(name: "Quadra 950"))
        try await waitUntil("first connected") {
            self.listener.state == .connected(guestName: "Quadra 950")
        }

        let second = FakeGuest(port: listener.boundPort!)
        second.start()
        // Same name, differently spelled — which the old rule folded into
        // one machine.
        try second.send(guestHello(name: " quadra 950 "))
        try await waitUntil("both are in the roster") {
            self.listener.guests.count == 2
        }
        XCTAssertFalse(second.received.contains { message in
            if case .refuse = message { return true }
            return false
        }, "the second Mac must not be refused for sharing a name")
        let ids = Set(listener.guests.map(\.id.slug))
        XCTAssertEqual(ids.count, 2,
                       "two machines, two handles, never one row")
        let sessions = Set(listener.guests.map(\.sessionID))
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(listener.state,
                       .connected(guestName: "Quadra 950"),
                       "and the first is still the one being driven")

        // The surviving session still answers pings.
        try first.send(.ping(id: 7))
        try await waitUntil("pong") {
            first.received.contains(.pong(id: 7))
        }
    }

    func testByeDisconnectsCalmly() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello())
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        try guest.send(.bye(Bye(code: .normal, reason: nil)))
        try await waitUntil("back to listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        XCTAssertEqual(listener.lastDisconnect,
                       "PowerBook 1400 disconnected")
    }

    func testJunkBeforeHelloIsAProtocolError() async throws {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.ping(id: 1))
        try await waitUntil("protocol error bye") { !guest.received.isEmpty }
        guard case .bye(let bye) = guest.received[0] else {
            return XCTFail("expected bye, got \(guest.received)")
        }
        XCTAssertEqual(bye.code, .protocolError)
        if case .connected = listener.state { XCTFail("must not connect") }
    }

    func testIdleGuestIsDeclaredDeadPassively() async throws {
        listener.stop()
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 0.3))
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(guestHello())
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        // Send nothing further; the passive clock should reclaim the session.
        try await waitUntil("passive death") {
            if case .listening = self.listener.state { return true }
            return false
        }
        XCTAssertEqual(listener.lastDisconnect,
                       "Connection lost (no traffic)")
    }
}

@MainActor
final class GuestPushCaptureTests: XCTestCase {
    private var listener: GuestListener!

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
        let guest = FakeGuest(port: listener.boundPort ?? 0)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        try await waitUntil("connected") {
            if case .connected = self.listener.state { return true }
            return false
        }
        return guest
    }

    /// 4x2 8-bit raw with a 768-byte palette - small enough to hand-build,
    /// real enough to exercise decode.
    private func pushBlob() -> (offer: CaptureOffer, bulk: Data) {
        var palette = [UInt8](repeating: 0, count: 256 * 3)
        palette[3] = 255
        let pixels: [UInt8] = [1, 1, 1, 1, 1, 1, 1, 1]
        let blob = palette + pixels
        let offer = CaptureOffer(
            id: 9, width: 4, height: 2, depth: 8, rowBytes: 4,
            bytes: blob.count, paletteBytes: palette.count, encoding: "raw",
            captureMs: 1, encodeMs: 1)
        return (offer, Data(blob))
    }

    func testOfferAcceptBulkLandsInPushedCaptures() async throws {
        let guest = try await connectedGuest()
        var delivered: GuestListener.CaptureDelivery?
        let watch = listener.pushedCaptures.sink { delivered = $0 }
        defer { watch.cancel() }

        let (offer, bulk) = pushBlob()
        try guest.send(.captureOffer(offer))
        try await waitUntil("accept") {
            guest.received.contains(.captureAccept(CaptureAccept(id: 9)))
        }

        try guest.send(.captureBegin(CaptureBegin(
            id: 9, transfer: 1, width: 4, height: 2, depth: 8, rowBytes: 4,
            bytes: bulk.count, paletteBytes: 768, encoding: "raw",
            captureMs: 1, encodeMs: 1)))
        guest.sendRaw(try FrameCodec.encode(
            channel: .bulk, flags: [.end], transfer: 1, payload: bulk))
        try guest.send(.captureEnd(CaptureEnd(
            id: 9, transfer: 1, ok: true, sendMs: 5)))

        try await waitUntil("delivery") { delivered != nil }
        XCTAssertEqual(delivered?.format.width, 4)
        XCTAssertEqual(delivered?.wireBytes, bulk.count)
        XCTAssertNil(listener.captureProgress,
                     "progress must clear once the push lands")
    }

    func testStreamBracketRoutesFramesAndCloses() async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        var pushed = 0
        let watchFrames = listener.streamFrames.sink { frames.append($0) }
        let watchPushed = listener.pushedCaptures.sink { _ in pushed += 1 }
        defer { watchFrames.cancel(); watchPushed.cancel() }

        listener.startStream(depth: 8, origin: .person)
        var streamId: Int?
        try await waitUntil("stream.start") {
            for message in guest.received {
                if case .streamStart(let start) = message {
                    streamId = start.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(streamId)
        XCTAssertEqual(listener.activeStreamId, id)

        // Two frames, each a complete begin/bulk/end with the stream's id.
        let bulk = pushBlob().bulk
        for transfer in 1...2 {
            try guest.send(.captureBegin(CaptureBegin(
                id: id, transfer: transfer, width: 4, height: 2, depth: 8,
                rowBytes: 4, bytes: bulk.count, paletteBytes: 768,
                encoding: "raw", captureMs: 1, encodeMs: 1)))
            guest.sendRaw(try FrameCodec.encode(
                channel: .bulk, flags: [.end],
                transfer: UInt16(transfer), payload: bulk))
            try guest.send(.captureEnd(CaptureEnd(
                id: id, transfer: transfer, ok: true, sendMs: 2)))
        }
        try await waitUntil("two frames") { frames.count == 2 }
        XCTAssertEqual(pushed, 0, "stream frames must not route as pushes")
        XCTAssertNil(listener.captureProgress,
                     "stream frames must not drive the one-shot progress")

        listener.stopStream()
        try await waitUntil("stream.stop") {
            guest.received.contains(.streamStop(StreamStop(id: id)))
        }
        try guest.send(.streamStopped(StreamStopped(id: id, reason: nil)))
        try await waitUntil("bracket closed") {
            self.listener.activeStreamId == nil
        }
        XCTAssertNil(listener.streamEndReason)
    }

    /// A guest that does not implement the stream family refuses
    /// `stream.start`, and the bracket must close on THAT — not on the
    /// five-second unacknowledged-stop fallback.
    ///
    /// This is the 68K guest's ordinary behaviour, not a contrived one: its
    /// wire answers any message type it does not know with `error`
    /// (`send_error_reply`, now-guest-68k/src/core/wire68.c). Before the
    /// listener knew the bracket's own id, nothing here was routed and the
    /// Screenshots page sat on "Waiting for the first frame…" until the page
    /// itself noticed and asked for a stop it would also be refused.
    ///
    /// The test asserts the timing, because the timing is the defect: the
    /// deadline is far under the fallback, so a pass cannot be the fallback
    /// arriving early.
    func testStreamStartRefusalClosesBracketWithoutFallback() async throws {
        let guest = try await connectedGuest()
        /* Answer stream.start the way a guest without the family does, from
           the wire rather than from the test body, so what closes the
           bracket is a refusal that crossed the socket. */
        guest.onMessage = { message in
            if case .streamStart(let start) = message {
                try? guest.send(.error(ErrorMessage(
                    id: start.id, code: "not-implemented",
                    message: "stream.start is not implemented")))
            }
        }

        let opened = Date()
        let id = try XCTUnwrap(listener.startStream(depth: 8, origin: .person),
                               "the bracket must open before it can be refused")
        XCTAssertEqual(listener.activeStreamId, id)

        try await waitUntil("bracket closed") {
            self.listener.activeStreamId == nil
        }
        XCTAssertLessThan(
            Date().timeIntervalSince(opened), 2,
            "the refusal must close the bracket, not the 5s stop fallback")

        // The guest's own words, so a caller can say WHY the view is dead.
        XCTAssertEqual(listener.streamEndReason,
                       "stream.start is not implemented")
        // Nothing was asked to stop: there was never a stream to stop.
        XCTAssertFalse(
            guest.received.contains(.streamStop(StreamStop(id: id))),
            "a refused start must not be followed by a stop")

        /* And the refusal is written down, which is what stops the ledger
           reporting stream.start `unproven` against a machine that has
           answered the question outright. */
        let seen = try XCTUnwrap(
            listener.familyObservations[
                AgentIntegrationCapabilityNames.streamStart])
        XCTAssertFalse(seen.served)
        XCTAssertEqual(seen.code, "not-implemented")
    }

    /// The other half of the ledger: a guest that streams has SERVED
    /// `stream.start`, and the frame is the only thing that says so — the
    /// bracket has no completion for the observing wrapper to sit on.
    func testStreamFrameRecordsStartAsServed() async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        let watch = listener.streamFrames.sink { frames.append($0) }
        defer { watch.cancel() }
        XCTAssertNil(listener.familyObservations[
            AgentIntegrationCapabilityNames.streamStart],
            "nothing is known about the family before it is asked")

        let (_, send) = try await streamingGuest(guest, width: 4, height: 4)
        try send(1, redPalette + [UInt8](repeating: 1, count: 16), "key",
                 nil, 768, 4)
        try await waitUntil("keyframe") { frames.count == 1 }

        let seen = try XCTUnwrap(
            listener.familyObservations[
                AgentIntegrationCapabilityNames.streamStart])
        XCTAssertTrue(seen.served)
    }

    /// A refused `stream.refresh` must NOT kill a stream that is running.
    /// The three stream messages share the bracket's one id, so the naive
    /// "any error on this id ends the bracket" would tear down a working
    /// live view because the guest cannot serve a keyframe on demand.
    func testRefusedRefreshLeavesRunningStreamAlone() async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        let watch = listener.streamFrames.sink { frames.append($0) }
        defer { watch.cancel() }
        let (id, send) = try await streamingGuest(guest, width: 4, height: 4)
        try send(1, redPalette + [UInt8](repeating: 1, count: 16), "key",
                 nil, 768, 4)
        try await waitUntil("keyframe") { frames.count == 1 }

        listener.refreshStream()
        try await waitUntil("stream.refresh") {
            guest.received.contains(.streamRefresh(StreamRefresh(id: id)))
        }
        try guest.send(.error(ErrorMessage(
            id: id, code: "not-implemented",
            message: "stream.refresh is not implemented")))
        try await waitUntil("the refusal is seen") {
            self.listener.lastGuestError?.code == "not-implemented"
        }

        XCTAssertEqual(listener.activeStreamId, id,
                       "a refused keyframe must not end the stream")
        // And it is not evidence against the family the guest is serving.
        let seen = try XCTUnwrap(
            listener.familyObservations[
                AgentIntegrationCapabilityNames.streamStart])
        XCTAssertTrue(seen.served)
    }

    func testStreamCompositesKeyDeltaAndEmptyFrames() async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        let watch = listener.streamFrames.sink { frames.append($0) }
        defer { watch.cancel() }

        listener.startStream(depth: 8, origin: .person)
        var streamId: Int?
        try await waitUntil("stream.start") {
            for message in guest.received {
                if case .streamStart(let start) = message {
                    streamId = start.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(streamId)

        // Keyframe: 4x2 raw, palette entry 1 = red, all pixels index 1.
        var palette = [UInt8](repeating: 0, count: 256 * 3)
        palette[3] = 255
        let keyPixels = [UInt8](repeating: 1, count: 8)
        let keyBlob = palette + keyPixels
        func sendFrame(_ transfer: Int, bytes: [UInt8], frame: String,
                       rects: [[Int]]? = nil, paletteBytes: Int = 0) throws {
            try guest.send(.captureBegin(CaptureBegin(
                id: id, transfer: transfer, width: 4, height: 2, depth: 8,
                rowBytes: 4, bytes: bytes.count, paletteBytes: paletteBytes,
                encoding: "raw", frame: frame, rects: rects,
                captureMs: 1, encodeMs: 1)))
            if !bytes.isEmpty {
                guest.sendRaw(try FrameCodec.encode(
                    channel: .bulk, flags: [.end],
                    transfer: UInt16(transfer), payload: Data(bytes)))
            }
            try guest.send(.captureEnd(CaptureEnd(
                id: id, transfer: transfer, ok: true, sendMs: 1)))
        }
        try sendFrame(1, bytes: keyBlob, frame: "key", paletteBytes: 768)
        try await waitUntil("keyframe") { frames.count == 1 }

        // Delta: patch pixel (1,0) to palette index 0 (black).
        try sendFrame(2, bytes: [0], frame: "delta",
                      rects: [[0, 1, 1, 1]])
        try await waitUntil("delta") { frames.count == 2 }

        // Empty: canvas untouched, still renders.
        try sendFrame(3, bytes: [], frame: "empty")
        try await waitUntil("empty") { frames.count == 3 }

        func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
            let data = image.dataProvider!.data! as Data
            let o = (y * image.bytesPerRow) + x * 4
            return [data[o], data[o + 1], data[o + 2]]
        }
        // Key: all red. Delta: (1,0) black, (0,0) still red. Empty: same.
        XCTAssertEqual(pixel(frames[0].image, 1, 0), [255, 0, 0])
        XCTAssertEqual(pixel(frames[1].image, 1, 0), [0, 0, 0])
        XCTAssertEqual(pixel(frames[1].image, 0, 0), [255, 0, 0])
        XCTAssertEqual(pixel(frames[2].image, 1, 0), [0, 0, 0])
        XCTAssertEqual(frames[2].wireBytes, 0)
    }

    /// Opens a bracket and hands back its id plus a frame sender, so the
    /// interlace tests can spell out only what makes them different.
    private func streamingGuest(_ guest: FakeGuest, width: Int, height: Int)
        async throws
        -> (id: Int, send: (Int, [UInt8], String, [[Int]]?, Int, Int) throws
                -> Void) {
        listener.startStream(depth: 8, origin: .person)
        var streamId: Int?
        try await waitUntil("stream.start") {
            for message in guest.received {
                if case .streamStart(let start) = message {
                    streamId = start.id
                    return true
                }
            }
            return false
        }
        let id = try XCTUnwrap(streamId)
        // rows defaults to `height`: a frame only says otherwise when the
        // point of the test is that it disagrees with the canvas.
        func send(_ transfer: Int, _ bytes: [UInt8], _ frame: String,
                  _ rects: [[Int]]?, _ paletteBytes: Int,
                  _ rows: Int) throws {
            try guest.send(.captureBegin(CaptureBegin(
                id: id, transfer: transfer, width: width, height: rows,
                depth: 8, rowBytes: width, bytes: bytes.count,
                paletteBytes: paletteBytes, encoding: "raw", frame: frame,
                rects: rects, captureMs: 1, encodeMs: 1)))
            if !bytes.isEmpty {
                guest.sendRaw(try FrameCodec.encode(
                    channel: .bulk, flags: [.end],
                    transfer: UInt16(transfer), payload: Data(bytes)))
            }
            try guest.send(.captureEnd(CaptureEnd(
                id: id, transfer: transfer, ok: true, sendMs: 1)))
        }
        return (id, send)
    }

    /// palette index 1 = red, everything else black.
    private var redPalette: [UInt8] {
        var palette = [UInt8](repeating: 0, count: 256 * 3)
        palette[3] = 255
        return palette
    }

    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
        let data = image.dataProvider!.data! as Data
        let o = (y * image.bytesPerRow) + x * 4
        return [data[o], data[o + 1], data[o + 2]]
    }

    /// An interlaced field is a DELTA carrying rowStep — it patches every
    /// other canvas row and must leave the canvas its full height.
    func testInterlacedFieldDeltaKeepsTheCanvasFullHeight() async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        let watch = listener.streamFrames.sink { frames.append($0) }
        defer { watch.cancel() }
        let (_, send) = try await streamingGuest(guest, width: 4, height: 4)

        // Key: 4x4, every pixel red.
        try send(1, redPalette + [UInt8](repeating: 1, count: 16), "key",
                 nil, 768, 4)
        try await waitUntil("keyframe") { frames.count == 1 }

        // Field delta, parity 0: rows 0 and 2 go black. rowStep is the 5th
        // element; the frame's own height is the FIELD's, half the canvas.
        try send(2, [UInt8](repeating: 0, count: 8), "delta",
                 [[0, 2, 0, 4, 2]], 0, 2)
        try await waitUntil("field delta") { frames.count == 2 }

        XCTAssertEqual(frames[1].image.height, 4,
                       "a field delta must not resize the canvas")
        XCTAssertEqual(pixel(frames[1].image, 0, 0), [0, 0, 0])
        XCTAssertEqual(pixel(frames[1].image, 0, 1), [255, 0, 0])
        XCTAssertEqual(pixel(frames[1].image, 0, 2), [0, 0, 0])
        XCTAssertEqual(pixel(frames[1].image, 0, 3), [255, 0, 0])
    }

    /// The guest-side bug this guards against: a decimated capture exported
    /// through the KEY path. It arrives as a well-formed key of half the
    /// height, and replacing the canvas with it strands the stream at half
    /// a screen. Reject it and keep the canvas we have.
    func testHalfHeightKeyFrameIsRejectedRatherThanResizingTheCanvas()
        async throws {
        let guest = try await connectedGuest()
        var frames: [GuestListener.CaptureDelivery] = []
        let watch = listener.streamFrames.sink { frames.append($0) }
        defer { watch.cancel() }
        let (_, send) = try await streamingGuest(guest, width: 4, height: 4)

        try send(1, redPalette + [UInt8](repeating: 1, count: 16), "key",
                 nil, 768, 4)
        try await waitUntil("keyframe") { frames.count == 1 }
        XCTAssertEqual(frames[0].image.height, 4)

        // A "key" holding only 2 of the 4 canvas rows: same width, same
        // stride, half the height.
        try send(2, redPalette + [UInt8](repeating: 1, count: 8), "key",
                 nil, 768, 2)
        // Nothing to wait on — a rejected frame is delivered nowhere — so
        // follow it with a frame that IS delivered and check what landed.
        try send(3, [], "empty", nil, 0, 4)
        try await waitUntil("empty after the bad key") { frames.count >= 2 }

        XCTAssertEqual(frames.count, 2,
                       "the half-height key must not be delivered")
        XCTAssertEqual(frames[1].image.height, 4,
                       "the canvas must survive a half-height key")
        XCTAssertEqual(pixel(frames[1].image, 0, 3), [255, 0, 0])
    }

    func testRefreshAsksTheGuestForAKeyframe() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 8, origin: .person)
        var streamId: Int?
        try await waitUntil("stream.start") {
            for message in guest.received {
                if case .streamStart(let start) = message {
                    streamId = start.id
                    return true
                }
            }
            return false
        }
        listener.refreshStream()
        let id = try XCTUnwrap(streamId)
        try await waitUntil("stream.refresh") {
            guest.received.contains(
                .streamRefresh(StreamRefresh(id: id)))
        }
    }

    func testGuestAbortReportsItsReason() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 1, origin: .person)
        var streamId: Int?
        try await waitUntil("stream.start") {
            for message in guest.received {
                if case .streamStart(let start) = message {
                    streamId = start.id
                    return true
                }
            }
            return false
        }
        try guest.send(.streamStopped(StreamStopped(
            id: try XCTUnwrap(streamId), reason: "capture failed")))
        try await waitUntil("bracket closed") {
            self.listener.activeStreamId == nil
        }
        XCTAssertEqual(listener.streamEndReason, "capture failed")
    }

    func testGuestStreamRequestOpensTheBracket() async throws {
        let guest = try await connectedGuest()
        try guest.send(.streamRequest(StreamRequest(depth: 1)))
        try await waitUntil("stream.start") {
            guest.received.contains {
                if case .streamStart(let start) = $0 {
                    return start.depth == 1
                }
                return false
            }
        }
        XCTAssertNotNil(listener.activeStreamId)
    }

    func testStreamRequestWhileStreamingIsDeclined() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 8, origin: .person)
        try await waitUntil("stream.start") {
            guest.received.contains {
                if case .streamStart = $0 { return true }
                return false
            }
        }
        try guest.send(.streamRequest(StreamRequest(depth: 1)))
        try await waitUntil("stream-busy error") {
            guest.received.contains {
                if case .error(let error) = $0 {
                    return error.code == "stream-busy"
                }
                return false
            }
        }
        // Only the original bracket ever opened.
        let starts = guest.received.filter {
            if case .streamStart = $0 { return true }
            return false
        }
        XCTAssertEqual(starts.count, 1)
    }

    func testGuestDisconnectClosesTheBracket() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 8, origin: .person)
        try await waitUntil("stream.start") {
            guest.received.contains {
                if case .streamStart = $0 { return true }
                return false
            }
        }
        try guest.send(.bye(Bye(code: .normal, reason: nil)))
        try await waitUntil("bracket closed") {
            self.listener.activeStreamId == nil
        }
        XCTAssertEqual(listener.streamEndReason, "connection lost")
    }

    func testOfferDuringAStreamIsRefusedBusy() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 8, origin: .person)
        try await waitUntil("stream.start") {
            guest.received.contains {
                if case .streamStart = $0 { return true }
                return false
            }
        }
        try guest.send(.captureOffer(pushBlob().offer))
        try await waitUntil("refuse") {
            guest.received.contains {
                if case .captureRefuse(let refuse) = $0 {
                    return refuse.reason?.contains("busy") == true
                }
                return false
            }
        }
    }

    func testOfferDuringASolicitedCaptureIsRefusedBusy() async throws {
        let guest = try await connectedGuest()
        listener.requestCapture(depth: 8) { _ in }
        try await waitUntil("capture.request") {
            guest.received.contains {
                if case .captureRequest = $0 { return true }
                return false
            }
        }

        try guest.send(.captureOffer(pushBlob().offer))
        try await waitUntil("refuse") {
            guest.received.contains {
                if case .captureRefuse(let refuse) = $0 {
                    return refuse.id == 9
                        && refuse.reason?.contains("busy") == true
                }
                return false
            }
        }
        // The solicited lane is untouched: no accept was sent.
        XCTAssertFalse(guest.received.contains(
            .captureAccept(CaptureAccept(id: 9))))
    }
}

@MainActor
final class GuestListenerDiagnosticsTests: XCTestCase {
    func testLogAndHealthAcrossASessionLifecycle() async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .listening = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.9", name: "Quadra 950",
                                    os: "8.1", chunk: nil)))
        while listener.health == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard let health = listener.health else {
            return XCTFail("no health after hello")
        }
        XCTAssertEqual(health.guestName, "Quadra 950")
        XCTAssertEqual(health.guestVersion, "0.9")
        XCTAssertEqual(health.guestOS, "8.1")
        XCTAssertTrue(listener.log.contains {
            $0.text.contains("Connected:")
                && $0.text.contains("Quadra 950") })

        try guest.send(.ping(id: 1))
        while (listener.health?.pingsAnswered ?? 0) == 0, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(listener.health?.pingsAnswered, 1)

        try guest.send(.bye(Bye(code: .normal, reason: nil)))
        while listener.health != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNil(listener.health)
        XCTAssertTrue(listener.log.contains {
            $0.text.contains("Quadra 950 disconnected") })
        listener.stop()
    }
}

@MainActor
final class GuestCommandTests: XCTestCase {
    func testRunCommandRoundTripsThroughAConnectedGuest() async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60))
        listener.start(port: 0)
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if case .listening = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        let guest = FakeGuest(port: listener.boundPort!)
        guest.onMessage = { message in
            if case .commandRequest(let request) = message {
                XCTAssertEqual(request.name, "gestalt")
                try? guest.send(.commandResult(CommandResult(
                    id: request.id, ok: true,
                    output: ["snapshot": [["System", "Mac OS 9.1"],
                                          ["CarbonLib", "1.6"]],
                             "cpu": [["Processor", "PowerPC 603e"]]],
                    error: nil)))
            }
        }
        guest.start()
        try guest.send(.hello(Hello(contract: Contract.revision, side: "guest",
                                    version: "0.1.0", name: "PowerBook 1400",
                                    os: "9.1", chunk: nil)))
        while Date() < deadline {
            if case .connected = listener.state { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }

        var received: CommandResult?
        listener.runCommand("gestalt") { received = $0 }
        while received == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(received?.ok, true)
        XCTAssertEqual(received?.output?["cpu"]?.first?.last, "PowerPC 603e")
        listener.stop()
    }

    func testRunCommandWithoutGuestFailsHonestly() async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        var received: CommandResult?
        listener.runCommand("gestalt") { received = $0 }
        XCTAssertEqual(received?.ok, false)
        XCTAssertEqual(received?.error?.code, "not-connected")
    }
}

/// Two machines on one port.
///
/// The host used to serve exactly one guest and refuse the next with an
/// explanation. It now tells them apart by the identity in their hello and
/// serves both; the refusal survives for the collision it was always
/// really about — the same Mac dialling twice.
@MainActor
final class MultiGuestListenerTests: XCTestCase {
    private var listener: GuestListener!

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

    /// Something that must NOT happen has no edge to wait for, so these
    /// wait a fixed slice and then assert. Long enough that the thing
    /// under test would have happened on loopback if it were going to.
    private func settle() async throws {
        try await Task.sleep(nanoseconds: 300_000_000)
    }

    private func startListener(maxGuests: Int = 4) async throws {
        listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: 60), maxGuests: maxGuests)
        listener.start(port: 0)
        try await waitUntil("listening") {
            if case .listening = self.listener.state { return true }
            return false
        }
    }

    override func setUp() async throws {
        try await startListener()
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    @discardableResult
    private func dial(_ name: String) async throws -> FakeGuest {
        let guest = FakeGuest(port: listener.boundPort!)
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", version: "0.1.0",
            name: name, os: "9.1", chunk: 8192)))
        try await waitUntil("\(name) answered") { !guest.received.isEmpty }
        return guest
    }

    private func connect(_ name: String) async throws -> FakeGuest {
        let guest = try await dial(name)
        try await waitUntil("\(name) connected") {
            self.listener.guests.contains { $0.name == name }
        }
        return guest
    }

    private func refusal(_ guest: FakeGuest) -> String? {
        for message in guest.received {
            if case .refuse(let refuse) = message { return refuse.reason }
        }
        return nil
    }

    private func answered(_ guest: FakeGuest, id: Int) -> Bool {
        guest.received.contains { message in
            switch message {
            case .fileListing(let listing): return listing.id == id
            case .fileRefuse(let refuse): return refuse.id == id
            default: return false
            }
        }
    }

    private func commandRequestID(_ guest: FakeGuest) -> Int? {
        for message in guest.received {
            if case .commandRequest(let request) = message {
                return request.id
            }
        }
        return nil
    }

    func testTwoDifferentMachinesAreBothServedOnOnePort() async throws {
        let powerPC = try await connect("PowerBook 1400c")
        let m68k = try await connect("PowerBook 180c")

        XCTAssertNil(refusal(m68k),
                     "the second machine is a guest, not a collision")
        XCTAssertEqual(listener.guests.map(\.name),
                       ["PowerBook 1400c", "PowerBook 180c"],
                       "oldest first, so the roster does not reshuffle")
        XCTAssertEqual(listener.guests.filter(\.isActive).map(\.name),
                       ["PowerBook 1400c"],
                       "exactly one is being driven, and it is the first in")
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 1400c"))

        // Both are live: each answers its own ping.
        try powerPC.send(.ping(id: 1))
        try m68k.send(.ping(id: 2))
        try await waitUntil("both pongs") {
            powerPC.received.contains(.pong(id: 1))
                && m68k.received.contains(.pong(id: 2))
        }
    }

    func testAGuestBeyondTheCapIsRefusedWithTheNumber() async throws {
        listener.stop()
        try await startListener(maxGuests: 2)
        _ = try await connect("Quadra 950")
        _ = try await connect("PowerBook 180c")

        let third = try await dial("Power Mac G3")
        XCTAssertEqual(refusal(third), "too many guests connected (2)",
                       "says the bound, so it is not read as a collision")
        XCTAssertEqual(listener.guests.count, 2)
    }

    /// The defect this slice exists to prevent: with one guest, serving
    /// our own share replied on `session` — which meant "the active
    /// guest", not "the one that asked". Accepting a second guest without
    /// this makes the host answer the wrong socket.
    func testTheBackgroundGuestsShareRequestIsAnsweredOnItsOwnSocket()
        async throws {
        let active = try await connect("PowerBook 1400c")
        let background = try await connect("PowerBook 180c")

        try background.send(.fileList(FileList(id: 77, path: "",
                                               cursor: nil)))
        // Either a listing or a refusal — which one depends on this Mac's
        // share, and the point is WHERE the answer went, not what it said.
        try await waitUntil("the asker was answered") {
            self.answered(background, id: 77)
        }
        XCTAssertFalse(answered(active, id: 77),
                       "the active guest never asked and must not be told")
    }

    /// Ids are drawn from one host-side sequence, so a guest can name a
    /// request that was sent to somebody else. Only the connection the
    /// request went out on may settle it.
    func testAnAnswerFromTheBackgroundGuestDoesNotSettleTheActivesCommand()
        async throws {
        let active = try await connect("PowerBook 1400c")
        let background = try await connect("PowerBook 180c")

        var settled: CommandResult?
        listener.runCommand("help") { settled = $0 }
        try await waitUntil("the request reached the active guest") {
            self.commandRequestID(active) != nil
        }
        let id = try XCTUnwrap(commandRequestID(active))
        XCTAssertNil(commandRequestID(background),
                     "a request goes to the driven guest only")

        try background.send(.commandResult(CommandResult(
            id: id, ok: true, output: nil, error: nil)))
        try await settle()
        XCTAssertNil(settled,
                     "the wrong Mac answering must not settle the waiter")

        try active.send(.commandResult(CommandResult(
            id: id, ok: true, output: nil, error: nil)))
        try await waitUntil("the right Mac settles it") { settled != nil }
    }

    func testTheActiveGuestLeavingPromotesTheOther() async throws {
        let active = try await connect("PowerBook 1400c")
        _ = try await connect("PowerBook 180c")

        try active.send(.bye(Bye(code: .normal, reason: nil)))
        try await waitUntil("promotion") {
            self.listener.state == .connected(guestName: "PowerBook 180c")
        }
        XCTAssertEqual(listener.guests.map(\.name), ["PowerBook 180c"])
        XCTAssertEqual(listener.lastDisconnect,
                       "PowerBook 1400c disconnected")
        XCTAssertEqual(listener.health?.guestName, "PowerBook 180c",
                       "health follows the guest being driven")
    }

    /// The live session key for a connected Mac, by the name it reports.
    ///
    /// A test cannot derive a key from a name any more, and should not be
    /// able to: that derivation WAS the defect. It asks the roster, which
    /// is what the picker does.
    private func liveKey(_ name: String) throws -> GuestKey {
        try XCTUnwrap(listener.guests.first { $0.name == name }?.key,
                      "no connected guest called \(name)")
    }

    func testABackgroundGuestLeavingDoesNotDisturbTheConsole()
        async throws {
        _ = try await connect("PowerBook 1400c")
        let background = try await connect("PowerBook 180c")

        try background.send(.bye(Bye(code: .normal, reason: nil)))
        try await waitUntil("the roster shrinks") {
            self.listener.guests.count == 1
        }
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 1400c"),
                       "the guest being driven is untouched")
        XCTAssertEqual(listener.health?.guestName, "PowerBook 1400c")
    }

    func testSelectGuestPointsTheCommandPlaneAtTheOtherMac() async throws {
        let powerPC = try await connect("PowerBook 1400c")
        let m68k = try await connect("PowerBook 180c")

        XCTAssertTrue(listener.selectGuest(try liveKey("PowerBook 180c")))
        XCTAssertEqual(listener.state,
                       .connected(guestName: "PowerBook 180c"))
        XCTAssertEqual(listener.guests.filter(\.isActive).map(\.name),
                       ["PowerBook 180c"])

        listener.runCommand("help") { _ in }
        try await waitUntil("the 68K guest is asked") {
            self.commandRequestID(m68k) != nil
        }
        XCTAssertNil(commandRequestID(powerPC),
                     "the machine we switched away from is left alone")
    }

    /// Switching away settles what was in flight rather than leaving it
    /// to be answered by whichever Mac speaks next.
    func testSwitchingAwayFailsTheOutstandingRequest() async throws {
        _ = try await connect("PowerBook 1400c")
        _ = try await connect("PowerBook 180c")

        var settled: CommandResult?
        listener.runCommand("help") { settled = $0 }
        listener.selectGuest(try liveKey("PowerBook 180c"))
        try await waitUntil("the waiter is answered") { settled != nil }
        XCTAssertEqual(settled?.ok, false)
        XCTAssertEqual(settled?.error?.code, "disconnected")
    }
}
