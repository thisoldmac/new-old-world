import Foundation

/// Scene-geometry hit-testing: a point in guest coordinates → the semantic
/// element under it. Lives in the renderer-free core (plan invariant): the
/// renderer maps pixels→elements only through this, so both heads resolve
/// clicks identically.
///
/// The one renderer-owned geometry is the menubar (its title extents depend
/// on text measurement) — the UI passes its drawn title boxes in via
/// `menubarBoxes`; headless callers address menus semantically instead.
public enum HitTester {

    public typealias WidgetKind = WindowChrome.Widget

    public enum Target: Equatable {
        /// A menubar title (resolved from the wire's MenuList `left`s).
        case menuTitle(index: Int)

        /// Menubar chrome for which the guest supplied no menu. This is
        /// deliberately distinct from the desktop: an unreported Apple menu
        /// or Application menu must not turn into invented controls or a
        /// Finder click merely because both occupy a known global position.
        case menubarBackground
        /// A title-bar widget on the front window — actuated by a real
        /// press-release at its center (TrackGoAway/TrackBox are tracking
        /// loops; the semantic wire can't drive them, positioned input can).
        case widget(windowID: String, kind: WidgetKind, x: Int, y: Int)
        /// The grow box: drag = resize (GrowWindow, same tracking story).
        case growBox(windowID: String, x: Int, y: Int)
        /// A control inside a window (visible controls only — invisible
        /// controls don't exist on the real screen).
        case control(windowID: String, control: Scene.Control)
        /// A live Dialog Manager item. It stays distinct from the same
        /// item's ControlRecord: a dialog press is routed through the
        /// application's Dialog Manager path, not guessed into TrackControl.
        case dialogItem(windowID: String, item: Scene.DialogItem)
        /// A live scrollbar, resolved to the region under the point — pressing
        /// an arrow, a page gap, or the thumb are three different guest
        /// actions, so the part is the target, not the control. Carries the
        /// global press point (the Control Manager tracks the real mouse).
        case scrollbar(windowID: String, control: Scene.Control,
                       part: Scrollbar.Part, x: Int, y: Int)
        /// A real title bar (kind==2 dialogs have none). Carries the click
        /// point so a single click can raise the window via a real click.
        case titlebar(windowID: String, psn: String, x: Int, y: Int)
        /// Window body: the guest point, plus whether the window is front
        /// (a click on a background window activates first).
        case content(windowID: String, psn: String, front: Bool,
                     x: Int, y: Int)
        /// Nothing but desktop under the point.
        case desktop(x: Int, y: Int)

        /// An icon inside a Finder folder window, hit by NAME. Same discipline
        /// as `desktopItem`: the click point is the icon's OWN centre, from
        /// the Finder's live `position of`, not wherever the pointer landed.
        case windowItem(windowID: String, name: String, x: Int, y: Int)

        /// A desktop icon, hit by NAME rather than by where the pointer landed.
        /// The click still goes to the guest as a coordinate — the Finder has no
        /// other way in for icons — but it is computed from the icon's OWN
        /// position, so it lands on the icon's centre rather than wherever the
        /// user happened to click inside its box.
        case desktopItem(name: String, x: Int, y: Int)
    }

    /// Guest title-bar height (the scene's window rect is the content port
    /// grown up by this much — SceneBuilder.titleBarHeight).
    public static let titlebar = SceneBuilder.titleBarHeight

    /// Guest menubar height. Widget/grow geometry lives in WindowChrome.
    public static let menubarHeight = 20
    /// Extra catch margin around the small title-bar widgets so an
    /// on-the-pixel click near the box still lands (the boxes are 11 px).
    static let widgetGrow = 3

    /// Icon box, matching the renderer's own geometry. The label sits under the
    /// icon and is part of the target: clicking a name selects the item, which
    /// is how the Finder behaves.
    public static let iconSize = 32
    public static let iconLabelHeight = 12

