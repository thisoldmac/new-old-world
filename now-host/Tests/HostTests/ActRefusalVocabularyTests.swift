import Foundation
import XCTest

/// **One vocabulary for a refusal, across the whole act lane.**
///
/// A refusal answers two questions at once: *why*, and **whether anything
/// might have happened anyway**. The second is a value — `reach` — because
/// it decides whether a caller may stop waiting, and reading "was not sent"
/// out of prose is how the Mirror's FIFO came to hold itself open for
/// fifteen seconds after a refusal that had demonstrably done nothing.
///
/// The guest draws the line structurally and `reach(ofGuestRefusal:)`
/// reads it: a refusal with no correlation was never registered by the act
/// plane, so nothing was armed, dispatched or attempted. That derivation is
/// deliberately not a list of codes, so a code the guest grows tomorrow
/// lands on the right side of it without anyone remembering.
///
/// **And it was only wired at two of the four sites that need it.** Found
/// 2026-08-07 by the MCP revival lane, from the outside: `now_text_set`
/// answered `reach: notSent` where `now_text_get` answered `unknown`, for
/// the same guest sentence about the same reference — two words for one
/// fact, and the wrong one is the one that makes a caller wait. `key` had
/// the same hole. Both also dropped the `correlation` and `settlement` the
/// guest sent, which is the evidence the whole distinction rests on.
///
/// So this reads the source and derives BOTH sets from it: every place that
/// builds a failure out of a guest's own reply, and every place that asks
/// what that reply's reach was. It maintains no list of sites, because a
/// list of sites is exactly what would have been complete on 2026-07-31 and
/// wrong on 2026-08-01.
final class ActRefusalVocabularyTests: XCTestCase {

    private static var actControlSource: String {
        let url = URL(fileURLWithPath: #filePath)   // …/Tests/HostTests/x
            .deletingLastPathComponent()            // …/Tests/HostTests
            .deletingLastPathComponent()            // …/Tests
            .deletingLastPathComponent()            // …/now-host
            .appendingPathComponent(
                "Sources/Host/Automation/AgentIntegrationActControl.swift")
        return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    func testEveryGuestRefusalDerivesItsReach() throws {
        let source = Self.actControlSource
        XCTAssertFalse(source.isEmpty,
                       "AgentIntegrationActControl.swift was not readable; "
                           + "this gate reads it rather than a list")

        let sites = Self.failureCallSites(in: source)
        XCTAssertGreaterThan(
            sites.count, 3,
            "Found \(sites.count) Self.failure(…) call sites, which is too "
                + "few to be this file — the scanner below has drifted from "
                + "the source's shape and is now a gate that cannot fail.")

        /* The ones built out of the machine's OWN reply. Everything else is
           this side's sentence about a local refusal or a timeout, where
           the default reach is the honest answer and a derivation would be
           asking the guest a question it was never sent. */
        let fromGuestReply = sites.filter { $0.contains("result.error") }
        XCTAssertFalse(fromGuestReply.isEmpty,
                       "No failure is built from a guest reply, which "
                           + "cannot be true of the act lane")

        let missing = fromGuestReply.filter {
            !$0.contains("reach: Self.reach(ofGuestRefusal:")
        }
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) of \(fromGuestReply.count) refusals built from \
            a guest's own reply do not derive `reach` from it, so they \
            silently answer `unknown` — "something may have happened on \
            that Macintosh" — for refusals the guest said carried no \
            correlation at all.

            Two words for one fact is what a caller reads as two different \
            situations. Pass `reach: Self.reach(ofGuestRefusal: \
            result.error)` (and the correlation and settlement beside it, \
            which are the evidence it rests on):

            \(missing.map { "  " + Self.firstLine(of: $0) }
                .joined(separator: "\n"))
            """)
    }

    /// The reverse direction: a site that derives reach must have a reply
    /// to derive it from.
    ///
    /// Without this the gate above is satisfiable by pasting the derivation
    /// everywhere, including onto local refusals where the request provably
    /// never left — which would turn every `notSent` this side can prove
    /// into an `unknown`, the exact loss the field exists to prevent.
    func testNothingDerivesReachWithoutAGuestReply() throws {
        let stray = Self.failureCallSites(in: Self.actControlSource).filter {
            $0.contains("reach: Self.reach(ofGuestRefusal:")
                && !$0.contains("result.error")
        }
        XCTAssertTrue(stray.isEmpty, """
            \(stray.count) failure(s) derive `reach` from a guest reply they \
            do not have. A local refusal is `notSent` because this side can \
            PROVE the request never left; deriving it from an absent reply \
            would answer `unknown` and make a caller wait for an act that \
            was never sent.
            """)
    }

    // MARK: Scanning

    /// Every `Self.failure(` call in the source, as its own text.
    ///
    /// A balanced-paren scan rather than a regular expression, because
    /// these calls span lines and nest calls inside their own arguments —
    /// and a scanner that stopped at the first `)` would read every one of
    /// them as ending at `Self.bounded(…)`, quietly matching nothing.
    private static func failureCallSites(in source: String) -> [String] {
        var sites: [String] = []
        let needle = Array("Self.failure(")
        let characters = Array(source)
        var index = 0
        while index < characters.count {
            guard index + needle.count <= characters.count,
                  Array(characters[index..<(index + needle.count)]) == needle
            else {
                index += 1
                continue
            }
            var depth = 0
            var cursor = index + needle.count - 1
            while cursor < characters.count {
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { break }
                }
                cursor += 1
            }
            let end = min(cursor + 1, characters.count)
            sites.append(String(characters[index..<end]))
            index = end
        }
        return sites
    }

    private static func firstLine(of site: String) -> String {
        site.split(separator: "\n", maxSplits: 1).first.map(String.init)
            ?? site
    }
}
