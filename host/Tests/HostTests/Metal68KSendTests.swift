import XCTest
@testable import Host

/// NOW-68K SENDING over a real wire — the emulator or the PowerBook 180c,
/// whichever dialled in. The mirror of Metal68KPutTests.
///
///     scripts/q800-68k                        # boot the emulator, then:
///     NOW_METAL=1 swift test --filter Metal68KSendTests
///
/// Opt-in, and once opted in it FAILS rather than skips (AGENTS.md): a
/// gate that reads green having never reached a machine is worse than no
/// gate.
///
/// ---- Why this is a ROUND TRIP and not a checksum ---------------------
///
/// The receive-direction test proves integrity by checksum, because
/// NOW-68K serves no listing and no pull, so there is no way to read its
/// disk back. Here the direction is reversed and that limitation
/// disappears: the bytes end up on THIS machine, where the test still
/// holds the original.
///
/// So every case below pushes a known pattern to the guest, asks the
/// guest to send that same file back, and compares the two byte for
/// byte. Nothing in the comparison comes from the guest's own
/// accounting — not its progress reports, not its CRC, not its byte
/// count. A test that trusted the guest's checksum would be asking the
/// sender to mark its own work, and the CRC is computed over exactly the
/// buffer the framing already used.
///
/// The round trip also means a failure has two possible homes, so the
/// push half runs first and its own failure is reported as a push
/// failure. If the push is sound and the return is wrong, the send half
/// is where the bug is.
///
/// ---- What a green run here does and does not prove -------------------
///
/// It proves the send is CORRECT: chunking, framing, the END flag, the
/// CRC, and the source interface's state machine, over a real MacTCP
/// stack with real packet boundaries. It proves nothing about the 180c.
/// The emulator is a 68040 under Mac OS 8.1 with 128 MB against a 68030
/// under System 7.1 with 4 MB, and timing, memory pressure and MacTCP
/// under load are exactly what does not carry over. Read a green run as
/// emulator-verified. Never write "works".
@MainActor
final class Metal68KSendTests: XCTestCase {
    private var listener: GuestListener!
    private var shareRoot: URL!
    private var previousRoot: URL!
    private var port: UInt16 = 5250

    /// Files the guest has sent back, by name, as they land.
    private var landed: [String: URL] = [:]

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        // Before anything binds — see MetalMachineGuard. This suite's
        // round trip is the one whose 2026-07-25 run produced numbers
        // nobody could attribute.
        try MetalMachineGuard.preflight(port: port)
        listener = GuestListener(
            identity: .init(version: "0.1-metal68k", name: "Metal Harness"),
            pacing: .classicMac)

        // A returning file lands in the host's share, so the share is
        // pointed at a temporary directory rather than the human's
        // Downloads folder — this test writes several megabytes and
        // overwrites its own names.
        shareRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("now68k-send-\(ProcessInfo().processIdentifier)")
        try FileManager.default.createDirectory(
            at: shareRoot, withIntermediateDirectories: true)
        previousRoot = listener.share.root
        // Read BEFORE the root moves: leftovers in the share a real run
        // lands in are the one piece of "somebody is mid-ladder"
        // evidence visible from this side. Reported, not thrown — a file
        // is evidence and this suite's own previous run is a likely
        // author of it.
        MetalMachineGuard.reportRecentLeftovers(in: previousRoot)
        listener.share.root = shareRoot

