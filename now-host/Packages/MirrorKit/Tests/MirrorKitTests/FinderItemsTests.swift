import XCTest
@testable import MirrorKit

/// Folder-window items: the parse, the join, and the geometry that turns a
/// Finder position into a point worth clicking.
///
/// The geometry numbers here are the ones measured on a live guest
/// (2026-07-31, mac99/OS 9.1) and re-verified by clicking — see
/// `FinderItems`'s header and `docs/FOLDER-ITEMS.md`. A window content rect of
/// (13,47)-(417,265) with an item at position (53,25) has its icon centre at
/// guest (82,88), and clicking (82,88) selected that file.
final class FinderItemsTests: XCTestCase {

    // MARK: - Parsing what the Finder said

    func testParsesWindowsItemsAndTruncation() {
        let raw = """
        "W|TimBotTu|Macintosh HD:TimBotTu:;;I|tbt-worker|53,25;;\
        I|mirror-dev|181,-103;;T|;;W|Apps|Macintosh HD:Apps:;;I|a|1,2;;"
        """
        let reports = FinderItems.parse(raw)
        XCTAssertEqual(reports.count, 2)
        XCTAssertEqual(reports[0].title, "TimBotTu")
        XCTAssertEqual(reports[0].path, "Macintosh HD:TimBotTu:")
        XCTAssertEqual(reports[0].items,
                       [.init(name: "tbt-worker", x: 53, y: 25),
                        .init(name: "mirror-dev", x: 181, y: -103)])
        XCTAssertTrue(reports[0].truncated, "the T| marker is the cap, said out loud")
        XCTAssertEqual(reports[1].title, "Apps")
        XCTAssertFalse(reports[1].truncated)
    }

    /// The guest truncates its script result at a byte cap, so the last record
    /// can arrive half-written. It has no `;;` terminator and must be dropped:
    /// a half-read position is a plausible lie, which is the one thing this
    /// surface may not ship.
    func testDropsATruncatedTrailingRecord() {
        let raw = "W|F|P:;;I|good|1,2;;I|bad|3"
        let reports = FinderItems.parse(raw)
        XCTAssertEqual(reports[0].items.map(\.name), ["good"])
    }

    func testIgnoresGarbageRecordsRatherThanGuessing() {
        let raw = "I|orphan|1,2;;W|F|P:;;I|nocoords|;;I|onecoord|5;;I|ok|1,2;;"
        let reports = FinderItems.parse(raw)
        XCTAssertEqual(reports.count, 1)
        XCTAssertEqual(reports[0].items.map(\.name), ["ok"])
    }

    // MARK: - Joining identity to position

    /// The Finder is authoritative on membership and position; the catalog
    /// only says what a thing IS. An item the catalog never described is still
    /// carried, because position is what makes it addressable.
    func testMergeTakesPositionFromTheFinderAndIdentityFromTheCatalog() {
        let catalog = [
            Scene.DesktopItem(name: "doc", kind: "file", type: "TEXT",
                              creator: "ttxt", x: 900, y: 900, placed: true,
                              alias: false, invisible: false),
            Scene.DesktopItem(name: "gone", kind: "file", type: nil,
                              creator: nil, x: 1, y: 1, placed: true,
                              alias: false, invisible: false),
        ]
        let placed = [FinderItems.Placed(name: "doc", x: 53, y: 25),
                      FinderItems.Placed(name: "stranger", x: 181, y: 25)]
        let merged = FinderItems.merge(placed: placed, catalog: catalog)

        XCTAssertEqual(merged.map(\.name), ["doc", "stranger"],
                       "the Finder decides what is in the window")
        XCTAssertEqual(merged[0].x, 53)
        XCTAssertEqual(merged[0].y, 25)
        XCTAssertEqual(merged[0].type, "TEXT", "identity came from the catalog")
        XCTAssertEqual(merged[1].kind, "file")
        XCTAssertTrue(merged[1].placed, "the Finder drew it; that IS placement")
    }

