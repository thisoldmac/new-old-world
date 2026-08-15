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
        /* A fresh registry assigns guest-1. These settings must load when
           that guest arrives even though Mirror has never been constructed:
           Continuity is app-owned now, and Logs may expose it first. */
        defaults.set(true,
                     forKey: "mirror.continuity.deepClickLog.guest-1")
        defaults.set(false,
                     forKey: "mirror.continuity.interruptPress.guest-1")

        let state = HostAppState(registry: .standard, defaults: defaults)
        /* Not just at the end: a failure below must not leave the port held
           for whatever runs next. */
        defer { state.stopListening() }

        /* A budget PER wait, not one shared by both. The two waits are
           independent events — a listener coming ready, then a guest's hello
           arriving — and a single deadline computed once means the first one
           spends the second one's time: on a loaded Mac a slow bind left the
           hello wait with a deadline already past, so it polled zero times
           and the test failed on a connection that was merely late. Same run
           took 0.06 s in isolation and 8.4 s under load. */
        func wait(_ cond: @escaping () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
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
        XCTAssertTrue(state.continuity.deepClickLog)
        XCTAssertFalse(state.continuity.interruptPress)
        // The badge mirrors the LISTENER'S key, not one derived from the
        // name: two Macs may report the same name, so a derived key would
        // put one machine's state under the other's badge.
        let screen = try XCTUnwrap(state.moduleRuntime(
            for: "screen", as: ScreenHostModuleRuntime.self))
        XCTAssertEqual(screen.model.connection.peerLabel,
                       "PowerBook 1400",
                       "Screenshots badge must mirror the connection")
        XCTAssertEqual(screen.model.connection,
                       .connected(name: "PowerBook 1400",
                                  key: try XCTUnwrap(
                                    state.listener.activeKey)),
                       "Screenshots badge must mirror the connection")
    }
}
