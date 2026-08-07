import Foundation

/// The one definition of a window's chrome geometry, in GUEST coordinates.
///
/// Both the hit-tester and the renderer consume this, so a click can never
/// land on a box the renderer drew somewhere else (the drift that made the
/// close box finicky). Guest coords throughout: the renderer applies its own
/// fit transform on top; the hit-tester compares raw.
///
/// Layout follows the Platinum WDEF the mock renderer draws. When the asset
/// pack lands with exact metrics, this is the one place they change.
public enum WindowChrome {
    /// The scene's window rect is the content port grown UP by this much
    /// (SceneBuilder.titleBarHeight); the title bar occupies that band.
    public static let titlebarHeight = SceneBuilder.titleBarHeight
    /// Close/zoom/collapse box side length. Confirmed against the machine —
    /// `PlatinumTitleBar.widgetSize`, eleven windows, always 11.
    public static let widgetSize = PlatinumTitleBar.widgetSize
    /// Grow-box catch span at the bottom-right corner.
    public static let growBoxSpan = 15

    public enum Widget: Equatable, CaseIterable {
        case close, zoom, collapse
    }

    /// The title-bar band (real windows only; dialogs draw none).
    public static func titlebar(_ win: Scene.Window) -> Rect {
        Rect(l: win.rect.l, t: win.rect.t,
             r: win.rect.r, b: win.rect.t + titlebarHeight)
    }

    /// Does this window have a title bar at all?
    ///
    /// The same discriminator `SceneRenderer` uses, and for the same stated
    /// reason: `kind` says who OWNS the window, not what it looks like, so a
    /// modal alert and a titled control panel are both `kind == 2`. A modal
    /// alert has no title; anything the Window Manager gives a title bar has
    /// one to put in it.
    ///
    /// **This used to read `win.kind != 2`, and that was wrong on the machine.**
    /// Date & Time, General Controls, Memory, Extensions Manager and Mouse are
    /// all `kind == 2` and all draw a close box and a collapse box — so the
    /// hit-tester refused to find a widget the guest was plainly showing, and
    /// no control panel in the corpus could be closed from the mirror.
    public static func hasTitleBar(_ win: Scene.Window) -> Bool {
        !(win.kind == 2 && win.title.isEmpty)
    }

    /// A title-bar widget's box, or nil when the window has no chrome for it
    /// (dialogs, or non-front windows — inactive windows hide their widgets).
    ///
    /// **Offsets MEASURED against the guest's own pixels**, eleven front
    /// windows across three sweeps — see `PlatinumTitleBar`, which owns them
    /// and carries the evidence. The three that changed here, and by how much:
    /// close `l+1` → `l-1`, collapse `r-14` → `r-10`, top `t+2` → `t+3`. The
    /// old numbers were calibrated by eye in July against two windows and were
    /// two to four pixels out on every one of them, which is more than the
    /// widget's own bevel is wide.
    ///
    /// Both the renderer and the hit-tester use this, so the drawn box, the
    /// click zone and the guest's real box coincide — a mismatch means device
    /// clicks miss.
    public static func widgetBox(_ win: Scene.Window, _ widget: Widget) -> Rect? {
        guard hasTitleBar(win), win.front else { return nil }
        switch widget {
        case .close:
            /* `closeBox == false` is the guest saying the machine draws
               none, and it is the only thing that withdraws one. nil is
               "not reported" — an older producer, or a window whose record
               would not validate — and takes the behaviour we already had.
               The asymmetry with `.zoom` below is deliberate: this widget
               was right on every window in the corpus, so absence of an
               answer is not a reason to start hiding it. */
            guard win.closeBox != false else { return nil }
            return PlatinumTitleBar.closeBox(win.rect)
        case .collapse: return PlatinumTitleBar.collapseBox(win.rect)
        case .zoom:     return zoomBox(win)
        }
    }

    /// The zoom box — **drawn only where the guest PROVED the machine draws
    /// one**, and nowhere else.
    ///
    /// A zoom box exists only for some WDEF variants. `kind` cannot stand in
    /// for it and the corpus proves so with a single pair: **Extensions
    /// Manager is `kind == 2` and HAS a zoom box; Memory is `kind == 2` and
    /// has none.** Seven control panels in the corpus show close + collapse
    /// only; four windows (a Finder folder, a SimpleText document, Extensions
    /// Manager, NOW's own Workshop) show all three.
    ///
    /// So this once returned a fabricated box on seven of eleven windows, and
    /// the fabrication was not only cosmetic: `HitTester` reported a zoom
    /// target there and `Serve`/`Battery` would send a click into the racing
    /// stripes, which the Window Manager reads as the start of a DRAG. An
    /// affordance the machine does not offer is worse than a missing one — so
    /// it then answered nil everywhere, which was honest and offered nothing.
    ///
    /// `Scene.Window.zoomBox` is the WindowRecord's own `spareFlag`, and it
    /// closes both halves: `true` draws it, `false` and nil do not. **nil
    /// keeps the honest-nothing behaviour** rather than guessing, because a
    /// producer that cannot say has told us nothing about this machine.
    private static func zoomBox(_ win: Scene.Window) -> Rect? {
        guard win.zoomBox == true else { return nil }
        return PlatinumTitleBar.zoomBox(win.rect)
    }

    /// The grow box at the bottom-right corner (front, non-dialog only).
    ///
    /// **`kind != 2` IS A GUESS AND IT IS WRONG, in both directions.**
    /// Extensions Manager is `kind == 2` and draws a grow box — counted in its
    /// own screendump, the same anti-diagonal ramp the Finder's corner shows —
    /// so this denies it a real affordance; and nothing here proves a `kind`
    /// 8/20/2000 window is resizable, so a fixed-size document window is
    /// offered a grow target the machine does not draw. It is the zoom box's
    /// defect wearing the other costume.
    ///
    /// **It is NOT fixed by the same field, and that is a finding.**
    /// docs/open-issues.md said "same fix, same field"; it is not.
    /// `spareFlag` is the zoom box alone — MacWindows.h's WindowRecord carries
    /// no grow flag at all. The only other candidate is the variation code in
    /// the high byte of `windowDefProc`, and it is ambiguous without the
    /// WDEF's resource id: `kWindowDocumentDefProcResID` 64 numbers variant 7
    /// `kWindowFullZoomGrowDocumentProc`, while `kWindowDialogDefProcResID` 65
    /// numbers its own variants from 0 independently — and a foreign walk
    /// cannot name a Handle's resource, which is the exact wall
    /// `contrlDefProc` already hit one level down.
    ///
    /// So this is left as it was, wrong and named, rather than changed to a
    /// different guess. Closing it needs an authority the WindowRecord does
    /// not hold.
    public static func growBox(_ win: Scene.Window) -> Rect? {
        guard win.kind != 2, win.front else { return nil }
        let r = win.rect
        return Rect(l: r.r - growBoxSpan, t: r.b - growBoxSpan, r: r.r, b: r.b)
    }

    public static func center(_ rect: Rect) -> (x: Int, y: Int) {
        ((rect.l + rect.r) / 2, (rect.t + rect.b) / 2)
    }

    static func contains(_ rect: Rect, _ x: Int, _ y: Int,
                         grow: Int = 0) -> Bool {
        x >= rect.l - grow && x < rect.r + grow
            && y >= rect.t - grow && y < rect.b + grow
    }
}
