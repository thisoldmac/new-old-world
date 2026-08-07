import XCTest
@testable import Host

/// **`NOW_PREFS_SUFFIX` must isolate ALL of a run's state, not the port.**
///
/// The suffix exists so a second copy of the host can be launched without
/// writing into the desk's real preferences — the shared checkout has
/// several sessions working in it at once, and before it existed, launching
/// a build to look at it overwrote whichever page another session's window
/// would reopen on.
///
/// It did not do that. `ProductIdentity.preferencesSuite` scoped four call
/// sites; every other consumer defaulted to `UserDefaults.standard`, which
/// is the application's own bundle-id domain and is **one store shared by
/// every host copy on the Mac**. A suffixed run therefore isolated its
/// listening port and went on writing the Mirror's app path, its QMP
/// socket, the forwarded agent port, the file locations, the host share
/// directory, the cloud settings and the sidebar into the desk's own
/// defaults, live, while a person had the app open.
///
/// Found on 2026-08-07 investigating whether an agent lane had reached a
/// human's running application. It had not: the wire and the agent socket
/// were both isolated, and each guest was paired with its own host
/// throughout. The isolation was simply much narrower than its name, and
/// nothing anywhere said which half it covered.
///
/// This reads the source rather than the behaviour on purpose. The defect
/// is a DEFAULT PARAMETER VALUE, invisible at every call site that relies
/// on it, and a behavioural test would have to know which type to ask —
/// which is the same "we only checked the ones we remembered" that let
/// fourteen of them through. `GuestWireConformanceTests` is the pattern.
final class HostDefaultsIsolationTests: XCTestCase {
    func testNoHostTypeDefaultsToTheSharedStandardDefaults() throws {
        let root = GateSource.repoRoot
            .appendingPathComponent("now-host/Sources/Host")
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
        let sources = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(sources.count, 50,
                            "the gate must actually be reading the sources")

        var offenders: [String] = []
        for url in sources.sorted(by: { $0.path < $1.path }) {
            /* Comments stripped, for the reason GateSource exists: this
               file's own prose names `UserDefaults.standard` repeatedly,
               and a gate a doc comment can satisfy — or trip — is not a
               gate. */
            let text = GateSource.withoutWholeLineSwiftComments(
                GateSource.withoutCComments(
                    try String(contentsOf: url, encoding: .utf8)))
            for (index, line) in text.components(
                separatedBy: .newlines).enumerated() {
                /* Only a defaults STORE, which is what a shared write goes
                   through. `ModuleRegistry.standard` and a `.standard`
                   date format are different words that happen to match, so
                   `UserDefaults` must be on the line too. */
                guard line.contains("UserDefaults"),
                      line.contains(".standard") else { continue }
                // The one place allowed to name it: the accessor whose
                // whole job is to decide between it and a suffixed suite.
                if url.lastPathComponent == "ProductIdentity.swift" {
                    continue
                }
                offenders.append("\(url.lastPathComponent):\(index + 1): "
                    + line.trimmingCharacters(in: .whitespaces))
            }
        }

        XCTAssertEqual(
            offenders, [],
            """
            These reach UserDefaults.standard directly. That is the app's \
            own bundle-id domain, shared by every host copy on this Mac, \
            so a run launched with NOW_PREFS_SUFFIX would write through \
            them into the desk's real preferences while somebody was \
            using it. Use ProductIdentity.defaults, which IS .standard \
            when no suffix is set:
            \(offenders.joined(separator: "\n"))
            """)
    }
}
