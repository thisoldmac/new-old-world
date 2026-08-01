import XCTest
@testable import MirrorKit

/// `MenuGeometry` is the guest's `menugeom` answer, held in the shape every
/// consumer (`SceneRenderer`'s drawing and hit test, `MirrorModuleModel`'s
/// aim) reads through `.matches(_:)` before trusting it at all. These tests
/// are about `.matches` and `rect(forItemIndex:)` in isolation — the wire
/// parsing lives in `AgentIntegrationActLaneTests` (`HostTests`), and the
/// drawing/hit-test consumption in `DropdownGeometryTests`
/// (`MirrorKitUITests`).
final class MenuGeometryTests: XCTestCase {
    private static func menu(id: Int = 129,
                             items: [Scene.MenuItem]) -> Scene.Menu {
        Scene.Menu(title: "File", apple: false, left: 38, id: id,
                  items: items)
    }

    private static let openItem =
        Scene.MenuItem(title: "Open…", index: 1, separator: false,
                       enabled: true, mark: false, cmd: "O")
    private static let sep =
        Scene.MenuItem(title: "", index: 2, separator: true, enabled: false,
                       mark: false, cmd: "")
    private static let closeItem =
        Scene.MenuItem(title: "Close", index: 3, separator: false,
                       enabled: true, mark: false, cmd: "W")

    private static let rect1 = MenuGeometry.ItemRect(
        top: 0, left: 0, bottom: 16, right: 100)
    private static let rect2 = MenuGeometry.ItemRect(
        top: 16, left: 0, bottom: 22, right: 100)
    private static let rect3 = MenuGeometry.ItemRect(
        top: 22, left: 0, bottom: 42, right: 100)

    /// The ordinary case: the same menu id, and a rect for every item the
    /// menu currently has.
    func testMatchesTheSameMenuWithEveryItemAnswered() {
        let menu = Self.menu(items: [Self.openItem, Self.sep, Self.closeItem])
        let geometry = MenuGeometry(
            menu: 129, width: 100, height: 42,
            orderedItems: [Self.rect1, Self.rect2, Self.rect3])
        XCTAssertTrue(geometry.matches(menu))
    }

    /// A stale read from a DIFFERENT menu must never be drawn under this
    /// one's title — the wrong-menu-id case `.matches` exists to catch. A
    /// person who opened menu 129 must never see menu 130's rects because
    /// two reads happened to race.
    func testDoesNotMatchADifferentMenuId() {
        let menu = Self.menu(id: 129,
                             items: [Self.openItem, Self.sep, Self.closeItem])
        let geometry = MenuGeometry(
            menu: 130, width: 100, height: 42,
            orderedItems: [Self.rect1, Self.rect2, Self.rect3])
        XCTAssertFalse(geometry.matches(menu))
    }

    /// The item cap (`kNowPeekActMenuItemMax`) or a menu that changed shape
    /// between the read and the draw both mean SOME item has no real rect
    /// — and `.matches` must refuse the whole geometry rather than let a
    /// caller mix real rects for the items it has with invented ones for
    /// the rest.
    func testDoesNotMatchWhenAnItemHasNoRect() {
        let menu = Self.menu(items: [Self.openItem, Self.sep, Self.closeItem])
        let geometry = MenuGeometry(
            menu: 129, width: 100, height: 22,
            orderedItems: [Self.rect1, Self.rect2])   // no item 3
        XCTAssertFalse(geometry.matches(menu))
    }

    /// `rect(forItemIndex:)` reads by the Menu Manager's own 1-based index,
    /// not by array position — the two happen to coincide in this fixture,
    /// so this pins the LOOKUP KEY rather than the coincidence.
    func testRectForItemIndexReadsByMenuManagerIndexNotPosition() {
        let geometry = MenuGeometry(
            menu: 129, width: 100, height: 42,
            orderedItems: [Self.rect1, Self.rect2, Self.rect3])
        XCTAssertEqual(geometry.rect(forItemIndex: 3), Self.rect3)
        XCTAssertNil(geometry.rect(forItemIndex: 4))
    }
}
