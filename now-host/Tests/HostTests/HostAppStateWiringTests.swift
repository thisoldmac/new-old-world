import XCTest
import Network
@testable import Host

/// Exercises the full path a connecting guest drives: HostAppState builds the
/// listener, mirrors its state into the Screenshots model. This is the wiring
/// the live UI observes — not just the Session state machine.
@MainActor
final class HostAppStateWiringTests: XCTestCase {
    func testConnectingGuestFlipsListenerAndScreenshotsBadge() async throws {
        let suite = "HostAppStateWiring.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        /* The one place that still listens AT LAUNCH, which is why it is the
           one place that has to name a port: settings read 0 as unset. The
           number comes from `testListenPort`, not from a constant — 52981
           was "a specific, unlikely-taken port" and sat inside the ephemeral
           range this process hands to its own port-0 listeners, so it took
           the port from itself (docs/open-issues.md, 2026-08-05). */
        defaults.set(Int(testListenPort()), forKey: "listenPort")
        defaults.set(true, forKey: "listenAtLaunch")

        let state = HostAppState(registry: .standard, defaults: defaults)
        /* Not just at the end: a failure below must not leave the port held
           for whatever runs next. */
        defer { state.stopListening() }

        let deadline = Date().addingTimeInterval(8)
        func wait(_ cond: @escaping () -> Bool) async throws {
            while !cond(), Date() < deadline {
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }
        try await wait {
            if case .listening = state.listener.state { return true }
            return false
        }
        guard case .listening = state.listener.state else {
            return XCTFail("listener never became ready: \(state.listener.state)")
        }

        let guest = FakeGuest(port: try XCTUnwrap(state.listener.boundPort))
        defer { guest.connection.cancel() }
        guest.start()
        try guest.send(.hello(
            Hello(contract: Contract.revision, side: "guest", version: "0.1.0",
                  name: "PowerBook 1400", os: "9.1", chunk: 8192)))

        try await wait {
            if case .connected = state.listener.state { return true }
            return false
        }
        XCTAssertEqual(state.listener.state,
                       .connected(guestName: "PowerBook 1400"),
                       "listener state must reflect the connection")
        // The badge mirrors the LISTENER'S key, not one derived from the
        // name: two Macs may report the same name, so a derived key would
        // put one machine's state under the other's badge.
        XCTAssertEqual(state.screenshots.connection.peerLabel,
                       "PowerBook 1400",
                       "Screenshots badge must mirror the connection")
        XCTAssertEqual(state.screenshots.connection,
                       .connected(name: "PowerBook 1400",
                                  key: try XCTUnwrap(
                                    state.listener.activeKey)),
                       "Screenshots badge must mirror the connection")
    }
}
