import Combine
import XCTest
@testable import Host

/// Pushes files to NOW-68K over a real wire — the emulator or the
/// PowerBook 180c, whichever dialled in.
///
///     scripts/q800-68k                       # boot the emulator, then:
///     NOW_METAL=1 swift test --filter Metal68KPutTests
///
/// Opt-in, and once opted in it FAILS rather than skips (AGENTS.md): a
/// gate that reads green having never reached a machine is worse than no
/// gate. `NOW_METAL` unset skips, because the human did not ask.
///
/// ---- What a green run here does and does not prove -------------------
///
/// It proves the transfer is CORRECT: that every byte arrived, in order,
/// and that the file on the guest's disk is the file that was sent. It
/// does not prove anything about the 180c. The emulator is a 68040 under
/// Mac OS 8.1 with 128 MB against a 68030 under System 7.1 with 4 MB;
/// timing, memory pressure and MacTCP's behaviour under load are exactly
/// the things that do not carry over, and they are exactly the things
/// that broke on the PowerBook 1400c (docs/large-transfers.md). Read a
/// green run as emulator-verified. Never write "works".
///
/// ---- Why the integrity check is real and not self-referential --------
///
/// Nothing here compares the guest's bytes to the host's directly —
/// NOW-68K serves no `file.list` and no pull, so there is no way to read
/// them back. The proof is the CHECKSUM, and it is two independent
/// implementations meeting:
///
///   * the host computes CRC-32 with its own code over the bytes it
///     sends, and puts it in file.end;
///   * the guest computes CRC-32 with n68_crc32.c over the bytes AS THEY
///     ARRIVE, in whatever runs MacTCP handed over;
///   * the guest compares them itself and answers file.done ok:false
///     code:"corrupt" on a mismatch, deleting the file.
///
/// So `ok:true` from a 4 MB push means both halves independently agree
/// about all 4,194,304 bytes. A test that read the count back off the
/// guest's own progress reports would be testing one half twice.
///
/// "As they arrive" rather than "as written" is load-bearing for
/// MacBinary and not a detail: the contract checksums the WHOLE file's
/// wire bytes (FileEnd.crc32), and an envelope's 128-byte header and its
/// inter-fork padding are wire bytes that reach neither fork. A receiver
/// that checksummed what it wrote would disagree with every sender on
/// every MacBinary file, and would report `corrupt` for files that
/// arrived perfectly.
@MainActor
final class Metal68KPutTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5250

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        // Before anything binds. `requireTheBuildUnderTest` asks whether
        // the right guest answered; this asks whether the machine was
        // free to answer at all, which is the question the contended run
        // of 2026-07-25 had no way to put.
        try MetalMachineGuard.preflight(port: port)
        listener = GuestListener(
            identity: .init(version: "0.1-metal68k", name: "Metal Harness"),
            pacing: .classicMac)
        listener.start(port: port)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    /// The guest dials us, so nothing here reaches out to it.
    @discardableResult
    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
        -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            // Checked every pass rather than once: a bind failure that
            // arrives late still means nothing could dial in, and
            // reporting it as "the Mac never answered" points a diagnosis
            // at the wrong end of the room for two minutes.
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
            Mac's end: if MacTCP has wedged, the dial never completes and \
            nothing here can tell you so. Reboot it.
            """)
        throw XCTSkip("no guest")
    }

    /// A pattern with no short period, so a transfer that duplicated or
    /// dropped a run fails the checksum rather than landing back on
    /// itself. Zeroes would hide exactly the bug worth finding.
    private func pattern(_ count: Int) -> Data {
        var out = Data(capacity: count)
        for i in 0..<count {
            out.append(UInt8((i &* 31 &+ (i >> 11) &* 7 &+ 13) & 0xFF))
        }
        return out
    }

    private struct Outcome {
        var ok: Bool
        var text: String
        var receipt: GuestListener.PutReceipt?
        /// Kept as numbers as well as prose, because the prose is for the
        /// person watching and the numbers are the baseline record
        /// (docs/68k-metal-baseline.md). Deriving them back out of the
        /// text later is how a measurement becomes an anecdote.
        var seconds: TimeInterval = 0
        var reports = 0
        var maxGap = 0
        /// Where a transfer that never finished stopped. 606208 of
        /// 1048576 was the whole of what the contended run left behind,
        /// and it lived in a transcript rather than in a record.
        var stalledAt: Int?
    }

    private func put(_ name: String, _ bytes: Data,
                     container: String = "data",
                     timeout: TimeInterval = 300) async -> Outcome {
        let started = Date()
        var result: Outcome?
        var lastSeen = 0
        var reports = 0
        var maxGap = 0
        var previous = 0

        // The progress stream is not decoration here: it is the sender's
        // clock. Recording the largest jump between reports is what would
        // catch a guest acking too coarsely for the host's window — the
        // failure mode that presents as a transfer stopping dead at
        // exactly the window size (docs/large-transfers.md).
        let watch = listener.$captureProgress.sink { progress in
            guard let progress, progress.received != lastSeen else { return }
            lastSeen = progress.received
            reports += 1
            maxGap = max(maxGap, progress.received - previous)
            previous = progress.received
        }
        defer { watch.cancel() }

        listener.putFileWithReceipt(
            name: name, into: "", container: container, bytes: bytes,
            overwrite: true
        ) { r in
            let secs = Date().timeIntervalSince(started)
            switch r {
            case .success(let receipt):
                let rate = Double(bytes.count) / 1024.0 / max(secs, 0.001)
                result = Outcome(
                    ok: true,
                    text: String(
                        format: "ok in %.1fs (%.0f KB/s), %d reports, "
                              + "largest gap %d B, integrity %@",
                        secs, rate, reports, maxGap, receipt.integrity),
                    receipt: receipt,
                    seconds: secs, reports: reports, maxGap: maxGap)
            case .failure(let f):
                result = Outcome(
                    ok: false,
                    text: "FAILED [\(f.code)] \(f.message) "
                        + "after \(Int(secs))s, \(lastSeen) of \(bytes.count)",
                    receipt: nil,
                    seconds: secs, reports: reports, maxGap: maxGap)
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while result == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if result == nil {
            listener.cancelFile()
            return Outcome(
                ok: false,
                text: "HUNG after \(Int(timeout))s at \(lastSeen) of "
                    + "\(bytes.count) bytes, \(reports) reports "
                    + "(largest gap \(maxGap) B)",
                receipt: nil,
                seconds: timeout, reports: reports, maxGap: maxGap,
                stalledAt: lastSeen)
        }
        return result!
    }

    /// The ladder, smallest first, so a size-keyed failure names the rung
    /// it starts at rather than just "4 MB does not work".
    ///
    /// The sizes are chosen against the buffers in the path rather than
    /// being round: the batch buffer and the progress step are both
    /// 8192, and the host's frame is 8192 too, so one byte either side of
    /// a multiple is where an off-by-one in the flush or the ack lives.
    ///
    /// ---- Repeats, and which rungs get them -------------------------------
    ///
    /// The small rungs are CORRECTNESS checks — a byte either side of a
    /// frame boundary is right or it is not, and running it three times
    /// says the same thing three times. The large ones are the only
    /// MEASUREMENT this suite makes, and on a machine whose MacTCP has
    /// been watched wedging silently, one sample of a rate is an
    /// anecdote. So `NOW_METAL_REPEATS` (default 1, the runbook asks for
    /// 3 on the 180c) repeats the rungs at or above 1 MB only, and the
    /// baseline record carries each sample separately so their spread is
    /// visible rather than averaged away.
    func testTheSizeLadderUpToFourMegabytes() async throws {
        let who = try await waitForGuest()
        print("=== \(who) ===")
        let repeats = MetalBaseline.repeats
        MetalBaseline.emitMeta(guestName: who,
                               version: listener.health?.guestVersion,
                               os: listener.health?.guestOS,
                               port: port, repeats: repeats)

        let sizes: [(String, Int)] = [
            ("empty", 0),
            ("one byte", 1),
            ("under one frame", 8191),
            ("exactly one frame", 8192),
            ("one frame plus a byte", 8193),
            ("past the window", 65536),
            ("256 KB", 262_144),
            ("1 MB", 1_048_576),
            ("4 MB", 4_194_304),
        ]

        var failures: [String] = []
        for (label, size) in sizes {
            let samples = size >= 1_048_576 ? repeats : 1
            for rep in 1...samples {
                let outcome = await put("N68 \(size)", pattern(size))
                let which = samples > 1 ? " [\(rep)/\(samples)]" : ""
                print("  \(label) (\(size) B)\(which): \(outcome.text)")
                MetalBaseline.emitRung(
                    direction: "receive", label: label, bytes: size,
                    seconds: outcome.seconds, rep: rep, of: samples,
                    result: outcome.ok ? "ok" : "failed",
                    extra: [("reports", String(outcome.reports)),
                            ("maxgap", String(outcome.maxGap)),
                            ("integrity", outcome.receipt?.integrity ?? "-"),
                            ("stalled_at",
                             outcome.stalledAt.map(String.init) ?? "-")])
                if !outcome.ok {
                    failures.append("\(label)\(which): \(outcome.text)")
                    // Keep going: which rungs fail is the diagnosis, and
                    // stopping at the first one throws that away.
                    continue
                }
                guard let r = outcome.receipt else { continue }
                XCTAssertEqual(r.receiverConfirmedBytes, size, label)
                XCTAssertEqual(r.finalization, "same-folder-rename", label)
                XCTAssertEqual(r.cleanup, "temp-renamed", label)
                // The guest sent a checksum at all. It having MATCHED is
                // proven by the transfer completing: the guest compares
                // the host's crc32 against its own and answers `corrupt`
                // when they differ.
                XCTAssertEqual(r.integrity, "guest-crc32-confirmed", label)
                // Silence from the guest would mean the host ran on its
                // own send counter, which on a slow link is a lie by
                // minutes — and it is what the window clocks on.
                if size > 8192 {
                    XCTAssertEqual(r.progressEvidence, "guest-progress",
                                   "\(label): the guest must clock the sender")
                }
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "rungs that failed:\n  " + failures.joined(separator: "\n  "))
    }

    /// A real MacBinary envelope: 128-byte header, data fork padded to
    /// 128, resource fork padded the same way.
    ///
    /// This is the container that carries an APPLICATION, which is the
    /// whole reason it matters on this machine — a Mac application IS
    /// its resource fork, and a transfer that can only carry a data fork
    /// cannot deliver one. The check that it worked is the same one the
    /// data ladder uses and it is not self-referential: the guest
    /// computes CRC-32 over the WIRE bytes (header and padding
    /// included), compares them against the host's, and answers
    /// `corrupt` on a mismatch. `ok:true` means both halves agree about
    /// the envelope.
    private func macBinary(data: Int, rsrc: Int,
                           type: String, creator: String) -> Data {
        func padded(_ n: Int) -> Int { (n + 127) & ~127 }
        var header = [UInt8](repeating: 0, count: 128)
        header[0] = 0                                  // old version, zero
        header[1] = 6
        for (i, b) in Array("AnApp!".utf8).enumerated() { header[2 + i] = b }
        for (i, b) in Array(type.utf8).enumerated() { header[65 + i] = b }
        for (i, b) in Array(creator.utf8).enumerated() { header[69 + i] = b }
        func put32(_ at: Int, _ v: UInt32) {
            header[at] = UInt8(truncatingIfNeeded: v >> 24)
            header[at + 1] = UInt8(truncatingIfNeeded: v >> 16)
            header[at + 2] = UInt8(truncatingIfNeeded: v >> 8)
            header[at + 3] = UInt8(truncatingIfNeeded: v)
        }
        put32(83, UInt32(data))
        put32(87, UInt32(rsrc))
        put32(95, 3_300_000_000)                       // Mac epoch seconds
        header[122] = 130                              // MacBinary III
        header[123] = 129
        // CRC-16/XMODEM over the first 124 bytes — the field that says
        // "this is a header and not 128 bytes of something else".
        var crc: UInt16 = 0
        for byte in header[0..<124] {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        header[124] = UInt8(truncatingIfNeeded: crc >> 8)
        header[125] = UInt8(truncatingIfNeeded: crc)

        var out = Data(header)
        out.append(pattern(data))
        out.append(Data(repeating: 0, count: padded(data) - data))
        // Inverted, so a decode that put a run in the wrong fork fails on
        // content rather than only on length.
        out.append(Data(pattern(rsrc).map { $0 ^ 0xFF }))
        out.append(Data(repeating: 0, count: padded(rsrc) - rsrc))
        return out
    }

    func testMacBinaryCarriesBothForks() async throws {
        try await waitForGuest()

        // Sizes chosen against the padding rule rather than for being
        // round: a fork that is an exact multiple of 128 has NO padding,
        // so the next section starts immediately, and that is where an
        // off-by-one in the decode lives.
        let cases: [(String, Int, Int)] = [
            ("both forks", 5000, 3000),
            ("data an exact multiple of 128", 4096, 1000),
            ("rsrc an exact multiple of 128", 1000, 4096),
            ("no resource fork", 2000, 0),
            ("no data fork", 0, 2000),
            ("a resource-heavy application", 12_000, 200_000),
        ]

        var failures: [String] = []
        for (label, data, rsrc) in cases {
            let env = macBinary(data: data, rsrc: rsrc,
                                type: "APPL", creator: "MPS ")
            let outcome = await put("N68 mb \(data)-\(rsrc)", env,
                                    container: "macbinary")
            print("  \(label) (\(data)+\(rsrc), envelope \(env.count) B): "
                  + outcome.text)
            if !outcome.ok {
                failures.append("\(label): \(outcome.text)")
                continue
            }
            if let r = outcome.receipt {
                // The receiver confirms the ENVELOPE's byte count — the
                // stream it took off the wire — not the forks' total.
                XCTAssertEqual(r.receiverConfirmedBytes, env.count, label)
                XCTAssertEqual(r.integrity, "guest-crc32-confirmed", label)
                XCTAssertEqual(r.cleanup, "temp-renamed", label)
            }
        }
        XCTAssertTrue(failures.isEmpty,
                      "envelopes that failed:\n  "
                      + failures.joined(separator: "\n  "))
    }

    /// A container from some later contract revision. It must be REFUSED
    /// rather than quietly written out as a raw data fork, which would
    /// produce a file of the wrong length and the wrong shape and blame
    /// the disk.
    func testAnUnknownContainerIsRefused() async throws {
        try await waitForGuest()
        var settled: String?
        listener.putFile(name: "N68 unknown", into: "",
                         container: "applesingle", bytes: pattern(4096),
                         overwrite: true) { r in
            switch r {
            case .success: settled = "accepted"
            case .failure(let f): settled = "refused: \(f.code) — \(f.message)"
            }
        }
        let deadline = Date().addingTimeInterval(60)
        while settled == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        print("  unknown container: \(settled ?? "no answer in 60s")")
        XCTAssertNotNil(settled, "the guest never answered the offer")
        XCTAssertEqual(settled?.hasPrefix("refused"), true, """
            An unrecognized container must be refused. Treating one as \
            `data` writes the envelope out as if it were the file.
            """)
        XCTAssertEqual(settled?.contains("container"), true, """
            The refusal has to SAY so. FileRefuse.code has no value for \
            "this receiver cannot handle that", so the code is io-error \
            and `reason` is the only place the truth can live.
            """)
    }

    /// The guest must still answer while bytes are streaming. A receive
    /// path that starves the event loop looks identical to a wedged
    /// machine from the far end, and on a cooperatively scheduled Mac it
    /// is a real risk: every FSWrite blocks the loop for as long as the
    /// disk takes.
    func testTheGuestStillAnswersDuringATransfer() async throws {
        try await waitForGuest()

        var idle: TimeInterval?
        var during: TimeInterval?

        idle = await commandLatency()
        async let transfer = put("N68 latency", pattern(1_048_576))
        try await Task.sleep(nanoseconds: 1_500_000_000)
        during = await commandLatency()
        let outcome = await transfer

        print("  help idle \(idle.map { String(format: "%.2fs", $0) } ?? "—")"
              + ", during \(during.map { String(format: "%.2fs", $0) } ?? "no answer")"
              + "; transfer \(outcome.text)")
        // One question, so `asked` is 1 and `unanswered` is 0 or 1 — the
        // receive direction samples the control lane rather than
        // hammering it, unlike the send suite. Recorded in the same shape
        // regardless, because the two directions' latencies under load
        // are the comparison the 180c is most likely to make interesting.
        MetalBaseline.emitControlLane(
            direction: "receive", asked: 1,
            unanswered: during == nil ? 1 : 0,
            worst: during ?? 0, idle: idle)
        XCTAssertTrue(outcome.ok, outcome.text)
        XCTAssertNotNil(during, """
            The guest stopped answering commands while receiving. It is \
            not wedged and it is not slow — it is starved, and from the \
            host those look the same.
            """)
    }

    private func commandLatency() async -> TimeInterval? {
        let started = Date()
        var got = false
        listener.runCommand("help") { _ in got = true }
        let deadline = Date().addingTimeInterval(25)
        while !got, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return got ? Date().timeIntervalSince(started) : nil
    }
}
