import XCTest
@testable import Host

/// The pure half of the Software module: how a wire entry becomes a row,
/// and how the search narrows it. The wire path is pinned by the
/// software.listing fixtures in GuestWireFixtureTests; the live round
/// trip is a metal item.
@MainActor
final class SoftwareModelTests: XCTestCase {
    private func entry(_ name: String, path: String = "HD:x",
                       type: String? = nil, creator: String? = nil,
                       sizeK: Int? = nil, off: Bool? = nil,
                       running: Bool? = nil,
                       version: String? = nil) -> SoftwareEntry {
        SoftwareEntry(name: name, path: path, type: type, creator: creator,
                      sizeK: sizeK, off: off, running: running,
                      version: version)
    }

    func testSizeLabelPicksTheLegibleUnit() {
        XCTAssertEqual(entry("x", sizeK: 92).sizeLabel, "92 KB")
        XCTAssertEqual(entry("x", sizeK: 3072).sizeLabel, "3.0 MB")
        // The guest sends -1 for a size it could not read; that is
        // "unknown", never "0 KB" and never "-1 KB".
        XCTAssertNil(entry("x", sizeK: -1).sizeLabel)
        XCTAssertNil(entry("x").sizeLabel)
        // 0 KB is a real (empty-forks) answer, kept.
        XCTAssertEqual(entry("x", sizeK: 0).sizeLabel, "0 KB")
    }

    func testStateLabelIsOneScanWord() {
        XCTAssertEqual(entry("x", running: true).stateLabel, "running")
        XCTAssertEqual(entry("x", off: true).stateLabel, "off")
        XCTAssertEqual(entry("x").stateLabel, "")
        // Running wins if a guest ever sent both - an off item that is
        // somehow running IS running.
        XCTAssertEqual(entry("x", off: true, running: true).stateLabel,
                       "running")
    }

    func testKindLabelJoinsCodesAndDropsBlanks() {
        XCTAssertEqual(entry("x", type: "APPL", creator: "ttxt").kindLabel,
                       "APPL / ttxt")
        XCTAssertNil(entry("x").kindLabel)
        XCTAssertNil(entry("x", type: "", creator: "").kindLabel)
        XCTAssertEqual(entry("x", type: "INIT").kindLabel, "INIT")
    }

    func testSearchMatchIsCaseInsensitiveSubstring() {
        let adobe = entry("Adobe Photoshop 5.0")
        XCTAssertTrue(SoftwareModel.matches(adobe, query: "adobe"))
        XCTAssertTrue(SoftwareModel.matches(adobe, query: "SHOP"))
        XCTAssertFalse(SoftwareModel.matches(adobe, query: "illustrator"))
    }

    func testLaunchabilityFollowsThePath() {
        // The path is the launch key; the guest sends "" when it could
        // not name the chain honestly, and such an entry must not offer
        // Launch from afar.
        XCTAssertTrue(entry("x", path: "HD:Apps:x").isLaunchable)
        XCTAssertFalse(entry("x", path: "").isLaunchable)
    }

    func testRevealabilityFollowsThePathForAnyType() {
        // Reveal opens nothing, so an extension (a non-APPL) is
        // revealable exactly when its path is nameable — the same gate
        // as launch, but not restricted to applications.
        XCTAssertTrue(entry("Some INIT", path: "HD:System:Extensions:x",
                            type: "INIT").isRevealable)
        // No path, nothing to select in the Finder.
        XCTAssertFalse(entry("x", path: "").isRevealable)
    }

    func testEntryIdentitySurvivesDuplicateNames() {
        // Two SimpleTexts differ by path; the table's selection must
        // tell them apart.
        let a = entry("SimpleText", path: "HD:Applications:SimpleText")
        let b = entry("SimpleText", path: "HD:Utilities:SimpleText")
        XCTAssertNotEqual(a.id, b.id)
    }
}
