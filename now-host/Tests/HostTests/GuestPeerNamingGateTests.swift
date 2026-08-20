import XCTest
@testable import Host

/// G-8's retired phrasing, gated where it can actually be reintroduced.
///
/// `now-guest-ppc/tests/peer_name_test.c` already pins the rule, but only
/// over `now_peer_name`'s own output — and its comment hopes an edit
/// "anywhere near this function" would fail there first. Three did not:
/// a Chat radio button, the Models menu placeholder and a `chat --skills`
/// help line all said "the other Mac" while 46 other strings said
/// "Other Mac", and nothing could see them, because they are literals in
/// `app.r` and `cmd_help.c` rather than a return value.
///
/// This reads the sources the way `GuestWireConformanceTests` does. It is
/// the same shape as the rule in AGENTS.md: a hand-maintained convention
/// wants a test that reads what it governs.
final class GuestPeerNamingGateTests: XCTestCase {

    private static let repoRoot: URL = {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }()

    /// Every guest source plus the resource fork's text, comments removed.
    ///
    /// `app.r` carries menu titles, dialog buttons and radio-button labels,
    /// so a gate that reads only `.c` files misses the two of the three
    /// that a person clicks.
    private func drawableSources() throws -> [(name: String, text: String)] {
        var out: [(name: String, text: String)] = []
        for half in ["now-guest-ppc/src", "now-guest-68k/src"] {
            let dir = Self.repoRoot.appendingPathComponent(half)
            guard FileManager.default.fileExists(atPath: dir.path) else {
                continue
            }
            let names = (FileManager.default.enumerator(atPath: dir.path)?
                .compactMap { $0 as? String } ?? [])
                .filter { $0.hasSuffix(".c") || $0.hasSuffix(".h") }.sorted()
            for n in names {
                out.append(("\(half)/\(n)", try String(
                    contentsOf: dir.appendingPathComponent(n),
                    encoding: .utf8)))
            }
        }
        for rez in ["now-guest-ppc/resources/app.r"] {
            let url = Self.repoRoot.appendingPathComponent(rez)
            if FileManager.default.fileExists(atPath: url.path) {
                out.append((rez, try String(contentsOf: url,
                                            encoding: .utf8)))
            }
        }
        XCTAssertFalse(out.isEmpty, "no guest sources under \(Self.repoRoot.path)")
        return out.map { ($0.name, GateSource.withoutCComments($0.text)) }
    }

    func testNoDrawableStringUsesTheRetiredPeerPhrasing() throws {
        var offenders: [String] = []

        for (name, text) in try drawableSources() {
            for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
                guard line.contains("\"") else { continue }
                // Only inside a literal: prose in a stripped comment is gone,
                // but a Rez line mixes code and text on one line.
                let literals = line.split(separator: "\"")
                    .enumerated()
                    .filter { $0.offset % 2 == 1 }
                    .map(\.element)
                for lit in literals where lit.contains("the other Mac") {
                    offenders.append("\(name): \(lit)")
                }
            }
        }
        XCTAssertTrue(offenders.isEmpty, """
            G-8 retires "the other Mac"; the guest says "Other Mac".
            \(offenders.joined(separator: "\n"))
            """)
    }
}
