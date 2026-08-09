import XCTest
@testable import MirrorKit

/// **A point in a Finder list view, all the way to the act that selects
/// that row** — hit test, object, plan, in one chain rather than three
/// files each pinning its own half.
///
/// The three existing suites each cover one link (`FinderItemsTests` the
/// geometry, `InteractionPolicyTests` the plan, `HitActionTests` the
/// legacy actions) and none of them crosses a seam. The defect this file
/// exists for lives exactly on a seam: every link was individually right
/// on 2026-08-07 and Michelle still reported list view as "completely not
/// selectable", because what a person clicks in a list row — the NAME —
/// is not a target at all, and nothing said so out loud.
///
/// **The numbers are one machine's own answers**, taken 2026-08-07 on
/// mac99 / OS 9.1, guest build `113f1b176035`, beside a screendump of the
/// window (`docs/local/` carries the run):
///
///   window   `axtree` bounds 48,103,452,321 (GLOBAL CONTENT)
///            scene `windows[].rect` 48,83,452,321 (structure — a title
///            bar higher, and the two documents never say so)
///   rows     `bounds of every item`, ten of them, all 16x16 at l=22:
///            t = 43, 62, 81, 100, 119, 138, 157, 176, 195, 214
///   headers  the window's own "Name" column header control, content
///            rect 0,21,214,42 — the machine saying where the name
///            column is, which is the only measured statement about the
///            horizontal extent of a row that exists.
final class ListRowSelectionTests: XCTestCase {

    // MARK: - The machine, as it answered

    /// Content origin, in global coordinates. Written once: the scene's
    /// structure rect plus the title bar is the SAME number, and stating
    /// it twice is how the two came apart.
    static let contentOrigin = (x: 48, y: 103)

    /// name → the box the Finder drew, content-local, in the order the
    /// Finder listed them (which is not the visual order).
    static let rows: [(String, Int)] = [
        ("System Folder", 119),
        ("TimBotTu", 214),
        ("Applications (Mac OS 9)", 43),
        ("Documents", 62),
        ("Late Breaking News", 81),
        ("Rumpus PRO 2.0", 100),
        ("TBT", 138),
        ("TBT-paced-dev", 157),
        ("TBT-sndbuf-dev", 176),
        ("TBTRunner", 195),
    ]

    static func listWindow() -> Scene.Window {
        let vertical = Scene.Control(
            ref: "now-element-081ced8e", role: "scrollbar", title: "",
            rect: Rect(l: 389, t: 41, r: 405, b: 204),
            enabled: true, visible: true, value: 0, min: 0, max: 188,
            checked: false)
        let horizontal = Scene.Control(
            ref: "now-element-f8ae2d57", role: "scrollbar", title: "",
            rect: Rect(l: -1, t: 203, r: 390, b: 219),
            enabled: true, visible: true, value: 0, min: 0, max: 0,
            checked: false)
        /* The Name column header, carried because it is the one thing on
           the machine that measures a row HORIZONTALLY. Nothing reads it
           yet, and `testTheNameColumnIsNotYetATarget` is why. */
        let nameHeader = Scene.Control(
            ref: "now-element-350171b7", role: "button", title: "Name",
            rect: Rect(l: 0, t: 21, r: 214, b: 42),
            enabled: true, visible: true, value: 0, min: 0, max: 1,
            checked: false)
        return Scene.Window(
            id: "0.1/Macintosh HD#0", app: "Finder", psn: "0.1",
            title: "Macintosh HD", kind: 20,
            rect: Rect(l: 48, t: 103 - SceneBuilder.titleBarHeight,
                       r: 452, b: 321),
            front: true, z: 0, visible: true,
            controls: [nameHeader, vertical, horizontal], text: nil,
            items: rows.map { name, top in
                .init(name: name, kind: "folder", type: nil, creator: nil,
                      x: 22, y: top, placed: true, alias: false,
                      invisible: false, w: 16, h: 16)
            },
            finder: .init(path: "Macintosh HD:", view: .name),
            display: nil)
    }

