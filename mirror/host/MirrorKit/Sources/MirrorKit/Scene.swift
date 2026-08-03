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
        /// The act-plane reference this window actuates through - the same
        /// symmetry invariant `Control.ref` carries, one level up.
        ///
        /// **The producer has always sent it and this model dropped it**,
        /// which is why no window has ever been closable, movable or
        /// resizable from a mirror: every act addressed by reference needs
        /// one, and a windowID (`psn + title + occurrence`) is a rendering
        /// key that nothing on a guest can resolve. The archived NOW port
        /// recorded the same drop one layer further out and stopped there.
        ///
        /// Optional because a producer may honestly have none: NOW's own
        /// Carbon window is not readable at the classic offsets, so it
        /// reports no reference rather than a fabricated one.
        public var ref: String? = nil
        /// The window record's own address on the guest, when the producer
        /// could say.
        ///
        /// Carried for ONE reason: it is the only exact join key between a
        /// scene and the machine it describes. `id` is a rendering key that
        /// moves when the title or the stacking moves, titles collide, and
        /// a modal alert has none — so a structural differ keyed on any of
        /// them mis-joins, and a mis-join is indistinguishable from a real
        /// mismatch. Nothing renders from this; it exists so a harness can
        /// say *which* window it is comparing.
        public var addr: UInt32? = nil
        /// Dialog TextEdit content (`kind==2` windows only today).
        public var text: TextContent?
        /// Icon-view items for a Finder window, in WINDOW-LOCAL content
        /// coords — the Finder's own live `position of`, which is scroll-
        /// compensated (`FinderItems`). nil when not fetched, or when the
        /// window is not a resolvable Finder folder window.
        ///
        /// **Additive within IR v1** (`IRSchema.v1Additions`, lane H2
        /// 2026-07-31). It was held out of the v1 freeze because the only
        /// source then available was `fdLocation`, the SAVED icon grid, whose
        /// values are wrong the moment the Finder lays a window out or scrolls
        /// it — and freezing a field whose values are known wrong obliges us
        /// to keep serving the wrong number. It re-enters now that the
        /// positions are the Finder's own, verified by clicking a computed
        /// point and being told the right file was selected. No major bump:
        /// a consumer that has never heard of the key ignores it.
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
            case items          // additive in v1 — see the declaration
            case ref            // additive in v1 — see the declaration
            case addr           // additive in v1 — see the declaration
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
        /// Whether a checkbox-like control is on.
        ///
        /// **Decodes to false when absent**, and that tolerance is
        /// deliberate rather than lax. A producer that reads a
        /// ControlRecord without its defProc cannot say what KIND of
        /// control it has, and `checked` is meaningless without that -
        /// NOW's scene walk says exactly this and refuses to emit the
        /// key rather than assert a fact it cannot know. Requiring it
        /// made an otherwise complete and correct IR v1 document
        /// undecodable over one field nobody could honestly fill.
        ///
        /// Absent therefore means "not known to be checked", which is
        /// what false already meant for every control that is not a
        /// checkbox. A producer that CAN determine it still sends it.
        public var checked: Bool = false

        /* Declaring an initialiser suppresses the compiler's memberwise
           one, and SceneBuilder builds these by hand - so it is restored
           verbatim rather than left to be discovered as a type-check
           timeout in another file. */
        public init(ref: String, role: String, title: String,
                    rect: Rect? = nil, enabled: Bool, visible: Bool,
                    value: Int? = nil, min: Int? = nil, max: Int? = nil,
                    checked: Bool = false) {
            self.ref = ref
            self.role = role
            self.title = title
            self.rect = rect
            self.enabled = enabled
            self.visible = visible
            self.value = value
            self.min = min
            self.max = max
            self.checked = checked
        }

        /* Swift's synthesised Decodable demands every non-optional key
           whether or not the property has a default, so the tolerance
           above needs saying out loud. Everything else decodes exactly as
           the synthesised initialiser would. */
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try c.decode(String.self, forKey: .ref)
            role = try c.decode(String.self, forKey: .role)
            title = try c.decode(String.self, forKey: .title)
            rect = try c.decodeIfPresent(Rect.self, forKey: .rect)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            visible = try c.decode(Bool.self, forKey: .visible)
            value = try c.decodeIfPresent(Int.self, forKey: .value)
            min = try c.decodeIfPresent(Int.self, forKey: .min)
            max = try c.decodeIfPresent(Int.self, forKey: .max)
            checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
        }
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

        /// Public because a HOST may know icons the guest's own walk
        /// cannot: NOW reads the Toolbox's windows, controls and menus,
        /// and a Finder icon is none of those - it is a file the Finder
        /// draws, and only the Finder knows where. Those arrive over
        /// AppleScript and are merged into the scene on this side.
        public init(name: String, kind: String, type: String?,
                    creator: String?, x: Int, y: Int, placed: Bool,
                    alias: Bool, invisible: Bool) {
            self.name = name; self.kind = kind; self.type = type
            self.creator = creator; self.x = x; self.y = y
            self.placed = placed; self.alias = alias
            self.invisible = invisible
        }
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
