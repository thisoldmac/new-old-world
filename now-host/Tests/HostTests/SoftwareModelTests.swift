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

    // MARK: duplicate groups
    //
    // The rule under test is the GUEST's, not one invented here: see
    // `compute_groups` in now-guest-ppc/src/software/software_module.c.
    // Two surfaces that group differently disagree invisibly, so these
    // pin the guest's three properties — case-folded sort, runs of two or
    // more, no group of one — rather than "grouping happens".

    private func names(_ rows: [SoftwareModel.SoftwareRow]) -> [String] {
        rows.map(\.name)
    }

    func testDuplicatesGatherUnderOneContainer() {
        let rows = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:Apps:SimpleText"),
            entry("Finder", path: "HD:System:Finder"),
            entry("SimpleText", path: "HD:Utilities:SimpleText"),
        ])
        XCTAssertEqual(names(rows), ["Finder", "SimpleText"],
                       "two SimpleTexts read as one row")
        let group = try! XCTUnwrap(rows.first { $0.name == "SimpleText" })
        XCTAssertTrue(group.isGroup)
        XCTAssertEqual(group.members.count, 2)
        XCTAssertEqual(group.children?.count, 2)
        XCTAssertEqual(group.versionText, "2 items",
                       "the guest puts the count where a version would be")
        XCTAssertTrue(SoftwareModel.isGroupID(group.id))
        // The single Finder is a plain row, never a group of one — the
        // guest's `j - i >= 2`.
        let finder = try! XCTUnwrap(rows.first { $0.name == "Finder" })
        XCTAssertFalse(finder.isGroup)
        XCTAssertNil(finder.children)
    }

    func testGroupingIsCaseInsensitiveLikeTheGuestsEqualString() {
        // EqualString(a, b, false, true): case-insensitive.
        let rows = SoftwareModel.rows(for: [
            entry("simpletext", path: "HD:a"),
            entry("SimpleText", path: "HD:b"),
        ])
        XCTAssertEqual(rows.count, 1, "one container, not two rows")
        XCTAssertTrue(rows[0].isGroup)
    }

    func testGroupingIsDiacriticSensitiveLikeTheGuest() {
        // ...and diacritic-SENSITIVE. Folding these together here would
        // show one row where the Mac shows two.
        let rows = SoftwareModel.rows(for: [
            entry("Resume", path: "HD:a"),
            entry("Résumé", path: "HD:b"),
        ])
        XCTAssertEqual(rows.count, 2)
        XCTAssertTrue(rows.allSatisfy { !$0.isGroup })
    }

    func testRowsSortUnderTheGuestsAsciiCaseFold() {
        // cmp_by_name lowers A-Z and compares bytes, shorter name first on
        // a prefix. So "apple" sorts before "Apple Menu Options" and both
        // before "Zoom", regardless of the case they arrived in.
        let rows = SoftwareModel.rows(for: [
            entry("Zoom", path: "HD:z"),
            entry("apple", path: "HD:a"),
            entry("Apple Menu Options", path: "HD:b"),
        ])
        XCTAssertEqual(names(rows), ["apple", "Apple Menu Options", "Zoom"])
    }

    func testGroupMembersKeepArrivalOrderForEqualNames() {
        // The guest's tie-break is the item's index, which makes the sort
        // stable; the disclosed order is the order the machine sent.
        let rows = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:second"),
            entry("SimpleText", path: "HD:first"),
        ])
        XCTAssertEqual(rows[0].members.map(\.path),
                       ["HD:second", "HD:first"])
    }

    func testContainerSumsSizesAndSkipsUnreadableMembers() {
        // The guest's `if (m->size_k > 0)`: an unreadable member (-1)
        // shrinks the total rather than poisoning it.
        let rows = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:a", sizeK: 100),
            entry("SimpleText", path: "HD:b", sizeK: -1),
            entry("SimpleText", path: "HD:c", sizeK: 300),
        ])
        XCTAssertEqual(rows[0].sizeText, "400 KB")
    }

    func testContainerReadsRunningWhenAnyMemberIs() {
        let rows = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:a"),
            entry("SimpleText", path: "HD:b", running: true),
        ])
        XCTAssertEqual(rows[0].stateText, "running")
        XCTAssertTrue(rows[0].isRunning)

        let quiet = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:a"),
            entry("SimpleText", path: "HD:b"),
        ])
        XCTAssertEqual(quiet[0].stateText, "")
    }

    func testAClosedGroupHidesItsMembersAndAnOpenOneShowsThem() {
        let tree = SoftwareModel.rows(for: [
            entry("SimpleText", path: "HD:a"),
            entry("SimpleText", path: "HD:b"),
            entry("Finder", path: "HD:f"),
        ])
        let closed = SoftwareModel.flatten(tree, expanded: [])
        XCTAssertEqual(names(closed), ["Finder", "SimpleText"])

        let id = try! XCTUnwrap(tree.first { $0.isGroup }).id
        let open = SoftwareModel.flatten(tree, expanded: [id])
        XCTAssertEqual(names(open),
                       ["Finder", "SimpleText", "SimpleText", "SimpleText"])
        XCTAssertEqual(open.map(\.depth), [0, 0, 1, 1],
                       "members sit one indent under their container")
        XCTAssertTrue(open.dropFirst(2).allSatisfy { !$0.isGroup },
                      "a disclosed member is an item, actionable on its own")
    }

    func testEntryIdentitySurvivesDuplicateNames() {
        // Two SimpleTexts differ by path; the table's selection must
        // tell them apart.
        let a = entry("SimpleText", path: "HD:Applications:SimpleText")
        let b = entry("SimpleText", path: "HD:Utilities:SimpleText")
        XCTAssertNotEqual(a.id, b.id)
    }
}