    static func scene() -> Scene {
        Scene(version: IR.version, seq: 1, source: "axtree", capturedAt: 0,
              screen: .init(w: 800, h: 600),
              apps: [.init(psn: "0.1", name: "Finder", front: true,
                           error: nil)],
              processes: nil, menubar: nil, windows: [listWindow()],
              desktopItems: nil,
              meta: .init(latencyMs: nil, bytes: nil, errors: [], plane: nil))
    }

    // MARK: - The chain, end to end

    /// The whole path a click takes, on the row this run actually drove:
    /// a global point → the row → the object → the act. The guest was then
    /// asked for that act and selected that row, watched in a screendump.
    func testAPointOnARowsIconResolvesToTheActThatSelectsThatRow() throws {
        let origin = Self.contentOrigin
        // Row 7 as the Finder listed it, "TBT" at content 22,138 — the
        // centre of the box the Finder drew.
        let point = (x: origin.x + 30, y: origin.y + 146)
        XCTAssertEqual(point.x, 78)
        XCTAssertEqual(point.y, 249, "the point this run sent to the guest")

        let scene = Self.scene()
        let hit = HitTester.hitTest(scene, x: point.x, y: point.y)
        guard case .windowItem(_, let name, let cx, let cy) = hit else {
            return XCTFail("expected a windowItem, got \(hit)")
        }
        XCTAssertEqual(name, "TBT")
        XCTAssertEqual(cx, 78, "the row's own centre, not where the pointer "
                       + "landed — the two agree here on purpose")
        XCTAssertEqual(cy, 249)

        let object = try XCTUnwrap(ObjectResolver.resolve(hit, in: scene))
        guard case .finderItem(let item) = object else {
            return XCTFail("expected a finderItem, got \(object)")
        }
        XCTAssertEqual(item.name, "TBT")
        XCTAssertEqual(item.container?.title, "Macintosh HD",
                       "the container is what makes `item \"X\" of window "
                       + "\"T\"` addressable without a path")

        let plan = InteractionPolicy.plan(
            for: .init(object: object,
                       gesture: .click(count: 1, mods: 0,
                                       at: Point(x: point.x, y: point.y))),
            planes: .residentActPlane)
        guard case .finderSelect(let planned, let container) = plan else {
            return XCTFail("expected finderSelect, got \(plan)")
        }
        XCTAssertEqual(planned, "TBT")
        XCTAssertEqual(container,
                       InteractionPlan.FinderContainer.window(
                           title: "Macintosh HD"))
    }

    /// Every row the window is SHOWING resolves to itself. A pitch error, a
    /// label height added back, or an off-by-one origin makes at least one
    /// row answer with its neighbour's name — which is a click that
    /// selects the WRONG FILE, and is the reason this asserts every visible
    /// row rather than a representative one.
    ///
    /// The two rows below the fold are asserted the other way. The window's
    /// icon field ends at the horizontal scrollbar (content 203), and the
    /// Finder listed two rows past it; a target for either would be a click
    /// on whatever the chrome is drawing instead.
    func testEveryVisibleRowResolvesToItsOwnNameAndTheRestDoNot() {
        let scene = Self.scene()
        let origin = Self.contentOrigin
        let field = FinderItems.iconArea(Self.listWindow())
        XCTAssertEqual(field, Rect(l: 0, t: 41, r: 389, b: 203),
                       "the window's own two scrollbars, and nothing else")

        var resolved: [String] = []
        for (name, top) in Self.rows {
            let hit = HitTester.hitTest(scene, x: origin.x + 30,
                                        y: origin.y + top + 8)
            if top + 8 < field.b {
                guard case .windowItem(_, let got, _, _) = hit else {
                    return XCTFail("\(name) at row top \(top) is inside the "
                                   + "icon field and resolved to \(hit)")
                }
                XCTAssertEqual(got, name)
                resolved.append(got)
            } else if case .windowItem(_, let got, _, _) = hit {
                XCTFail("\(got) is scrolled past the field's bottom "
                        + "(\(field.b)) and must not be a target")
            }
        }
        XCTAssertEqual(resolved.count, 8,
                       "eight of the ten rows are on screen; a count that "
                       + "drifts means the field moved and one of these "
                       + "assertions is no longer being made")
    }

