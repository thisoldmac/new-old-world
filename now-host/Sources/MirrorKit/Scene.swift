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
///
/// ## Changed in the NOW port — a plane has three states, not two
///
/// Upstream every list here is a non-optional array with no custom
/// `init(from:)`, so Swift's synthesized decode **requires** the key. That is
/// correct for upstream's producer, which walks every plane every time and
/// therefore always emits them. It is wrong for NOW's, which omits a plane it
/// did not walk: `now-guest-ppc/src/scene/scene_json.c` writes `controls` only
/// when `controls_present`, `items` only when `items_present`, and drops the
/// whole `menubar` when the front process's menu list did not parse. A scene
/// that guest legitimately produces was **undecodable** by MirrorKit as it
/// stood — the one thing standing between our guest and this code.
///
/// So every non-optional collection below decodes **if present**, defaulting
/// to empty. And because absent, empty and populated are three different
/// claims — *"this producer does not report them"*, *"I walked and found
/// none"*, *"here they are"* — each carries a `…Present` flag beside it that
/// records which of the three arrived. The flag is not on the wire; it drives
/// `encode(to:)`, so an absent plane re-encodes absent instead of being
/// laundered into `[]` by a round trip. `NOWSceneDocument` (the host's own
/// decoder) keeps the same distinction by making the fields optional; it can,
/// because nothing renders from it. Here the renderer, the hit tester and the
/// action model all read `window.controls` as an array, and making that
/// optional would be a redesign rather than a port.
///
/// Two rules follow for anyone editing this file:
///
/// - **A new list gets the same treatment.** A bare `[T]` here is a decode
///   that fails on a producer poorer than the one it was written against.
/// - **The flag defaults to `true`.** A scene built in memory reports what it
///   holds; only a decoder that saw no key sets it false.
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
    /// False when the decoded document carried no `apps` key at all. See the
    /// three-states note in this type's header.
    public var appsPresent: Bool = true
    /// The real cross-process Process Manager truth — only the observe plane
    /// fills this shelf today.
    public var processes: [ProcessRef]?
    /// Front app's menubar, or nil (observe plane, or no menus on the wire).
    public var menubar: Menubar?
    /// Global stacking order, index 0 = frontmost.
    public var windows: [Window]
    /// False when the decoded document carried no `windows` key at all.
    public var windowsPresent: Bool = true
    /// Desktop icons from the Desktop Folder's Finder Info (fdLocation) —
    /// a semantic layer, not pixels. nil when not fetched this poll.
    public var desktopItems: [DesktopItem]?
    public var meta: Meta

    /// The wire keys. The `…Present` flags are absent from this list on
    /// purpose: they are how this decoder remembers what it was told, not
    /// something it was told.
    enum CodingKeys: String, CodingKey {
        case version, seq, source, capturedAt, screen
        case apps, processes, menubar, windows, desktopItems, meta
    }

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
        /// False when the decoded menubar carried no `menus` key. A menubar
        /// with no menus is not the same object as a menubar that declined
        /// to say — the guest drops the whole `menubar` when its menu list
        /// did not parse, but a future producer may report the bar and not
        /// its contents.
        public var menusPresent: Bool = true

        enum CodingKeys: String, CodingKey { case app, menus }
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
        /// False when this menu carried no `items` key. NOW's guest omits it
        /// per menu, not per bar: a menu whose item walk hit a bound reports
        /// nothing rather than a short list that reads as complete
        /// (`scene_json.c`, `m->items_present`).
        public var itemsPresent: Bool = true

        enum CodingKeys: String, CodingKey { case title, apple, left, id, items }
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
        /// False when this window carried no `controls` key. **This is the
        /// defect the port exists to fix**: NOW's guest omits `controls` for
        /// a window whose control walk did not run or did not complete, and
        /// upstream's synthesized decode required the key, so such a scene
        /// failed to decode at all. Empty means the walk ran and the window
        /// has none; absent means nobody looked.
        public var controlsPresent: Bool = true
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
        /// False when `meta` carried no `errors` key. An empty `errors` is a
        /// real claim — the walk finished and found nothing wrong — which is
        /// exactly why it has to stay distinguishable from silence.
        public var errorsPresent: Bool = true
        /// Plane annotation (the observe plane marks itself pre-AXPeek).
        public var plane: String?

        enum CodingKeys: String, CodingKey {
            case latencyMs, bytes, errors, plane
        }
    }
}

// MARK: - Three-state plane coding

/// Decode a list a partial producer may omit.
///
/// Returns the list and whether the key was there, which is the whole point:
/// the caller stores both, so `[]` from an empty array and `[]` from a missing
/// key stay tellable apart. Deliberately not an `Optional` accessor — every
/// consumer in this package reads these as arrays, and turning them optional
/// would be a redesign of the renderer, not a decoding fix.
private func decodePlane<K: CodingKey, T: Decodable>(
    _ container: KeyedDecodingContainer<K>,
    _ type: T.Type, forKey key: K
) throws -> (value: [T], present: Bool) {
    if let list = try container.decodeIfPresent([T].self, forKey: key) {
        return (list, true)
    }
    return ([], false)
}

