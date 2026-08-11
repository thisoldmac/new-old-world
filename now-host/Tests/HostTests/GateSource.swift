import Foundation

/// The reader every gate that PROVES SOMETHING BY READING SOURCE uses.
///
/// A family of tests in this suite establishes a structural property by
/// scanning source text: that a console verb delegates to the one shared
/// implementation, that a hello field is filled from a seam rather than a
/// literal, that a probe table matches the contract. They are cheap and they
/// have caught real drift. They also share one failure mode, and it has now
/// been found three times:
///
/// **A comment that names the identifier satisfies a scan of the raw text.**
///
/// Every occurrence was found by accident, and every one of them looked like
/// a passing gate:
///
/// 1. The PowerPC hello's `now_agent_access()` seam. Replacing the call with
///    a literal left the comment three lines above — the one explaining why a
///    literal is wrong — to satisfy the check.
/// 2. The same file's `now_build_stamp()` gate, shipped and mutation-proven
///    that morning, hollow by the afternoon for the same reason.
/// 3. `CommandParityTests`'s `proc_list_rows` check, found by this audit:
///    `n68_exec.c` may be given a second, divergent process walk and the gate
///    still passes on the comment above `show_processes` — the comment whose
///    text is "proc_list_rows() is the one implementation."
///
/// The comment is not incidental to the failure; it is *caused* by it. A
/// function worth gating is a function worth explaining, so the prose beside
/// the code names exactly the identifiers the gate looks for. The better the
/// comment, the more reliably it hides the deletion.
///
/// So a gate reads through here.
///
/// **What this does not do.** It removes comments; it does not parse. A
/// stripped scan still cannot tell a live call from a dead one, an argument
/// from a token that merely appears in the body, or a reachable control from
/// a spelled one. Those limits are inherent to reading text and are stated
/// where each gate makes its claim — see `HostFaceReach.reached` for the
/// standing decision not to paper over them with a partial parser.
enum GateSource {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // HostTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // now-host
            .deletingLastPathComponent()   // repo
    }

    /// A file exactly as written. For contracts, fixtures and documents,
    /// where the comment syntax is not C's and prose is not the hazard.
    static func raw(_ path: String) throws -> String {
        try String(contentsOf: repoRoot.appendingPathComponent(path),
                   encoding: .utf8)
    }

    /// A guest C source with its comments removed — what a gate scanning
    /// for an identifier should read.
    static func guestC(_ path: String) throws -> String {
        withoutCComments(try raw(path))
    }

    /// A host Swift source with its comment LINES and block comments
    /// removed.
    ///
    /// Deliberately more conservative than the C reader: a trailing `//` is
    /// left alone, because `"https://…"` inside a string literal is not a
    /// comment and telling the two apart needs a lexer. Whole-line `//` and
    /// `///` are what a doc comment is made of, and a doc comment is what
    /// has actually caused trouble here.
    static func hostSwift(_ path: String) throws -> String {
        withoutWholeLineSwiftComments(withoutCComments(try raw(path)))
    }

    /// Drops `/* … */`. The guests are C in the classic-Mac dialect, which
    /// has no `//`, so for them this is all there is.
    static func withoutCComments(_ source: String) -> String {
        var out = "", rest = Substring(source)
        while let open = rest.range(of: "/*") {
            out += rest[rest.startIndex..<open.lowerBound]
            guard let close = rest.range(of: "*/",
                                         range: open.upperBound
                                            ..< rest.endIndex) else {
                return out                   // unterminated; take what we have
            }
            rest = rest[close.upperBound...]
        }
        return out + rest
    }

    /// Drops lines whose first non-space characters are `//`.
    static func withoutWholeLineSwiftComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter {
                !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//")
            }
            .joined(separator: "\n")
    }
}
