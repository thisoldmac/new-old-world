import Foundation
import XCTest
@testable import Host

/// **One question, one producer.** The PowerPC guest used to answer "what
/// processes are running, and which of them is faceless" from five
/// independent `GetNextProcess` walks, with the `modeOnlyBackground` test
/// copy-pasted into four of them — `commands.c` said so in a comment:
/// *"the same test `serve_process_list` makes."* The scene plane read the
/// bit in none of them, so at one instant `process.list` said
/// `kind: background` about a process the scene called
/// `ax_oracle_not_found`. Both were honest. A caller could not tell.
///
/// The failure mode was never the redundancy. It was **disagreement**, and
/// a driving agent that reads one answer and acts on another is the thing
/// this project exists not to ship.
///
/// This gate is **structural, not enumerated**: it walks every `.c` under
/// `now-guest-ppc/src` at test time and derives both sets from what it
/// finds. There is no list of files to keep in step, because a hand-kept
/// list of what to check is exactly what rots — a sixth walk added to a
/// new directory is caught the same day it is written.
final class ProcessRosterSingleSourceTests: XCTestCase {

    /// Where the one answer lives. Named once, here, because *everything*
    /// below is "…and nowhere else".
    private static let home = "now-guest-ppc/src/processes/proc_roster.c"

    /// Every guest `.c`, with comments stripped — prose that explains a
    /// rule must not be able to satisfy the rule. `CommandParityTests`
    /// found that exact hole three times.
    private func guestSources() throws -> [(path: String, text: String)] {
        let root = GateSource.repoRoot
            .appendingPathComponent("now-guest-ppc/src")
        let e = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        var out: [(String, String)] = []
        while let url = e?.nextObject() as? URL {
            guard url.pathExtension == "c" else { continue }
            let rel = url.path.replacingOccurrences(
                of: GateSource.repoRoot.path + "/", with: "")
            out.append((rel, try GateSource.guestC(rel)))
        }
        return out.sorted { $0.0 < $1.0 }
    }

    /// The premise: this gate is looking at the tree it thinks it is. A
    /// path typo would make every check below vacuously pass, which is the
    /// shape of a gate that reads green having never reached anything.
    func testTheGateFoundTheGuestAndItsOneHome() throws {
        let sources = try guestSources()
        XCTAssertGreaterThan(sources.count, 100,
                             "found \(sources.count) guest .c files — this "
                             + "gate is not reading the guest")
        XCTAssertTrue(sources.contains { $0.path == Self.home },
                      "\(Self.home) is missing; the one home for the "
                      + "process roster has moved or gone")
    }

    /// **What is faceless is decided in one place.** `modeOnlyBackground`
    /// is a process's own `SIZE` declaration; reading it is fine, having
    /// four opinions about what it means is not.
    func testTheBackgroundOnlyBitIsReadInOneFile() throws {
        let offenders = try guestSources()
            .filter { $0.path != Self.home }
            .filter { $0.text.contains("modeOnlyBackground") }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            "modeOnlyBackground is tested outside \(Self.home): "
            + "\(offenders.joined(separator: ", ")). A second opinion "
            + "about what is faceless is how two faces come to disagree "
            + "about the same machine — call now_proc_kind_classify.")
    }

    /// **What is the Finder is decided in the same place.** The 'FNDR'
    /// type and 'MACS' creator existed as three verbatim copies. Spelled
    /// both ways the guest spells them, because `-Werror` forbids the
    /// multi-character constant and each site chose its own workaround.
    func testTheFinderSignatureIsSpelledInOneFile() throws {
        let hex = ["0x464E4452", "0x4D414353"]
        let chars = ["'F', 'N', 'D', 'R'", "'M', 'A', 'C', 'S'"]
        let offenders = try guestSources()
            .filter { $0.path != Self.home }
            .filter { file in
                (hex + chars).contains { file.text.contains($0) }
            }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            "the Finder's signature is spelled outside \(Self.home): "
            + "\(offenders.joined(separator: ", ")). now_proc_kind_classify "
            + "is what asks the question.")
    }

    /// **A walk reads its rows through the roster.** The rule is narrow on
    /// purpose and derived from the source rather than declared: a file
    /// that *enumerates* processes (`GetNextProcess`) must not also read
    /// their records (`GetProcessInformation`) — that pairing is a private
    /// walk, which is the thing that came in five copies.
    ///
    /// Files that look up **one** known PSN keep their
    /// `GetProcessInformation`, and that is deliberate: `prefs.c` asking
    /// its own name is not a roster, and a gate that pretended otherwise
    /// would be enforcing tidiness rather than agreement.
    func testNoFileBothWalksProcessesAndReadsTheirRecords() throws {
        let offenders = try guestSources()
            .filter { $0.path != Self.home }
            .filter { $0.text.contains("GetNextProcess")
                      && $0.text.contains("GetProcessInformation") }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            "a private process walk lives in: "
            + "\(offenders.joined(separator: ", ")). Enumerating processes "
            + "AND reading their records is what proc_roster.c is — use "
            + "now_proc_roster_begin/next, so the walk shares one front "
            + "sample, one kind and one admission rule.")
    }

    /// **One front process per reply.** The roster samples
    /// `GetFrontProcess` once, in `now_proc_roster_begin`, before the first
    /// row — so a walk cannot emit a reply in which two rows carry
    /// `front: true`, because a walk has no way to ask twice.
    ///
    /// `observe.c` did exactly that until 2026-08-07: it read the front
    /// inside `bind_target`, per process, and a `Cmd-Tab` mid-walk made
    /// the reply contradict itself. A snapshot that disagrees with itself
    /// is worse than a stale one, because nothing in it says which half to
    /// believe.
    func testNoWalkSamplesTheFrontProcessItself() throws {
        let offenders = try guestSources()
            .filter { $0.path != Self.home }
            .filter { $0.text.contains("now_proc_roster_next")
                      && $0.text.contains("GetFrontProcess") }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            "a roster walk also calls GetFrontProcess: "
            + "\(offenders.joined(separator: ", ")). The walk's own sample "
            + "is on every row it yields (NowProcRosterRow.is_front); a "
            + "second read mid-walk is how one reply comes to name two "
            + "front processes.")
    }

    /// **One fronting answer.** `SetFrontProcess` returning `noErr` means
    /// the switch was *scheduled*. Three implementations made three
    /// different claims about whether it happened — the console confirmed,
    /// the wire did not look, and the anchor cycle counted accepted
    /// requests in a field documented as "actually brought forward".
    ///
    /// `now_proc_front_confirm` is the ask-and-re-read, once. A raw
    /// `SetFrontProcess` outside it is a caller reporting that it
    /// dispatched rather than what happened.
    func testSetFrontProcessIsCalledInOnePlace() throws {
        let home = "now-guest-ppc/src/processes/proc_actions.c"
        let offenders = try guestSources()
            .filter { $0.path != home }
            .filter { $0.text.contains("SetFrontProcess(") }
            .map(\.path)
        XCTAssertEqual(
            offenders, [],
            "SetFrontProcess is called outside \(home): "
            + "\(offenders.joined(separator: ", ")). noErr means SCHEDULED; "
            + "call now_proc_front_confirm so the caller reports what "
            + "happened rather than that it dispatched.")
    }
}
