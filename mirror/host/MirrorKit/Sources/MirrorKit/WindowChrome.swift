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

    public static func center(_ rect: Rect) -> (x: Int, y: Int) {
        ((rect.l + rect.r) / 2, (rect.t + rect.b) / 2)
    }

    static func contains(_ rect: Rect, _ x: Int, _ y: Int,
                         grow: Int = 0) -> Bool {
        x >= rect.l - grow && x < rect.r + grow
            && y >= rect.t - grow && y < rect.b + grow
    }
}
