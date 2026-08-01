import XCTest
@testable import MirrorKit

/// Desktop icons are hit by NAME, and the click that follows is computed from
/// the icon's own reported position rather than from wherever the pointer
/// landed. These pin the geometry, which is the part with something to get
/// wrong — the icon box, the label strip under it, and the fact that icons live
/// behind every window.
final class DesktopHitTests: XCTestCase {

    private func item(_ name: String, _ x: Int, _ y: Int,
                      placed: Bool = true,
                      invisible: Bool = false) -> Scene.DesktopItem {
        .init(name: name, kind: "file", type: nil, creator: nil,
              x: x, y: y, placed: placed, alias: false, invisible: invisible)
    }

    /// A real captured scene with our items dropped onto its desktop — the same
    /// approach the other hit tests use, so the geometry around the icons is the
    /// guest's own rather than something invented here.
    private func scene(_ items: [Scene.DesktopItem],
                       windows: [Scene.Window]? = nil) throws -> Scene {
        guard let url = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        let data = try Data(contentsOf:
            url.appendingPathComponent("02-axtree-front-finder.raw.json"))
        var s = try FixtureEnvelope.scene(from: data)
        s.desktopItems = items
        if let windows { s.windows = windows }
        else { s.windows = [] }
        return s
    }

    func testAClickOnTheIconBoxSelectsItByName() throws {
        let s = try scene([item("HelloWorld", 608, 348)])
        guard case .desktopItem(let name, let x, let y) =
                HitTester.hitTest(s, x: 616, y: 356) else {
            return XCTFail("expected a desktopItem hit")
        }
        XCTAssertEqual(name, "HelloWorld")
        // The click goes to the icon's CENTRE, not the pointer's position.
        XCTAssertEqual(x, 608 + HitTester.iconSize / 2)
        XCTAssertEqual(y, 348 + HitTester.iconSize / 2)
    }

    /// The Finder selects an item when you click its name, so the label strip
    /// under the icon is part of the target.
    func testTheLabelUnderTheIconIsPartOfTheTarget() throws {
        let s = try scene([item("HelloWorld", 608, 348)])
        let inLabel = 348 + HitTester.iconSize + 4
        guard case .desktopItem = HitTester.hitTest(s, x: 616, y: inLabel) else {
            return XCTFail("the label should hit the item")
        }
    }

    func testEmptyDesktopIsNotAnItem() throws {
        let s = try scene([item("HelloWorld", 608, 348)])
        guard case .desktop = HitTester.hitTest(s, x: 100, y: 100) else {
            return XCTFail("empty desktop must stay a plain desktop click")
        }
    }

    func testUnplacedAndInvisibleItemsAreNotTargets() throws {
        let s = try scene([item("nowhere", 608, 348, placed: false),
                       item("hidden", 200, 200, invisible: true)])
        guard case .desktop = HitTester.hitTest(s, x: 616, y: 356) else {
            return XCTFail("an unplaced item must not be hit")
        }
        guard case .desktop = HitTester.hitTest(s, x: 208, y: 208) else {
            return XCTFail("an invisible item must not be hit")
        }
    }

    /// Icons are painted on the backdrop, behind everything. A window over an
    /// icon must win the point, or clicking a document would select whatever
    /// happens to sit underneath it.
    func testAWindowOverAnIconWinsThePoint() throws {
        let win = Scene.Window(id: "0.1/Doc#0", app: "SimpleText", psn: "0.1",
                               title: "Doc", kind: 0,
                               rect: Rect(l: 590, t: 320, r: 700, b: 420),
                               front: true, z: 0, visible: true, controls: [])
        let s = try scene([item("HelloWorld", 608, 348)], windows: [win])
        if case .desktopItem = HitTester.hitTest(s, x: 616, y: 356) {
            XCTFail("the window should have taken the point")
        }
    }

    func testDoubleClickOpensWhileSingleClickSelects() {
        let target = HitTester.Target.desktopItem(name: "HelloWorld",
                                                  x: 624, y: 364)
        XCTAssertEqual(ActionModel.click(on: target, count: 1),
                       [.click(x: 624, y: 364, count: 1, mods: 0)])
        XCTAssertEqual(ActionModel.click(on: target, count: 2),
                       [.qmpDoubleClick(x: 624, y: 364)])
    }
}
