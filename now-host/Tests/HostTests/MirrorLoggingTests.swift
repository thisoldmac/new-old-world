import Foundation
import XCTest
@testable import Host

/// The Mirror's logging, and the registry it belongs to.
///
/// Both guests are read as text, the way every source gate here is: these
/// cannot run classic Mac code, and a claim about which branch logs is a
/// claim about what is written down. The reach is stated in each test.
final class MirrorLoggingTests: XCTestCase {

    // MARK: the arm path is instrumented

    /// `now_peek_settle` has FOUR exits and they are four different
    /// answers — no resident, already armed, the request was never
    /// published, the resident never echoed in time. To a caller all four
    /// are the same bare `0`/`1`, and until 2026-08-08 all four were also
    /// the same silence. That is what made six crash mechanisms
    /// unfalsifiable after the 2026-08-07 PowerBook session: the log could
    /// say the Mirror had been asked for and never that it had refused,
    /// nor which of four refusals it was.
    ///
    /// **Reach.** This counts calls in the function body; it cannot check
    /// that each one carries the right reason, and a fifth exit added
    /// without a log would raise the required count only if someone
    /// updated this number. What it does catch is the deletion — which is
    /// the mutation it was watched against.
    func testEverySettleExitReportsItsOutcome() throws {
        let text = try GateSource.guestC("now-guest-ppc/src/peek/peek.c")
        let body = try XCTUnwrap(Self.functionBody(named: "now_peek_settle",
                                                   in: text))
        let calls = body.components(separatedBy: "now_mirror_log_settle(")
            .count - 1
        XCTAssertGreaterThanOrEqual(calls, 4, """
            now_peek_settle has four exits and each is a different reason a \
            plane did not arm. All four reaching the log is the whole point \
            of the mirror area — see docs/logging.md, "The mirror area".
            """)
    }

    /// The silent failure this whole area was written for.
    ///
    /// `AGENTS.md` records it: a binary not named exactly `New Old World`
    /// (creator `NOWo`) arms **no plane at all**, while the resident goes
    /// on reporting `active` with full capabilities and nothing anywhere
    /// names the cause. Renaming one build took `requested` from 0 to 15
    /// with nothing else changed. It must be one log line, and it must be
    /// on the branch that decides it.
    func testTheIdentityRefusalIsNamedWhereItIsDecided() throws {
        let text = try GateSource.guestC("now-guest-ppc/src/peek/peek.c")
        let body = try XCTUnwrap(Self.functionBody(named: "maintain_writer",
                                                   in: text))
        XCTAssertTrue(body.contains("kMirrorWriterNotCanonical"), """
            maintain_writer's identity branch is where a dev-named binary \
            silently arms nothing. It logs there or the failure is invisible \
            again — AGENTS.md, "no writer".
            """)
        XCTAssertTrue(body.contains("kMirrorWriterOtherSession"),
                      "another session holding the table is a different "
                      + "refusal and must not read as the same one")
    }

    /// Who asked. The union is what reaches the table, so the union's
    /// change is the event — but the owner that moved it is knowable only
    /// at the claim, and a request with no owner cannot be traced back to
    /// the page or verb that wanted it.
    func testTheArmRequestNamesTheOwnerThatMovedIt() throws {
        let text = try GateSource.guestC("now-guest-ppc/src/peek/peek.c")
        let body = try XCTUnwrap(Self.functionBody(named: "publish_claims_to",
                                                   in: text))
        XCTAssertTrue(body.contains("now_mirror_log_request("), """
            the published union changing is the arm/disarm request. \
            Unlogged, the log can show a plane going dark with nothing \
            saying who let go of it.
            """)
    }

    // MARK: the registry is a real closed vocabulary