    // MARK: - Geometry

    /// A Finder folder window as the guest reported it on 2026-07-31: content
    /// (13,47)-(417,265), vertical scrollbar at global (402,67)-(418,251),
    /// horizontal at (12,250)-(403,266) — both content-local in the scene.
    static func folderWindow(items: [Scene.DesktopItem]) -> Scene.Window {
        let vertical = Scene.Control(
            ref: "v", role: "scrollbar", title: "",
            rect: Rect(l: 389, t: 20, r: 405, b: 204),
            enabled: true, visible: true, value: -4, min: -4, max: 188,
            checked: false)
        let horizontal = Scene.Control(
            ref: "h", role: "scrollbar", title: "",
            rect: Rect(l: -1, t: 203, r: 390, b: 219),
            enabled: true, visible: true, value: -52, min: -52, max: -52,
            checked: false)
        return Scene.Window(
            id: "0.1/TimBotTu#0", app: "Finder", psn: "0.1",
            title: "TimBotTu", kind: 20,
            // The scene's window rect is the content port grown UP by the
            // title bar, so the measured content top (47) is expressed
            // through the same constant the rest of the core uses rather
            // than written twice.
            rect: Rect(l: 13, t: 47 - SceneBuilder.titleBarHeight,
                       r: 417, b: 265),
            front: true, z: 0, visible: true,
            controls: [vertical, horizontal], text: nil,
            items: items, display: nil)
    }

    static func item(_ name: String, _ x: Int, _ y: Int) -> Scene.DesktopItem {
        .init(name: name, kind: "folder", type: nil, creator: nil,
              x: x, y: y, placed: true, alias: false, invisible: false)
    }

    /// The info bar's height is never written down here — it is read off where
    /// the window's own vertical scrollbar starts. No phantom constants.
    func testIconAreaComesFromTheWindowsOwnScrollbars() {
        let win = Self.folderWindow(items: [])
        let area = FinderItems.iconArea(win)
        XCTAssertEqual(area, Rect(l: 0, t: 20, r: 389, b: 203))
    }

    func testClickPointIsTheIconCentreInGuestCoords() {
        let win = Self.folderWindow(items: [Self.item("tbt-worker", 53, 25)])
        let point = FinderItems.clickPoint(win.items![0], in: win)
        XCTAssertEqual(point?.x, 82, "13 + 53 + 16, measured live")
        XCTAssertEqual(point?.y, 88, "47 + 25 + 16, measured live")
    }

    /// An item the Finder has scrolled out has a position and NO click point.
    /// nil is the answer: inventing a point for an invisible icon is exactly
    /// how a click lands on the wrong file.
    func testScrolledOutItemsHaveNoClickPoint() {
        // Each of the first three sits BETWEEN the icon field's edge and the
        // window content's edge — the strip the chrome occupies. An area that
        // forgot to inset for the scrollbars and the info bar would call all
        // three clickable, which is the whole failure mode.
        let win = Self.folderWindow(items: [
            Self.item("under-info-bar", 53, 0),   // centre y 16, field starts 20
            Self.item("below", 53, 196),          // centre y 212, field ends 203
            Self.item("behind", 392, 60),         // centre x 408, field ends 389
            Self.item("scrolled-away", 53, -103), // above the fold entirely
            Self.item("visible", 53, 25),
        ])
        let items = win.items!
        XCTAssertNil(FinderItems.clickPoint(items[0], in: win))
        XCTAssertNil(FinderItems.clickPoint(items[1], in: win))
        XCTAssertNil(FinderItems.clickPoint(items[2], in: win))
        XCTAssertNil(FinderItems.clickPoint(items[3], in: win))
        XCTAssertNotNil(FinderItems.clickPoint(items[4], in: win))
    }

    // MARK: - Hit-testing

