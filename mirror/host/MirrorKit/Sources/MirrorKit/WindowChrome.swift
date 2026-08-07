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
    /// Close/zoom/collapse box side length.
    public static let widgetSize = 11
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

    /// A title-bar widget's box, or nil when the window has no chrome for it
    /// (dialogs, or non-front windows — inactive windows hide their widgets).
    ///
    /// Offsets calibrated against the guest framebuffer (SimpleText + a Finder
    /// window, 2026-07-16): the box top sits `r.t + 2`, close hugs the left
    /// (`r.l + 1`), collapse is `r.r - 3 - size` (rightmost), zoom sits
    /// `r.r - 18 - size` (left of collapse). Both the renderer and the
    /// hit-tester use these, so the drawn box, the click zone, and the guest's
    /// real box all coincide — a mismatch here means device clicks miss.
    public static func widgetBox(_ win: Scene.Window, _ widget: Widget) -> Rect? {
        guard win.kind != 2, win.front else { return nil }
        let r = win.rect
        let y = r.t + 2
        let x: Int
        switch widget {
        case .close:    x = r.l + 1
        case .collapse: x = r.r - 3 - widgetSize
        case .zoom:     x = r.r - 18 - widgetSize
        }
        return Rect(l: x, t: y, r: x + widgetSize, b: y + widgetSize)
    }

    /// The grow box at the bottom-right corner (front, non-dialog only).
    public static func growBox(_ win: Scene.Window) -> Rect? {
        guard win.kind != 2, win.front else { return nil }
        let r = win.rect
        return Rect(l: r.r - growBoxSpan, t: r.b - growBoxSpan, r: r.r, b: r.b)
    }

    /// **Does the Window Manager give this window a title bar?**
    ///
    /// `kind` says who OWNS the window, not what it looks like: a modal
    /// alert and a titled assistant are both windowKind 2, because both
    /// came from the Dialog Manager. Until the IR carries the WDEF
    /// variant the title is the honest discriminator — anything the
    /// Window Manager gives a title bar has one to put in it.
    ///
    /// Stated once here because THREE places were each answering it, and
    /// they answered it identically only by luck.
    public static func hasTitleBar(_ win: Scene.Window) -> Bool {
        !(win.kind == 2 && win.title.isEmpty)
    }

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