    /// `docs/logging.md`'s area table is a hand-maintained enumeration, and
    /// AGENTS.md's rule for those is that they want a test that reads them.
    /// This one earned that on the day it was written: `act`, `mach`,
    /// `chat` and `network` were all in use and none of them was in the
    /// table, so the "small closed vocabulary" had four undocumented words
    /// in it and nothing had noticed.
    ///
    /// **Reach.** One spelling, `now_log(<level>, "<area>"`, read after
    /// comments are stripped, over both guests. A tag passed through a
    /// variable is invisible here — and would also be invisible to a
    /// reader of the source, which is the better argument against writing
    /// one.
    func testEveryAreaInUseIsInTheRegistry() throws {
        let registry = try Self.registeredAreas()
        XCTAssertTrue(registry.contains("mirror"),
                      "the registry parse found no 'mirror' row, so this "
                      + "test is reading the wrong table")
        for (file, area) in try Self.areasInUse() {
            XCTAssertTrue(registry.contains(area), """
                \(file) logs under "\(area)", which is not a row in \
                docs/logging.md's area table. The vocabulary is closed on \
                purpose: a log is meant to be readable by subsystem, and an \
                ad-hoc word is one nobody knows to grep for.
                """)
        }
    }

    /// `now_log` formats the area with `%-6.6s`, so a seventh character is
    /// TRUNCATED and never reaches the file. `network` shipped that way:
    /// the line said `networ`, and `grep network` — the one thing the tag
    /// exists for — found nothing. Silent, and it made the code and the log
    /// disagree with nobody to say so.
    func testNoAreaIsTruncatedByTheLineFormat() throws {
        for (file, area) in try Self.areasInUse() {
            XCTAssertLessThanOrEqual(area.count, 6, """
                \(file) logs under "\(area)", which is \(area.count) \
                characters. now_log pads and truncates the area to six \
                (%-6.6s), so the file would read \
                "\(area.prefix(6))" and a grep for the real tag would find \
                nothing.
                """)
        }
    }

    // MARK: - reading the sources

    /// `(file, area)` for every literal area tag in either guest.
    private static func areasInUse() throws -> [(String, String)] {
        var found: [(String, String)] = []
        let pattern = #"now_log\s*\(\s*kLog\w+\s*,\s*"([a-z]+)""#
        let regex = try NSRegularExpression(pattern: pattern)
        for root in ["now-guest-ppc/src", "now-guest-68k/src"] {
            let dir = GateSource.repoRoot.appendingPathComponent(root)
            guard let walk = FileManager.default.enumerator(atPath: dir.path)
            else { continue }
            for case let name as String in walk where name.hasSuffix(".c") {
                let path = "\(root)/\(name)"
                let text = try GateSource.guestC(path)
                let range = NSRange(text.startIndex..., in: text)
                for match in regex.matches(in: text, range: range) {
                    if let r = Range(match.range(at: 1), in: text) {
                        found.append((path, String(text[r])))
                    }
                }
            }
        }
        XCTAssertFalse(found.isEmpty,
                       "no now_log call was found in either guest — this "
                       + "gate read nothing, which is not the same as clean")
        return found
    }

    /// The first column of every row in the area table, which is the only
    /// place the vocabulary is written down.
    private static func registeredAreas() throws -> Set<String> {
        let doc = try GateSource.raw("docs/logging.md")
        var areas: Set<String> = []
        let regex = try NSRegularExpression(pattern: #"^\|\s*`([a-z]+)`\s*\|"#,
                                            options: .anchorsMatchLines)
        let range = NSRange(doc.startIndex..., in: doc)
        for match in regex.matches(in: doc, range: range) {
            if let r = Range(match.range(at: 1), in: doc) {
                areas.insert(String(doc[r]))
            }
        }
        return areas
    }

    /// Braces-balanced body of a C function — the same reader
    /// `LoggingSpecTests` uses, and for the same reason: it must find the
    /// DEFINITION rather than a forward declaration, or it silently
    /// measures the next function instead.
    private static func functionBody(named name: String,
                                     in text: String) -> String? {
        var searchFrom = text.startIndex
        var open: Range<String.Index>?
        while let start = text.range(of: "\(name)(",
                                     range: searchFrom..<text.endIndex) {
            searchFrom = start.upperBound
            var depth = 1
            var i = start.upperBound
            while i < text.endIndex, depth > 0 {
                if text[i] == "(" { depth += 1 }
                if text[i] == ")" { depth -= 1 }
                i = text.index(after: i)
            }
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
                if depth == 0 { return String(text[open.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
