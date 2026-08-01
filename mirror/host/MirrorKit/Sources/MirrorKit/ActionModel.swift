import Foundation

/// The semantic action vocabulary: what the mirror can DO to the guest,
/// element-first. Every gesture resolves to a list of these; the dispatcher
/// turns them into wire verbs (or the QMP drag plane).
public enum MirrorAction: Equatable {
    /// Semantic, fail-closed click on a resolved control.
    case axdo(ref: String, count: Int = 1, mods: Int = 0, text: String? = nil)
    /// Keystroke. Menu shortcuts MUST carry the virtual keycode — Finder's
    /// MenuEvent matches the code, not the char (CONTROL-SURFACE.md).
    case key(code: Int, char: Int, mods: Int)
    /// Type ASCII text into the current focus.
    case type(text: String)
    /// Bring a process forward (PSN as the scene's "hi.lo" string).
    case activate(psn: String)
    /// Positional click at a guest point (front app receives it).
    case click(x: Int, y: Int, count: Int = 1, mods: Int = 0)
    /// Press-move-release, positioned closed-loop over QMP. Drives
    /// DragWindow/GrowWindow tracking loops the wire can't. EMU-ONLY.
    case drag(x0: Int, y0: Int, x1: Int, y1: Int)
    /// A real hardware press-release at a point via QMP — for the title-bar
    /// widget tracking loops (TrackGoAway/TrackBox). EMU-ONLY.
    case qmpClick(x: Int, y: Int)
    /// A real hardware double-click at a point via QMP — two rapid
    /// press-releases without repositioning between, so the guest sees a
    /// genuine double-click (opens icons). EMU-ONLY.
    case qmpDoubleClick(x: Int, y: Int)
    /// Select a shortcut-less menu item: press on the menubar title, drag
    /// down the guest-drawn menu to the item row, release. EMU-ONLY.
    case menuDrag(menuLeft: Int, itemIndex: Int)

    /// Perform a menu command through the Portal: the guest's in-process agent
    /// answers the application's own MenuSelect with this item, so the app runs
    /// its real command handler. No menu is drawn, no tracking loop runs, and
    /// no QMP is involved — which is what makes it metal-shaped where the drag
    /// below is emulator-only. This is the path for a shortcut-less item; a ⌘
    /// item should still go as a keystroke, which needs no patch at all.
    case menuInvoke(menuID: Int, itemIndex: Int, titleLeft: Int)
    /// A scrollbar thumb drag. Distinct from `drag` because the DROP POSITION
    /// is the value: TrackControl live-tracks the thumb, so this needs the
    /// precise (unity-compensated) motion a menu drag needs — the 1.6x a
    /// window drag wants would overshoot and slam the thumb to the end.
    case thumbDrag(x0: Int, y0: Int, x1: Int, y1: Int)
}

/// Per-target availability — the typed emu-only discipline (plan decision
/// 6): the GUI grays what a target can't do, the headless head reports it
/// as data; nothing degrades silently.
public enum ActionAvailability: Equatable {
    case available
    /// Requires the emulator's QMP input plane and this target has none
    /// (metal, or emu launched without --qmp).
    case emulatorOnly(reason: String)
}

public enum ActionModel {

    /// Command-key modifier bit in the Mac event modifiers word (the wire's
    /// `mods` is `evtQModifiers`: cmd=256 shift=512 opt=2048 ctrl=4096).
    public static let cmdKey = 256

