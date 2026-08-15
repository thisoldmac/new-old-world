import Foundation
import Network
import XCTest
@testable import Host

/// Live emulator acceptance for slice 2 of
/// `docs/local/plan-host-to-guest-drag-2026-08-15.md`: the guest's real
/// Drag Manager promise drag of a published `continuity.offer`.
///
///     NOW_DRAG_LIVE_PORT=<wire port> swift test --filter LiveDragManagerAcceptanceTests
///
/// Opt-in and env-gated exactly like its slice-1 sibling and the
/// `Metal*Tests`: a guest that does not answer once opted in is a FAILURE,
/// not a skip (AGENTS.md > Testing). An emulator guest, so it asserts
/// against a lane's wire port rather than `NOW_METAL_PORT`.
///
/// WHAT THIS CAN AND CANNOT SEE, said plainly because the difference is
/// the whole reason the slice has a state machine the host `cc` runs
/// separately:
///
///   - Reachable from here: every refusal by NAME, on a real guest, over
///     both faces — no offer, over-cap, busy, nothing-to-cancel — plus the
///     arm/expire cycle, which is the apply-race guard's observable half.
///     An arm that expires `button-never-came` is POSITIVE evidence that
///     the drag did not start from wire arrival, because the request was
///     accepted and no drag followed.
///   - NOT reachable from here: the drop itself. `TrackDrag` needs the
///     applied button, which is the resident's synthetic one, driven over
///     the Continuity UDP plane. `testDragRipensWhenTheButtonIsApplied`
///     attempts exactly that and says which half it got.
///
/// ONE GUEST, MANY TESTS. Every case here drives the SAME live guest
/// process, so state outlives a test: the drag machine, the one-at-a-time
/// transfer lane, and the offer table are all shared. A case that leaves a
/// transfer running fails whichever case runs next, and it fails there
/// rather than here — the cancel case once went red after 85 seconds while
/// passing in isolation for exactly that reason. So each case leaves the
/// lane idle before it returns, and none asserts on a state it did not
/// itself establish.
///
/// The size-cap case deliberately publishes a file just over the guest's
/// own `kNowContinuityDragPromiseCapBytes`. The number is NOT imported
/// from the guest header — it is written here as a literal, so a cap
/// changed on one side and not the other shows up as a live guest
/// accepting a file this test expected it to refuse.
@MainActor
final class LiveDragManagerAcceptanceTests: XCTestCase {
    /// The guest's promise cap, restated rather than shared. See above.
    private let guestPromiseCapBytes = 1_048_576

