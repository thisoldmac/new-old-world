import XCTest
@testable import Host

/// `GuestActPumpControl` against a real `GuestListener` over loopback, the
/// same rig `MirrorSessionModelTests` and `GuestCommandTests` use: the
/// property under test is what crosses the wire (`actstate`'s own rows),
/// not anything a fake built from Swift values alone could stand in for.
@MainActor
final class GuestActPumpControlTests: XCTestCase {

    /// One `actstate` reply, shaped the way `mach_actstate.c` writes rows —
    /// label/value pairs under the `"actstate"` group. Only the rows a test
    /// needs are given; `classify` reads by label and does not require the
    /// full report `mach_actstate.c` actually emits.
    private static func actstateReply(id: Int, rows: [[String]]) -> ControlMessage {
        .commandResult(CommandResult(id: id, ok: true,
                                     output: ["actstate": rows], error: nil))
    }

    /// A guest that answers every `actstate` command the same way, and
    /// records how many it was asked.
    private final class Served {
        private(set) var count = 0
        func bump() { count += 1 }
    }

    private func serve(_ guest: FakeGuest, rows: @escaping () -> [[String]])
        -> Served {
        let served = Served()
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message,
                  request.name == "actstate" else { return }
            served.bump()
            try? guest.send(Self.actstateReply(id: request.id, rows: rows()))
        }
        return served
    }

    // MARK: - start()

    /// The plane ready and the pump running settles on the first read —
    /// nothing here should need to poll at all.
    func testStartSucceedsWhenThePumpIsRunning() async throws {
        let (listener, guest) = try await connectedListener()
        let served = serve(guest) {
            [["Plane", "ready"], ["Pump", "running"]]
        }
        let pump = GuestActPumpControl(listener: listener, attempts: 3,
                                       delayNanoseconds: 5_000_000)

        let outcome = await pump.start()

        XCTAssertEqual(outcome, .started)
        XCTAssertEqual(served.count, 1,
                       "a running pump should not need a second look")
    }

    /// The plane is ready but the pump never attaches — every poll comes
    /// back "never attached", so `start()` exhausts its attempts and names
    /// what the guest itself reported: a refusal ("it can and said no this
    /// time"), not an unsupported claim.
    func testStartRefusesByNameWhenThePumpNeverAttaches() async throws {
        let (listener, guest) = try await connectedListener()
        let served = serve(guest) {
            [["Plane", "ready"], ["Pump", "never attached"]]
        }
        let pump = GuestActPumpControl(listener: listener, attempts: 3,
                                       delayNanoseconds: 5_000_000)

        let outcome = await pump.start()

        guard case .refused(let reason) = outcome else {
            return XCTFail("expected .refused, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("never attached"), reason)
        XCTAssertEqual(served.count, 3,
                       "start() should have polled every attempt before "
                       + "giving up")
    }

    /// The extension predates the V4 pump handshake: the plane itself
    /// reports ready (menu/control acts still work), but `mach_actstate.c`
    /// writes "Pump region": "absent…" and nothing past it. This is the
    /// "cannot do this at all" shape — `.unsupported`, not `.refused` — and
    /// settles on the first read since polling cannot change a fact about
    /// which binary is installed.
    func testStartIsUnsupportedWhenThisExtensionPredatesThePump() async throws {
        let (listener, guest) = try await connectedListener()
        let served = serve(guest) {
            [["Plane", "ready"],
             ["Pump region", "absent (this extension predates the act pump)"]]
        }
        let pump = GuestActPumpControl(listener: listener, attempts: 3,
                                       delayNanoseconds: 5_000_000)

        let outcome = await pump.start()

        guard case .unsupported(let reason) = outcome else {
            return XCTFail("expected .unsupported, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("predates the act pump"), reason)
        XCTAssertEqual(served.count, 1,
                       "an extension that predates the pump is not a "
                       + "transient state worth polling for")
    }

    /// A guest build old enough to have no `actstate` verb at all answers
    /// with the exec plane's own `unknown-command` — the "lacks the
    /// capability" case one layer further back than the pump region.
    func testStartIsUnsupportedWhenActstateItselfIsUnknown() async throws {
        let (listener, guest) = try await connectedListener()
        guest.onMessage = { message in
            guard case .commandRequest(let request) = message else { return }
            try? guest.send(.commandResult(CommandResult(
                id: request.id, ok: false, output: nil, outputObjects: nil,
                error: .init(code: "unknown-command",
                            message: "actstate is not a command this "
                                     + "build understands"))))
        }
        let pump = GuestActPumpControl(listener: listener, attempts: 3,
                                       delayNanoseconds: 5_000_000)

        let outcome = await pump.start()

        guard case .unsupported(let reason) = outcome else {
            return XCTFail("expected .unsupported, got \(outcome)")
        }
        XCTAssertTrue(reason.contains("no actstate verb"), reason)
    }

    // MARK: - stop()

    /// `stop()` sends nothing over the wire — the guest tears its own pump
    /// down when the wire session ends, not when this page's Stop does —
    /// and calling it twice is exactly as inert as calling it once.
    func testStopIsIdempotentAndSendsNothing() async throws {
        let (listener, guest) = try await connectedListener()
        let baseline = guest.received.count
        let pump = GuestActPumpControl(listener: listener)

        pump.stop()
        pump.stop()

        // No async boundary crosses stop() by design, so there is nothing
        // to wait for: if it were going to send a command, the request
        // would already be in `received`.
        XCTAssertEqual(guest.received.count, baseline,
                       "stop() has no wire message to send")
    }
}