    func testHitTestResolvesAFolderIconByName() {
        let win = Self.folderWindow(items: [
            Self.item("tbt-worker", 53, 25),
            Self.item("mirror-dev", 181, 25),
        ])
        let scene = Self.scene(with: win)
        // A point inside the second icon's box.
        let hit = HitTester.hitTest(scene, x: 13 + 185, y: 47 + 30)
        guard case .windowItem(_, let name, let x, let y) = hit else {
            return XCTFail("expected a windowItem, got \(hit)")
        }
        XCTAssertEqual(name, "mirror-dev")
        // …and it reports the icon's OWN centre, not where the pointer landed.
        XCTAssertEqual(x, 13 + 181 + 16)
        XCTAssertEqual(y, 47 + 25 + 16)
    }

    func testAClickInTheIconFieldWithNoIconIsStillContent() {
        let win = Self.folderWindow(items: [Self.item("tbt-worker", 53, 25)])
        let scene = Self.scene(with: win)
        let hit = HitTester.hitTest(scene, x: 13 + 250, y: 47 + 120)
        guard case .content = hit else {
            return XCTFail("empty icon field is window content, got \(hit)")
        }
    }

    func testButtonsActivateOnOnePrimaryClickButOtherFinderViewsSelect() {
        var window = Self.folderWindow(items: [Self.item("System Folder", 20, 8)])
        window.finder = .init(path: "Macintosh HD:", view: .button)
        XCTAssertTrue(FinderItems.activatesOnPrimaryClick(window))

        for view in [Scene.FinderPresentation.View.icon, .name, .smallIcon] {
            window.finder?.view = view
            XCTAssertFalse(FinderItems.activatesOnPrimaryClick(window),
                           "\(view) keeps select then double-click semantics")
        }
    }

    /// A scrollbar drawn over the icon field is still a scrollbar. The order
    /// matters: resolving an icon first would make the scrollbar unclickable
    /// on any window whose icons run under it.
    func testControlsWinOverIcons() {
        let win = Self.folderWindow(items: [Self.item("under", 385, 60)])
        let scene = Self.scene(with: win)
        let hit = HitTester.hitTest(scene, x: 13 + 395, y: 47 + 70)
        guard case .scrollbar = hit else {
            return XCTFail("expected the scrollbar, got \(hit)")
        }
    }

    func testClickOnAnItemSelectsAndDoubleClickOpens() {
        let win = Self.folderWindow(items: [Self.item("tbt-worker", 53, 25)])
        let scene = Self.scene(with: win)
        let hit = HitTester.hitTest(scene, x: 82, y: 88)
        XCTAssertEqual(ActionModel.click(on: hit),
                       [.click(x: 82, y: 88, count: 1, mods: 0)])
        XCTAssertEqual(ActionModel.click(on: hit, count: 2),
                       [.deviceDoubleClick(x: 82, y: 88)])
    }

    // MARK: - The cache key

    /// Scrolling changes the viewport, not the directory model. The cached
    /// roster remains valid and is translated by the reported scroll delta.
    func testLayoutKeyDoesNotChangeWhenTheWindowScrolls() {
        let before = Self.folderWindow(items: [])
        var after = before
        after.controls[0].value = 124        // the measured post-scroll value
        XCTAssertEqual(FinderItems.layoutKey(before),
                       FinderItems.layoutKey(after))
        let beforeScroll = FinderItems.scrollPosition(before)
        let afterScroll = FinderItems.scrollPosition(after)
        XCTAssertEqual(afterScroll.x, beforeScroll.x)
        XCTAssertEqual(afterScroll.y, 124)
    }

    func testLayoutKeyIgnoresMovingButChangesWhenTheWindowResizes() {
        let before = Self.folderWindow(items: [])
        var moved = before
        moved.rect.l += 40
        moved.rect.r += 40
        XCTAssertEqual(FinderItems.layoutKey(before),
                       FinderItems.layoutKey(moved))
        var after = before
        after.rect.r += 40
        XCTAssertNotEqual(FinderItems.layoutKey(before),
                          FinderItems.layoutKey(after))
    }

