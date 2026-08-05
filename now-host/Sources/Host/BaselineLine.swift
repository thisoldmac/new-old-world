import Foundation

/// The one grammar for a greppable measurement line.
///
/// `NOWBASE `-prefixed, space-separated `key=value`, values with no spaces
/// in them. Deliberately not JSON: a measurement has to survive being
/// copied out of a terminal into a commit message and a doc table, and it
/// has to stay legible as it scrolls past during a run that may be about
/// to fail. `docs/68k-metal-baseline.md` says how to read one.
///
/// It lives in the application rather than in the test target because two
/// different things now emit measurements — the metal transfer suites,
/// which run under XCTest, and the Mirror act instrument, which runs
/// inside the app a person is driving. A second copy of this grammar
/// would not fail to build when it drifted; it would fail to *agree*, and
/// every recorded baseline's provenance is the marker string.
enum BaselineLine {

    /// The prefix a run is grepped for. Changing it invalidates every
    /// recorded baseline's provenance, so it lives here once.
    static let marker = "NOWBASE"

    /// A value with a space in it would split into two fields and quietly
    /// corrupt the record, so spaces become underscores and the rest is
    /// passed through. Not general escaping — the values here are
    /// versions, verdicts, integrity strings and numbers, and pretending
    /// otherwise would invite somebody to put a message in one.
    static func sanitise(_ value: String) -> String {
        let cleaned = value.map { $0 == " " || $0 == "\n" ? "_" : $0 }
        return cleaned.isEmpty ? "-" : String(cleaned)
    }

    /// `NOWBASE <kind> k=v k=v`. Order is the caller's, because a record
    /// read by a human wants its identifying fields first.
    static func line(_ kind: String, _ fields: [(String, String)]) -> String {
        let body = fields
            .map { "\($0.0)=\(sanitise($0.1))" }
            .joined(separator: " ")
        return body.isEmpty ? "\(marker) \(kind)" : "\(marker) \(kind) \(body)"
    }
}
