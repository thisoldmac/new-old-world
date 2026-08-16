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
        // 180s, not 60s. THE GUEST'S REDIAL BACKS OFF, and it grows with
        // consecutive failures — the Workshop's own Connection row counts
        // it down ("Retry in 22 s" was observed at 2026-08-15 21:07). Every
        // run of this file leaves the guest disconnected when the listener
        // stops, so a case that follows a spin-up, a `tools/askguest.py`
        // nudge, or another case can easily arrive mid-backoff. At 60s
        // three runs in a row failed `no guest dialled in` against a guest
        // that answered `tools/askguest.py` seconds later — a live machine
        // reported dead by a stopwatch, which is the one thing an opted-in
        // gate must never do quietly.
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if case .connected = listener.state, listener.activeKey != nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        // THROWS, RATHER THAN FAILING AND CARRYING ON. XCTFail is not a
        // return: every `execLine` after it parks in a
        // `withCheckedContinuation` that only the guest's reply resumes,
        // and there is no guest — so the case does not fail, it HANGS,
        // and a hang is the one outcome an opted-in gate can produce that
        // nobody can read. Watched: a run sat past ten minutes with 65
        // bytes of output while the guest answered `tools/askguest.py`
        // perfectly well on the same port seconds later.
        XCTFail("no guest dialled in on \(port) within 180s — long enough "
                + "to outlast the guest's redial backoff, so this is a "
                + "guest that is not dialling rather than one that is slow")
        throw NoGuest(port: port)
    }

    private struct NoGuest: Error { let port: UInt16 }

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

    /// `ext` is a PARAMETER because the extension decides the offer's
    /// type and creator (`OutboundFile.classicType`), and that is a
    /// property under test rather than a detail of the fixture.
    private func write(bytes: Int, label: String,
                       ext: String = "bin") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "now-slice2-\(label)-\(UUID().uuidString).\(ext)")
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

    /// WHERE THE POINTER IS WHEN THE BUTTON COMES UP IS THE WHOLE TEST.
    ///
    /// The run above holds the button at (300, 240) and ends `cancelled`.
    /// A screen capture of that guest says why: the emulator's screen is
    /// 800x600 and NOW's own Workshop window covers roughly x 20..785,
    /// y 45..550, so (300, 240) is inside OUR window. NOW installs no drag
    /// receive handler, the Drag Manager had nobody to give the drop to,
    /// and `userCanceledErr` is the correct answer to a drop nothing
    /// accepted. Nothing was broken; the pointer was never over a receiver.
    ///
    /// So put it over one. `kDesktopDrop` is in the strip of desktop below
    /// the Workshop window and clear of both the Control Strip and the
    /// icons at the bottom right. The Finder owns the desktop, speaks
    /// promised HFS, and positions what it receives where it landed —
    /// which is the fidelity this whole feature exists for.
    ///
    /// The move happens WHILE THE BUTTON IS HELD, in steps, because that
    /// is what the plane is for: the resident's timer replaces the
    /// published point with newer host points for the duration of a hold,
    /// which is how a foreign application's nested tracking loop is driven
    /// at all (continuity_intake.c). A single packet at the destination
    /// would test teleportation, not a drag.
    func testDropOnTheDesktopMaterialisesTheFile() async throws {
        try await waitConnected()
        let udpPort = try await arm(epoch: 525_256)
        guard let udpPort else {
            return XCTFail(
                "no udpPort in the continuity report: the button plane "
                    + "cannot be driven, so this case cannot run at all. "
                    + "Opted in and unable to reach the guest is a FAILURE, "
                    + "not a skip.")
        }

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        // `.txt`, NOT `.bin`, AND THE DIFFERENCE IS THE OFFER'S IDENTITY.
        // `OutboundFile.classicType` maps `.bin` to (nil, nil) — it is the
        // one extension in that table with no type and no creator — so a
        // `.bin` fixture publishes an offer the guest can only promise as
        // '????'/'????'. Whether a Finder that cannot classify a promised
        // file declines to ask for it is exactly the open question, and
        // testing the drop with the one fixture that provokes it measures
        // two things at once. A MacBinary offer legitimately carries no
        // type either, and that case is owed its own test — but it is not
        // the case this one is for.
        let small = try write(bytes: 4096, label: "drop", ext: "txt")
        defer { try? FileManager.default.removeItem(at: small) }
        guard case .published(let item) = control.publish(
            fileAt: small, epoch: 525_256, generation: 1) else {
            return XCTFail("publish failed")
        }
        // THE GUEST'S OWN NAME FOR IT, not this Mac's. `OutboundFile.plan`
        // projects every name through `ClassicName` — 31 MacRoman bytes,
        // no colons, a fingerprint appended when truncation costs
        // addressability — so a UUID-bearing fixture arrives as something
        // like `now-slice2-drop-BE85C8#0A0E.txt`. Asserting the host's
        // `lastPathComponent` against the guest's Desktop could never
        // match: this case would have failed on a working drop, and its
        // paired `before` check would have passed vacuously, which is a
        // guard that reads as coverage while proving nothing either way.
        let expectedName = item.name
        print("=== offer published as \(expectedName) "
              + "type=\(item.fileType ?? "nil") "
              + "creator=\(item.creator ?? "nil") ===")
        XCTAssertEqual(item.fileType, "TEXT",
                       "the fixture must publish a REAL type, or this case "
                           + "cannot distinguish an unclassifiable promise "
                           + "from a Finder that never asks")

        // THE GUEST'S DESKTOP BEFORE, so what lands is what THIS test put
        // there. A file already present would otherwise read as a pass.
        let before = await execLine("ls Desktop Folder")
        print("=== guest Desktop before the drop: \(before.text) ===")
        XCTAssertFalse(
            before.text.contains(expectedName),
            "the file this test is about to drop is already on the guest's "
                + "Desktop; the run proves nothing. Before: " + before.text)

        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: udpPort)!, using: .udp)
        connection.start(queue: .global())
        defer { connection.cancel() }
        try await Task.sleep(nanoseconds: 500_000_000)

        var sequence: UInt32 = 1
        var generation: UInt32 = 1
        func send(h: Int, v: Int, down: Bool) {
            sequence &+= 1
            let packet = ContinuityStateDatagram(
                nonceHi: 2, nonceLo: 2, epoch: 525_256,
                positionSequence: sequence, h: Int16(h), v: Int16(v),
                buttonGeneration: generation,
                flags: down ? [.inside, .primaryDown] : [.inside],
                requestedHz: 30, hostStamp: 0)
            connection.send(content: ContinuityDatagramCodec.encode(packet),
                            completion: .contentProcessed { _ in })
        }

        // Start inside NOW's window — a drag picked up where the offer is
        // shown — and travel to the desktop, which is the crossing this
        // slice is a stand-in for.
        let startH = 300, startV = 240
        // WHERE THE DESKTOP ACTUALLY IS, AND IT IS NOT A CONSTANT.
        // 800x600 with the Workshop window at its default size leaves a
        // desktop band roughly y 552..570 — eighteen pixels between our
        // own window's bottom edge and the Control Strip, with the
        // Finder's own icons in it. The first drop this slice ever
        // measured aimed at (300, 570) and came back `loc='null'`: no
        // receiver set a drop location, which is what a drop onto a
        // strip that is not the desktop looks like. A target that thin
        // is a rig hazard, not a property of the product, so the point
        // is settable and the case that runs for real makes room first.
        let target = ProcessInfo.processInfo.environment["NOW_DRAG_DROP"]?
            .split(separator: ",").compactMap { Int($0) }
        let dropH = target?.count == 2 ? target![0] : 300
        let dropV = target?.count == 2 ? target![1] : 570
        print("=== drop target: \(dropH),\(dropV) ===")

        for _ in 0..<10 {
            send(h: startH, v: startV, down: false)
            try await Task.sleep(nanoseconds: 30_000_000)
        }

        // THE EXPERIMENT MASK, AND IT IS SCAFFOLD. `NOW_DRAG_X=N` appends
        // the guest's diagnostic switch to this line so one booted guest
        // answers several hypotheses in a row — a build/spin/boot cycle
        // is ~20 minutes and reading one bit per cycle is how a slice
        // like this eats a week. Unset, the line is the product's.
        let mask = ProcessInfo.processInfo.environment["NOW_DRAG_X"]
        let dragLine = mask.map { "offer --drag --x=\($0)" } ?? "offer --drag"
        print("=== drag line: \(dragLine) ===")
        let armed = await execLine(dragLine)
        assertConsoleSaid(armed, contains: "armed",
                          "the arm must be placed before the button moves, "
                              + "or this measures nothing")

        generation &+= 1
        // Hold at the start point long enough for the arm to ripen and
        // TrackDrag to be running before anything moves.
        for _ in 0..<40 {
            send(h: startH, v: startV, down: true)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // Travel, held, in steps a tracking loop can follow.
        for step in 1...30 {
            let v = startV + (dropV - startV) * step / 30
            send(h: dropH, v: v, down: true)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        // Settle at the destination before letting go, so the drop point
        // is the one this test names rather than a point in transit.
        for _ in 0..<15 {
            send(h: dropH, v: dropV, down: true)
            try await Task.sleep(nanoseconds: 40_000_000)
        }

        generation &+= 1
        for _ in 0..<20 {
            send(h: dropH, v: dropV, down: false)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        // The promise streams inside the Finder's drop handling; 4 KB is
        // fast but the round trip is not instant.
        try await Task.sleep(nanoseconds: 8_000_000_000)

        let report = await execLine("offer")
        print("=== report after the drop: \(report.text) ===")
        let log = await runCommand("tail", line: "50")
        print("=== guest log after the drop ===")
        print(String(describing: log.output))

        // THE BUILD UNDER TEST, ASSERTED FROM ITS OWN OUTPUT. The detail
        // line is emitted by no earlier build, so its presence is what
        // says this guest is running the code this test is about — the
        // `requireTheBuildUnderTest()` rule, answered by a capability only
        // this build has rather than by a version string.
        let logText = String(describing: log.output)
        XCTAssertTrue(
            logText.contains("drag drop:"),
            "no `drag drop:` line: this guest is not running the build "
                + "under test, so nothing it says about the drop is "
                + "evidence about this code. It was `drag detail:` until "
                + "this commit, and that line now exists in TWO builds — "
                + "which is the whole failure mode this assertion is "
                + "for, arriving one build later. Log: " + logText)

        // THE OUTCOME, FROM THE GUEST'S OWN STATE MACHINE.
        XCTAssertTrue(
            report.text.contains("Last drag                ok"),
            "the drop did not settle. `cancelled` here means the pointer "
                + "was over nothing that accepts a drop — check the "
                + "`drag detail:` line's coordinates against the 800x600 "
                + "screen. Report: " + report.text)

        // AND FROM THE FILE SYSTEM, which is a different artifact than the
        // state machine and the only one that can say a FILE exists. A
        // state machine reporting success is exactly what a promise that
        // handed back a stale FSSpec would also do.
        let after = await execLine("ls Desktop Folder")
        print("=== guest Desktop after the drop: \(after.text) ===")
        XCTAssertTrue(
            after.text.contains(expectedName),
            "the drag settled but no file named \(expectedName) is on the "
                + "guest's Desktop: the promise reported success and "
                + "materialised nothing, which is the one outcome worse "
                + "than a refusal. Desktop: " + after.text)

        _ = await execLine("offer --stop")
    }
}