    func testLayoutKeyChangesWhenListViewAddsColumnHeaders() {
        let before = Self.folderWindow(items: [])
        var after = before
        after.controls.append(.init(
            ref: "name-header", role: "button", title: "Name",
            rect: Rect(l: 0, t: 21, r: 214, b: 42), enabled: true,
            visible: true, value: 0, min: 0, max: 1, checked: false))
        XCTAssertNotEqual(FinderItems.layoutKey(before),
                          FinderItems.layoutKey(after))
    }

    func testDesktopBackdropIsNotAFolderWindow() {
        var backdrop = Self.folderWindow(items: [])
        backdrop.title = "Desktop"
        XCTAssertFalse(FinderItems.isFolderWindow(backdrop))
        XCTAssertTrue(FinderItems.isFolderWindow(Self.folderWindow(items: [])))
    }

    static func scene(with win: Scene.Window) -> Scene {
        Scene(version: IR.version, seq: 1, source: "axtree", capturedAt: 0,
              screen: .init(w: 800, h: 600),
              apps: [.init(psn: "0.1", name: "Finder", front: true, error: nil)],
              processes: nil, menubar: nil, windows: [win],
              desktopItems: nil,
              meta: .init(latencyMs: nil, bytes: nil, errors: [], plane: nil))
    }

    // MARK: - The list view (measured 2026-08-07, mac99 / OS 9.1)
    //
    // Macintosh HD in `name` view, ten rows, window bounds 48,103,452,321.
    // The Finder's own answers, taken beside a screendump of the window:
    //
    //   Applications (Mac OS 9)  bounds 22,43,38,59   position 194,42
    //   Documents                bounds 22,62,38,78   position 386,42
    //   Late Breaking News       bounds 22,81,38,97   position   2,66
    //   System Folder            bounds 22,119,38,135 position   2,42
    //   TimBotTu                 bounds 22,214,38,230 position 386,66
    //
    // Two facts the code now depends on, and both are in that table: the row
    // pitch is 19 px, and `position` describes a three-column icon grid the
    // window is not drawing.

    /// The row icons are 16x16, not 32x32 — and the whole defect is what
    /// happens when a reader assumes otherwise at a 19-px pitch.
    func testAListRowsTargetIsTheRowAndNotAnIconBox() {
        let row = Scene.DesktopItem(
            name: "Applications (Mac OS 9)", kind: "folder", type: nil,
            creator: nil, x: 22, y: 43, placed: true, alias: false,
            invisible: false, w: 16, h: 16)
        let size = HitTester.targetSize(row)
        XCTAssertEqual(size.w, 16)
        XCTAssertEqual(size.h, 16, "a row's name is drawn BESIDE the icon, so "
                       + "the label height belongs to the icon view alone; "
                       + "adding it here reaches into the next row")
        XCTAssertLessThan(size.h, 19, "the Finder's measured row pitch — a "
                          + "target taller than this can select two files")
    }

    /// An icon-view icon keeps the label under it, which is what the Finder
    /// draws and what a click on a name selects.
    func testAnIconViewIconKeepsItsLabel() {
        let icon = Scene.DesktopItem(
            name: "System Folder", kind: "folder", type: nil, creator: nil,
            x: 34, y: 25, placed: true, alias: false, invisible: false,
            w: 32, h: 32)
        let size = HitTester.targetSize(icon)
        XCTAssertEqual(size.w, 32)
        XCTAssertEqual(size.h, 32 + HitTester.iconLabelHeight)
    }