    private var listener: GuestListener!
    private var port: UInt16 = 0

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOW_DRAG_LIVE_PORT"] != nil,
            "set NOW_DRAG_LIVE_PORT=<wire port> to run against a live guest")
        port = UInt16(
            ProcessInfo.processInfo.environment["NOW_DRAG_LIVE_PORT"]!)!
        listener = GuestListener(identity: .init(
            version: "0.2.0-slice2-live", name: "Slice-2 Drag Harness"))
        let deadline = Date().addingTimeInterval(10)
        while true {
            listener.start(port: port)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard case .failed = listener.state, Date() < deadline else {
                break
            }
            listener.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func waitConnected() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if case .connected = listener.state, listener.activeKey != nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("no guest dialled in on \(port) within 60s")
    }

    @discardableResult
    private func arm(epoch: UInt32) async throws -> UInt16? {
        var acked = false
        var reportEpoch: UInt32 = 0
        var armState = ""
        var udpPort: UInt16?
        listener.onContinuityReport = { _, report in
            reportEpoch = report.epoch
            armState = report.state
            udpPort = report.udpPort.map(UInt16.init)
            acked = true
        }
        listener.armContinuity(nonceHi: 2, nonceLo: 2, epoch: epoch,
                               requestedHz: 30, leaseTicks: 3600)
        let deadline = Date().addingTimeInterval(15)
        while !acked, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(acked, "no continuity.report ack within 15s")
        XCTAssertEqual(reportEpoch, epoch)
        print("=== continuity armed: epoch=\(reportEpoch) state=\(armState) "
              + "udpPort=\(String(describing: udpPort)) ===")
        return udpPort
    }

    private func execLine(_ line: String) async -> GuestListener.ExecOutcome {
        await withCheckedContinuation { cont in
            listener.exec(line) { cont.resume(returning: $0) }
        }
    }

    private func runCommand(_ name: String,
                            line: String) async -> CommandResult {
        await withCheckedContinuation { cont in
            listener.runCommand(name, line: line) { cont.resume(returning: $0) }
        }
    }

    /// THE CONSOLE FACE DOES NOT ANSWER `ok` THE WAY THE WIRE FACE DOES,
    /// and the first live run of this file asserted as though it did — so
    /// three cases went red naming the product when the defect was here.
    ///
    /// `exec` reports whether the LINE RAN. A guest that refused by name
    /// ran the line perfectly well and put its refusal in the output, so
    /// `ok` is true and the sentence a person reads is in `text`. The wire
    /// face, being typed, carries the same refusal as `ok=false` +
    /// `error.message`. Both are correct and they are not interchangeable;
    /// asserting on `ok` here tests the console's plumbing rather than the
    /// guest's answer. Slice 1's sibling file records the same trap for
    /// `--take`.
    private func assertConsoleSaid(_ outcome: GuestListener.ExecOutcome,
                                   contains needle: String,
                                   _ what: String,
                                   file: StaticString = #filePath,
                                   line: UInt = #line) {
        XCTAssertTrue(
            outcome.text.contains(needle),
            "\(what): expected the console to say \"\(needle)\", got: "
                + "\(outcome.text)", file: file, line: line)
    }

    private func write(bytes: Int, label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-slice2-\(label)-\(UUID().uuidString).bin")
        try Data(repeating: 0x4E, count: bytes).write(to: url)
        return url
    }

    // MARK: - refusals, by name, on a real guest

    func testDragRefusesByNameWithNothingHeldOut() async throws {
        try await waitConnected()
        try await arm(epoch: 525_251)

        // No offer published under this epoch at all.
        let attempt = await execLine("offer --drag")
        print("=== --drag with no offer: ok=\(attempt.ok) "
              + "code=\(attempt.code ?? "") message=\(attempt.message ?? "") "
              + "text=\(attempt.text) ===")
        assertConsoleSaid(attempt, contains: "Nothing is being held out",
                          "a drag of nothing must be refused BY NAME; a "
                              + "generic failure is indistinguishable from "
                              + "a guest that does not know the act at all")
        XCTAssertFalse(attempt.text.contains("armed"),
                       "a drag of nothing must not arm")

        // And the same act over the OTHER face, same grammar.
        let wire = await runCommand("offer", line: "--drag")
        print("=== wire face --drag with no offer: ok=\(wire.ok) "
              + "code=\(wire.error?.code ?? "") "
              + "message=\(wire.error?.message ?? "") ===")
        XCTAssertFalse(wire.ok)
        XCTAssertEqual(wire.error?.message,
                       "Nothing is being held out right now",
                       "both faces must refuse in the same words — one "
                           + "implementation behind them is the rule")
    }

    func testDragRefusesOverTheSizeCapByName() async throws {
        try await waitConnected()
        try await arm(epoch: 525_252)

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        let big = try write(bytes: guestPromiseCapBytes + 1, label: "over")
        defer { try? FileManager.default.removeItem(at: big) }

        guard case .published(let item) = control.publish(
            fileAt: big, epoch: 525_252, generation: 1) else {
            return XCTFail("publishing the over-cap file failed")
        }
        print("=== published \(guestPromiseCapBytes + 1) bytes: \(item) ===")

        let attempt = await execLine("offer --drag")
        print("=== --drag over the cap: text=\(attempt.text) ===")
        assertConsoleSaid(attempt, contains: "Too big",
                          "over the cap must refuse: the promise callback "
                              + "runs inside the Finder's drop handling, and "
                              + "v1's answer to an enormous file is a named "
                              + "refusal rather than a progress bar nobody "
                              + "can see")
        // THE REFUSAL MUST NAME THE ACTUAL SIZE, and this line exists
        // because the first live run passed while the guest said "0 bytes;
        // the limit is 1048576" about a 1048577-byte file. A refusal that
        // argues against itself is worse than a bare one, and a guard that
        // only looked for "Too big" was green for the wrong reason — the
        // same class as a mutation-unwatched test.
        assertConsoleSaid(attempt, contains: "\(guestPromiseCapBytes + 1)",
                          "the size refusal must name the file's OWN size, "
                              + "not whatever the drag state happened to "
                              + "hold (a refusal leaves that state untouched "
                              + "on purpose, so it is empty here)")
        assertConsoleSaid(attempt, contains: "\(guestPromiseCapBytes)",
                          "and the limit it was measured against")
        XCTAssertFalse(attempt.text.contains("armed"),
                       "an over-cap file must not arm a drag")
        // The wire face carries the same refusal in its typed form.
        let wireOver = await runCommand("offer", line: "--drag")
        let wireOverMessage = wireOver.error?.message ?? "nil"
        print("=== wire face --drag over the cap: \(wireOverMessage) ===")
        XCTAssertFalse(wireOver.ok)
        XCTAssertTrue(wireOverMessage.contains("Too big"),
                      "both faces must refuse in the same words: "
                          + wireOverMessage)

        // The SAME file is still perfectly takeable — the cap is about
        // streaming inside somebody else's nested loop, not about the file.
        let take = await execLine("offer --take")
        print("=== --take of the same over-cap file: text=\(take.text) ===")
        assertConsoleSaid(take, contains: "Asked for",
                          "the cap must bound the DRAG only; refusing "
                              + "--take of the same file would mean the "
                              + "limit had leaked into the lane it was "
                              + "never about")
        // WAIT FOR THE LANE, DO NOT GUESS AT IT. These tests share one
        // live guest process, so a 1 MB transfer still running when this
        // test returns is the NEXT test's problem — and it presented as a
        // cancel test failing after 85 seconds while passing in isolation,
        // which is the most expensive shape of flake to read. A fixed
        // sleep is what produced that; polling until the guest says the
        // pull is done is what fixes it.
        var settled = false
        for _ in 0..<40 {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            let again = await execLine("offer --take")
            // "A transfer is already in flight" means the lane is still
            // busy; anything else means the previous one let go.
            if !again.text.contains("already in flight") {
                settled = true
                break
            }
        }
        XCTAssertTrue(settled,
                      "the over-cap --take never let go of the lane inside "
                          + "80s; leaving it running would make whichever "
                          + "test ran next fail for a reason that is not "
                          + "about it")
        try await Task.sleep(nanoseconds: 5_000_000_000)
    }

    func testUnderTheCapArmsAndExpiresWithoutAnAppliedButton() async throws {
        try await waitConnected()
        try await arm(epoch: 525_253)

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        let small = try write(bytes: 4096, label: "small")
        defer { try? FileManager.default.removeItem(at: small) }
        guard case .published = control.publish(
            fileAt: small, epoch: 525_253, generation: 1) else {
            return XCTFail("publish failed")
        }

        let armed = await execLine("offer --drag")
        print("=== --drag under the cap: text=\(armed.text) ===")
        assertConsoleSaid(armed, contains: "armed",
                          "the reply must say ARMED rather than dragging — "
                              + "the drag begins on applied button state, "
                              + "and claiming otherwise would be the apply "
                              + "race written into the console's own words")

        // THE APPLY-RACE GUARD, OBSERVED. No button is being applied, so
        // the arm must expire by name. That it expires rather than having
        // dragged is the positive evidence that wire arrival did not start
        // a drag: had it, the state would not be waiting on anything.
        // kNowContinuityDragArmTicks is 120 ticks — two seconds.
        try await Task.sleep(nanoseconds: 4_000_000_000)
        let report = await execLine("offer")
        print("=== report after the arm window: \(report.text) ===")
        XCTAssertTrue(
            report.text.contains("button-never-came"),
            "an arm with no applied button must expire NAMING itself; "
                + "anything else means it either hung or started a drag "
                + "from wire arrival. Got: " + report.text)

        // And having expired, the machine takes a fresh arm rather than
        // staying stuck busy — the failure mode that would wedge the verb.
        let again = await execLine("offer --drag")
        print("=== re-arm after expiry: text=\(again.text) ===")
        assertConsoleSaid(again, contains: "armed",
                          "an expired arm must not leave the verb busy")
        _ = await execLine("offer --stop")
    }

    func testCancelIsAVerbThatWorksAndRefusesWhenThereIsNothingToStop()
        async throws
    {
        try await waitConnected()
        try await arm(epoch: 525_254)

        // Nothing armed: --stop refuses by name rather than pretending.
        let idle = await execLine("offer --stop")
        print("=== --stop with nothing armed: text=\(idle.text) ===")
        assertConsoleSaid(idle, contains: "No drag to stop",
                          "a cancel with nothing to cancel must refuse by "
                              + "name rather than pretend it stopped one")

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        let small = try write(bytes: 4096, label: "cancel")
        defer { try? FileManager.default.removeItem(at: small) }
        guard case .published = control.publish(
            fileAt: small, epoch: 525_254, generation: 1) else {
            return XCTFail("publish failed")
        }

        let armed = await execLine("offer --drag")
        assertConsoleSaid(armed, contains: "armed", "arm before cancel")

        // Cancelled BEFORE the button ripens, which is the case this side
        // still owns outright — it must end then and there, not linger.
        let stopped = await execLine("offer --stop")
        print("=== --stop while armed: text=\(stopped.text) ===")
        assertConsoleSaid(stopped, contains: "stopping", "cancel while armed")

        let report = await execLine("offer")
        print("=== report after cancel: \(report.text) ===")
        XCTAssertTrue(report.text.contains("cancelled"),
                      "a cancelled drag must say so: " + report.text)
        // Idle again, so a second stop refuses exactly as the first did.
        let againIdle = await execLine("offer --stop")
        print("=== second --stop after the cancel: text=\(againIdle.text) ===")
        assertConsoleSaid(againIdle, contains: "No drag to stop",
                          "after a cancel the machine must be idle, so "
                              + "there is nothing left to stop")
    }

    // MARK: - the half that needs the button plane

    /// Attempts the whole gesture: arm, then drive the applied button down
    /// over the Continuity UDP plane so the arm ripens into a real
    /// `TrackDrag`.
    ///
    /// This test REPORTS what it reached rather than asserting a drop.
    /// Whether the datagram lands depends on the emulator's UDP forward
    /// matching the port the guest chose, and a drop needs a Finder target
    /// under the pointer — neither is a property of this slice's code, and
    /// asserting on them here would produce a red that names the rig
    /// instead of the product. What it DOES assert is the one thing that is
    /// ours: that the guest's state left `waiting-button` if and only if
    /// the plane actually applied a button.
    func testDragRipensWhenTheButtonIsApplied() async throws {
        try await waitConnected()
        let udpPort = try await arm(epoch: 525_255)

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        let small = try write(bytes: 4096, label: "ripen")
        defer { try? FileManager.default.removeItem(at: small) }
        guard case .published = control.publish(
            fileAt: small, epoch: 525_255, generation: 1) else {
            return XCTFail("publish failed")
        }

        guard let udpPort else {
            print("=== NO udpPort in the continuity report: the button "
                  + "plane cannot be driven from here, so the drop half is "
                  + "UNVERIFIED in this run ===")
            return
        }

        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: udpPort)!, using: .udp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await Task.sleep(nanoseconds: 500_000_000)

        func send(_ packet: ContinuityStateDatagram) {
            connection.send(content: ContinuityDatagramCodec.encode(packet),
                            completion: .contentProcessed { _ in })
        }

        // Position first, button after: the drag is meant to start where
        // the pointer already is, and a packet carrying both at once
        // cannot show which of the two the guest acted on.
        var sequence: UInt32 = 1
        var generation: UInt32 = 1
        func packet(down: Bool) -> ContinuityStateDatagram {
            sequence &+= 1
            return ContinuityStateDatagram(
                nonceHi: 2, nonceLo: 2, epoch: 525_255,
                positionSequence: sequence, h: 300, v: 240,
                buttonGeneration: generation,
                flags: down ? [.inside, .primaryDown] : [.inside],
                requestedHz: 30, hostStamp: 0)
        }

        for _ in 0..<10 { send(packet(down: false)) ; try await Task.sleep(nanoseconds: 30_000_000) }

        let armed = await execLine("offer --drag")
        assertConsoleSaid(armed, contains: "armed",
                          "the arm must be placed before the button is "
                              + "driven, or this measures nothing")
        print("=== armed, now driving the applied button down ===")

        generation &+= 1
        // Held down well past the 120-tick arm window, so the arm has every
        // chance to ripen rather than expire under a single packet.
        for _ in 0..<120 {
            send(packet(down: true))
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        let during = await execLine("offer")
        print("=== report while the button is held: \(during.text) ===")

        generation &+= 1
        for _ in 0..<10 {
            send(packet(down: false))
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        try await Task.sleep(nanoseconds: 2_000_000_000)

        let after = await execLine("offer")
        print("=== report after the button came up: \(after.text) ===")

        // THE GUEST'S OWN ACCOUNT, because a report line says what the
        // state machine ended at and not what the plane did on the way.
        // Every drag line logs under "mirror" (see continuity_dragmgr.c on
        // why it is not a word of its own), so this is where an arm that
        // ripened, an arm that expired, and an arm somebody tore down are
        // three visibly different stories rather than one idle state.
        let log = await runCommand("tail", line: "40")
        print("=== guest log tail after the button drive ===")
        print(String(describing: log.output))

        // THE ONE ASSERTION THAT IS OURS. If the plane never applied a
        // button, the arm can only have expired `button-never-came`; if it
        // did, the drag must have started and therefore ENDED with some
        // other verdict. What must never happen is a state still waiting on
        // a button seconds after the window closed — that is the arm
        // hanging, which is the failure the whole named-expiry path exists
        // to prevent.
        XCTAssertFalse(
            after.text.contains("waiting-button"),
            "the arm is still waiting long after its window: an arm that "
                + "neither ripened nor expired is exactly the hang the "
                + "named refusal exists to prevent. Report: " + after.text)
        _ = await execLine("offer --stop")
    }
}
