import Foundation
import XCTest
@testable import Host

/// The rules docs/logging.md states, checked where they can be.
final class LoggingSpecTests: XCTestCase {

    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    /// `HH:MM:SS area   [!?] message` — the same shape on both machines,
    /// because the point of the format is that the two files read as one.
    @MainActor
    func testALineMatchesTheFormatTheSpecDefines() throws {
        let log = HostLog.shared
        log.setPersistsToDisk(true)             // the file is a switch now
        let url = try XCTUnwrap(log.url)
        log.write(.warn, "files", "#7 refused: exists (something is there)")
        let line = try XCTUnwrap(
            String(contentsOf: url, encoding: .utf8)
                .split(separator: "\n").last.map(String.init))

        let pattern = #"^\d{2}:\d{2}:\d{2} \w+\s+\? #7 refused: exists"#
        XCTAssertNotNil(line.range(of: pattern, options: .regularExpression),
                        "line did not match the spec's format: \(line)")
    }

    /// Rule 2, and the only rule that breaks things silently rather than
    /// loudly: a log call in a per-chunk path costs a disk write per
    /// chunk and starves the transfer it is measuring. The File Sharing
    /// panel proved it by doing exactly that with a progress bar.
    ///
    /// **Two limits, both inherent, both verified rather than guessed.**
    ///
    /// The check is one literal, `now_log(`, so any other spelling of the
    /// same call is invisible. Confirmed by mutation on 2026-07-31: adding
    /// `#define NOWLOG now_log` above `take_bulk_in` and calling `NOWLOG(…)`
    /// inside it builds clean on the PowerPC cross-compiler and passes
    /// here, with a disk write back in the per-chunk path. A macro alias is
    /// the whole of what it takes.
    ///
    /// And the hot list is three hand-written entries. A fourth per-chunk
    /// function is unguarded until someone adds it, and NOW-68K's transfer
    /// paths — `wire68.c`, `n68_puttx.c` — are not on it at all, though the
    /// rule applies to them and a 68030 has less headroom to lose.
    ///
    /// Neither is fixed here. Catching every spelling means expanding
    /// macros, and knowing which functions are per-chunk means a call
    /// graph; each is a small C front end, and a check that looks like it
    /// covers the rule while missing the next macro is worse than one whose
    /// reach is written down. The reach is: these three functions, this one
    /// spelling.
    func testNothingLogsInAPerChunkPath() throws {
        let hot = [
            ("now-guest-ppc/src/core/wire.c", "take_bulk_in"),
            ("now-guest-ppc/src/files/fileshare.c", "now_files_receive_chunk"),
            ("now-guest-ppc/src/files/fileshare.c", "batch_write"),
        ]
        for (file, function) in hot {
            let text = try GateSource.guestC(file)
            let body = try XCTUnwrap(functionBody(named: function, in: text),
                                     "could not find \(function) in \(file)")
            XCTAssertFalse(body.contains("now_log("), """
                \(function) runs once per chunk. A log call there is a \
                disk write per chunk, which starves the transfer it is \
                measuring — see docs/logging.md, "What to log".
                """)
        }
    }

    /// Rule 11, and the one boundary the Mirror's new `mirror` area may
    /// not cross.
    ///
    /// `ext/` is the NOW Extension. Its QuickDraw bottlenecks, its trap
    /// patches and its jGNE filter run **inside foreign processes, at draw
    /// time**, and are bounded and allocation-free by construction —
    /// `now_content.c` says so in its own comments. A disk write there
    /// would change the timing of the thing being measured and could take
    /// the Finder down with it, which is strictly worse than the silence
    /// the `mirror` area was added to fix.
    ///
    /// So a fact only knowable inside a hook is surfaced as a COUNTER the
    /// application reads at task time (`NowContentCounters`, read by
    /// `now_mirror_log_idle`), never as a line the resident writes.
    ///
    /// **Which half of this the linker already does, measured rather than
    /// assumed.** `now_log(` is checked first, and on 2026-08-08 the
    /// mutation for it — a call plus a local `extern` declaration, which is
    /// how someone would get it compiling — BUILT and then failed to LINK:
    /// the INIT has no such symbol. So for that one spelling the linker is
    /// the primary enforcement and this assertion is a named reason
    /// arriving before an unresolved-symbol error nobody can read.
    ///
    /// **The File Manager half is the one nothing else catches**, and it is
    /// the real hazard. `FSWrite`, `PBWrite` and their neighbours are
    /// TRAPS: an INIT may call them with no library and no symbol, so a
    /// resident that decided to keep its own little log would link clean
    /// and then perform a disk write inside a QuickDraw bottleneck running
    /// in the Finder's context at draw time. `ext/src` is clean of them
    /// today except for the Device Manager `PBOpenSync` MacTCP needs, which
    /// is named as an exception here rather than matched loosely.
    ///
    /// **Reach.** Literal spellings over comment-stripped text — a macro
    /// alias defeats it, as it defeats the per-chunk check above. Unlike
    /// that check the FILE LIST IS DERIVED, so a new resident source is
    /// covered the day it lands.
    func testTheResidentNeverLogs() throws {
        // Disk writes an INIT can reach through traps alone.
        let banned = ["now_log(", "FSWrite(", "PBWrite", "FSpCreate(",
                      "FSpOpenDF(", "SetFPos(", "FlushVol(", "DebugStr("]
        let extDir = GateSource.repoRoot.appendingPathComponent("ext/src")
        let sources = try FileManager.default
            .contentsOfDirectory(atPath: extDir.path)
            .filter { $0.hasSuffix(".c") }
            .sorted()
        XCTAssertFalse(sources.isEmpty,
                       "ext/src has no C sources — this gate found nothing "
                       + "to read, which is not the same as finding it clean")
        for name in sources {
            let text = try GateSource.guestC("ext/src/\(name)")
            for call in banned {
                XCTAssertFalse(text.contains(call), """
                    ext/src/\(name) calls \(call): it is resident code, and \
                    it runs inside foreign processes at draw time and at \
                    interrupt level, bounded and allocation-free by \
                    construction. Writing to disk there changes the timing \
                    of the thing it measures and can take the Finder down \
                    with it. Surface the fact as a counter the application \
                    reads at task time instead — see docs/logging.md, rule \
                    11, and now-guest-ppc/src/mirror/mirror_log.h.
                    """)
            }
        }
    }

    /// Braces-balanced body of a C function, so the check reads the
    /// function rather than a window of lines around its name.
    ///
    /// It must find the DEFINITION, not a forward declaration: taking
    /// the first mention found the `static void take_bulk_in(...);`
    /// prototype and then measured the next function's body instead —
    /// green, and about the wrong code. A definition is the one whose
    /// parameter list is followed by `{` rather than `;`.
    private func functionBody(named name: String, in text: String) -> String? {
        var searchFrom = text.startIndex
        var open: Range<String.Index>?
        while let start = text.range(of: "\(name)(",
                                     range: searchFrom..<text.endIndex) {
            searchFrom = start.upperBound
            // Skip to the end of the parameter list.
            var depth = 1
            var i = start.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
            // Then the next meaningful character decides which it is.
            while i < text.endIndex, text[i].isWhitespace {
                i = text.index(after: i)
            }
            guard i < text.endIndex else { break }
            if text[i] == "{" {
                open = i..<text.index(after: i)
                break
            }
        }
        guard let open else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            if text[index] == "}" {
                depth -= 1
                if depth == 0 {
                    return String(text[open.lowerBound...index])
                }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
