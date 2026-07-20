import AppKit
import Network
import XCTest
@testable import Host

@MainActor
final class GuestStatusTests: XCTestCase {
    private func health(lastTraffic: Date,
                        name: String = "PowerBook 1400")
        -> GuestListener.SessionHealth {
        .init(guestName: name, guestVersion: "0.1.0", guestOS: "9.1",
              connectedAt: lastTraffic, lastTraffic: lastTraffic,
              pingsAnswered: 3, framesReceived: 9)
    }

    // MARK: - Derivation

    func testIdleAndListeningBothReadAsNoGuest() {
        XCTAssertEqual(GuestStatus.evaluate(state: .idle, health: nil),
                       .notListening)
        XCTAssertEqual(GuestStatus.evaluate(state: .listening(port: 5252),
                                            health: nil),
                       .waiting(port: 5252))
        XCTAssertFalse(GuestStatus.evaluate(state: .listening(port: 5252),
                                            health: nil).isConnected)
    }

    func testFailureCarriesItsReason() {
        let status = GuestStatus.evaluate(state: .failed("Port 5252 in use"),
                                          health: nil)
        XCTAssertEqual(status, .failed("Port 5252 in use"))
        XCTAssertEqual(status.menuLine, "Port 5252 in use")
        XCTAssertEqual(status.glyph, "⚠")
        XCTAssertFalse(status.isConnected)
    }

    func testFreshTrafficIsConnectedAndNotQuiet() {
        let now = Date()
        let status = GuestStatus.evaluate(
            state: .connected(guestName: "PowerBook 1400"),
            health: health(lastTraffic: now.addingTimeInterval(-2)), now: now)
        XCTAssertTrue(status.isConnected)
        XCTAssertFalse(status.isQuiet)
        XCTAssertEqual(status.glyph, "●")
        XCTAssertEqual(status.menuLine, "Connected: PowerBook 1400")
    }

    /// Past the threshold the Mac is probably sitting in a modal dialog —
    /// still connected, but worth saying so before the idle timeout fires.
    func testSilenceBecomesQuietWithoutBecomingDisconnected() {
        let now = Date()
        let status = GuestStatus.evaluate(
            state: .connected(guestName: "Quadra 950"),
            health: health(lastTraffic: now.addingTimeInterval(-34),
                           name: "Quadra 950"), now: now)
        XCTAssertTrue(status.isConnected, "quiet is not gone")
        XCTAssertTrue(status.isQuiet)
        XCTAssertEqual(status.glyph, "◐")
        XCTAssertEqual(status.menuLine, "Quadra 950 — quiet for 34s")
    }

    func testQuietThresholdSitsWellBeforeTheIdleTimeout() {
        // 75s is when the listener declares the guest gone; "quiet" has to
        // show up meaningfully earlier or it never shows up at all.
        XCTAssertLessThan(GuestStatus.quietAfter, 75)
    }

    /// The hello has landed but no health record exists yet for that first
    /// instant; that must read as fresh, not as silence since 1970.
    func testConnectedWithoutHealthYetIsTreatedAsFresh() {
        let status = GuestStatus.evaluate(
            state: .connected(guestName: "PowerBook 1400"), health: nil)
        XCTAssertFalse(status.isQuiet)
        XCTAssertEqual(status.menuLine, "Connected: PowerBook 1400")
    }

    // MARK: - Monitor

