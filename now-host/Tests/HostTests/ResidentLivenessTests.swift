import XCTest
@testable import Host

/// **Telling a STARVED Macintosh from a GONE one.**
///
/// On a cooperatively-scheduled machine a blocked callee starves every
/// application, so the guest cannot send its own keepalive exactly when
/// the host most needs to know the machine is alive. Measured 2026-08-05:
/// the Finder's "could not find the application program" alert starved
/// every process on the guest — including an unrelated background
/// application on its own port — for over 90 s, past the host's silence
/// window, so the wire died against a perfectly healthy Macintosh.
///
/// A resident component dials its own `role: resident` connection and
/// keeps it alive. Traffic there licenses one inference and no more: the
/// MACHINE is alive, so a silent session for it is starved rather than
/// gone.
///
/// Every test here runs against a real `GuestListener` over a real socket
/// with a short silence window, because the thing under test is a timer
/// and a policy meeting each other.
@MainActor
final class ResidentLivenessTests: XCTestCase {

    /// A listener whose silence window is short enough to watch.
    private func listening(idleTimeout: TimeInterval = 0.4) async throws
        -> GuestListener {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"),
            timing: .init(idleTimeout: idleTimeout))
        listener.start(port: 0)
        try await waitUntil("listener ready") {
            if case .listening = listener.state { return true }
            return false
        }
        return listener
    }

    private func dial(_ listener: GuestListener, name: String,
                      role: String? = nil) throws -> FakeGuest {
        let guest = FakeGuest(port: try XCTUnwrap(listener.boundPort))
        guest.start()
        try guest.send(.hello(Hello(
            contract: Contract.revision, side: "guest", role: role,
            version: "0.1.0", name: name, os: "9.1", chunk: 8192)))
        return guest
    }

    /// **The defect, in one test.** With nothing else answering for the
    /// machine, a silent guest is declared gone — which is right when it
    /// IS gone and was wrong on 2026-08-05.
    func testASilentGuestWithNoResidentChannelIsStillDeclaredGone()
        async throws {
        let listener = try await listening()
        let guest = try dial(listener, name: "PowerBook 1400")
        defer { guest.connection.cancel(); listener.stop() }
        try await waitUntil("connected") {
            if case .connected = listener.state { return true }
            return false
        }
        let key = try XCTUnwrap(listener.activeKey)

        // Say nothing at all, for several silence windows.
        try await waitUntil("the session is declared gone", timeout: 5) {
            !listener.isConnected(key)
        }
    }

    /// The fix: the same silence, with the machine proving itself alive on
    /// a channel the starved application does not own.
    func testAStarvedGuestSurvivesWhileItsMachineKeepsAnswering()
        async throws {
        let listener = try await listening()
        let guest = try dial(listener, name: "PowerBook 1400")
        try await waitUntil("connected") {
            if case .connected = listener.state { return true }
            return false
        }
        let key = try XCTUnwrap(listener.activeKey)

        let resident = try dial(listener, name: "PowerBook 1400",
                                role: "resident")
        defer {
            guest.connection.cancel(); resident.connection.cancel()
            listener.stop()
        }
        try await waitUntil("the resident channel is filed") {
            listener.machineIsAnswering(sessionKey: key)
        }

        /* The application says nothing while the resident keeps pinging —
           which is the wedge, reproduced without a Macintosh. */
        for _ in 0..<6 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            try resident.send(.ping(id: 1))
        }

        XCTAssertTrue(listener.isConnected(key),
                      "the session must survive: the machine is answering, "
                          + "so this application is starved and not gone")
        XCTAssertEqual(listener.isAnswering(key), false,
                       "and it must NOT read as healthy — a starved guest "
                           + "shown as connected is how a person concludes "
                           + "the Mirror is broken")
    }

    /// **The regression this pairs with.** A held-open session must still
    /// die once its machine stops proving itself, or the resident channel
    /// has bought an immortal session — strictly worse than the defect it
    /// replaced, because the host would believe in a guest forever.
    func testTheSessionDiesOnceTheResidentChannelGoesToo() async throws {
        let listener = try await listening()
        let guest = try dial(listener, name: "PowerBook 1400")
        try await waitUntil("connected") {
            if case .connected = listener.state { return true }
            return false
        }
        let key = try XCTUnwrap(listener.activeKey)
        let resident = try dial(listener, name: "PowerBook 1400",
                                role: "resident")
        defer { guest.connection.cancel(); listener.stop() }
        try await waitUntil("the resident channel is filed") {
            listener.machineIsAnswering(sessionKey: key)
        }
        try? await Task.sleep(nanoseconds: 600_000_000)
        XCTAssertTrue(listener.isConnected(key), "held while alive")

        resident.connection.cancel()
        try await waitUntil("the machine stops answering", timeout: 5) {
            !listener.machineIsAnswering(sessionKey: key)
        }

        try await waitUntil("the session is now declared gone", timeout: 5) {
            !listener.isConnected(key)
        }
    }

    /// **Ambiguous means NO, and this is the test that says so.**
    ///
    /// Two Macintoshes calling themselves the same thing from one address
    /// — the ordinary emulator case, which `mintSessionKey` already guards
    /// against — are indistinguishable to a resident channel. If one
    /// machine's resident were allowed to vouch for the other's wedged
    /// session, a genuinely dead guest would be held open for as long as
    /// its namesake kept pinging: an immortal session, which is worse than
    /// the timeout it replaced because nothing would ever correct it.
    ///
    /// So a resident speaks only when exactly one live session matches it,
    /// and with two the old behaviour stands.
    func testAResidentWillNotVouchWhenTwoMachinesShareItsName()
        async throws {
        let listener = try await listening()
        let first = try dial(listener, name: "PowerBook 1400")
        try await waitUntil("the first guest is connected") {
            listener.activeKey != nil
        }
        let key = try XCTUnwrap(listener.activeKey)
        let second = try dial(listener, name: "PowerBook 1400")
        let resident = try dial(listener, name: "PowerBook 1400",
                                role: "resident")
        defer {
            first.connection.cancel(); second.connection.cancel()
            resident.connection.cancel(); listener.stop()
        }
        try await waitUntil("both guests are connected") {
            listener.guests.count == 2
        }
        try await waitUntil("the resident hello is answered") {
            resident.received.contains { if case .hello = $0 { return true }
                                         return false }
        }

        XCTAssertFalse(listener.machineIsAnswering(sessionKey: key),
                       "with two same-named machines the resident cannot "
                           + "say WHICH of them it speaks for, and a wrong "
                           + "guess holds a dead guest open forever")

        // And the consequence: the silent session still dies, as before.
        try await waitUntil("the silent session is declared gone",
                            timeout: 5) {
            !listener.isConnected(key)
        }
    }

    /// A resident channel is not a guest. It never becomes the one being
    /// driven, or the console, the modules and the agent projection would
    /// all be handed a connection that cannot answer a command.
    func testAResidentChannelIsNeverTheActiveGuest() async throws {
        let listener = try await listening(idleTimeout: 60)
        let resident = try dial(listener, name: "PowerBook 1400",
                                role: "resident")
        defer { resident.connection.cancel(); listener.stop() }
        /* Waited on the guest's OWN hello being answered, so the
           assertion below cannot pass merely by racing the handshake — an
           activeKey that is nil because nothing has arrived yet would
           prove nothing. */
        try await waitUntil("the resident hello is answered") {
            resident.received.contains { if case .hello = $0 { return true }
                                         return false }
        }

        XCTAssertNil(listener.activeKey,
                     "a liveness channel must never become the active guest")
    }

    /// **A liveness channel carries liveness and NOTHING else.** The
    /// contract allows it hello, ping and bye; anything more would be a
    /// resident component claiming a lane it has no business in, and a
    /// host that quietly served it would let a bug on the guest turn the
    /// machine's heartbeat into a second, unaccountable command path.
    ///
    /// It is also the load-bearing half of the vouching rule: this channel
    /// can keep a session alive, so what it is allowed to say has to be a
    /// closed set rather than whatever the guest happens to send.
    func testAResidentChannelMaySendOnlyLiveness() async throws {
        let listener = try await listening(idleTimeout: 60)
        let resident = try dial(listener, name: "PowerBook 1400",
                                role: "resident")
        defer { resident.connection.cancel(); listener.stop() }
        try await waitUntil("the resident hello is answered") {
            resident.received.contains { if case .hello = $0 { return true }
                                         return false }
        }

        // A perfectly well-formed message that this channel may not send.
        try resident.send(.commandResult(
            CommandResult(id: 1, ok: true, output: nil, error: nil)))

        try await waitUntil("the channel is dropped for protocol error") {
            resident.received.contains {
                if case .bye(let bye) = $0 {
                    return bye.code == .protocolError
                }
                return false
            }
        }
    }

    /// An unknown role is a NEWER sender and is refused, rather than served
    /// as a session — serving it would hand a liveness-only channel a
    /// command lane it cannot answer, and its silence would then read as a
    /// wedged Macintosh.
    func testAnUnknownRoleIsRefusedRatherThanServedAsASession()
        async throws {
        let listener = try await listening(idleTimeout: 60)
        let odd = try dial(listener, name: "PowerBook 1400",
                           role: "telemetry")
        defer { odd.connection.cancel(); listener.stop() }

        try await waitUntil("refused") {
            odd.received.contains { if case .refuse = $0 { return true }
                                    return false }
        }
        XCTAssertNil(listener.activeKey)
    }
}
