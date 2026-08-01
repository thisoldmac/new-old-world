import Foundation

/// The scene IR — the mirror's answer to "what's on the guest screen".
///
/// Port source: `prototypes/mirror/scene.py` (schema v0), which retires into
/// the golden-fixture oracle once this port passes its fixtures.
///
/// **FROZEN AT v1** (2026-07-31, MIRRORKIT-PLAN decision 5 — the parity gate).
/// The encoded field set is enumerated in `IRSchema` and asserted by
/// `IRFreezeTests`: adding or removing a field here turns the suite red. New
/// fields are additive within v1 (record them in `IRSchema.v1Additions`);
/// removing or renaming one moves `IR.version`. See `IRVersion.swift`.
///
/// Two properties are deliberately **outside** the frozen IR and are excluded
/// from `Codable` — `Window.island` and `Window.items`. Reasons at their
/// declarations.
public struct Scene: Codable, Equatable, Sendable {
    /// IR version stamp — the body's self-stamp, the same number the service
    /// puts in `result["irVersion"]`. Always `IR.version`; the fixture corpus
    /// is pinned to it.
    public var version: Int
    /// Monotonically increasing per poller run.
    public var seq: Int
    /// "axtree" | "observe" (| "mock" in the spike).
    public var source: String
    /// Host epoch seconds at capture. Injected, not sampled, so scene
    /// building is a pure function (and fixture-testable).
    public var capturedAt: Double
    public var screen: ScreenSize
    public var apps: [AppRef]
    /// The real cross-process Process Manager truth — only the observe plane
    /// fills this shelf today.
    public var processes: [ProcessRef]?
    /// Front app's menubar, or nil (observe plane, or no menus on the wire).
    public var menubar: Menubar?
    /// Global stacking order, index 0 = frontmost.
    public var windows: [Window]
    /// Desktop icons from the Desktop Folder's Finder Info (fdLocation) —
    /// a semantic layer, not pixels. nil when not fetched this poll.
    public var desktopItems: [DesktopItem]?
    public var meta: Meta

    public struct ScreenSize: Codable, Equatable, Sendable {
        public var w: Int
        public var h: Int
        public init(w: Int, h: Int) { self.w = w; self.h = h }
    }

