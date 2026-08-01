import Foundation

/// One request for a menu's real per-item geometry, read from its own MDEF
/// rather than assumed at a fixed row height (`contract/asyncapi.yaml
/// :menugeom`, `now-guest-ppc/src/act/act_cmds.c:now_act_run_menugeom`).
public struct AgentIntegrationMenuGeomRequest: Codable, Equatable, Sendable {
    /// The menu's id, as the scene reports it (`Scene.Menu.id`) — not a
    /// title, which is not an identity the Menu Manager understands.
    public let menu: Int
    /// The process that owns the menu. Omit both for the frontmost — the
    /// same shape `activate` and `menuAct`'s process addressing take.
    public let serialHi: Int?
    public let serialLo: Int?

    public init(menu: Int, serialHi: Int? = nil, serialLo: Int? = nil) {
        self.menu = menu
        self.serialHi = serialHi
        self.serialLo = serialLo
    }

    /// Both serials or neither — half a serial names no process, and the
    /// guest's own args refuse them apart rather than defaulting together.
    public var isWellFormed: Bool {
        (serialHi == nil) == (serialLo == nil)
    }
}

/// What the guest answered for one menu — real rects, not an assumed
/// uniform row. `width`/`height` are the menu's own published size
/// (`(*mh)->menuWidth/menuHeight`), not an estimate from title lengths.
///
/// **May carry fewer items than the menu has.** A caller that gets fewer
/// rects than the menu's item count has hit `kNowPeekActMenuItemMax` (the
/// contract's own wording), not a truncated answer to the ones it did get.
public struct AgentIntegrationMenuGeomReceipt: Codable, Equatable, Sendable {
    public let menu: Int
    public let width: Int
    public let height: Int
    /// In the guest's own answer order — item 1, item 2, … — so a caller
    /// that wants the Menu Manager's 1-based index back can derive it from
    /// position without this type guessing at one.
    public let items: [AgentIntegrationMenuItemRect]

    public init(menu: Int, width: Int, height: Int,
                items: [AgentIntegrationMenuItemRect]) {
        self.menu = menu
        self.width = width
        self.height = height
        self.items = items
    }
}

/// One item's rect, in the SAME field order the MDEF filled and the guest's
/// table stores it — `top, left, bottom, right` — so nothing here reorders
/// a QuickDraw `Rect` into a caller's own convention.
public struct AgentIntegrationMenuItemRect: Codable, Equatable, Sendable {
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
}

public typealias AgentIntegrationMenuGeomResult =
    AgentIntegrationProjectedResult<AgentIntegrationMenuGeomReceipt>
