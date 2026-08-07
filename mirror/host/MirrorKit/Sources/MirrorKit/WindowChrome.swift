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
    /// Grow-box catch span at the bottom-right corner. Kept, and deliberately
    /// unused today: `growBox` answers nil on every window because nothing in
    /// IR v1 says WHICH windows have one. The span is the geometry, and the
    /// geometry was never the missing half — see `growBox`.
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
    ///
    /// Stated ONCE here because THREE places were each answering it, and they
    /// answered it identically only by luck. (Round 8's merge found a second,
    /// byte-identical copy of this function further down the same file: two
    /// branches had each added it, and git kept both without a conflict. A
    /// symbol census cannot see that — the name is present either way — so it
    /// was the compiler that caught it.)
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

    /// The grow box — **and today the honest answer is always "we cannot
    /// say"**, for the same reason and by the same argument as `zoomBox`.
    ///
    /// This read `guard win.kind != 2` until 2026-08-07, and fidelity sweep D
    /// measured that discriminator wrong **in both directions at once**, in
    /// the guest's own pixels: Appearance is `kind == 2000`, so it passed the
    /// guard and **got a grow box the machine does not draw**; Extensions
    /// Manager is `kind == 2`, so it failed the guard and **lost one the
    /// machine does draw**. `kind` says who OWNS a window, not what its frame
    /// looks like — the same lesson `hasTitleBar` and `zoomBox` each learned
    /// separately, one function above and one below.
    ///
    /// Resizability is a property of the **WDEF variant**, and IR v1 does not
    /// carry it: the WindowRecord has `goAwayFlag` (close) and `spareFlag`
    /// (zoom) and **no grow flag at all**. The variation code lives in the
    /// high byte of `windowDefProc` and is ambiguous without the WDEF's
    /// resource id, because `kWindowDocumentDefProcResID` and
    /// `kWindowDialogDefProcResID` number their variants independently — a
    /// foreign walk holding only a Handle cannot say which it is looking at.
    ///
    /// So this is not a bad guess awaiting a better one; there is no field to
    /// guess from, and **an affordance the machine does not offer is worse
    /// than a missing one.** A fabricated box is not cosmetic: `HitTester`
    /// reports it as a target and `Serve`/`Battery` drag from it, which on a
    /// window with no grow box is a drag inside the content region of a live
    /// application. That is the same failure the zoom box was removed for.
    ///
    /// **The cost is real and is not hidden:** every window loses its grow
    /// box, including the ones that have one (sweep D's Workshop, SimpleText,
    /// Finder, Apple System Profiler, Extensions Manager). `mirror.act.window
    /// op: resize` answers `element_not_found` and the battery records a skip
    /// rather than a pass.
    ///
    /// **What fills this in:** `FindWindow`'s `inGrow` — ask the Window
    /// Manager, in the target application's own context, which part a point in
    /// that corner belongs to. That is an **act**, not a read, so it needs an
    /// armed, gated surface rather than the passive scene walk every other
    /// chrome fact comes from. Written up in docs/open-issues.md.
    public static func growBox(_ win: Scene.Window) -> Rect? { nil }

    /// The chrome band a titleless dialog wears instead of a title bar:
    /// a raised border with an inner hairline, drawn on all four sides.
    public static let dialogBand = 6

    /// **Where a window's content begins on screen, in guest coordinates.**
    ///
    /// A control's rect is content-relative, so this number is the whole
    /// of the mapping between what the renderer DRAWS and what the hit
    /// tester can FIND. There is exactly one of it for the same reason
    /// `widgetBox` is shared: when the two sides each carried their own,
    /// they drifted, and a control drew where it could not be clicked.
    ///
    /// It is `titlebarHeight` for EVERY window, including a titleless
    /// dialog, because it is not a statement about chrome — it is the
    /// guest's own rect convention, the one number here that is a
    /// measurement rather than a drawing choice. The scene's window rect
    /// is the content port grown up by exactly this much whether or not
    /// anything is drawn in the band.
    ///
    /// **The renderer disagreed with it, and it cost a modal nobody could
    /// dismiss.** Michelle, 2026-08-07, on Mail's Internet-setup alert:
    /// *"the button labels are now correct, but the buttons still dont
    /// work, and the modal is otherwise blank"*. `SceneRenderer` treated
    /// the band as chrome it could shrink, and put a titleless dialog's
    /// content 14 pixels HIGH and 6 pixels right of where the guest said
    /// it was. Fourteen is more than half a push button, so aiming at the
    /// middle of a drawn button hit-tested ABOVE every dialog item, fell
    /// through to the user pane spanning the whole dialog, and was
    /// refused for having no semantics. Nothing was wrong with the dialog
    /// plane, the DITL, the refs, or the act: `ditemact` dismissed that
    /// alert on the first try. The click never reached any of them.
    ///
    /// MEASURED, not assumed. Guest screendump and scene taken at the same
    /// instant, 2026-08-07, emulated G4, guest build `e715b0a6a5d7`:
    /// NOW's own "Take Screenshot" button is content-local (172, 423) in a
    /// window at (28, 50), and the machine draws its box at (200, 493) —
    /// rect plus (0, 20) exactly, on a TITLED window. Mail's alert puts
    /// its three buttons at local y 85 in a window at t = 96, and the
    /// machine draws them at y 201 — the same (0, 20), on a titleless one.
    /// One convention, both classes.
    ///
    /// NO LONGER OFF IN THE TITLED RENDER. This paragraph used to say the
    /// titled case was off by (1, 2) — `SceneRenderer` drawing content at
    /// `Platinum.contentTop` = 22 and one pixel in, for a bevel and
    /// hairline — and left it there because two pixels never lost a click.
    /// A sibling branch removed the cause rather than the symptom: the
    /// frame is drawn OUTSIDE the scene rect now, `Platinum.contentTop` is
    /// 20, and the renderer counts off `PlatinumTitleBar.Row.contentTop`,
    /// which is the same 20. Both classes agree with the machine.
    ///
    /// The correction is recorded here rather than deleted because the two
    /// halves landed on different branches and this sentence auto-merged
    /// clean while being wrong — prose restating a constant is a second
    /// place to be wrong, which is the whole reason the constant is
    /// derived and not restated.
    public static func contentOrigin(_ win: Scene.Window) -> (x: Int, y: Int) {
        (win.rect.l, win.rect.t + titlebarHeight)
    }

    /// The content box, for a renderer that has to fill and clip it.
    public static func content(_ win: Scene.Window) -> Rect {
        let origin = contentOrigin(win)
        return Rect(l: origin.x, t: origin.y,
                    r: win.rect.r, b: win.rect.b)
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