    /// An item whose producer never asked the Finder for a size answers
    /// exactly what every reader assumed before the field existed. Older
    /// fixtures decode unchanged; nothing that was right becomes wrong.
    func testAnItemWithNoMeasuredBoxKeepsTheOldIconAssumption() {
        let size = HitTester.targetSize(Self.item("legacy", 53, 25))
        XCTAssertEqual(size.w, HitTester.iconSize)
        XCTAssertEqual(size.h, HitTester.iconSize + HitTester.iconLabelHeight)
    }

    /// The click point for a list row must land IN that row. Computed from a
    /// constant 32/2 it fell 16 px down a 16-px row — past the 19-px pitch and
    /// into the next file, which is a wrong selection rather than a miss.
    func testAListRowsClickPointStaysInsideItsOwnRow() throws {
        let win = Self.folderWindow(items: [
            .init(name: "Applications (Mac OS 9)", kind: "folder", type: nil,
                  creator: nil, x: 22, y: 43, placed: true, alias: false,
                  invisible: false, w: 16, h: 16),
        ])
        let point = try XCTUnwrap(FinderItems.clickPoint(win.items![0],
                                                         in: win))
        let origin = FinderItems.contentOrigin(win)
        let localY = point.y - origin.y
        XCTAssertGreaterThanOrEqual(localY, 43)
        XCTAssertLessThan(localY, 43 + 19,
                          "past the row pitch is the NEXT file, and a click "
                          + "that selects the wrong file is the failure this "
                          + "lane exists to remove")
        XCTAssertEqual(point.x - origin.x, 30, "22 + 16/2")
    }

    /// Two adjacent rows resolve to themselves. One box that reached into the
    /// next row would make the later item win both points, because the hit
    /// tester takes the last match in draw order.
    func testAdjacentListRowsDoNotShadowEachOther() {
        let win = Self.folderWindow(items: [
            .init(name: "Applications (Mac OS 9)", kind: "folder", type: nil,
                  creator: nil, x: 22, y: 43, placed: true, alias: false,
                  invisible: false, w: 16, h: 16),
            .init(name: "Documents", kind: "folder", type: nil, creator: nil,
                  x: 22, y: 62, placed: true, alias: false, invisible: false,
                  w: 16, h: 16),
        ])
        let origin = FinderItems.contentOrigin(win)
        XCTAssertEqual(HitTester.windowItem(win, x: origin.x + 30,
                                            y: origin.y + 50)?.name,
                       "Applications (Mac OS 9)")
        XCTAssertEqual(HitTester.windowItem(win, x: origin.x + 30,
                                            y: origin.y + 69)?.name,
                       "Documents")
    }

    /// The script asks for the box, and asking for the position is the bug.
    func testTheWindowsScriptAsksForBoundsAndNotPosition() {
        let script = FinderItems.windowsScript()
        XCTAssertTrue(script.contains("set q to bounds of t"))
        XCTAssertFalse(script.contains("position of"),
                       "`position` is the SAVED icon grid in a list view, "
                       + "which is a layout the window is not drawing")
    }

    /// Four numbers is a box; two is an older record with no size. Anything
    /// else is a partial read of a truncated result and is dropped — a half
    /// coordinate is a plausible lie.
    func testParseReadsABoxAndStillReadsABarePosition() {
        let box = FinderItems.parse(
            "W|Macintosh HD|Macintosh HD:;;I|Documents|22,62,38,78;;")
        XCTAssertEqual(box.first?.items.first?.x, 22)
        XCTAssertEqual(box.first?.items.first?.y, 62)
        XCTAssertEqual(box.first?.items.first?.w, 16)
        XCTAssertEqual(box.first?.items.first?.h, 16)

        let bare = FinderItems.parse("W|T|T:;;I|old|53,25;;")
        XCTAssertEqual(bare.first?.items.first?.x, 53)
        XCTAssertNil(bare.first?.items.first?.w)

        let partial = FinderItems.parse("W|T|T:;;I|torn|22,62,38;;")
        XCTAssertTrue(partial.first?.items.isEmpty ?? false)
    }
}
