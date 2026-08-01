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

        /// The Application menu at the right of the bar — the app switcher.
        case appMenu

        /// A row in the open Application menu: switching apps is `activate`,
        /// which names a process rather than a place on screen.
        case appMenuItem(psn: String, name: String)
        /// A title-bar widget on the front window — actuated by a real
        /// press-release at its center (TrackGoAway/TrackBox are tracking
        /// loops; the wire can't drive them, QMP can).
        case widget(windowID: String, kind: WidgetKind, x: Int, y: Int)
        /// The grow box: drag = resize (GrowWindow, same tracking story).
        case growBox(windowID: String, x: Int, y: Int)
        /// A control inside a window (visible controls only — invisible
        /// controls don't exist on the real screen).
        case control(windowID: String, control: Scene.Control)
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

    /// The topmost desktop icon containing this point, if any. Later items win,
    /// matching the draw order (the renderer paints them in list order, so the
    /// last one drawn is the one visibly on top).
    public static func desktopItem(_ scene: Scene, x: Int, y: Int)
        -> Scene.DesktopItem? {
        guard let items = scene.desktopItems else { return nil }
        var hit: Scene.DesktopItem?
        for item in items where item.placed && !item.invisible {
            if x >= item.x, x < item.x + iconSize,
               y >= item.y, y < item.y + iconSize + iconLabelHeight {
                hit = item
            }
        }
        return hit
    }

    /// The apps the Application menu lists.
    ///
    /// Not every process: the guest runs faceless background things (the agent
    /// itself, `tbt-worker`, Control Strip Extension) that the real Application
    /// menu does not show either. An app earns a row by having a window, or by
    /// being frontmost — which is the closest we get to "has a user interface"
    /// from what the scene carries.
    public static func switchableApps(_ scene: Scene) -> [Scene.AppRef] {
        let withWindows = Set(scene.windows.map(\.psn))
        return scene.apps.filter { $0.front || withWindows.contains($0.psn) }
    }

    /// Right-aligned Application menu: icon plus name, at the far right of the
    /// bar, with the clock to its left — the OS 9 order.
    public static func appMenuWidth(_ scene: Scene) -> Int {
        let name = scene.apps.first(where: { $0.front })?.name ?? ""
        return 24 + name.count * 6 + 10
    }

    /// Width of the open switcher, sized to its longest app name.
    public static func appMenuDropdownWidth(_ scene: Scene) -> Int {
        let longest = switchableApps(scene).map(\.name.count).max() ?? 0
        return max(140, 40 + longest * 6 + 12)
    }

    /// A row in the open Application menu, by pointer position.
    public static func appMenuRow(_ scene: Scene, x: Int, y: Int)
        -> Scene.AppRef? {
        let apps = switchableApps(scene)
        let width = appMenuDropdownWidth(scene)
        let left = scene.screen.w - width
        guard x >= left, y >= menubarHeight else { return nil }
        let row = (y - menubarHeight - 2) / 16
        guard row >= 0, row < apps.count else { return nil }
        return apps[row]
    }

    public static func hitTest(_ scene: Scene, x: Int, y: Int) -> Target {
        if y >= 0, y < menubarHeight,
           x >= scene.screen.w - appMenuWidth(scene) {
            return .appMenu
        }
        // The menubar strip resolves against the wire's MenuList lefts:
        // a title's span runs from its left to the next title's left.
        if y >= 0, y < menubarHeight, let menus = scene.menubar?.menus,
           !menus.isEmpty {
            for (i, menu) in menus.enumerated() where x >= menu.left {
                let next = i + 1 < menus.count
                    ? menus[i + 1].left : menu.left + 60
                if x < next {
                    return .menuTitle(index: i)
                }
            }
        }
        // Windows front-to-back; the desktop backdrop and invisible windows
        // aren't on the screen the user sees.
        for win in scene.windows
        where win.visible && !isDesktopBackdrop(win) && contains(win.rect, x, y) {
            // Title bar strip (real windows only; dialogs draw none).
            if win.kind != 2, y < win.rect.t + titlebar {
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
            // Controls carry content-local rects; content origin is the
            // window box's top-left pushed below the title bar.
            let cx = x - win.rect.l
            let cy = y - (win.rect.t + titlebar)
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