    public struct AppRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        /// Per-app oracle error (`ax_oracle_*`), surfaced honestly.
        public var error: String?
    }

    public struct ProcessRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        public var signature: String
    }

    public struct Menubar: Codable, Equatable, Sendable {
        public var app: String
        public var menus: [Menu]
    }

    public struct Menu: Codable, Equatable, Sendable {
        /// Empty for the Apple menu (the wire sends the Chicago apple byte).
        public var title: String
        public var apple: Bool
        /// Guest menubar x of this title (MenuList `left`) — the anchor for
        /// guest-true menubar layout and for the QMP menu-drag.
        public var left: Int
        /// The guest's own menu ID. Carried because acting by IDENTITY needs it:
        /// the Portal answers the application's MenuSelect with (menuID, item),
        /// and a title is not an identity the Menu Manager understands.
        public var id: Int
        public var items: [MenuItem]
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String
        /// 1-based Menu Manager item index — the row the guest will draw
        /// this item at when the menu opens (menu-drag targeting).
        public var index: Int
        public var separator: Bool
        public var enabled: Bool
        public var mark: Bool
        /// ⌘-shortcut character, or "" — actuation sends the KEYCODE, not
        /// this char (Finder matches on keycode; CONTROL-SURFACE.md).
        public var cmd: String
    }

    public struct Window: Codable, Equatable, Sendable {
        /// Stable-ish: psn + title + occurrence index.
        public var id: String
        public var app: String
        public var psn: String
        public var title: String
        public var kind: Int?
        /// Rendered box in global px — content port grown upward by the
        /// title-bar height.
        public var rect: Rect
        /// Frontmost window of the front app.
        public var front: Bool
        public var z: Int
        /// The Window Manager's visible flag, honestly carried — renderers
        /// and action models decide what to do with an invisible window.
        public var visible: Bool
        public var controls: [Control]
        /// Dialog TextEdit content (`kind==2` windows only today).
        public var text: TextContent?
        /// Icon-view items for a Finder window, in WINDOW-LOCAL content
        /// coords (fdLocation). nil when not fetched / not a resolvable
        /// Finder folder window.
        ///
        /// **Not in the frozen IR (v1).** `ScenePoller.includeWindowItems`
        /// ships `false` because these positions are *not guest-accurate* yet
        /// (Lane H2 owns making them true), and no fixture covers them.
        /// Freezing a field whose values are known wrong is the expensive
        /// half of a contract: it obliges us to keep serving the wrong
        /// number. The renderer still reads it in-process; it re-enters the
        /// IR additively (`IRSchema.v1Additions`) when the positions are real.
        public var items: [DesktopItem]? = nil
        /// The QuickDraw content plane: draw ops captured by QDPeek
        /// (`qdtrace`), port-local coords, replayed into the content area.
        /// nil when not traced. The renderer draws it in place of the empty
        /// content rect.
        public var display: [DisplayOp]?
        /// M3 pixel island: this window's content area as the guest's REAL
        /// pixels, for content with no semantics to read — the Finder
        /// composites its icon views offscreen and blits them in, so their
        /// icons exist only as pixels (finding
        /// `finder-window-icons-are-offscreen-blits`). When set it IS the
        /// content: the renderer draws it instead of the op replay, and the
        /// chrome around it stays semantic. Fetched on change, cached between.
        ///
        /// **Not in the frozen IR (v1).** It has never been on the wire:
        /// `Serve.sceneMethod` nils every island before encoding, because
        /// island pixels ride their own pager, not the scene. This is
        /// host-internal render state that happens to live on the same
        /// struct — freezing it would put a base64 RGBA blob in an
        /// interchange contract no consumer has ever received.
        public var island: PixelIsland? = nil

        /// The frozen IR is everything except the two host-internal shelves
        /// above. Listing the keys explicitly is also what makes an
        /// accidentally-added property fail to encode silently: a new field
        /// must be named here to reach the wire, and named in `IRSchema` to
        /// pass the freeze gate.
        enum CodingKeys: String, CodingKey {
            case id, app, psn, title, kind, rect, front, z, visible
            case controls, text, display
        }
    }

    public struct Control: Codable, Equatable, Sendable {
        /// The ax2 ref this control actuates through — the symmetry invariant.
        public var ref: String
        /// "control", or "scrollbar" when ranged.
        public var role: String
        public var title: String
        /// Content-relative rect for rendering; nil when the wire had none.
        public var rect: Rect?
        public var enabled: Bool
        /// Hidden controls (e.g. a closed drawer's sliders) are carried,
        /// not dropped — `axdo` refuses them anyway (`not_actionable`).
        public var visible: Bool
        public var value: Int?
        public var min: Int?
        public var max: Int?
        public var checked: Bool
    }

    public struct TextContent: Codable, Equatable, Sendable {
        public var content: String
        public var active: Bool
    }

    /// One desktop icon. Position is the saved Finder `fdLocation` in GLOBAL
    /// screen coords; `placed` is false for {0,0} (Finder auto-arranges those
    /// at draw time — the real position isn't in the catalog, so we don't
    /// invent one). `type`/`creator` key a future per-app icon; today the
    /// renderer draws a generic glyph by kind/alias.
    public struct DesktopItem: Codable, Equatable, Sendable {
        public var name: String
        /// "folder" | "file".
        public var kind: String
        public var type: String?
        public var creator: String?
        public var x: Int
        public var y: Int
        public var placed: Bool
        public var alias: Bool
        public var invisible: Bool
    }

    public struct Meta: Codable, Equatable, Sendable {
        public var latencyMs: Double?
        public var bytes: Int?
        public var errors: [String]
        /// Plane annotation (the observe plane marks itself pre-AXPeek).
        public var plane: String?
    }
}

/// A normalized rectangle in the scene's coordinate space.
public struct Rect: Codable, Equatable, Sendable {
    public var l: Int
    public var t: Int
    public var r: Int
    public var b: Int
    public var width: Int { r - l }
    public var height: Int { b - t }
    public init(l: Int, t: Int, r: Int, b: Int) {
        self.l = l; self.t = t; self.r = r; self.b = b
    }
}
