import Foundation
import Network
import XCTest
@testable import Host

/// THE RIG-DEFECT CONTROL for slice 2's standing reading, run as one
/// measurement so the two shapes differ in exactly one thing.
///
///     NOW_DRAG_LIVE_PORT=<wire port> NOW_DRAG_NATIVE_TRACK=1 \
///     NOW_QMP_SOCK=<run>/qmp.sock \
///     swift test --filter LiveDragNativeTrackExperiment
///
/// WHY IT EXISTS. On 2026-08-15 three NOW-originated promise drags onto
/// the Finder's desktop answered `loc='null' asks=0`, and `TrackDrag`
/// reported `inwin=1` for NOW's own window with the pointer 400 px
/// outside it. That was written down as "the Drag Manager's targeting
/// does not follow the driven pointer". The 2026-08-16 re-measure with
/// the V15 tracking-handler observer narrowed it but reproduced the
/// failed drop.
///
/// The hypothesis this file tests is that BOTH readings were taken on a
/// rig where NOW's own window covered essentially the whole 800x600
/// screen — the Workshop at its default size leaves an eighteen-pixel
/// desktop band — so `inwin=1` may have been the Drag Manager correctly
/// naming the window that was actually under the pointer. That is the
/// same class of defect as the `dragobs calls=0` retraction: an
/// instrument reading a rig rather than the product.
///
/// So: the same drag, twice, differing only in whether NOW is on screen.
///
///   A. NOW fronted and visible — the OLD rig shape, reproduced
///      deliberately, dropping into the thin desktop band at the bottom.
///   B. NOW HIDDEN (`hide`, a real `ShowHideProcess`) with the Finder
///      fronted — the shape the forensics rules ask for, dropping into
///      the middle of a fully exposed desktop.
///
/// If A reproduces `inwin=1 / loc='null'` and B tracks out and completes,
/// the standing reading is a rig defect. If both stick, the wall is real.
///
/// It also answers two questions the fake dialogs' fate depends on, and
/// only a completed drop can answer them: does the FINDER put up a
/// copy-progress window of its own, and what does it do when the same
/// name is dropped twice? Both are captured as QMP screendumps.
///
/// Opt-in, like every live case here: unset, it skips; opted in, a guest
/// that does not answer is a FAILURE.
@MainActor
final class LiveDragNativeTrackExperiment: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 0
    private var qmpSocket: String?
    private var receipts: URL!
    private var transcript: [String] = []
    /// ONE SEQUENCE FOR THE WHOLE SESSION, and it is a member rather than
    /// a local for a measured reason: the guest drops a state datagram
    /// whose `positionSequence` it has already passed, so a second
    /// gesture that restarts at 1 is a gesture the plane never sees. The
    /// first run of this file did exactly that — control B's button
    /// "never came" and its pointer never moved, which reads precisely
    /// like a guest refusing to be driven while hidden. It was the rig.
    private var sequence: UInt32 = 0
    /// AND ONE BUTTON GENERATION, ADVANCED BY EXACTLY ONE PER EDGE. The
    /// second run of this file gave each gesture its own base (1, 10, 20)
    /// and every gesture after the first reported `button-never-came`,
    /// which reads exactly like a plane that refuses to drive a hidden
    /// application. A real host counts its edges; so does this now.
    private var generation: UInt32 = 0
    private var udp: NWConnection?

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOW_DRAG_NATIVE_TRACK"] != nil,
            "set NOW_DRAG_NATIVE_TRACK=1 (and NOW_DRAG_LIVE_PORT) to run "
                + "this experiment against a live guest")
        guard let raw = ProcessInfo.processInfo
            .environment["NOW_DRAG_LIVE_PORT"], let p = UInt16(raw) else {
            throw NoGuest(port: 0)
        }
        port = p
        qmpSocket = ProcessInfo.processInfo.environment["NOW_QMP_SOCK"]
        let dir = ProcessInfo.processInfo.environment["NOW_RECEIPTS"]
            .map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.temporaryDirectory
        receipts = dir
        try? FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true)
        listener = GuestListener(identity: .init(
            version: "0.2.0-native-track", name: "Native-track Experiment"))
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
        // GUARDED, because `setUp` SKIPS before it sets any of this and
        // tearDown still runs. Force-unwrapping `receipts` here crashed
        // the whole HostTests binary — signal 5, taking every other case
        // in the process with it and failing `scripts/test-all` for a
        // file that had declined to run. An opt-in case must cost a
        // non-participant nothing.
        guard let receipts else { return }
        let text = transcript.joined(separator: "\n") + "\n"
        try? text.write(to: receipts.appendingPathComponent(
            "native-track-transcript.txt"), atomically: true, encoding: .utf8)
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

    /// The guest's screen, from OUTSIDE the guest. The `screenshot` verb
    /// travels the same wire this experiment is measuring; QMP does not,
    /// so a capture cannot be an artifact of the thing under test.
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

    /// THE WHOLE RING, not the newest page. `tail` serves at most 40 rows
    /// and the product's own `drag drop:` / `drag attrs:` lines fall off
    /// the first page as soon as V15's per-message table is on — the
    /// first run of this file captured 46 of 111 rows and neither line
    /// was in them.
    private func pagedLog(pages: Int) async -> String {
        var collected: [String] = []
        var before: Int?
        for _ in 0..<pages {
            let line = before.map { "40 mirror before \($0)" } ?? "40 mirror"
            let page = await runCommand("tail", line: line)
            let text = String(describing: page.output)
            collected.append(text)
            // The guest prints its own backward cursor as ["next", "N"].
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

    /// THE FILE SYSTEM, ASKED OF THE FINDER ITSELF. `ls` lists the SHARE,
    /// which on this rig is not the boot volume ("no such folder in the
    /// share" for `Desktop Folder`), so it can neither confirm nor deny a
    /// drop. The Finder is also the party that would have created the
    /// file, which makes it the right witness rather than merely an
    /// available one.
    private func askTheFinder(about name: String) async -> String {
        let script = "tell application \"Finder\" to return "
            + "(exists file \"\(name)\" of desktop) as string"
        let out = await runCommand("script", line: script)
        return String(describing: out.output)
    }

    /// THE ANSWER, NOT THE ENVELOPE. `script`'s reply also carries
    /// `truncated` and `wrapped` booleans, so the run before this one
    /// read every gesture as landed by finding the word "true" anywhere
    /// in it — a check that could not fail, beside a drop that did.
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

    /// One whole gesture: publish, arm the drag, drive the held pointer
    /// from `from` to `to` over the Continuity UDP plane, release, and
    /// read back everything the guest will say about it.
    private struct Gesture {
        let name: String
        let report: String
        let log: String
        let desktopBefore: String
        let desktopAfter: String
    }

    private func drag(label: String, epoch: UInt32, publishGeneration: UInt32,
                      udpPort: UInt16, file: URL,
                      from: (Int, Int), to: (Int, Int),
                      shotDuringPull: Bool) async throws -> Gesture {
        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        guard case .published(let item) = control.publish(
            fileAt: file, epoch: epoch, generation: publishGeneration) else {
            XCTFail("publish failed for \(label)")
            throw NoGuest(port: port)
        }
        say("[\(label)] published \(item.name) type=\(item.fileType ?? "nil") "
            + "creator=\(item.creator ?? "nil")")

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
        let armed = await execLine("offer --drag")
        say("[\(label)] offer --drag: \(armed.text)")

        generation &+= 1
        for _ in 0..<40 {
            send(h: from.0, v: from.1, down: true)
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        // DWELL AT EVERY STEP, not just at the ends: the forensics rig
        // rules ask for motion the guest's own tracking loop can follow,
        // and a step it never samples is a step that did not happen as
        // far as any handler is concerned.
        for step in 1...30 {
            let h = from.0 + (to.0 - from.0) * step / 30
            let v = from.1 + (to.1 - from.1) * step / 30
            send(h: h, v: v, down: true)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        for _ in 0..<15 {
            send(h: to.0, v: to.1, down: true)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        screendump("\(label)-held-at-target")

        generation &+= 1
        for _ in 0..<20 {
            send(h: to.0, v: to.1, down: false)
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        if shotDuringPull {
            // WHILE THE PROMISE IS STREAMING. A Finder copy-progress
            // window, if there is one, exists only here.
            try await Task.sleep(nanoseconds: 300_000_000)
            screendump("\(label)-during-pull-1")
            try await Task.sleep(nanoseconds: 900_000_000)
            screendump("\(label)-during-pull-2")
        }
        try await Task.sleep(nanoseconds: 8_000_000_000)
        screendump("\(label)-settled")

        let report = await execLine("offer")
        let logText = await pagedLog(pages: 8)
        let after = await askTheFinder(about: item.name)
        say("[\(label)] report: \(report.text)")
        say("[\(label)] Finder after: \(after)")
        say("[\(label)] log:\n\(logText)")
        _ = await execLine("offer --stop")
        return Gesture(name: item.name, report: report.text, log: logText,
                       desktopBefore: before, desktopAfter: after)
    }

    // MARK: - the measurement

    func testHiddenVersusFrontedIsTheOnlyDifference() async throws {
        try await waitConnected()
        let epoch: UInt32 = 917_001
        guard let udpPort = try await arm(epoch: epoch) else {
            return XCTFail("no udpPort: the button plane cannot be driven")
        }

        // THE BUILD UNDER TEST, before anything else is believed.
        let mirror = await runCommand("mirror", line: "")
        say("mirror: \(String(describing: mirror.output))")

        // ---- control A: the OLD rig shape, reproduced on purpose ----
        let frontA = await execLine("front New Old World")
        say("[A] front New Old World: \(frontA.text)")
        try await Task.sleep(nanoseconds: 1_500_000_000)
        screendump("A-before")
        let fileA = try fixture(named: "NativeTrackA.txt", bytes: 4096)
        let a = try await drag(label: "A", epoch: epoch, publishGeneration: 1,
                               udpPort: udpPort, file: fileA,
                               from: (300, 240), to: (300, 570),
                               shotDuringPull: false)

        // ---- control A2: still fronted, but onto REAL BARE DESKTOP ----
        // Two things at once, and both were confounded before. It is the
        // SECOND gesture, so "the second one failed" and "the hidden one
        // failed" stop being one observation. And its target is the
        // exposed desktop band down the LEFT edge (x < 25, full height),
        // which the Workshop's default geometry leaves uncovered — where
        // (300, 570) is the eighteen-pixel bottom band shared with the
        // Control Strip, and a drop that lands on the Control Strip is
        // a `loc='null'` this product is right to produce.
        let fileA2 = try fixture(named: "NativeTrackA2.txt", bytes: 4096)
        let a2 = try await drag(label: "A2", epoch: epoch,
                                publishGeneration: 5,
                                udpPort: udpPort, file: fileA2,
                                from: (300, 240), to: (10, 300),
                                shotDuringPull: true)

        // ---- control B: NOW hidden, the Finder fronted ----
        let hide = await execLine("hide New Old World")
        say("[B] hide New Old World: \(hide.text)")
        let frontB = await execLine("front Finder")
        say("[B] front Finder: \(frontB.text)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        screendump("B-before")
        let fileB = try fixture(named: "NativeTrackB.txt", bytes: 4096)
        let b = try await drag(label: "B", epoch: epoch, publishGeneration: 10,
                               udpPort: udpPort, file: fileB,
                               from: (300, 240), to: (10, 300),
                               shotDuringPull: true)

        // ---- control F: VISIBLE but not frontmost ----
        // B refuses before the drag begins (`button-never-came`), and
        // "hidden" and "not frontmost" are two different reasons wearing
        // that one word. F separates them: NOW is shown again and the
        // Finder is brought forward, so the only thing left is front-ness.
        let show = await execLine("hide --show New Old World")
        say("[F] hide --show New Old World: \(show.text)")
        let frontF = await execLine("front Finder")
        say("[F] front Finder: \(frontF.text)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        screendump("F-before")
        let fileF = try fixture(named: "NativeTrackF.txt", bytes: 4096)
        let f = try await drag(label: "F", epoch: epoch, publishGeneration: 30,
                               udpPort: udpPort, file: fileF,
                               from: (300, 240), to: (10, 300),
                               shotDuringPull: false)
        say("  F (visible, not front) last drag: \(f.report)")

        // ---- the same name a second time, only if B landed one ----
        var c: Gesture?
        if finderSaidYes(b.desktopAfter) {
            say("[C] B materialised \(b.name); dropping the same name again "
                + "to watch the FINDER's own collision behaviour")
            c = try await drag(label: "C", epoch: epoch, publishGeneration: 20,
                               udpPort: udpPort, file: fileB,
                               from: (300, 240), to: (10, 300),
                               shotDuringPull: true)
        } else {
            say("[C] skipped: B materialised nothing, so there is no "
                + "collision to provoke")
        }

        // Put the screen back the way it was found.
        _ = await execLine("hide --show New Old World")

        // ---- the verdict, stated as an assertion so it cannot be read
        //      as narration ----
        say("VERDICT INPUTS")
        say("  A  (fronted)     landed: \(finderSaidYes(a.desktopAfter))")
        say("  A2 (fronted, 2nd) landed: \(finderSaidYes(a2.desktopAfter))")
        say("  A2 last drag: \(a2.report)")
        say("  B (hidden)  landed: \(finderSaidYes(b.desktopAfter))")
        if let c {
            say("  C (collision) landed: \(finderSaidYes(c.desktopAfter))")
        }
        XCTAssertTrue(
            a.log.contains("drag drop:") || b.log.contains("drag drop:"),
            "neither control produced a `drag drop:` line, so this guest "
                + "is not running the build under test and nothing it said "
                + "is evidence")
    }
}
