import XCTest
import CoreGraphics
@testable import MirrorKit
@testable import MirrorKitUI

/// **`SceneRenderer`'s dropdown consuming `menugeom`, and falling back
/// honestly when there is nothing to consume.**
///
/// The two facts this file exists to pin, together, are the ones a broken
/// fallback or a broken real-geometry path would each violate silently:
///
/// 1. With NO geometry (nobody asked yet, the guest refused, or a stale
///    read for a different menu), the drawing and the aim both use the
///    SAME uniform-16px assumption they always did — a regression here
///    would either draw nothing where the old pane drew a working menu, or
///    aim at the wrong row without anyone noticing until a real machine.
/// 2. With a MATCHING geometry, the drawing and the aim both use the real
///    per-item rects — proven not by checking pixels (there is no
///    framebuffer here) but by choosing a fixture where the real layout and
///    the uniform assumption disagree about which item is under a given
///    point, and asserting the ANSWER that only the real data can produce.
///    A mutation that quietly ignored `geometry` and always fell back would
///    fail exactly this test, returning the uniform assumption's item
///    instead.
final class DropdownGeometryTests: XCTestCase {

    // MARK: - fixture: a 3-row menu whose REAL layout disagrees with the
    // uniform 16px assumption on purpose.

    private static let openItem =
        Scene.MenuItem(title: "Open…", index: 1, separator: false,
                       enabled: true, mark: false, cmd: "")
    private static let sep =
        Scene.MenuItem(title: "", index: 2, separator: true, enabled: false,
                       mark: false, cmd: "")
    private static let closeItem =
        Scene.MenuItem(title: "Close", index: 3, separator: false,
                       enabled: true, mark: false, cmd: "")

    private static let menu = Scene.Menu(
        title: "File", apple: false, left: 38, id: 129,
        items: [openItem, sep, closeItem])

    /// Item 1: 16px (matches the uniform guess). Item 2 (separator): a REAL
    /// 6px sliver, not the uniform 16px row a fallback would give it. Item
    /// 3: a REAL 20px row, taller than the uniform guess — together the
    /// two mismatches (one narrower, one wider than 16px) mean a point that
    /// resolves correctly under real geometry resolves to a DIFFERENT item,
    /// or to none, under the uniform assumption.
    private static let geometry = MenuGeometry(
        menu: 129, width: 100, height: 42,
        orderedItems: [
            .init(top: 0, left: 0, bottom: 16, right: 100),
            .init(top: 16, left: 0, bottom: 22, right: 100),
            .init(top: 22, left: 0, bottom: 42, right: 100),
        ])

    /// A geometry for the SAME menu id that does not cover every item (as
    /// if the guest's `menugeom` had hit `kNowPeekActMenuItemMax`) — usable
    /// for nothing, by `.matches`' own rule, so every assertion below must
    /// read as the fallback despite a non-nil geometry being passed in.
    private static let partialGeometry = MenuGeometry(
        menu: 129, width: 100, height: 16,
        orderedItems: [.init(top: 0, left: 0, bottom: 16, right: 100)])

    // MARK: - dropdownFrame

    func testFrameFallsBackToTheUniformEstimateWithNoGeometry() {
        let frame = SceneRenderer.dropdownFrame(Self.menu)
        // Pinned exactly: menu.left - 6, menubarHeight + 1, and a
        // height of items.count * 16 + 4 — the estimate this pane has
        // always used absent real data.
        XCTAssertEqual(frame, CGRect(x: 32, y: 21, width: 120, height: 52))
    }

    func testFrameUsesTheGuestsRealWidthAndHeightWhenGeometryMatches() {
        let frame = SceneRenderer.dropdownFrame(Self.menu,
                                                geometry: Self.geometry)
        // menu.left - 1, menubarHeight (0-offset), width/height from the
        // MDEF's own numbers + 2 for this renderer's own border — NOT the
        // title-length estimate the fallback used above (120×52).
        XCTAssertEqual(frame, CGRect(x: 37, y: 20, width: 102, height: 44))
    }

    func testFrameFallsBackWhenGeometryNamesADifferentMenu() {
        let stale = MenuGeometry(menu: 999, width: 100, height: 42,
                                 orderedItems: Self.geometry.rectsForTest)
        let frame = SceneRenderer.dropdownFrame(Self.menu, geometry: stale)
        XCTAssertEqual(frame, SceneRenderer.dropdownFrame(Self.menu, geometry: nil),
                      "a geometry read for a DIFFERENT menu id must never "
                          + "size this one's frame")
    }