        listener.announceReceivedFile = { [weak self] _, url, _ in
            self?.landed[url.lastPathComponent] = url
        }
        listener.start(port: port)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
        if let previousRoot {
            // Restored even on a failing run: this is a UserDefaults key,
            // so leaving it pointed at a deleted temp directory would
            // break the human's next real transfer.
            GuestListener(identity: .init(version: "x", name: "x"),
                          pacing: .classicMac).share.root = previousRoot
        }
        if let shareRoot {
            try? FileManager.default.removeItem(at: shareRoot)
        }
    }

    @discardableResult
    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
        -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // A bind failure means nothing could dial in; reporting it as
            // "the Mac never answered" aims two minutes of diagnosis at
            // the wrong end of the room.
            try MetalMachineGuard.requireItIsListening(listener.state,
                                                       port: port)
            if case .connected(let name) = listener.state {
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("""
            No guest dialled in within \(Int(seconds))s. NOW_METAL is set, \
            so this is a failure and not a skip — boot one with \
            scripts/q800-68k, or check that the 180c is running a build \
            whose dev settings point at this port. The harness WAS \
            listening on \(port) and nothing else held it, so this is the \
            Mac's end; if MacTCP has wedged, the dial never completes and \
            nothing here can tell you so.
            """)
        throw XCTSkip("no guest")
    }

    /// Refuses to test a guest that is not the build under test.
    ///
    /// THIS IS NOT PARANOIA. Several QEMU guests run at once on this
    /// machine — one per session — and under QEMU user-mode networking
    /// every one of them sees this Mac as 10.0.2.2. Any of them can
    /// reach this listener. The first run of this file spent a while
    /// reporting `unknown-command` for `put` from a guest that was
    /// simply an older build, and the failure said nothing about that;
    /// worse, the refusal test PASSED against it, because "unknown
    /// command" is also a refusal with a reason.
    ///
    /// `help` is the discriminator because it renders the guest's own
    /// doc table, so a guest that lists `put` is a guest that has it.
    /// AGENTS.md's version of this is "check the build stamp before
    /// believing a test result".
    private func requireTheBuildUnderTest() async throws {
        var help: CommandResult?
        listener.runCommand("help", line: "") { help = $0 }
        let deadline = Date().addingTimeInterval(30)
        while help == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        let reply = try XCTUnwrap(help, "the guest did not answer `help`")
        let verbs = (reply.output ?? [:]).values.flatMap { $0 }
            .flatMap { $0 }
        guard verbs.contains(where: { $0 == "put" }) else {
            XCTFail("""
                The guest on this wire does not list `put`, so it is NOT \
                the build under test — most likely another session's VM \
                found this listener, or scripts/q800-68k injected an old \
                binary. Re-run it, and give this run a port nothing else \
                is dialling (NOW_METAL_PORT). Verbs seen: \
                \(verbs.sorted().joined(separator: ", "))
                """)
            throw XCTSkip("wrong build on the wire")
        }
    }

    /// A pattern with no short period, so a transfer that duplicated or
    /// dropped a run fails the comparison rather than landing back on
    /// itself. Zeroes would hide exactly the bug worth finding, and a
    /// chunking bug is the one this direction is most likely to have.
    private func pattern(_ count: Int) -> Data {
        var out = Data(capacity: count)
        for i in 0..<count {
            out.append(UInt8((i &* 31 &+ (i >> 11) &* 7 &+ 13) & 0xFF))
        }
        return out
    }

    // MARK: - the two halves of a round trip

    private func push(_ name: String, _ bytes: Data,
                      timeout: TimeInterval = 300) async throws {
        var done: Result<GuestListener.PutReceipt, GuestListener.FileFailure>?
        listener.putFileWithReceipt(
            name: name, into: "", container: "data", bytes: bytes,
            overwrite: true
        ) { done = $0 }

        let deadline = Date().addingTimeInterval(timeout)
        while done == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        switch done {
        case .success:
            return
        case .failure(let f):
            throw XCTSkip("""
                the PUSH half failed before the send half could be tested: \
                [\(f.code)] \(f.message). That is Metal68KPutTests' \
                territory, not this file's — fix it there.
                """)
        case nil:
            throw XCTSkip("the push half hung after \(Int(timeout))s")
        }
    }

    private struct Sent {
        var ok: Bool
        var detail: String
        var seconds: TimeInterval
    }

    /// Asks the guest to send `name` back, and waits for it to land.
    ///
    /// The command answers as soon as the OFFER is away, not when the
    /// file arrives — deliberately, because a command that blocked for a
    /// multi-megabyte transfer would hold a command.result for minutes.
    /// So the arrival is waited on separately, which is also what makes
    /// the mid-flight test below possible.
    private func askToSend(_ name: String,
                           timeout: TimeInterval = 300) async -> Sent {
        let started = Date()
        landed[name] = nil

        var reply: CommandResult?
        listener.runCommand("put", line: name) { reply = $0 }

        var deadline = Date().addingTimeInterval(30)
        while reply == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        guard let reply else {
            return Sent(ok: false, detail: "the put command never answered",
                        seconds: Date().timeIntervalSince(started))
        }
        guard reply.ok else {
            let e = reply.error
            return Sent(
                ok: false,
                detail: "put refused: [\(e?.code ?? "?")] \(e?.message ?? "")",
                seconds: Date().timeIntervalSince(started))
        }

        deadline = Date().addingTimeInterval(timeout)
        while landed[name] == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        let secs = Date().timeIntervalSince(started)
        if landed[name] == nil {
            return Sent(ok: false,
                        detail: "the offer went out but nothing arrived in "
                              + "\(Int(timeout))s",
                        seconds: secs)
        }
        return Sent(ok: true, detail: "", seconds: secs)
    }

    // MARK: - the ladder

    /// Sizes chosen against the buffers in the path rather than for being
    /// round: the negotiated chunk is 4096, so one byte either side of a
    /// multiple is where an off-by-one in the last frame or the END flag
    /// lives. 0 is here because a zero-length source sends NO bulk frame
    /// at all — begin then end — which is a decision
    /// guest68k/tests/test_puttx.c pins and only a real host can confirm
    /// does not leave a receiver waiting.
    ///
    /// `NOW_METAL_REPEATS` (default 1, the runbook asks for 3 on the
    /// 180c) repeats the rungs at or above 1 MB. The small ones are
    /// correctness and repeat nothing useful; the large ones are this
    /// suite's only measurement, and the emulator's send rate reads off a
    /// cached disk, so the 180c's is the first real one and a single
    /// sample of it would be an anecdote.
    func testTheRoundTripLadder() async throws {
        let who = try await waitForGuest()
        print("=== \(who) — guest to host ===")
        try await requireTheBuildUnderTest()
        let repeats = MetalBaseline.repeats
        MetalBaseline.emitMeta(guestName: who,
                               version: listener.health?.guestVersion,
                               os: listener.health?.guestOS,
                               port: port, repeats: repeats)

        let sizes: [(String, Int)] = [
            ("empty", 0),
            ("one byte", 1),
            ("under one chunk", 4095),
            ("exactly one chunk", 4096),
            ("one chunk plus a byte", 4097),
            ("two chunks", 8192),
            ("64 KB", 64 * 1024),
            ("256 KB", 256 * 1024),
            ("1 MB", 1024 * 1024),
            // The same headline size the receive direction uses, so the
            // two can be read against each other.
            ("4 MB", 4 * 1024 * 1024),
        ]

        var failures: [String] = []
        for (label, size) in sizes {
            let original = pattern(size)
            let samples = size >= 1_048_576 ? repeats : 1

            for rep in 1...samples {
                // A NAME PER SAMPLE, and it is not tidiness. NOW-68K's
                // offer never sets `overwrite`, so the host defaults it
                // to false (`GuestListener.acceptOffer`) and REFUSES a
                // second offer of a name the share already holds. Reusing
                // one name made every repeat read as "the offer went out
                // but nothing arrived in 300s" — a 300 s stall that looks
                // exactly like the machine having gone away, produced
                // entirely by this harness. Watched, 2026-07-26, on the
                // emulator.
                let name = "RT\(size)r\(rep)"
                let which = samples > 1 ? " [\(rep)/\(samples)]" : ""
                try await push(name, original)

                let sent = await askToSend(name)
                func record(_ result: String) {
                    MetalBaseline.emitRung(
                        direction: "send", label: label, bytes: size,
                        seconds: sent.seconds, rep: rep, of: samples,
                        result: result,
                        // The comparison is what makes a send rung mean
                        // anything, so whether it ran is part of the
                        // record and not something to infer from `ok`.
                        extra: [("verify", result == "ok"
                                           ? "byte-identical" : "-")])
                }
                guard sent.ok, let url = landed[name] else {
                    failures.append("\(label)\(which) (\(size) B): "
                                    + sent.detail)
                    print("  \(label)\(which): FAILED — \(sent.detail)")
                    record("failed")
                    continue
                }

                let returned = try Data(contentsOf: url)
                // The whole point. Not a count, not a checksum the guest
                // computed — the bytes this test sent, against the bytes
                // it got back.
                if returned != original {
                    let where_ = zip(returned, original).enumerated()
                        .first { $0.element.0 != $0.element.1 }?.offset
                    failures.append("""
                        \(label)\(which) (\(size) B): came back WRONG — \
                        \(returned.count) bytes against \(original.count), \
                        first difference at \(where_.map(String.init) ?? "n/a")
                        """)
                    print("  \(label)\(which): CORRUPT")
                    record("corrupt")
                    continue
                }
                let rate = Double(size) / 1024.0 / max(sent.seconds, 0.001)
                print(String(format: "  %@%@: ok in %.1fs (%.0f KB/s)",
                             label, which, sent.seconds, rate))
                record("ok")
            }
        }

        XCTAssertTrue(failures.isEmpty, """
            NOW-68K did not send these back intact:
            \(failures.joined(separator: "\n"))
            """)
    }

    /// THE RULE THIS DIRECTION EXISTS TO KEEP. n68_puttx.h states that
    /// bulk never touches the control queue and that control drains
    /// first, so a reply queued during a transfer waits for the chunk in
    /// flight and never for the transfer.
    ///
    /// Nothing off-metal can check that: it is a property of a real
    /// socket under real back-pressure. Here it is one question — does
    /// the guest still answer while it is sending — and the answer has a
    /// number. A guest that starved its control lane would time out, and
    /// one that merely got slow would show it in the round trip.
    ///
    /// This is also the test that would have caught the failure the
    /// ledger already records the cost of: a dropped command.result is a
    /// contract violation, and the host's own timeout is how it shows up.
    func testTheControlLaneSurvivesATransfer() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        let name = "RTbusy"
        // Large enough that the transfer outlives several control round
        // trips. At 1 MB the emulator finished in under a second and the
        // sample was five questions, which is thin evidence for a claim
        // about starvation.
        let size = 4 * 1024 * 1024
        try await push(name, pattern(size))

        var reply: CommandResult?
        listener.runCommand("put", line: name) { reply = $0 }
        let deadline = Date().addingTimeInterval(30)
        while reply == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        _ = try XCTUnwrap(reply, "the put command never answered")

        // Now the bulk stream is running. Ask a control question
        // repeatedly until the file lands, and keep the worst answer.
        var worst: TimeInterval = 0
        var asked = 0
        var unanswered = 0
        while landed[name] == nil, Date() < deadline.addingTimeInterval(300) {
            let started = Date()
            var help: CommandResult?
            listener.runCommand("help", line: "") { help = $0 }
            let each = Date().addingTimeInterval(20)
            while help == nil, Date() < each {
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            asked += 1
            if help == nil {
                unanswered += 1
            } else {
                worst = max(worst, Date().timeIntervalSince(started))
            }
        }

        XCTAssertNotNil(landed[name], "the transfer never finished")
        XCTAssertGreaterThan(asked, 0, """
            the transfer finished before a single control question could \
            be asked, so this proved nothing — use a larger file.
            """)
        print(String(format: "=== control lane: %d asked, %d unanswered, "
                           + "worst %.2fs", asked, unanswered, worst))
        // The claim nothing off metal can check, and the one most likely
        // to read differently on a 33 MHz 68030 with 4 MB. No idle
        // figure: this case measures only under load, and a dash is
        // honester than a number taken from somewhere else.
        MetalBaseline.emitControlLane(direction: "send", asked: asked,
                                      unanswered: unanswered, worst: worst,
                                      idle: nil)
        XCTAssertEqual(unanswered, 0, """
            \(unanswered) of \(asked) control requests went unanswered \
            while a bulk transfer was running. Bulk is starving the \
            control lane — see the wire-sharing rule in n68_puttx.h; \
            either the bulk slot is consuming control slots or \
            flush_outbound stopped draining control first.
            """)
        XCTAssertLessThan(worst, 10.0, """
            a control request took \(worst)s during a transfer. The rule \
            says a reply waits for the chunk in flight (~12 ms at the \
            measured rate) and never for the transfer, so this is bulk \
            being drained ahead of control rather than behind it.
            """)
    }

    /// The refusals, which have to be refusals and not silence: the host
    /// is blocked on a command.result the contract promises always comes.
    func testTheRefusals() async throws {
        try await waitForGuest()
        try await requireTheBuildUnderTest()

        var missing: CommandResult?
        listener.runCommand("put", line: "NoSuchFileHere") { missing = $0 }
        var deadline = Date().addingTimeInterval(30)
        while missing == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let absent = try XCTUnwrap(missing, "no answer for a missing file")
        XCTAssertFalse(absent.ok, "a file that is not there was accepted")
        XCTAssertNotNil(absent.error?.message,
                        "a refusal must say why — the person typing it is "
                        + "standing at the machine")

        var bad: CommandResult?
        listener.runCommand("put", line: "Lab:Secrets") { bad = $0 }
        deadline = Date().addingTimeInterval(30)
        while bad == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        let path = try XCTUnwrap(bad, "no answer for a path")
        XCTAssertFalse(path.ok, """
            a colon-bearing name was accepted. `put` takes a leaf, and a \
            colon is HFS's own separator — the sender is where that \
            promise is kept, because the receiver is entitled to assume \
            it ran.
            """)
    }
}
