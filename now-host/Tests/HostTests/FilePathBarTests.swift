import XCTest
@testable import Host

/// The path bar, tested as a decomposition rather than as pixels: which
/// components a path has, which of them are places we may go, what the
/// top of the tree is called, and what is left when a path is deeper than
/// the bar can draw.
///
/// The rules being asserted are HFS rules, not POSIX ones. They are
/// stated once in `contract/share_path.h` and pinned by
/// `now-guest-ppc/tests/share_path_test.c`; the host splits with the one
/// splitter that follows them, `FileChangeNames.components`.
final class FilePathBarTests: XCTestCase {

    // MARK: - The root is a volume, not a slash

    func testAWholeVolumeIsOneCrumbAndItIsADisk() {
        let crumbs = FilePathBar.crumbs(shareRoot: "Macintosh HD:",
                                        breadcrumb: [])
        XCTAssertEqual(crumbs.map(\.name), ["Macintosh HD"],
                       "a trailing colon names the volume; it is not a "
                       + "second, empty component")
        XCTAssertTrue(crumbs[0].isVolume)
        // Sharing the whole disk makes one crumb both the disk and the
        // place browsing starts, so it is navigable.
        XCTAssertEqual(crumbs[0].role, .shareRoot)
        XCTAssertEqual(crumbs[0].depth, -1)
    }

    func testTheDiskIsNamedEvenWhenItIsNotWhereBrowsingStarts() {
        let crumbs = FilePathBar.crumbs(shareRoot: "Macintosh HD:Lab:",
                                        breadcrumb: [])
        XCTAssertEqual(crumbs.map(\.name), ["Macintosh HD", "Lab"])
        XCTAssertTrue(crumbs[0].isVolume)
        XCTAssertEqual(crumbs[0].role, .aboveShare)
        // The share boundary stops here: the disk is context, not a
        // destination.
        XCTAssertNil(crumbs[0].depth)
        XCTAssertFalse(crumbs[0].isNavigable)
        XCTAssertEqual(crumbs[1].role, .shareRoot)
        XCTAssertEqual(crumbs[1].depth, -1)
    }

    func testNothingSharedYetStillRendersARoot() {
        let crumbs = FilePathBar.crumbs(shareRoot: nil, breadcrumb: [])
        XCTAssertEqual(crumbs.count, 1)
        // Subscripting a bar that regressed to empty would take the whole
        // test process down with it, so this asks rather than indexes.
        guard let root = crumbs.first else {
            return XCTFail("absence is a fact to render, not a blank bar")
        }
        XCTAssertTrue(root.isPlaceholder)
        XCTAssertFalse(root.isVolume,
                       "we were not told a disk name, so we invent none")
        XCTAssertEqual(root.depth, -1)
        // An empty string is the same absence spelled differently.
        XCTAssertEqual(FilePathBar.crumbs(shareRoot: "", breadcrumb: [])
                        .first?.isPlaceholder, true)
    }

    // MARK: - Depths are what a click will actually do

    func testEveryFolderCrumbCarriesItsJumpTarget() {
        let crumbs = FilePathBar.crumbs(
            shareRoot: "Macintosh HD:Lab:",
            breadcrumb: ["Code", "now", "now-host"])
        XCTAssertEqual(crumbs.map(\.name),
                       ["Macintosh HD", "Lab", "Code", "now", "now-host"])
        XCTAssertEqual(crumbs.map(\.depth), [nil, -1, 0, 1, 2],
                       "-1 is the share root; 0 is the first folder in it")
    }

    func testTwoFoldersOfTheSameNameAtDifferentDepthsStayDistinct() {
        let crumbs = FilePathBar.crumbs(shareRoot: "HD:",
                                        breadcrumb: ["src", "now", "src"])
        XCTAssertEqual(Set(crumbs.map(\.id)).count, crumbs.count,
                       "identity must survive a repeated folder name, or "
                       + "the bar redraws the wrong crumb")
    }

    // MARK: - Names an HFS volume can really have

    func testComponentsThatWouldMangleUnderAPosixSplitter() {
        // Every one of these is a legal HFS name and none of them is
        // punctuation to this splitter: share_path_test.c pins ".." and
        // dots as ordinary, and "/" is only special on the host's own
        // file system.
        let awkward = ["Read/Me", "..", ".", "Système", "My Documents",
                       String(repeating: "N", count: 31)]
        // The share root is the half that arrives as TEXT from the other
        // machine and has to be split here, so the awkward names belong
        // on that side of the seam as well as in the breadcrumb, which
        // arrives already in pieces.
        let root = "Macintosh HD:Read/Me:..:Système:"
        let crumbs = FilePathBar.crumbs(shareRoot: root,
                                        breadcrumb: awkward)
        XCTAssertEqual(Array(crumbs.prefix(4)).map(\.name),
                       ["Macintosh HD", "Read/Me", "..", "Système"],
                       "a slash is an ordinary character in an HFS name, "
                       + "and dot-dot is a folder rather than an ascent")
        XCTAssertEqual(Array(crumbs.dropFirst(4)).map(\.name), awkward)
        XCTAssertEqual(crumbs.last?.name.count, 31,
                       "31 characters is what HFS can name, and the bar "
                       + "shows all of them")
        XCTAssertEqual(FilePathBar.fullPath(shareRoot: root,
                                            breadcrumb: ["Read/Me"]),
                       "Macintosh HD:Read/Me:..:Système:Read/Me")
    }