    /// **THE DEFECT, named.** A column header is wide, short, and at the
    /// TOP of the window; a horizontal scroll bar is wide, short, and at
    /// the BOTTOM. `iconArea` told them apart by shape alone, so each of
    /// list view's four headers pulled the icon field's bottom up to its
    /// own top — leaving a field whose bottom was ABOVE its top, no click
    /// point for any row, and every click falling through to bare window
    /// content. Icon view has no headers, which is why this survived: the
    /// two views differ by exactly the controls that broke it.
    func testAColumnHeaderDoesNotBoundTheIconField() {
        let field = FinderItems.iconArea(Self.listWindow())
        XCTAssertGreaterThan(field.b, field.t,
                             "a field with its bottom above its top makes "
                             + "every row unclickable, which is what list "
                             + "view did until 2026-08-07")
        XCTAssertEqual(field.b, 203,
                       "the horizontal SCROLLBAR's top — not the Name "
                       + "header's 21, which is what shape alone picked")
    }

    /// The icon view is unchanged by that rule, which is the half that
    /// already worked and must keep working. Same window, headers removed,
    /// as the Finder draws it when it is not showing a list.
    func testIconViewsFieldIsUnchanged() {
        var win = Self.listWindow()
        win.controls = win.controls.filter { $0.role == "scrollbar" }
        XCTAssertEqual(FinderItems.iconArea(win),
                       FinderItems.iconArea(Self.listWindow()))
    }

    /// A semantic list row is a host-owned item target across the visible
    /// row. The guest still receives a select-by-name act, so the host never
    /// turns this wider affordance into an invented positional click.
    func testTheNameColumnTargetsItsSemanticRow() {
        let scene = Self.scene()
        let origin = Self.contentOrigin
        // Well past the 16x16 icon, on the row named TBT.
        let hit = HitTester.hitTest(scene, x: origin.x + 150,
                                    y: origin.y + 146)
        guard case .windowItem(_, let name, _, _) = hit else {
            return XCTFail("expected the semantic list row, got \(hit)")
        }
        XCTAssertEqual(name, "TBT")
    }

    func testRowTargetingInfersNameViewWhileViewMetadataIsUnknown() {
        var window = Self.listWindow()
        window.finder?.view = .unknown
        var scene = Self.scene()
        scene.windows = [window]
        let origin = Self.contentOrigin
        let hit = HitTester.hitTest(scene, x: origin.x + 150,
                                    y: origin.y + 146)
        guard case .windowItem(_, let name, _, _) = hit else {
            return XCTFail("drawn list row fell through to \(hit)")
        }
        XCTAssertEqual(name, "TBT")
        XCTAssertEqual(FinderItems.presentationView(window), .name)
    }

    /// The header is a control and wins over the rows under it, which is
    /// the ordering that keeps a column sort clickable.
    func testTheColumnHeaderIsAControlAndNotARow() {
        let scene = Self.scene()
        let origin = Self.contentOrigin
        let hit = HitTester.hitTest(scene, x: origin.x + 100,
                                    y: origin.y + 30)
        guard case .control(_, let ctl) = hit else {
            return XCTFail("expected the Name header control, got \(hit)")
        }
        XCTAssertEqual(ctl.title, "Name")
    }

    /// **Twenty points, named.** The scene's window rect and `axtree`'s
    /// bounds describe the same window in two frames, and a reader that
    /// takes the first for a content origin puts every derived point one
    /// title bar high. On this window that lands a row click in the
    /// row ABOVE, and a header click in the info bar.
    func testTheStructureRectIsATitleBarAboveTheContentOrigin() {
        let win = Self.listWindow()
        XCTAssertEqual(FinderItems.contentOrigin(win).y, Self.contentOrigin.y)
        XCTAssertEqual(win.rect.t, Self.contentOrigin.y - 20,
                       "measured: scene 83, axtree 71+... — the same 20 the "
                       + "Extensions Manager window showed on this machine")
        let scene = Self.scene()
        // The same row, aimed with the structure rect instead.
        let wrong = HitTester.hitTest(scene, x: win.rect.l + 30,
                                      y: win.rect.t + 146)
        guard case .windowItem(_, let name, _, _) = wrong else {
            // Landing on nothing is the milder outcome; landing on the
            // wrong file is the one worth naming.
            return
        }
        XCTAssertNotEqual(name, "TBT",
                          "if these ever agree the constant has moved and "
                          + "this test is measuring nothing")
    }
}
