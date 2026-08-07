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
        case .close:    return PlatinumTitleBar.closeBox(win.rect)
        case .collapse: return PlatinumTitleBar.collapseBox(win.rect)
        case .zoom:     return zoomBox(win)
        }
    }

    /// The zoom box — **and today the honest answer is always "we cannot say".**
    ///
    /// A zoom box exists only for some WDEF variants, and IR v1 does not carry
    /// the variant. `kind` cannot stand in for it and the corpus proves so with
    /// a single pair: **Extensions Manager is `kind == 2` and HAS a zoom box;
    /// Memory is `kind == 2` and has none.** Seven control panels in the corpus
    /// show close + collapse only; four windows (a Finder folder, a SimpleText
    /// document, Extensions Manager, NOW's own Workshop) show all three.
    ///
    /// So this returned a fabricated box on seven of eleven windows, and the
    /// fabrication was not only cosmetic: `HitTester` reported a zoom target
    /// there and `Serve`/`Battery` would send a click into the racing stripes,
    /// which the Window Manager reads as the start of a DRAG. An affordance the
    /// machine does not offer is worse than a missing one.
    ///
    /// **What fills this in:** the WindowRecord already carries it —
    /// `spareFlag` is the zoom flag and `goAwayFlag` the close flag, both one
    /// byte, both beside the `windowKind` the walk already reads
    /// (`scene_walk.c`). It is a contract field and a guest read, in that
    /// order, and it is written up in docs/open-issues.md.
    private static func zoomBox(_ win: Scene.Window) -> Rect? { nil }

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

    public static func center(_ rect: Rect) -> (x: Int, y: Int) {
        ((rect.l + rect.r) / 2, (rect.t + rect.b) / 2)
    }

    static func contains(_ rect: Rect, _ x: Int, _ y: Int,
                         grow: Int = 0) -> Bool {
        x >= rect.l - grow && x < rect.r + grow
            && y >= rect.t - grow && y < rect.b + grow
    }
}
