import XCTest
import Network
import Combine
@testable import Host

/// A scripted guest: dials the listener over loopback, sends frames, and
/// collects decoded control replies.
@MainActor
private final class FakeGuest {
    let connection: NWConnection
    private let decoder = FrameDecoder()
    private(set) var received: [ControlMessage] = []
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

    private func guestHello(name: String = "PowerBook 1400",
                            contract: Int = Contract.revision) -> ControlMessage {
        .hello(Hello(contract: contract, side: "guest", version: "0.1.0",
                     name: name, os: "9.1", chunk: 8192))
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

    func testSecondGuestIsRefusedBusyAndFirstSurvives() async throws {
        let first = FakeGuest(port: listener.boundPort!)
        first.start()
        try first.send(guestHello(name: "Quadra 950"))
        try await waitUntil("first connected") {
            self.listener.state == .connected(guestName: "Quadra 950")
        }

        let second = FakeGuest(port: listener.boundPort!)
        second.start()
        try second.send(guestHello(name: "PowerBook 1400"))
        try await waitUntil("busy refusal") { !second.received.isEmpty }
        guard case .refuse(let refuse) = second.received[0] else {
            return XCTFail("expected refuse, got \(second.received)")
        }
        XCTAssertEqual(refuse.reason, "busy: Quadra 950")
        XCTAssertEqual(listener.state,
                       .connected(guestName: "Quadra 950"))

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

        listener.startStream(depth: 8)
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

    func testGuestAbortReportsItsReason() async throws {
        let guest = try await connectedGuest()
        listener.startStream(depth: 1)
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
        listener.startStream(depth: 8)
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
        listener.startStream(depth: 8)
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
        listener.startStream(depth: 8)
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
            $0.text.contains("Connected: Quadra 950") })

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

@MainActor
final class ConsoleModelTests: XCTestCase {
    func testTypingGestaltRendersGuestOutput() async throws {
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
            if case .commandRequest(let req) = message {
                try? guest.send(.commandResult(CommandResult(
                    id: req.id, ok: true,
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

        let console = ConsoleModel(listener: listener)
        console.input = "gestalt"
        console.submit()
        while console.lines.allSatisfy({ !$0.text.contains("carbonLib") }),
              Date() < deadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(console.lines.contains { $0.text.contains("1.6") },
                      "console should render the guest's gestalt output")
        // Unknown command is a local, honest failure — no wire traffic.
        console.input = "teleport"
        console.submit()
        XCTAssertTrue(console.lines.contains {
            $0.text.contains("not a declared command") })

        // help + --help render locally from the catalog, no wire round-trip.
        console.input = "help"
        console.submit()
        XCTAssertTrue(console.lines.contains {
            $0.text.contains("gestalt") && $0.text.contains("CarbonLib") })
        console.input = "gestalt --help"
        console.submit()
        XCTAssertTrue(console.lines.contains {
            $0.text.contains("Usage: gestalt") })
        console.input = "gestalt -h"
        console.submit()
        XCTAssertEqual(console.lines.filter {
            $0.text.contains("Usage: gestalt") }.count, 2)

        // A domain flag shows only that group.
        console.input = "gestalt --cpu"
        console.submit()
        let cpuDeadline = Date().addingTimeInterval(5)
        while console.lines.allSatisfy({ !$0.text.contains("603e") }),
              Date() < cpuDeadline {
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertTrue(console.lines.contains { $0.text.contains("PowerPC 603e") })
        listener.stop()
    }
}
