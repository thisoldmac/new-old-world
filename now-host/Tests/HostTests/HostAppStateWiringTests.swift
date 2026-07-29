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
        // A specific, unlikely-taken port; listen at launch.
        defaults.set(52981, forKey: "listenPort")
        defaults.set(true, forKey: "listenAtLaunch")

        let state = HostAppState(registry: .standard, defaults: defaults)

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

        let guest = NWConnection(host: .ipv4(.loopback),
                                 port: NWEndpoint.Port(rawValue: 52981)!,
                                 using: .tcp)
        defer { guest.cancel() }
        guest.start(queue: .main)
        let hello = try ControlMessageCodec.encode(.hello(
            Hello(contract: Contract.revision, side: "guest", version: "0.1.0",
                  name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        let frame = try FrameCodec.encode(channel: .control, payload: hello)
        guest.send(content: frame, completion: .idempotent)

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

        state.stopListening()
    }
}