/// Encode a list only when it was reported, so a round trip preserves which
/// of the three states this scene is in. Without this the first decode/encode
/// cycle would quietly promote "nobody looked" to "looked, found none".
private func encodePlane<K: CodingKey, T: Encodable>(
    _ container: inout KeyedEncodingContainer<K>,
    _ value: [T], present: Bool, forKey key: K
) throws {
    if present { try container.encode(value, forKey: key) }
}

// These live in extensions rather than in the type bodies so the memberwise
// initializers survive: declaring `init(from:)` inside a struct suppresses
// them, and every construction site in this package uses one.

extension Scene {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        seq = try c.decode(Int.self, forKey: .seq)
        source = try c.decode(String.self, forKey: .source)
        capturedAt = try c.decode(Double.self, forKey: .capturedAt)
        screen = try c.decode(ScreenSize.self, forKey: .screen)
        (apps, appsPresent) = try decodePlane(c, AppRef.self, forKey: .apps)
        processes = try c.decodeIfPresent([ProcessRef].self, forKey: .processes)
        menubar = try c.decodeIfPresent(Menubar.self, forKey: .menubar)
        (windows, windowsPresent) = try decodePlane(c, Window.self,
                                                    forKey: .windows)
        desktopItems = try c.decodeIfPresent([DesktopItem].self,
                                             forKey: .desktopItems)
        meta = try c.decode(Meta.self, forKey: .meta)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(seq, forKey: .seq)
        try c.encode(source, forKey: .source)
        try c.encode(capturedAt, forKey: .capturedAt)
        try c.encode(screen, forKey: .screen)
        try encodePlane(&c, apps, present: appsPresent, forKey: .apps)
        try c.encodeIfPresent(processes, forKey: .processes)
        try c.encodeIfPresent(menubar, forKey: .menubar)
        try encodePlane(&c, windows, present: windowsPresent, forKey: .windows)
        try c.encodeIfPresent(desktopItems, forKey: .desktopItems)
        try c.encode(meta, forKey: .meta)
    }
}

extension Scene.Menubar {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        app = try c.decode(String.self, forKey: .app)
        (menus, menusPresent) = try decodePlane(c, Scene.Menu.self,
                                                forKey: .menus)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(app, forKey: .app)
        try encodePlane(&c, menus, present: menusPresent, forKey: .menus)
    }
}

extension Scene.Menu {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        apple = try c.decode(Bool.self, forKey: .apple)
        left = try c.decode(Int.self, forKey: .left)
        id = try c.decode(Int.self, forKey: .id)
        (items, itemsPresent) = try decodePlane(c, Scene.MenuItem.self,
                                                forKey: .items)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encode(apple, forKey: .apple)
        try c.encode(left, forKey: .left)
        try c.encode(id, forKey: .id)
        try encodePlane(&c, items, present: itemsPresent, forKey: .items)
    }
}

extension Scene.Window {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        app = try c.decode(String.self, forKey: .app)
        psn = try c.decode(String.self, forKey: .psn)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decodeIfPresent(Int.self, forKey: .kind)
        rect = try c.decode(Rect.self, forKey: .rect)
        front = try c.decode(Bool.self, forKey: .front)
        z = try c.decode(Int.self, forKey: .z)
        visible = try c.decode(Bool.self, forKey: .visible)
        (controls, controlsPresent) = try decodePlane(c, Scene.Control.self,
                                                      forKey: .controls)
        text = try c.decodeIfPresent(Scene.TextContent.self, forKey: .text)
        display = try c.decodeIfPresent([DisplayOp].self, forKey: .display)
        items = try c.decodeIfPresent([Scene.DesktopItem].self, forKey: .items)
        // Host-internal render state, never on the wire. See its declaration.
        island = nil
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(app, forKey: .app)
        try c.encode(psn, forKey: .psn)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(rect, forKey: .rect)
        try c.encode(front, forKey: .front)
        try c.encode(z, forKey: .z)
        try c.encode(visible, forKey: .visible)
        try encodePlane(&c, controls, present: controlsPresent,
                        forKey: .controls)
        try c.encodeIfPresent(text, forKey: .text)
        try c.encodeIfPresent(display, forKey: .display)
        try c.encodeIfPresent(items, forKey: .items)
    }
}

extension Scene.Meta {
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        latencyMs = try c.decodeIfPresent(Double.self, forKey: .latencyMs)
        bytes = try c.decodeIfPresent(Int.self, forKey: .bytes)
        (errors, errorsPresent) = try decodePlane(c, String.self,
                                                  forKey: .errors)
        plane = try c.decodeIfPresent(String.self, forKey: .plane)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(latencyMs, forKey: .latencyMs)
        try c.encodeIfPresent(bytes, forKey: .bytes)
        try encodePlane(&c, errors, present: errorsPresent, forKey: .errors)
        try c.encodeIfPresent(plane, forKey: .plane)
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
