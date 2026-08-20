import XCTest
@testable import Host

/// **A test may not spend the state of the Mac it happens to run on.**
///
/// Two of these shipped, found the same afternoon (2026-08-20) while
/// chasing the first:
///
///   * `ContinuityEdgeController` defaulted to the real
///     `AppKitContinuityKeyboardEnvironment`, so any test that drove the
///     pointer across the edge installed a CONSUMING session-wide event tap
///     inside `xctest` and stalled every keystroke on the Mac for as long
///     as the suite ran. `ContinuityEventTapOwnershipTests` holds that.
///   * Three tests exercised the capture copy against `NSPasteboard.general`
///     — the person's own clipboard — so a green run silently threw away
///     whatever they had copied.
///
/// Neither failed anything. Both are invisible in review, because the line
/// that does it is the obvious line to write. So the rule is structural:
/// the shared singletons named here belong to the human at the keyboard,
/// and a test that wants one names its own instead.
///
/// It reads source, which cannot tell a live call from a dead one — the
/// standing limit stated in `GateSource`. It can tell that nobody typed it.
final class NoSharedSystemStateInTests: XCTestCase {
    /// Suffixed to keep this file's own prose from satisfying the scan; the
    /// symbol never appears whole outside a comment here.
    private static let sharedBoard = "NSPasteboard" + ".general"

    func testNoTestTakesTheHumansClipboard() throws {
        let root = GateSource.repoRoot
            .appendingPathComponent("now-host/Tests")
        let sources = try XCTUnwrap(FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil))
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(sources.count, 100,
                             "the gate must actually be reading the suite")

        var offenders: [String] = []
        for url in sources.sorted(by: { $0.path < $1.path }) {
            let text = GateSource.withoutWholeLineSwiftComments(
                GateSource.withoutCComments(
                    try String(contentsOf: url, encoding: .utf8)))
            for (index, line) in text.components(separatedBy: .newlines)
                .enumerated() where line.contains(Self.sharedBoard) {
                offenders.append(
                    "\(url.lastPathComponent):\(index + 1)")
            }
        }
        XCTAssertEqual(offenders, [], """
            These tests use the shared system pasteboard, which is the \
            clipboard of whoever is running the suite: \
            \(offenders.joined(separator: ", ")). Name your own board — \
            NSPasteboard(name:) with a unique name — and inject it through \
            the model's pasteboardForCopying seam.
            """)
    }
}
