import Foundation
@testable import Host

/// One line per measurement, in a shape a person can grep and a script
/// can read, so that the first metal run on the PowerBook 180c produces
/// a BASELINE and not an anecdote.
///
/// ---- Why the existing prints are not enough --------------------------
///
/// The metal suites already print rates, and those prints are how the
/// emulator numbers in the ledger were obtained. They are prose: the
/// receive suite says "1 MB: ok in 2.9s (357 KB/s)" and the send suite
/// says something else in a different order, so comparing two runs means
/// reading two transcripts side by side, and comparing a 180c run
/// against the emulator's means retyping both into a table. Nobody does
/// that twice.
///
/// More to the point, the transcript loses the things that decide
/// whether a number can be believed at all — which build answered, on
/// which port, against which machine, and whether it was the first
/// attempt or the third. The 2026-07-25 run is the case in point: the
/// numbers it produced were real numbers and none of them could be
/// attributed afterwards, because nothing recorded the conditions
/// alongside them.
///
/// ---- The shape --------------------------------------------------------
///
///     NOWBASE meta guest=now-68k version=0.19 port=5252 machine=...
///     NOWBASE rung dir=receive bytes=4194304 secs=11.70 rate_kbs=350 ...
///     NOWBASE control phase=during asked=28 unanswered=0 worst_s=0.10
///
/// `NOWBASE `-prefixed, space-separated `key=value`, values with no
/// spaces in them. Deliberately not JSON: this has to survive being
/// copied out of a terminal into a commit message and a doc table, and
/// it has to be legible as it scrolls past during a run that may be
/// about to fail.
///
/// docs/68k-metal-baseline.md says what to record and how to read it.
///
/// The grammar itself moved to `BaselineLine` in the application when the
/// Mirror act instrument began emitting the same kind of line from inside
/// the running app. Two copies of it would not fail to build when they
/// drifted — they would fail to agree, and the marker is what every
/// recorded baseline's provenance rests on.
enum MetalBaseline {

    static var marker: String { BaselineLine.marker }

    static func sanitise(_ value: String) -> String {
        BaselineLine.sanitise(value)
    }

    static func line(_ kind: String, _ fields: [(String, String)]) -> String {
        BaselineLine.line(kind, fields)
    }

    /// Prints it. A separate call so a test can build a line and assert
    /// on it without printing, which is how the tests below work.
    static func emit(_ kind: String, _ fields: [(String, String)]) {
        print(line(kind, fields))
    }

    // MARK: - the records

    /// Everything needed to decide whether the rungs below are worth
    /// anything: WHICH build answered, on WHICH machine, over WHICH port.
    /// A rate without these is a number without a subject — which is
    /// precisely what the contended run produced.
    /// Each record is BUILT by one function and PRINTED by another, so
    /// the tests can assert on the real thing. A test that assembled the
    /// same line itself would be testing its own copy of the format —
    /// which is the shape AGENTS.md names as testing one half twice.
    static func meta(guestName: String, version: String?, os: String?,
                     port: UInt16, repeats: Int,
                     machine: String? = ProcessInfo.processInfo
                        .environment["NOW_METAL_MACHINE"]) -> String {
        let machine = machine.flatMap { $0.isEmpty ? nil : $0 } ?? "unnamed"
        return line("meta", [
            ("guest", guestName),
            ("version", version ?? "?"),
            ("os", os ?? "?"),
            ("port", String(port)),
            ("machine", machine),
            ("repeats", String(repeats)),
        ])
    }

    static func emitMeta(guestName: String, version: String?, os: String?,
                         port: UInt16, repeats: Int) {
        print(meta(guestName: guestName, version: version, os: os,
                   port: port, repeats: repeats))
    }

    /// One rung of a ladder, in one direction.
    ///
    /// `rate_kbs` is derived here rather than by each caller so that two
    /// directions cannot disagree about what a kilobyte is — the send and
    /// receive suites computed it separately and it would have been easy
    /// for one of them to have used 1000.
    ///
    /// `rep` is not decoration. One sample from a machine whose MacTCP
    /// has been watched wedging silently is an anecdote; three with their
    /// spread visible is a baseline, and a rung whose three samples
    /// disagree by 3× has said something no single number could.
    static func rung(direction: String, label: String, bytes: Int,
                     seconds: TimeInterval, rep: Int, of repeats: Int,
                     result: String,
                     extra: [(String, String)] = []) -> String {
        // Guarded because a zero-length rung is a real case both ladders
        // carry, and an infinity is a number no table can hold.
        let rate = seconds > 0
            ? Double(bytes) / 1024.0 / seconds
            : 0
        return line("rung", [
            ("dir", direction),
            ("label", label),
            ("bytes", String(bytes)),
            ("secs", String(format: "%.2f", seconds)),
            ("rate_kbs", String(format: "%.0f", rate)),
            ("rep", "\(rep)/\(repeats)"),
            ("result", result),
        ] + extra)
    }

    static func emitRung(direction: String, label: String, bytes: Int,
                         seconds: TimeInterval, rep: Int, of repeats: Int,
                         result: String, extra: [(String, String)] = []) {
        print(rung(direction: direction, label: label, bytes: bytes,
                   seconds: seconds, rep: rep, of: repeats,
                   result: result, extra: extra))
    }

    /// The control lane under load — the claim nothing off-metal can
    /// check, and the one most likely to differ on a 33 MHz 68030 with
    /// 4 MB from a 68040 with 128.
    static func controlLane(direction: String, asked: Int,
                            unanswered: Int, worst: TimeInterval,
                            idle: TimeInterval?) -> String {
        line("control", [
            ("dir", direction),
            ("asked", String(asked)),
            ("unanswered", String(unanswered)),
            ("worst_s", String(format: "%.2f", worst)),
            ("idle_s", idle.map { String(format: "%.2f", $0) } ?? "-"),
        ])
    }

    static func emitControlLane(direction: String, asked: Int,
                                unanswered: Int, worst: TimeInterval,
                                idle: TimeInterval?) {
        print(controlLane(direction: direction, asked: asked,
                          unanswered: unanswered, worst: worst, idle: idle))
    }

    /// How many times a headline rung is measured. One on the emulator,
    /// because correctness is what an emulator run is for; the runbook
    /// asks for three on the 180c, because a rate is what a metal run is
    /// for and a single sample from that machine has already proved able
    /// to mean nothing.
    static var repeats: Int {
        ProcessInfo.processInfo.environment["NOW_METAL_REPEATS"]
            .flatMap { Int($0) }
            .map { max(1, $0) } ?? 1
    }
}
