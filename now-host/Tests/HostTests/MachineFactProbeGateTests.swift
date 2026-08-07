import Foundation
import XCTest
@testable import Host

/// A guest may not ask the machine a question, receive the answer, and then
/// report a constant instead.
///
/// The defect class this gates is *hardcoded machine facts*: a field that
/// claims to describe the machine and describes the developer's machine
/// instead. It is uniquely nasty here because it is **always plausible** —
/// right on the machine it was written on, right in every test, and silently
/// wrong the first time somebody runs it somewhere else. No test that runs on
/// one machine can catch it, and every test we have runs on one machine.
///
/// So this gate does not try to judge whether a constant is true. It catches
/// the one shape of the defect that is mechanically decidable and was
/// actually shipped:
///
///     if (Gestalt(gestaltAddressingModeAttr, &v) == noErr) {
///         add_row(rows, &n, max, "cpu", "Addressing", "32-bit");
///     }
///
/// `gestaltAddressingModeAttr` answers a bit field. That block fetched it into
/// `v`, ignored `v`, and stated "32-bit" — a census that held the correct
/// answer in a local variable and reported a literal over the top of it. The
/// lab's PowerBook 180c has dead PRAM and boots in 24-bit addressing every
/// time, so the machine most likely to be misreported is one on the desk
/// (`now-guest-ppc/src/commands/commands.c`, fixed 2026-08-07).
///
/// **The rule.** A block-form probe — `if (Gestalt(sel, &var) == noErr) { … }`
/// — must read `var` somewhere in the condition's remainder or the block. If
/// it does not, the value was fetched and discarded, and whatever the block
/// reports is independent of what the machine said.
///
/// **There is no allowlist, and none is needed.** A probe that genuinely only
/// cares *whether the selector exists* has two forms already used in this
/// codebase that say so in the code itself:
///
///     add_row(…, "AppleEvents", (Gestalt(gestaltAppleEventsAttr, &v) == noErr)
///                                   ? "yes" : "no");
///     has_ot = (Gestalt(gestaltOpenTpt, &v) == noErr);
///
/// Neither is block form, so neither is examined. That is the escape hatch:
/// write presence as presence. It cannot be an escape *comment*, because this
/// gate reads through `GateSource` with comments stripped — a comment naming
/// the variable would satisfy a raw scan, which is the hole that has now been
/// found five times in this suite.
///
/// **What this does NOT cover**, stated plainly, because an overstated gate is
/// worse than none:
///
/// - It says nothing about whether a constant elsewhere is true. `"24-bit"`,
///   `"yes"`, `"unknown"` are all literals and all legitimate; deciding which
///   literals are machine facts is not mechanically decidable and this gate
///   does not pretend to.
/// - It only sees `Gestalt`. A fact read from a low-memory global, a QuickDraw
///   global, or a Toolbox call and then discarded is the same defect and is
///   invisible here.
/// - It only sees `== noErr` block form. The `!= noErr` guard form is the
///   failure path — not using the value there is correct — so it is skipped.
/// - Like every source-reading gate in this suite, it reads text. It cannot
///   tell a live call from a dead one, and a use of `var` inside the block
///   satisfies it even if that use is itself pointless.
///
/// The classification sweep this came out of, including the categories that
/// no gate covers, is in `docs/open-issues.md`.
final class MachineFactProbeGateTests: XCTestCase {

    /// Where a guest asks the machine questions. `ext/` is included because a
    /// resident component probes too, and its answers reach the same host.
    private static let guestTrees = [
        "now-guest-ppc/src",
        "now-guest-68k/src",
        "ext",
    ]

    private struct Probe {
        let file: String
        let line: Int
        let selector: String
        let variable: String
        let usesTheAnswer: Bool
    }

    // MARK: - The scan

