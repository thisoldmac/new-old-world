import Foundation

/// One menu's REAL per-item geometry, as its own MDEF computed it — the
/// guest's `menugeom` verb (`contract/asyncapi.yaml:menugeom`,
/// `ext/src/now_ext_act.c:act_serve_menugeom`), not a fixed row height
/// assumed from outside.
///
/// **Reopens a ruling, on the condition the ruling itself named.**
/// `docs/input-plane-decisions.md` §3 deleted this project's one-time
/// consumer of an assumed menu row height (`ActionModel.menuRowHeight`,
/// `menuItemPoint`, `.menuDrag`) on the finding that nothing drew a menu or
/// hit-tested one, so a computed pixel had no reader. That finding no
/// longer holds: `SceneRenderer.drawDropdown` draws the mirror's OWN
/// dropdown, and `SceneRenderer.dropdownItem` hit-tests a point inside it —
/// exactly the "a mirror that draws menus itself" case the ruling named as
/// the one worth re-opening for.
///
/// **Coordinates are LOCAL to the menu's own (0,0)-origin box**, sized
/// `width`×`height` — the same box `mCalcItemMsg` was handed
/// (`now_ext_act.c:act_serve_menugeom`'s own comment: the MDEF computes an
/// item's rect inside the bounds it is given and does not itself know
/// where the menu will be drawn on screen). A caller places the box by its
/// own on-screen frame and offsets every item rect by that frame's origin —
/// see `SceneRenderer.dropdownFrame(_:geometry:)`.
public struct MenuGeometry: Equatable, Sendable {
    /// One item's rect, in the field order the MDEF filled and the guest's
    /// wire carries it — `top, left, bottom, right` — so nothing here
    /// reorders a QuickDraw `Rect` into a caller's own convention.
    public struct ItemRect: Equatable, Sendable {
        public let top: Int
        public let left: Int
        public let bottom: Int
        public let right: Int

        public init(top: Int, left: Int, bottom: Int, right: Int) {
            self.top = top
            self.left = left
            self.bottom = bottom
            self.right = right
        }

        public var height: Int { bottom - top }
        public var width: Int { right - left }
    }

    /// The guest's own menu id — `Scene.Menu.id`, not a title.
    public let menu: Int
    /// The menu's own published width/height (`(*mh)->menuWidth/menuHeight`)
    /// — the actual on-screen box size, not an estimate from title lengths.
    public let width: Int
    public let height: Int
    /// Keyed by the Menu Manager's own 1-based item index (`Scene.MenuItem
    /// .index`), NOT by array position — `menugeom` may answer fewer items
    /// than the menu has (it hit `kNowPeekActMenuItemMax`, the contract's
    /// own wording for that case, and never a truncated answer to the ones
    /// it did get), so a caller must be able to ask "do I have THIS item"
    /// rather than assume the two arrays walk in lockstep.
    private let itemsByIndex: [Int: ItemRect]

    public init(menu: Int, width: Int, height: Int,
                items: [Int: ItemRect]) {
        self.menu = menu
        self.width = width
        self.height = height
        self.itemsByIndex = items
    }

    /// Convenience for the wire seam: the guest answers items 1...count in
    /// order (`now_act_run_menugeom`'s own loop), so a caller with that flat
    /// list can hand it here and get the keyed form every consumer wants.
    public init(menu: Int, width: Int, height: Int, orderedItems: [ItemRect]) {
        var byIndex: [Int: ItemRect] = [:]
        for (offset, rect) in orderedItems.enumerated() {
            byIndex[offset + 1] = rect
        }
        self.init(menu: menu, width: width, height: height, items: byIndex)
    }

    public func rect(forItemIndex index: Int) -> ItemRect? {
        itemsByIndex[index]
    }

    /// **Usable for THIS menu, right now.** Two facts have to hold: the
    /// geometry was read for the same menu id (a stale read from a
    /// previously-open menu must not be drawn under a different one's
    /// title), and it answers for every item the scene currently reports —
    /// a partial answer (the item cap, or a menu that changed between the
    /// read and this draw) falls back to the uniform assumption entirely
    /// rather than mixing real rects with invented ones for the items it
    /// does not have.
    public func matches(_ scene: Scene.Menu) -> Bool {
        guard menu == scene.id else { return false }
        return scene.items.allSatisfy { itemsByIndex[$0.index] != nil }
    }
}