    func testFrameFallsBackWhenGeometryDoesNotCoverEveryItem() {
        let frame = SceneRenderer.dropdownFrame(
            Self.menu, geometry: Self.partialGeometry)
        XCTAssertEqual(frame, SceneRenderer.dropdownFrame(Self.menu, geometry: nil),
                      "a geometry missing an item's rect (the cap, or a "
                          + "menu that changed shape) must fall back "
                          + "entirely, not mix real and invented rects")
    }

    // MARK: - dropdownItem: the aim, real vs. fallback

    /// **The mutation-watch case.** This point sits inside item 3's REAL
    /// rect (y 22..42 of the geometry, offset into frame coordinates) but
    /// would fall in the SEPARATOR's row under the uniform assumption
    /// (row 1 of a 16px stride). A driver that silently ignored `geometry`
    /// here would aim `menuact` at the separator instead of "Close" —
    /// exactly the wrong-row defect `menugeom` exists to prevent.
    func testDropdownItemAimsAtTheRealRowWhenGeometryMatches() {
        let frame = SceneRenderer.dropdownFrame(Self.menu,
                                                geometry: Self.geometry)
        // Real "Close" occupies local y 22..42 → frame.minY + 1 + 22 ..< +42.
        let y = Int(frame.minY) + 1 + 30
        let x = Int(frame.minX) + 1 + 10
        let hit = SceneRenderer.dropdownItem(Self.menu, x: x, y: y,
                                             geometry: Self.geometry)
        XCTAssertEqual(hit, Self.closeItem,
                      "a point inside the REAL geometry's item 3 must "
                          + "resolve to item 3, not to whatever the "
                          + "uniform 16px stride would have put there")
    }

    /// The same point, but with no geometry: the same fixture proves the
    /// FALLBACK's own (different, and real-machine-wrong) answer, so a
    /// change that broke the fallback path specifically — rather than the
    /// real-geometry path — fails HERE instead of silently passing because
    /// the real-geometry test above happened to cover for it.
    func testDropdownItemFallsBackToTheUniformStrideWithNoGeometry() {
        let frame = SceneRenderer.dropdownFrame(Self.menu)
        // Same absolute y this suite used against the real geometry above,
        // re-derived against the FALLBACK's own frame origin so the two
        // tests probe the same "item 3, real geometry" region on their own
        // terms rather than sharing a hard-coded magic number.
        let y = Int(frame.minY) + 2 + 20   // row (20-2)/16... see below
        let x = Int(frame.minX) + 10
        let hit = SceneRenderer.dropdownItem(Self.menu, x: x, y: y,
                                             geometry: nil)
        // (y - frame.minY - 2) / 16 == 1 → the SEPARATOR's row under the
        // uniform assumption. Asserting the separator here — not "Close" —
        // is the point: the fallback disagrees with the real answer, on
        // purpose, in this fixture.
        XCTAssertEqual(hit, Self.sep)
    }

    func testDropdownItemFallsBackWhenGeometryNamesADifferentMenu() {
        let stale = MenuGeometry(menu: 999, width: 100, height: 42,
                                 orderedItems: Self.geometry.rectsForTest)
        let frame = SceneRenderer.dropdownFrame(Self.menu, geometry: nil)
        let y = Int(frame.minY) + 2   // row 0, "Open…", under the fallback
        let x = Int(frame.minX) + 10
        let hit = SceneRenderer.dropdownItem(Self.menu, x: x, y: y,
                                             geometry: stale)
        XCTAssertEqual(hit, Self.openItem)
    }

    func testDropdownItemOutsideEveryRowIsNil() {
        let frame = SceneRenderer.dropdownFrame(Self.menu,
                                                geometry: Self.geometry)
        let hit = SceneRenderer.dropdownItem(
            Self.menu, x: Int(frame.minX) + 10, y: Int(frame.maxY) + 50,
            geometry: Self.geometry)
        XCTAssertNil(hit)
    }
}

private extension MenuGeometry {
    /// Test-only: re-expose the ordered rects this fixture built with, so
    /// the "wrong menu id" tests can build a second geometry that carries
    /// the SAME rects under a different id without this file hand-copying
    /// three literals a second time.
    var rectsForTest: [ItemRect] {
        (1...3).compactMap { rect(forItemIndex: $0) }
    }
}