    func testMonitorStartsDisconnectedAndTracksTheListener() async throws {
        let listener = GuestListener(
            identity: .init(version: "0.1-test", name: "Test Host"))
        let monitor = GuestStatusMonitor(listener: listener)
        XCTAssertEqual(monitor.status, .notListening)

        listener.start(port: 0)
        let deadline = Date().addingTimeInterval(5)
        while !monitor.status.isConnected, Date() < deadline {
            monitor.refresh()
            if case .waiting = monitor.status { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .waiting = monitor.status else {
            return XCTFail("expected waiting, got \(monitor.status)")
        }
        listener.stop()
        monitor.refresh()
        XCTAssertEqual(monitor.status, .notListening)
    }

    // MARK: - Menu header

    func testHeaderShowsTheConnectionWhenNothingIsBlocking() {
        let delegate = AppDelegate()
        let line = delegate.statusHeaderLine(
            status: .connected(name: "PowerBook 1400", quietFor: 1),
            readiness: .init(isEnabled: true, reason: nil))
        XCTAssertEqual(line, "Connected: PowerBook 1400")
    }

    /// A connected-but-greyed-out command is the confusing case: the header
    /// has to say which lane occupant is responsible.
    func testHeaderExplainsAGreyOutThatTheConnectionDoesNotExplain() {
        let delegate = AppDelegate()
        let line = delegate.statusHeaderLine(
            status: .connected(name: "PowerBook 1400", quietFor: 1),
            readiness: .init(isEnabled: false,
                             reason: "A file transfer is using the connection"))
        XCTAssertEqual(line, "Connected: PowerBook 1400 — a file transfer "
                       + "is using the connection")
    }

    /// When there is no guest the connection line already says everything;
    /// appending "no Mac is connected" to it would just stutter.
    func testHeaderDoesNotRestateAMissingGuest() {
        let delegate = AppDelegate()
        let line = delegate.statusHeaderLine(
            status: .waiting(port: 5252),
            readiness: .init(isEnabled: false, reason: "No Mac is connected"))
        XCTAssertEqual(line, "Listening on 5252 — no Mac connected")
    }

    /// End to end over a real loopback connection: a guest saying hello must
    /// move the menu bar from "no Mac connected" with the command greyed out
    /// to "Connected" with it live — the two halves of what the menu bar
    /// promises, proven together rather than each in isolation.
    func testARealGuestFlipsBothTheStatusAndTheCommand() async throws {
        let suite = "GuestStatusE2E.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(52983, forKey: "listenPort")
        defaults.set(true, forKey: "listenAtLaunch")

        let state = HostAppState(registry: .standard, defaults: defaults)
        let deadline = Date().addingTimeInterval(8)
        func wait(_ cond: @escaping () -> Bool) async throws {
            while !cond(), Date() < deadline {
                state.guestStatus.refresh()
                try await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        try await wait { if case .waiting = state.guestStatus.status
                         { return true } else { return false } }
        guard case .waiting(let port) = state.guestStatus.status else {
            return XCTFail("never listened: \(state.guestStatus.status)")
        }
        XCTAssertEqual(port, 52983)
        XCTAssertFalse(state.quickCapture.readiness.isEnabled,
                       "no guest — the command must be greyed out")
        XCTAssertEqual(state.quickCapture.readiness.reason,
                       "No Mac is connected")

        let guest = NWConnection(host: .ipv4(.loopback),
                                 port: NWEndpoint.Port(rawValue: 52983)!,
                                 using: .tcp)
        defer { guest.cancel() }
        guest.start(queue: .main)
        let hello = try ControlMessageCodec.encode(.hello(
            Hello(contract: Contract.revision, side: "guest", version: "0.1.0",
                  name: "PowerBook 1400", os: "9.1", chunk: 8192)))
        guest.send(content: try FrameCodec.encode(channel: .control,
                                                  payload: hello),
                   completion: .idempotent)

        try await wait { state.guestStatus.status.isConnected }
        XCTAssertEqual(state.guestStatus.status.menuLine,
                       "Connected: PowerBook 1400")
        XCTAssertEqual(state.guestStatus.status.glyph, "●")
        XCTAssertTrue(state.quickCapture.readiness.isEnabled,
                      "a connected guest must enable the command")

        state.stopListening()
        state.guestStatus.refresh()
        XCTAssertEqual(state.guestStatus.status, .notListening)
        XCTAssertFalse(state.quickCapture.readiness.isEnabled,
                       "the command must go grey again when the wire closes")
    }

    func testStatusLineIsTheFirstMenuItemAndIsNotClickable() throws {
        let delegate = AppDelegate()
        let menu = delegate.makeStatusMenu()
        let header = try XCTUnwrap(menu.item(withTag: AppDelegate.statusLineTag))
        XCTAssertEqual(menu.items.first, header, "status reads first")
        XCTAssertNil(header.action, "the header is a label, not a command")
        XCTAssertFalse(header.isEnabled)
    }
}