    /// Mac US virtual keycodes. Menu shortcut matching keys off the CODE,
    /// not just the char — sending char alone silently no-ops in Finder.
    public static let keycodes: [Character: Int] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4,
        "i": 34, "j": 38, "k": 40, "l": 37, "m": 46, "n": 45, "o": 31,
        "p": 35, "q": 12, "r": 15, "s": 1, "t": 17, "u": 32, "v": 9,
        "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22,
        "7": 26, "8": 28, "9": 25,
    ]

    public static func availability(_ action: MirrorAction,
                                    target: MirrorTarget) -> ActionAvailability {
        switch action {
        case .drag, .qmpClick, .qmpDoubleClick, .menuDrag, .thumbDrag:
            return target.qmp != nil
                ? .available
                : .emulatorOnly(reason: "needs the emulator QMP input plane; "
                                + "this target has none")
        default:
            return .available
        }
    }

    // MARK: - Guest menu geometry (menu-drag targeting)

    /// OS 9 standard menu rows are 16 px tall, drawn directly below the
    /// 20 px menubar. Item i (1-based) centers at menubarBottom + (i-1)*16
    /// + 8. Calibrated live (see the slice-7 commit) — a wrong row height
    /// selects the wrong item, so treat changes as behavior changes.
    public static let menuRowHeight = 16
    public static let menubarHeight = HitTester.menubarHeight

    static func menuItemPoint(menuLeft: Int, itemIndex: Int) -> (x: Int, y: Int) {
        (menuLeft + 20,
         menubarHeight + 1 + (itemIndex - 1) * menuRowHeight + menuRowHeight / 2)
    }

    // MARK: - Gesture → actions

    /// A primary click on a hit target. Returns the action sequence to
    /// dispatch in order (a background-window click activates first), or
    /// [] when the element is inert (disabled control, desktop backdrop…).
    public static func click(on target: HitTester.Target,
                             count: Int = 1, mods: Int = 0) -> [MirrorAction] {
        switch target {
        case .control(_, let ctl):
            guard ctl.enabled, !ctl.ref.isEmpty else { return [] }
            return [.axdo(ref: ctl.ref, count: count, mods: mods, text: nil)]
        case .scrollbar(_, _, let part, let x, let y):
            // A real press-release at the region: the Control Manager's
            // TrackControl is a tracking loop the wire can't drive (the same
            // story as the title-bar widgets), and it auto-repeats a line/page
            // while the button is held. `axdo` would click the control's
            // CENTRE — a page gap — whatever the user actually pressed.
            // The thumb is a drag, not a click.
            guard part != .thumb else { return [] }
            return [.qmpClick(x: x, y: y)]
        case .appMenu:
            // Opening the switcher is mirror-local UI: nothing is sent to the
            // guest until a row is chosen.
            return []
        case .appMenuItem(let psn, _):
            // Switching apps names a PROCESS, not a place on screen.
            // SetFrontProcess is metal-safe and already proven.
            return [.activate(psn: psn)]
        case .windowItem(_, _, let x, let y):
            // Identical treatment to a desktop icon, and for the same reason:
            // the coordinates are the icon's own centre as the FINDER reports
            // it, so the click is as good as the guest's own layout. Select
            // with a wire click (metal-safe); open with a real double-click,
            // which is the QMP path today.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
        case .desktopItem(_, let x, let y):
            // A plain click SELECTS the icon; a double-click OPENS it. The
            // coordinates are the icon's own centre, not where the pointer
            // landed, so the click is as good as the position the guest itself
            // reported. Selection is metal-safe (a posted click); opening still
            // wants a real double-click, which is the QMP path today.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
        case .titlebar(_, _, let x, let y):
            // A real click in the title bar raises the window (the guest's
            // SelectWindow) — activate/SetFrontProcess only fronts the app,
            // not a specific window, and never reorders same-app windows.
            return [.qmpClick(x: x, y: y)]
        case .content(_, _, let front, let x, let y):
            // Double-click (open an icon/item) → a real QMP double-click.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            // Front window: a semantic click (metal-safe). Background window:
            // a real click to raise it (+ hit the content), like the guest.
            return front ? [.click(x: x, y: y, count: 1, mods: mods)]
                         : [.qmpClick(x: x, y: y)]
        case .desktop(let x, let y):
            // Double-click a desktop icon → a real QMP double-click (the
            // Finder opens it); single click selects via a wire click.
            if count >= 2 { return [.qmpDoubleClick(x: x, y: y)] }
            return [.click(x: x, y: y, count: 1, mods: mods)]
        case .widget(_, _, let x, let y):
            // Real press-release inside the box; the widget's tracking loop
            // needs the hardware button.
            return [.qmpClick(x: x, y: y)]
        case .growBox:
            return []   // the grow box acts on drag, not click
        case .menuTitle:
            return []   // opening a menu is UI state, not a guest action
        }
    }

    /// A grow-box drag → resize (GrowWindow tracks from the grab point).
    public static func growDrag(from: (x: Int, y: Int),
                                to: (x: Int, y: Int)) -> [MirrorAction] {
        [.drag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// A scrollbar thumb drag → scroll (TrackControl live-tracks the thumb).
    /// Both points are GLOBAL; the caller maps the control's space through the
    /// window's content origin.
    public static func thumbDrag(from: (x: Int, y: Int),
                                 to: (x: Int, y: Int)) -> [MirrorAction] {
        [.thumbDrag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// A wheel notch over a window → line scrolls on its scrollbar. OS 9 has
    /// no wheel driver, so injecting wheel events would be a no-op dressed up
    /// as support; the honest mapping is the arrow the user would have clicked.
    /// `notches` > 0 scrolls DOWN. Global points, via the content origin.
    public static func wheel(_ notches: Int, on ctl: Scene.Control,
                             contentOrigin: (x: Int, y: Int)) -> [MirrorAction] {
        guard Scrollbar.isLive(ctl), notches != 0,
              let c = Scrollbar.center(ctl, notches > 0 ? .lineDown : .lineUp)
        else { return [] }
        let p = (x: c.x + contentOrigin.x, y: c.y + contentOrigin.y)
        return Array(repeating: MirrorAction.qmpClick(x: p.x, y: p.y),
                     count: Swift.min(abs(notches), 8))
    }

    /// Select a menu item, whatever it takes: ⌘ items go by keystroke
    /// (cheap, wire-only, metal-safe); shortcut-less items go by QMP
    /// menu-drag (emu-only, typed). A separator is structurally inert.
    ///
    /// We deliberately do NOT gate on `item.enabled`. A classic app disables
    /// its menus at rest and only AdjustMenus()es them at menu-down time, so
    /// the passively-read enable flag reads false even for perfectly
    /// selectable items (SimpleText's whole File menu reads disabled until
    /// you actually pull it down). The guest's own MenuSelect / keystroke
    /// dispatch is the real authority on enablement — a truly disabled item
    /// just no-ops — and the caller verifies the effect by re-poll.
    public static func menuSelect(menu: Scene.Menu,
                                  item: Scene.MenuItem) -> [MirrorAction] {
        guard !item.separator else { return [] }
        if !item.cmd.isEmpty {
            return menuItem(item)          // ⌘ items: a keystroke, no patch
        }
        // Shortcut-less items go through the Portal, which answers the app's own
        // MenuSelect by IDENTITY. The menu-drag that used to serve this case
        // aimed at rows computed from a uniform-16px assumption the guest has
        // since disproved (separators are 6px), and was emulator-only besides.
        return [.menuInvoke(menuID: menu.id, itemIndex: item.index,
                            titleLeft: menu.left)]
    }

    /// A title-bar drag gesture → window move (emu-only availability).
    public static func titlebarDrag(from: (x: Int, y: Int),
                                    to: (x: Int, y: Int)) -> [MirrorAction] {
        [.drag(x0: from.x, y0: from.y, x1: to.x, y1: to.y)]
    }

    /// The keystroke path for a ⌘-shortcut menu item (both heads land here).
    /// Shortcut-less items don't come through here — `menuSelect` routes them
    /// to the QMP menu-drag instead.
    public static func menuItem(_ item: Scene.MenuItem) -> [MirrorAction] {
        // No `item.enabled` gate — see menuSelect: the resting enable flag is
        // not authoritative for app menus. A ⌘ keystroke to a truly disabled
        // item is a guest-side no-op.
        guard !item.separator, !item.cmd.isEmpty,
              let ch = item.cmd.lowercased().first,
              let ascii = ch.asciiValue else { return [] }
        return [.key(code: keycodes[ch] ?? 0, char: Int(ascii),
                     mods: cmdKey)]
    }

    /// Type into a resolved control: click-to-focus then keystrokes, in one
    /// fail-closed verb.
    public static func typeInto(_ ctl: Scene.Control,
                                text: String) -> [MirrorAction] {
        guard ctl.enabled, !ctl.ref.isEmpty else { return [] }
        return [.axdo(ref: ctl.ref, count: 1, mods: 0, text: text)]
    }
}
