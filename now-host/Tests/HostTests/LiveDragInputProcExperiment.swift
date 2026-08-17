import Foundation
import Network
import XCTest
@testable import Host

/// SLICE 0 of the blessed-path drag plan, run as one measurement.
///
///     NOW_DRAG_LIVE_PORT=<wire port> NOW_DRAG_INPUT_PROC=1 \
///     NOW_QMP_SOCK=<run>/qmp.sock NOW_RECEIPTS=<outside the run dir> \
///     swift test --filter LiveDragInputProcExperiment
///
/// WHY IT EXISTS. On 2026-08-17 a NOW-originated Drag Manager promise
/// drag was measured and found unable to leave NOW — not because
/// targeting ignores the driven pointer, but because **the pointer never
/// moves**: Continuity applies Cursor Device motion at task time only,
/// and a drag source's `TrackDrag` consumes NOW's task time for the
/// whole drag. `SetDragInputProc` is the Drag Manager's own seam for
/// exactly this — the source hands the Manager a mouse sample each time
/// the Manager wants one, from inside `TrackDrag`, in our own context.
///
/// The plan's four slice-0 questions, one gesture each:
///
///   1. **P** — does the ghost track the reported position? A SCRIPTED
///      ramp (`--x=16`), so a frozen coordinate cannot be blamed on the
///      transport, ending on exposed desktop. Screendumps mid-drag.
///   2. answered by the same screendumps: cursor sprite vs. ghost.
///   3. **D** — desktop drop, plane-fed (`--x=8`): does `inwin` flip off
///      NOW's window, does `loc` resolve non-null, does the promise get
///      ASKED, does the Finder create the file. **W** — the same into an
///      open Finder window, which is the first out-of-process pull.
///      **C** — the same name a second time, for the Finder's own
///      collision behaviour, only if W landed one.
///   4. **N** — a reported path to somewhere no target accepts, then
///      button-up: `dragNotAcceptedErr` (or `userCanceledErr`), promise
///      never asked, nothing created.
///
/// THE RIG RULES THIS ENCODES, each paid for by the run before it:
/// one UDP socket and one position sequence for the whole session (a
/// restarted sequence is a gesture the plane never sees); one button
/// generation advanced by exactly one per edge; NOW stays FRONTMOST,
/// because the synthetic button lands in the front process and a
/// background NOW never sees it; the whole log ring is paged, because
/// `tail` serves 40 rows and the decisive lines fall off the first page.
///
/// Opt-in: unset, it skips; opted in, a guest that does not answer is a
/// FAILURE.
@MainActor
final class LiveDragInputProcExperiment: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 0
    private var qmpSocket: String?
    private var receipts: URL!
    private var transcript: [String] = []
    private var sequence: UInt32 = 0
    private var generation: UInt32 = 0
    private var udp: NWConnection?

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOW_DRAG_INPUT_PROC"] != nil,
            "set NOW_DRAG_INPUT_PROC=1 (and NOW_DRAG_LIVE_PORT) to run "
                + "this experiment against a live guest")
        guard let raw = ProcessInfo.processInfo
            .environment["NOW_DRAG_LIVE_PORT"], let p = UInt16(raw) else {
            throw NoGuest(port: 0)
        }
        port = p
        qmpSocket = ProcessInfo.processInfo.environment["NOW_QMP_SOCK"]
        // OUTSIDE THE RUN DIRECTORY BY DEFAULT, and this is not a
        // preference: `tools/lane-ports reclaim` deletes $NOW_SPIN_RUN,
        // which on 2026-08-17 took every screendump of the measurement
        // that was arguing about screendumps.
        let dir = ProcessInfo.processInfo.environment["NOW_RECEIPTS"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: "/private/tmp/now-slice0-receipts")
        receipts = dir
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        listener = GuestListener(identity: .init(
            version: "0.2.0-input-proc", name: "Input-proc Experiment"))
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
        // GUARDED: `setUp` skips before it sets any of this and tearDown
        // still runs. Force-unwrapping here once crashed the whole
        // HostTests binary for a file that had declined to run.
        guard let receipts else { return }
        let text = transcript.joined(separator: "\n") + "\n"
        try? text.write(to: receipts.appendingPathComponent(
            "input-proc-transcript.txt"), atomically: true, encoding: .utf8)
        listener?.stop()
        listener = nil
    }

    private struct NoGuest: Error { let port: UInt16 }

    private func say(_ line: String) {
        print(line)
        transcript.append(line)
    }

    private func waitConnected() async throws {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if case .connected = listener.state, listener.activeKey != nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("no guest dialled in on \(port) within 180s")
        throw NoGuest(port: port)
    }

    @discardableResult
    private func arm(epoch: UInt32) async throws -> UInt16? {
        var acked = false
        var udpPort: UInt16?
        var armState = ""
        listener.onContinuityReport = { _, report in
            armState = report.state
            udpPort = report.udpPort.map(UInt16.init)
            acked = true
        }
        listener.armContinuity(nonceHi: 7, nonceLo: 7, epoch: epoch,
                               requestedHz: 30, leaseTicks: 3600)
        let deadline = Date().addingTimeInterval(15)
        while !acked, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(acked, "no continuity.report ack within 15s")
        say("armed epoch=\(epoch) state=\(armState) "
            + "udp=\(String(describing: udpPort))")
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

    /// The guest's screen from OUTSIDE the guest. The `screenshot` verb
    /// travels the wire under measurement; QMP does not.
    @discardableResult
    private func screendump(_ tag: String) -> String? {
        guard let socket = qmpSocket else { return nil }
        let ppm = receipts.appendingPathComponent("shot-\(tag).ppm").path
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        task.arguments = [
            "/Users/michelle/Lab/Code/timbottu/tools/qmp", socket,
            "screendump", "{\"filename\":\"\(ppm)\"}",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        try? task.run()
        task.waitUntilExit()
        say("screendump \(tag) -> \(ppm)")
        return ppm
    }

    /// THE WHOLE RING, not the newest page — AND READ EARLY.
    ///
    /// Run 1 of this file paged eight seconds after the release and found
    /// `drag input:` as its OLDEST product line: `drag ... ended:`,
    /// `drag detail:`, `drag drop:` and `drag attrs:` had all been pushed
    /// out of a 2000-line ring. The V15 tracking stream is the reason —
    /// a four-second drag accumulates ~9400 handler passes and the idle
    /// drain dumps them sixteen at a time for seconds afterwards, so the
    /// lines the measurement turns on have a shelf life of about a
    /// second. Every caller pages IMMEDIATELY now, and the settle wait
    /// happens after.
    private func pagedLog(pages: Int) async -> String {
        var collected: [String] = []
        var before: Int?
        for _ in 0..<pages {
            let line = before.map { "40 mirror before \($0)" } ?? "40 mirror"
            let page = await runCommand("tail", line: line)
            let text = String(describing: page.output)
            collected.append(text)
            guard let range = text.range(of: "\"next\", \"") else { break }
            let rest = text[range.upperBound...]
            guard let close = rest.firstIndex(of: "\""),
                  let n = Int(rest[rest.startIndex..<close]), n > 0 else {
                break
            }
            if n == before { break }
            before = n
        }
        return collected.reversed().joined(separator: "\n")
    }

    /// THE FILE SYSTEM, ASKED OF THE FINDER ITSELF — `ls` lists the
    /// share, which on this rig is not the boot volume.
    private func askTheFinder(about name: String) async -> String {
        let script = "tell application \"Finder\" to return "
            + "(exists file \"\(name)\" of desktop) as string"
        let out = await runCommand("script", line: script)
        return String(describing: out.output)
    }

    /// THE ANSWER, NOT THE ENVELOPE.
    private func finderSaidYes(_ reply: String) -> Bool {
        guard let range = reply.range(of: "\"output\", ") else { return false }
        let rest = reply[range.upperBound...].prefix(24)
        return rest.contains("true")
    }

    private func fixture(named name: String, bytes: Int) throws -> URL {
        let url = receipts.appendingPathComponent(name)
        try Data(repeating: 0x4E, count: bytes).write(to: url)
        return url
    }

    private struct Gesture {
        let name: String
        let report: String
        let log: String
        let landedBefore: Bool
        let landedAfter: Bool
    }

    /// One whole gesture. `arm` is the scaffold grammar the guest parses
    /// (`--drag --x=16@10,300`); `drivePath` says whether this host also
    /// drives the pointer over UDP during the hold, which the SCRIPTED
    /// variants deliberately do not — a script that agrees with a plane
    /// driving the same points cannot be told from the plane.
    private func drag(label: String, epoch: UInt32, publishGeneration: UInt32,
                      udpPort: UInt16, file: URL, arm armLine: String,
                      from: (Int, Int), to: (Int, Int),
                      drivePath: Bool, holdSeconds: Double,
                      shotDuringPull: Bool) async throws -> Gesture {
        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        guard case .published(let item) = control.publish(
            fileAt: file, epoch: epoch, generation: publishGeneration) else {
            XCTFail("publish failed for \(label)")
            throw NoGuest(port: port)
        }
        say("[\(label)] published \(item.name) arm=`\(armLine)` "
            + "from=\(from) to=\(to) drivePath=\(drivePath)")

        let before = await askTheFinder(about: item.name)
        say("[\(label)] Finder before: \(before)")

        if udp == nil {
            let connection = NWConnection(
                host: .ipv4(.loopback),
                port: NWEndpoint.Port(rawValue: udpPort)!, using: .udp)
            connection.start(queue: .global())
            udp = connection
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let connection = udp!

        func send(h: Int, v: Int, down: Bool) {
            sequence &+= 1
            let packet = ContinuityStateDatagram(
                nonceHi: 7, nonceLo: 7, epoch: epoch,
                positionSequence: sequence, h: Int16(h), v: Int16(v),
                buttonGeneration: generation,
                flags: down ? [.inside, .primaryDown] : [.inside],
                requestedHz: 30, hostStamp: 0)
            connection.send(content: ContinuityDatagramCodec.encode(packet),
                            completion: .contentProcessed { _ in })
        }

        for _ in 0..<10 {
            send(h: from.0, v: from.1, down: false)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let armed = await execLine("offer \(armLine)")
        say("[\(label)] offer \(armLine): \(armed.text)")

        generation &+= 1
        for _ in 0..<40 {
            send(h: from.0, v: from.1, down: true)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // DWELL AT EVERY STEP: a step the guest never samples is a step
        // that did not happen as far as any handler is concerned.
        if drivePath {
            for step in 1...30 {
                let h = from.0 + (to.0 - from.0) * step / 30
                let v = from.1 + (to.1 - from.1) * step / 30
                send(h: h, v: v, down: true)
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        // MID-DRAG, WHILE THE BUTTON IS STILL REPORTED DOWN. This is the
        // one moment questions 1 and 2 can be answered at all: where the
        // ghost is, and where the arrow is, with the drag still running.
        let holdSteps = max(1, Int(holdSeconds / 0.6))
        for step in 0..<holdSteps {
            if drivePath {
                send(h: to.0, v: to.1, down: true)
            }
            try await Task.sleep(nanoseconds: 600_000_000)
            if step == 0 || step == holdSteps / 2 {
                screendump("\(label)-held-\(step)")
            }
        }
        screendump("\(label)-held-at-target")

        // THE RELEASE. A scripted drag releases ITSELF (the input proc
        // reports btnState up on its own clock); the plane-fed ones are
        // released here. Both then get the plane's button lowered, so
        // the arm state and the resident agree whatever happened.
        // BEFORE THE RELEASE BURST, not after. A scripted drag drops on
        // its OWN clock — the input proc reports btnState up while the
        // hold loop is still running — so the promise pull is already
        // under way here, and a shot taken after the burst can miss the
        // only window a progress panel would exist in.
        if shotDuringPull {
            screendump("\(label)-during-pull-0")
        }
        generation &+= 1
        for _ in 0..<20 {
            send(h: to.0, v: to.1, down: false)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        if shotDuringPull {
            // WHILE THE PROMISE IS STREAMING. A Finder copy-progress
            // window, if there is one, exists only here.
            screendump("\(label)-during-pull-1")
        }
        // THE LOG FIRST, EVERYTHING ELSE AFTER. See pagedLog: the
        // decisive product lines survive about a second.
        let logText = await pagedLog(pages: 8)
        if shotDuringPull {
            screendump("\(label)-during-pull-2")
        }
        try await Task.sleep(nanoseconds: 6_000_000_000)
        screendump("\(label)-settled")

        let report = await execLine("offer")
        let after = await askTheFinder(about: item.name)
        say("[\(label)] report: \(report.text)")
        say("[\(label)] Finder after: \(after)")
        say("[\(label)] log:\n\(logText)")
        _ = await execLine("offer --stop")
        return Gesture(name: item.name, report: report.text, log: logText,
                       landedBefore: finderSaidYes(before),
                       landedAfter: finderSaidYes(after))
    }

    // MARK: - the measurement

    /// A FRESH EPOCH PER GESTURE, and this is a rig repair rather than
    /// tidiness. Run 1 armed once and every gesture after the first
    /// reported `button-never-came`: the plane's button edge stopped
    /// being applied once a four-second `TrackDrag` had held it, and a
    /// stuck plane and a refused drag wear the same word. Re-arming is
    /// the one operation that puts the plane back in a known state, and
    /// the offer is published under the same fresh epoch it will be
    /// dragged under.
    private var epochCounter: UInt32 = 917_100
    private func freshEpoch() async throws -> (UInt32, UInt16) {
        epochCounter &+= 1
        guard let udpPort = try await arm(epoch: epochCounter) else {
            throw NoGuest(port: port)
        }
        // The socket is per-port and the port does not move, but the
        // sequence must keep climbing: a restarted sequence is a gesture
        // the plane never sees.
        return (epochCounter, udpPort)
    }

    func testTheInputProcDrivesTheDrag() async throws {
        try await waitConnected()

        // THE BUILD UNDER TEST, before anything it says is believed.
        let mirror = await runCommand("mirror", line: "")
        say("mirror: \(String(describing: mirror.output))")

        // NOW STAYS FRONTMOST FOR EVERY GESTURE. The synthetic button is
        // applied into the FRONT process's context; a background NOW
        // never sees it and its arm expires `button-never-came`, which
        // is a rig reading and not a result (2026-08-17, control F).
        _ = await execLine("front New Old World")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        screendump("00-before")

        // ---- the Finder's own window, opened and MEASURED ------------
        // Asked for rather than assumed, and asked three ways because
        // run 1's single phrasing answered -1753 and the gesture then
        // aimed at a guess.
        _ = await runCommand(
            "script",
            line: "tell application \"Finder\" to open startup disk")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        var windowTarget: (Int, Int)?
        for phrasing in [
            "tell application \"Finder\" to get bounds of Finder window 1",
            "tell application \"Finder\" to get bounds of window 1",
            "tell application \"Finder\" to get (bounds of Finder window 1) "
                + "as text",
        ] {
            let reply = await runCommand("script", line: phrasing)
            let text = String(describing: reply.output)
            say("window bounds via `\(phrasing)`: \(text)")
            if let t = Self.interior(ofBounds: text) {
                windowTarget = t
                break
            }
        }
        _ = await execLine("front New Old World")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        screendump("01-window-open")
        let target = windowTarget ?? (400, 300)
        say("aiming Finder-window gestures at \(target) "
            + "(measured=\(windowTarget != nil))")

        // ---- P: does the GHOST track a reported position at all? ------
        // Scripted (`--x=16`), so the answer cannot be an artifact of
        // the transport, and the host drives NO path — every point the
        // Manager sees comes from the input proc.
        let (epP, udpP) = try await freshEpoch()
        let fileP = try fixture(named: "InputProcP.txt", bytes: 4096)
        let p = try await drag(
            label: "P", epoch: epP, publishGeneration: 1, udpPort: udpP,
            file: fileP, arm: "--drag --x=16@10,300",
            from: (300, 240), to: (10, 300), drivePath: false,
            holdSeconds: 2.4, shotDuringPull: true)

        // ---- W: into the OPEN FINDER WINDOW ---------------------------
        // The first out-of-process promise pull into another process's
        // WINDOW rather than onto its desktop.
        let (epW, udpW) = try await freshEpoch()
        let fileW = try fixture(named: "InputProcW.txt", bytes: 4096)
        let w = try await drag(
            label: "W", epoch: epW, publishGeneration: 1, udpPort: udpW,
            file: fileW, arm: "--drag --x=16@\(target.0),\(target.1)",
            from: (300, 240), to: target, drivePath: false,
            holdSeconds: 2.4, shotDuringPull: true)

        // ---- C: the SAME NAME again -----------------------------------
        // The Finder's own collision behaviour, which decides the fate of
        // the hand-built replace dialog. Only provoked if W got as far
        // as a pull.
        var c: Gesture?
        if w.landedAfter || Self.logSaysAsked(w.log) {
            let (epC, udpC) = try await freshEpoch()
            c = try await drag(
                label: "C", epoch: epC, publishGeneration: 1,
                udpPort: udpC, file: fileW,
                arm: "--drag --x=16@\(target.0),\(target.1)",
                from: (300, 240), to: target, drivePath: false,
                holdSeconds: 2.4, shotDuringPull: true)
        } else {
            say("[C] skipped: W materialised nothing, so there is no "
                + "collision to provoke")
        }

        // ---- N: ABORT BY NON-ACCEPTANCE -------------------------------
        // Reported back over NOW's own window, then button-up. Nobody
        // there accepts a promised HFS file, so the Manager's own
        // snap-back should play and TrackDrag should answer
        // dragNotAcceptedErr (-1857) or userCanceledErr (-128).
        let (epN, udpN) = try await freshEpoch()
        let fileN = try fixture(named: "InputProcN.txt", bytes: 4096)
        let n = try await drag(
            label: "N", epoch: epN, publishGeneration: 1, udpPort: udpN,
            file: fileN, arm: "--drag --x=16@300,240",
            from: (300, 240), to: (300, 240), drivePath: false,
            holdSeconds: 2.4, shotDuringPull: false)

        // ---- L: the PLANE feeding the proc, not a script --------------
        // Slice 1 replaces the script with the wire, so the last gesture
        // asks whether the notifier-written point is fresh enough to
        // steer the Manager while TrackDrag holds this application. It
        // is the only gesture that drives a path over UDP.
        let (epL, udpL) = try await freshEpoch()
        let fileL = try fixture(named: "InputProcL.txt", bytes: 4096)
        let l = try await drag(
            label: "L", epoch: epL, publishGeneration: 1, udpPort: udpL,
            file: fileL, arm: "--drag --x=8",
            from: (300, 240), to: (10, 300), drivePath: true,
            holdSeconds: 2.4, shotDuringPull: true)

        // ---- the verdict inputs, stated so they cannot read as
        //      narration ----
        say("VERDICT INPUTS")
        var all = [("P", p), ("W", w), ("N", n), ("L", l)]
        if let c { all.insert(("C", c), at: 2) }
        for g in all {
            say("  \(g.0) landed=\(g.1.landedAfter) "
                + "asked=\(Self.logSaysAsked(g.1.log))")
            say("  \(g.0) report: \(g.1.report)")
        }
        XCTAssertTrue(
            p.log.contains("drag input:"),
            "no `drag input:` line anywhere, so this guest is not running "
                + "the build under test and nothing it said is evidence")
    }

    /// A point well inside a Finder window's content, from the Finder's
    /// own `bounds` string (`left, top, right, bottom`). Nudged down past
    /// the title bar rather than centred, so a tall window's midpoint
    /// cannot land on a proxy row that means something else.
    /// THE PLAN'S SLICE-2 OBSERVATIONS, captured the moment a drop
    /// completes and not a slice later, because they decide the fate of
    /// two hand-built dialogs and only a completed drop can answer them:
    ///
    ///   * does the FINDER show a copy-progress window of its own while
    ///     it pulls a promise? Run 2's 4 KB file crossed too fast for
    ///     the question to mean anything, so this one is 600 KB.
    ///   * what does the Finder natively do when the SAME NAME is
    ///     dropped twice? Run 2 collided by accident (its `P` fixture
    ///     survived run 1) and answered `transfer-failed` with the
    ///     decisive lines already paged out. This asks on purpose.
    ///
    /// Separate from the four-question case so a rig failure in one is
    /// not a rig failure in both.
    func testTheFindersOwnProgressAndCollision() async throws {
        try await waitConnected()
        _ = await execLine("front New Old World")
        try await Task.sleep(nanoseconds: 1_500_000_000)

        // A NAME NOTHING HAS USED, so the first drop is a create and the
        // second is unambiguously a collision.
        let stamp = Int(Date().timeIntervalSince1970) % 100000
        let name = "Collide\(stamp).txt"
        let big = receipts.appendingPathComponent(name)
        // SIZE IS A DIAL, because the first ask of these questions used
        // 600 KB and the pull answered `transfer-failed` before a single
        // screendump could catch it mid-stream — which makes the
        // progress question unanswerable AND the collision question
        // unaskable in one stroke. 4 KB is the size proven to land, so
        // the collision half can still be had; NOW_DRAG_FIXTURE_BYTES
        // raises it for the progress half without a rebuild.
        let bytes = ProcessInfo.processInfo
            .environment["NOW_DRAG_FIXTURE_BYTES"].flatMap { Int($0) } ?? 4096
        try Data(repeating: 0x4E, count: bytes).write(to: big)
        say("fixture \(name) is \(bytes) bytes")
        // THE DIAGNOSTIC MASK IS A DIAL TOO. Slice 2 asks the same two
        // gestures of more than one promise-materialisation rule, and a
        // rebuild per hypothesis costs a spin cycle each.
        let mask = ProcessInfo.processInfo
            .environment["NOW_DRAG_MASK"] ?? "16"
        let arm = "--drag --x=\(mask)@10,300"
        say("arm mask \(mask)")

        let (ep1, udp1) = try await freshEpoch()
        let first = try await drag(
            label: "B1", epoch: ep1, publishGeneration: 1, udpPort: udp1,
            file: big, arm: arm,
            from: (300, 240), to: (10, 300), drivePath: false,
            holdSeconds: 2.4, shotDuringPull: true)
        let size1 = await runCommand(
            "script",
            line: "tell application \"Finder\" to return (size of item "
                + "\"\(name)\" of desktop) as string")
        say("[B1] size on the guest: \(String(describing: size1.output)) "
            + "(host wrote \(bytes))")

        guard first.landedAfter else {
            say("[B2] skipped: B1 materialised nothing, so there is no "
                + "collision to provoke")
            return XCTFail("B1 did not land; the collision question cannot "
                           + "be asked and is NOT answered by this run")
        }

        let (ep2, udp2) = try await freshEpoch()
        let second = try await drag(
            label: "B2", epoch: ep2, publishGeneration: 1, udpPort: udp2,
            file: big, arm: arm,
            from: (300, 240), to: (10, 300), drivePath: false,
            holdSeconds: 2.4, shotDuringPull: true)
        let after = await runCommand(
            "script",
            line: "tell application \"Finder\" to return (count of "
                + "(every file of desktop whose name contains "
                + "\"Collide\(stamp)\")) as string")
        say("[B2] files matching the name afterwards: "
            + "\(String(describing: after.output))")
        say("COLLISION INPUTS")
        say("  B1 landed=\(first.landedAfter) report: \(first.report)")
        say("  B2 landed=\(second.landedAfter) report: \(second.report)")
    }

    /// THE OUTPUT FIELD, NOT THE ENVELOPE. The reply also carries
    /// `timeoutMs 15000` and `osaErr 0`, and a naive scan for numbers
    /// reads those as a window — which is how a rig aims a gesture at a
    /// coordinate nothing put there.
    static func interior(ofBounds reply: String) -> (Int, Int)? {
        guard let range = reply.range(of: "\"output\", ") else { return nil }
        let field = reply[range.upperBound...].prefix(64)
        let digits = field.split(whereSeparator: { !"-0123456789".contains($0) })
            .compactMap { Int($0) }
        guard digits.count >= 4 else { return nil }
        let (l, t, r, b) = (digits[0], digits[1], digits[2], digits[3])
        guard r > l + 40, b > t + 60 else { return nil }
        return ((l + r) / 2, t + 40 + (b - t - 40) / 2)
    }

    static func logSaysAsked(_ log: String) -> Bool {
        log.contains("drag promise asked for")
    }
}