    /// The box that selects a Finder item, from whatever the item carries.
    ///
    /// **The size is the Finder's own `bounds`, not a constant.** An icon-view
    /// icon is 32×32; a list-view row's icon and a small-icon-view icon are
    /// 16×16 (measured 2026-08-07, mac99 / OS 9.1 — see `FinderItems`). An
    /// item with no size at all is one whose producer never asked, and it
    /// keeps the 32×32 every reader assumed before the field existed.
    ///
    /// **The label is added BELOW and only below.** A name drawn under an
    /// icon is part of the target — clicking it selects, which is what the
    /// Finder does — and that is the icon view's arrangement. A list or
    /// small-icon row draws its name BESIDE the icon instead, and the Finder
    /// does not measure that text for us, so the row's target is the icon
    /// alone. That under-claims: it costs a click that must land on the icon.
    /// Guessing the text's width would over-claim, and an over-claimed box in
    /// a 19-pixel row pitch is a click that selects the wrong file.
    public static func targetSize(_ item: Scene.DesktopItem) -> (w: Int, h: Int) {
        guard let w = item.w, let h = item.h, w > 0, h > 0 else {
            return (iconSize, iconSize + iconLabelHeight)
        }
        return (w, h >= iconSize ? h + iconLabelHeight : h)
    }

    /// The topmost desktop icon containing this point, if any. Later items win,
    /// matching the draw order (the renderer paints them in list order, so the
    /// last one drawn is the one visibly on top).
    public static func desktopItem(_ scene: Scene, x: Int, y: Int)
        -> Scene.DesktopItem? {
        guard let items = scene.desktopItems else { return nil }
        var hit: Scene.DesktopItem?
        for item in items where item.placed && !item.invisible {
            let box = targetSize(item)
            if x >= item.x, x < item.x + box.w,
               y >= item.y, y < item.y + box.h {
                hit = item
            }
        }
        return hit
    }

    /// The topmost icon in a Finder folder window containing this GLOBAL
    /// point, if any. Later items win, matching the draw order.
    ///
    /// Icon view uses the icon and its label. Name view is a semantic list:
    /// the full visible row is the item, not merely the 16x16 glyph at its
    /// leading edge. An item whose centre is scrolled out of the visible icon
    /// field is not a target at all; `FinderItems.clickPoint` is the authority
    /// on that and the caller checks it.
    public static func windowItem(_ win: Scene.Window, x: Int, y: Int)
        -> Scene.DesktopItem? {
        let origin = FinderItems.contentOrigin(win)
        let cx = x - origin.x, cy = y - origin.y
        var hit: Scene.DesktopItem?
        for target in FinderItems.itemTargetRects(win) {
            if contains(target.rect, cx, cy) {
                hit = target.item
            }
        }
        return hit
    }

    /// **What the Application menu offers**, which must always include
    /// the Finder.
    ///
    /// This used to be "front, or has a window", read from `apps` alone.
    /// Watched 2026-08-03 with NOW in front: the switcher listed one
    /// application and the Finder was not in it, so a person could not
    /// reach the Finder from the mirror at all - and clicking the desktop
    /// did not front it either, which is the other half of the same
    /// stranding.
    ///
    /// The desktop's owner is always offered, and the roster falls back to
    /// `processes` for a qualifying application `apps` does not mention. It
    /// does not offer every process: the guest also runs faceless background
    /// things (the agent, worker, and system schedulers) which the Macintosh's
    /// Application menu does not show.
    public static func switchableApps(_ scene: Scene) -> [Scene.AppRef] {
        let withWindows = Set(scene.windows.map(\.psn))
        let desktop = scene.windows.first(where: isDesktopBackdrop)?.psn
        var out: [Scene.AppRef] = []
        var seen = Set<String>()

        func offer(_ app: Scene.AppRef) {
            guard !seen.contains(app.psn) else { return }
            seen.insert(app.psn)
            out.append(app)
        }

        for app in scene.apps
        where app.front || withWindows.contains(app.psn)
            || app.psn == desktop {
            offer(app)
        }
        for proc in scene.processes ?? []
        where proc.front || withWindows.contains(proc.psn)
            || proc.psn == desktop {
            offer(.init(psn: proc.psn, name: proc.name, front: proc.front,
                        error: nil))
        }
        return out
    }

