import XCTest
import Network
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