    func testTheFullPathIsSpelledTheWayThatMachineSpellsIt() {
        XCTAssertEqual(
            FilePathBar.fullPath(shareRoot: "Macintosh HD:Lab:",
                                 breadcrumb: ["Code", "now"]),
            "Macintosh HD:Lab:Code:now",
            "one separator between the root and what is inside it, "
            + "however the guest punctuated its own root")
        XCTAssertEqual(
            FilePathBar.fullPath(shareRoot: "Macintosh HD:Lab",
                                 breadcrumb: ["Code"]),
            "Macintosh HD:Lab:Code")
        XCTAssertEqual(
            FilePathBar.fullPath(shareRoot: "Macintosh HD:", breadcrumb: []),
            "Macintosh HD")
        XCTAssertEqual(
            FilePathBar.fullPath(shareRoot: nil, breadcrumb: []), "")
    }

    // MARK: - How a deep path degrades

    func testAThreeDeepPathIsShownWhole() {
        let items = FilePathBar.items(shareRoot: "Macintosh HD:Lab:",
                                      breadcrumb: ["a", "b", "c"])
        XCTAssertFalse(items.contains { if case .elision = $0 { return true }
                                        else { return false } },
                       "the common case never folds")
        XCTAssertEqual(items.count, 5)
    }

    func testADeepPathKeepsTheDiskTheShareAndWhereYouAre() {
        let deep = ["Applications", "Utilities", "Old", "Network",
                    "Tools", "Here"]
        let items = FilePathBar.items(shareRoot: "Macintosh HD:Lab:",
                                      breadcrumb: deep)
        XCTAssertEqual(shownNames(items),
                       ["Macintosh HD", "Lab", "Tools", "Here"],
                       "the two questions being asked are which machine "
                       + "and where exactly; the middle is what folds")
        XCTAssertEqual(hiddenNames(items),
                       ["Applications", "Utilities", "Old", "Network"])
    }

    func testAFoldLosesNothingAndKeepsTheOrder() {
        let deep = (1...20).map { "folder\($0)" }
        let items = FilePathBar.items(shareRoot: "HD:Users:Guest:Share:",
                                      breadcrumb: deep)
        let all = FilePathBar.crumbs(shareRoot: "HD:Users:Guest:Share:",
                                     breadcrumb: deep)
        XCTAssertEqual(flattened(items).map(\.id), all.map(\.id),
                       "shown and folded together are the path, in order")
        // Every folded crumb that is a place we may go is still one
        // click away, because the fold is a menu.
        XCTAssertEqual(hiddenNames(items).count, 18 + 2)
    }

    func testTheBarHasAWidthCeilingRatherThanGrowingWithDepth() {
        for depth in 0...40 {
            let items = FilePathBar.items(
                shareRoot: "HD:Users:Guest:Documents:Share:",
                breadcrumb: (0..<depth).map { "d\($0)" })
            XCTAssertLessThanOrEqual(items.count, 6,
                                     "depth \(depth) drew \(items.count) "
                                     + "elements")
        }
    }

    func testTheUnenterableMiddleFoldsSeparatelyFromTheFolders() {
        let items = FilePathBar.items(
            shareRoot: "Macintosh HD:Users:Guest:Documents:Share:",
            breadcrumb: ["a", "b", "c", "d", "e"])
        XCTAssertEqual(shownNames(items),
                       ["Macintosh HD", "Share", "d", "e"])
        // Above the share root nothing is clickable, so the fold there
        // is context; inside it everything is.
        let folded = items.flatMap { item -> [FilePathBar.Crumb] in
            if case .elision(let hidden) = item { return hidden }
            return []
        }
        XCTAssertEqual(folded.filter { $0.role == .aboveShare }.map(\.name),
                       ["Users", "Guest", "Documents"])
        XCTAssertEqual(folded.filter { $0.role == .folder }.map(\.name),
                       ["a", "b", "c"])
    }

    func testNamesAreNeverCutShort() {
        // The fold is by depth precisely so this never happens: a
        // truncated HFS name is ambiguous, and 31 characters is short
        // enough that names differ late.
        let long = ["System Folder Extensions (Off)",
                    "System Folder Extensions (On)"]
        let items = FilePathBar.items(shareRoot: "Macintosh HD:",
                                      breadcrumb: long)
        XCTAssertEqual(shownNames(items).suffix(2), long[...])
    }

    // MARK: - Helpers

    private func flattened(_ items: [FilePathBar.Item])
        -> [FilePathBar.Crumb] {
        items.flatMap { item -> [FilePathBar.Crumb] in
            switch item {
            case .crumb(let crumb): return [crumb]
            case .elision(let hidden): return hidden
            }
        }
    }

    private func shownNames(_ items: [FilePathBar.Item]) -> [String] {
        items.compactMap {
            if case .crumb(let crumb) = $0 { return crumb.name }
            return nil
        }
    }

    private func hiddenNames(_ items: [FilePathBar.Item]) -> [String] {
        items.flatMap { item -> [String] in
            if case .elision(let hidden) = item {
                return hidden.map(\.name)
            }
            return []
        }
    }
}