    /// Right-aligned Application menu: icon plus name, at the far right of the
    /// bar, with the clock to its left — the OS 9 order.
    public static func appMenuWidth(_ scene: Scene) -> Int {
        /* The live MenuList carries this right-aligned menu's actual left
           edge. Prefer it for both drawing and hit-testing: character-count
           estimates moved the clock and switcher roughly 30 px right of the
           authoritative guest when New Old World was frontmost. A zero left
           remains the legacy/incomplete-scene fallback. */
        if let left = scene.menubar?.menus.first(where: {
            $0.id == ObjectResolver.applicationMenuID
        })?.left, left > 0, left < scene.screen.w {
            return scene.screen.w - left
        }
        let name = scene.apps.first(where: { $0.front })?.name ?? ""
        return 24 + name.count * 6 + 10
    }

    /// The Application menu as the GUEST has it, when the scene carries
    /// it. Its id is the system's (-16489) and its items are the real
    /// ones: Hide <app>, Hide Others, Show All, a separator, then the
    /// running applications.
    ///
    /// Preferring it over the mirror's own synthesised switcher is what
    /// gets the hide/show commands at all - a list rebuilt from `apps`
    /// can only ever offer the applications, and those three rows are
    /// half of what the menu is for.
    public static func applicationMenuIndex(_ scene: Scene) -> Int? {
        scene.menubar?.menus.firstIndex { $0.id == ObjectResolver.applicationMenuID }
    }

    public static func hitTest(_ scene: Scene, x: Int, y: Int) -> Target {
        if y >= 0, y < menubarHeight,
           x >= scene.screen.w - appMenuWidth(scene) {
            /* Only the guest's own Application menu is a control. A locally
               synthesised app list collided with this menu and silently
               dropped Hide / Hide Others / Show All whenever foreign scene
               collection was incomplete. Missing guest state is inert. */
            if let index = applicationMenuIndex(scene) {
                return .menuTitle(index: index)
            }
            return .menubarBackground
        }
        // The menubar strip resolves against the wire's MenuList lefts:
        // a title's span runs from its left to the next title's left.
        //
        // A menu the producer never placed claims NO span. It used to
        // claim the leftmost one, because an absent `left` arrived as 0,
        // so it stole the Apple menu's clicks - the same substitution
        // that let a menu act arm on the Apple menu's title.
        if y >= 0, y < menubarHeight, let menus = scene.menubar?.menus,
           !menus.isEmpty {
            let placed = menus.enumerated().compactMap {
                (i, m) -> (index: Int, left: Int)? in
                guard m.id != ObjectResolver.applicationMenuID,
                      let left = m.left else { return nil }
                return (i, left)
            }
            for (n, entry) in placed.enumerated() where x >= entry.left {
                let next = placed.dropFirst(n + 1)
                    .filter { $0.left > entry.left }
                    .map(\.left).min() ?? (entry.left + 60)
                if x < next {
                    return .menuTitle(index: entry.index)
                }
            }
        }
        if y >= 0, y < menubarHeight {
            return .menubarBackground
        }
        // Windows front-to-back; the desktop backdrop and invisible windows
        // aren't on the screen the user sees.
        for win in scene.windows
        where win.visible && !isDesktopBackdrop(win) && contains(win.rect, x, y) {
            // Title bar strip (real windows only; dialogs draw none).
            /* Same rule the renderer uses: `kind` says who OWNS the
               window, not what it looks like, and a titled dialog has a
               real title bar. Keeping these two in step matters more
               than either being right on its own - when they disagreed,
               a control drew 11 pixels above where it could be hit. */
            if WindowChrome.hasTitleBar(win),
               y < win.rect.t + titlebar {
                if let target = widgetHit(win, x, y) {
                    return target
                }
                return .titlebar(windowID: win.id, psn: win.psn, x: x, y: y)
            }
            // The grow box: bottom-right corner of the front document window.
            if let grow = WindowChrome.growBox(win),
               WindowChrome.contains(grow, x, y) {
                let c = WindowChrome.center(grow)
                return .growBox(windowID: win.id, x: c.x, y: c.y)
            }
            /* Controls carry content-local rects; the content origin is
               `WindowChrome`'s, which is the SAME number the renderer
               draws from. It used to be spelled out here as "the window
               box pushed below the title bar", which is only true of a
               window that has one — see WindowChrome.contentOrigin for
               the fourteen pixels that cost a modal nobody could
               dismiss. */
            let origin = WindowChrome.contentOrigin(win)
            let cx = x - origin.x
            let cy = y - origin.y
            // DITL items are drawn over the structural ControlRecord chain,
            // and later items are drawn over earlier ones. Hit in that same
            // order. Date & Time's Date Formats button occupied the same box
            // as a low-level record; testing controls first made the visible
            // button resolve as an unknown control and every click refuse.
            //
            // Topmost, but ANSWERABLE first. An alert's default-outline slot
            // is a user item laid over the button it outlines and declared
            // after it, so plain topmost resolves the click to an item with
            // no action and no reference — and the mirror refuses a button
            // that works. Internet Explorer's Error alert, captured
            // 2026-08-06: item 7 is a user item over item 1's OK, and
            // `ditemact` on item 1 dismissed the alert while every click in
            // the mirror did nothing.
            let items = (win.dialogItems ?? []).reversed().filter {
                $0.visible && contains($0.rect, cx, cy)
            }
            if let answerable = items.first(where: {
                $0.semantic.action != nil
            }) ?? items.first {
                return .dialogItem(windowID: win.id, item: answerable)
            }
            for ctl in win.controls where ctl.visible {
                if let r = ctl.rect, contains(r, cx, cy) {
                    // A live scrollbar resolves to the region pressed: the
                    // guest does something different for each.
                    if let part = Scrollbar.part(ctl, atX: cx, y: cy) {
                        return .scrollbar(windowID: win.id, control: ctl,
                                          part: part, x: x, y: y)
                    }
                    return .control(windowID: win.id, control: ctl)
                }
            }
            // Finder folder icons, under the controls (a scrollbar drawn over
            // the icon field is still a scrollbar) and over the bare content.
            if let item = windowItem(win, x: x, y: y),
               let p = FinderItems.clickPoint(item, in: win) {
                return .windowItem(windowID: win.id, name: item.name,
                                   x: p.x, y: p.y)
            }
            return .content(windowID: win.id, psn: win.psn,
                            front: win.front, x: x, y: y)
        }
        // Desktop icons sit on the backdrop, behind every window — so they are
        // tested only once nothing else has claimed the point.
        if let item = desktopItem(scene, x: x, y: y) {
            return .desktopItem(name: item.name,
                                x: item.x + Self.iconSize / 2,
                                y: item.y + Self.iconSize / 2)
        }
        return .desktop(x: x, y: y)
    }