    /// Every C source under the guest trees, comments removed.
    private func guestSources() throws -> [(name: String, text: String)] {
        var out: [(String, String)] = []
        let fm = FileManager.default

        for tree in Self.guestTrees {
            let dir = GateSource.repoRoot.appendingPathComponent(tree)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir),
                  isDir.boolValue else { continue }

            let names = (fm.enumerator(atPath: dir.path)?
                .compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".c") }
                .sorted()
            for n in names {
                let text = try String(
                    contentsOf: dir.appendingPathComponent(n), encoding: .utf8)
                out.append(("\(tree)/\(n)",
                            GateSource.withoutCComments(text)))
            }
        }
        XCTAssertFalse(
            out.isEmpty,
            "no guest C sources under \(GateSource.repoRoot.path). This gate "
                + "reads the guests' own probes; finding none means it is "
                + "checking nothing, which is worth failing over.")
        return out
    }

    /// `if ( Gestalt ( SELECTOR , & VAR ) == noErr` — the block-form probe.
    private static let probePattern = try! NSRegularExpression(
        pattern: #"if\s*\(\s*Gestalt\s*\(\s*([^,]+?)\s*,\s*&\s*(\w+)\s*\)\s*==\s*noErr"#)

    /// From the end of the match, the condition's remainder plus the braced
    /// block that follows — or `nil` when the `if` has no block (a one-line
    /// body ending in `;`), which this gate does not examine.
    private func regionAfter(_ source: [Character], from start: Int) -> String? {
        var i = start
        // Skip to the brace or the statement's end, whichever comes first.
        while i < source.count, source[i] != "{", source[i] != ";" { i += 1 }
        guard i < source.count, source[i] == "{" else { return nil }

        var depth = 0
        var end = i
        while end < source.count {
            if source[end] == "{" { depth += 1 }
            else if source[end] == "}" {
                depth -= 1
                if depth == 0 { break }
            }
            end += 1
        }
        guard end < source.count else { return nil }   // unbalanced
        return String(source[start...end])
    }

    private func probes() throws -> [Probe] {
        var found: [Probe] = []

        for (name, text) in try guestSources() {
            let chars = Array(text)
            let ns = text as NSString
            let matches = Self.probePattern.matches(
                in: text, range: NSRange(location: 0, length: ns.length))

            for m in matches {
                let selector = ns.substring(with: m.range(at: 1))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let variable = ns.substring(with: m.range(at: 2))

                let after = m.range.location + m.range.length
                guard let region = regionAfter(chars, from: after) else {
                    continue                     // not block form
                }

                let line = ns.substring(to: m.range.location)
                    .components(separatedBy: "\n").count

                found.append(Probe(
                    file: name, line: line, selector: selector,
                    variable: variable,
                    usesTheAnswer: mentions(variable, in: region)))
            }
        }
        return found
    }

    /// A whole-word occurrence — so `v` is not satisfied by `vers` or `&vp`.
    private func mentions(_ variable: String, in region: String) -> Bool {
        let pattern = "\\b" + NSRegularExpression.escapedPattern(for: variable)
            + "\\b"
        guard let re = try? NSRegularExpression(pattern: pattern) else {
            return true                          // never fail on our own bug
        }
        return re.firstMatch(
            in: region,
            range: NSRange(location: 0, length: (region as NSString).length))
            != nil
    }

    // MARK: - The gate

    /// No guest fetches a Gestalt answer into a variable and then reports
    /// something that does not depend on it.
    func testNoGuestProbeDiscardsTheAnswerItAskedFor() throws {
        let discarding = try probes().filter { !$0.usesTheAnswer }

        guard discarding.isEmpty else {
            let detail = discarding.map {
                "  \($0.file):\($0.line) — Gestalt(\($0.selector), &\($0.variable)) "
                    + "and the block never reads \($0.variable)"
            }.joined(separator: "\n")

            return XCTFail("""
                \(discarding.count) probe(s) ask the machine a question and \
                then report something independent of the answer:

                \(detail)

                A block-form probe fetches a value; if the block never reads \
                it, whatever the block reports is a constant wearing a \
                measurement's clothes. That is the hardcoded-machine-fact \
                defect in its most convincing form — it is right on the \
                machine you wrote it on, right in every test here, and wrong \
                on somebody else's Macintosh, with a Gestalt call standing \
                over it as evidence that it was checked.

                Two ways to be right:
                  - Use the answer. If the selector returns a bit field, test \
                    the bit — `(v & (1L << gestaltVMPresent)) ? "on" : "off"` \
                    is the idiom already in commands.c.
                  - If you only care that the selector EXISTS, say so in the \
                    form that reads as presence and this gate does not \
                    examine: `(Gestalt(sel, &v) == noErr) ? "yes" : "no"`, or \
                    assign it to a Boolean. A comment saying "presence only" \
                    will not work and is not meant to — this gate reads \
                    source with comments stripped.
                """)
        }
    }

    /// The gate is looking at something.
    ///
    /// Not ceremony. Every check above is a filter over a list, and a regex
    /// that silently stops matching — a reformat putting `Gestalt(` on its own
    /// line, a rename — turns the whole file into a test that passes by
    /// finding nothing. That is the `guard … else { return }` failure this
    /// suite has already been bitten by, one layer down.
    ///
    /// The floor is deliberately well below the current count so ordinary work
    /// does not trip it; it catches the scanner going blind, not a probe being
    /// deleted.
    func testTheProbeScannerStillFindsProbes() throws {
        let all = try probes()
        XCTAssertGreaterThan(
            all.count, 20,
            "This gate found only \(all.count) block-form Gestalt probes "
                + "across the guest trees. There were 35 when it was written "
                + "(2026-08-07). A number this low means the scanner has gone "
                + "blind — most likely the pattern no longer matches how the "
                + "probes are written — and a blind scanner reports every "
                + "guest clean. Fix the pattern; do not lower this number.")
    }
}