    /// Title-bar widgets on the active window, from WindowChrome (the same
    /// boxes the renderer draws) with a small catch margin. Nearest-box
    /// wins when the margins of two boxes overlap.
    private static func widgetHit(_ win: Scene.Window,
                                  _ x: Int, _ y: Int) -> Target? {
        var best: (kind: WidgetKind, box: Rect, d: Int)?
        for kind in WindowChrome.Widget.allCases {
            guard let box = WindowChrome.widgetBox(win, kind),
                  WindowChrome.contains(box, x, y, grow: widgetGrow) else {
                continue
            }
            let c = WindowChrome.center(box)
            let d = abs(c.x - x) + abs(c.y - y)
            if best == nil || d < best!.d { best = (kind, box, d) }
        }
        guard let best else { return nil }
        let c = WindowChrome.center(best.box)
        return .widget(windowID: win.id, kind: best.kind, x: c.x, y: c.y)
    }

    /// The Finder window that IS the desktop. Match on identity, NOT kind:
    /// Finder folder windows are ALSO kind 20, so a kind check hides every
    /// open Finder window. The desktop is the one titled "Desktop".
    public static func isDesktopBackdrop(_ win: Scene.Window) -> Bool {
        win.app == "Finder" && win.title == "Desktop"
    }

    private static func contains(_ r: Rect, _ x: Int, _ y: Int) -> Bool {
        x >= r.l && x < r.r && y >= r.t && y < r.b
    }
}
