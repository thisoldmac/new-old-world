import Foundation

/// The **Platinum title bar**, as the machine draws it — every row, every run
/// and every widget box, in guest coordinates.
///
/// ## Why this is measured and not ported
///
/// `docs/deriving-a-drawn-procedure.md` names five rungs of evidence and says
/// to work down them, cheapest first, stopping when the answer is firm. For
/// the tab strip rung 3 — the guest's own QuickDraw drain — answered nearly
/// everything. **For the title bar rung 3 answers nothing at all**, and that
/// is the first finding here:
///
/// > The Window Manager draws window frames through a route the content plane
/// > cannot see. Fourteen captures across three sweeps carry 4,550 ops for one
/// > control panel and **not one of them is in the title bar**: every port in
/// > every drain is window-LOCAL (origin 0,0, bounded by the content rect),
/// > no port carries screen-global coordinates, and no `text` op anywhere in
/// > the corpus draws a window's own title. `qdtrace` hooks an application's
/// > ports; the WDEF does not draw into one.
///
/// So the ladder skips straight to rung 4 — **the guest's own pixels** — and
/// every number below was counted out of QMP screendumps of a real Mac OS 9.1
/// guest, cross-checked across **eleven front windows** in
/// `sweep-2026-08-07-a/b/c` (seven control panels, a Finder folder window, a
/// SimpleText document, Extensions Manager and NOW's own Workshop). A rule is
/// only written here if all eleven agree; where they disagree the disagreement
/// is stated rather than averaged.
///
/// Nothing here is a `GetThemeMetric` answer. **No `GetThemeMetric` call
/// exists on the guest side of this project**, and this file does not add one:
/// like `DrawnTabStrip.Metrics`, these are numbers read off the machine's
/// output, not asked of its Appearance Manager. Plan 016's P2 remains the
/// route to the values nothing on screen is currently drawing — notably every
/// INACTIVE state below.
///
/// ## The frame of reference
///
/// `Scene.Window.rect` is the content port grown UP by
/// `SceneBuilder.titleBarHeight` (20), so with `r = win.rect`:
///
/// * the content the guest draws into starts at `y = r.t + 20`;
/// * **the window's outer black frame is at `y = r.t - 2`**, two rows ABOVE
///   the scene rect. Measured identically on eight windows
///   (`contentTop - outerBlack == 22` every time). The scene convention is
///   off by two and this file states the true number rather than moving the
///   convention, which every other consumer of `rect` depends on.
///
/// Rows, relative to `r.t`, of an ACTIVE title bar:
///
/// | row | colour | what it is |
/// |---|---|---|
/// | `t-2` | `000000` | the window's outer frame |
/// | `t-1` | `FFFFFF` | the frame band's lit edge |
/// | `t`, `t+1` | `CCCCCC` | the band's face |
/// | `t+2` … `t+13` | stripes | the racing stripes, twelve rows |
/// | `t+14` … `t+17` | `CCCCCC` | the band's face |
/// | `t+18` | `999999` | the band's shadowed edge |
/// | `t+19` | `000000` | the frame around the content |
/// | `t+20` | — | the guest's content |
public enum PlatinumTitleBar {
    // MARK: - The seven colours this bar is made of

    /// The window frame, and the ring around each widget's neighbourhood.
    public static let frame: UInt32 = 0x000000
    /// The frame band's lit edge, the widget recess's lit edge, and every
    /// second racing stripe.
    public static let lit: UInt32 = 0xFFFFFF
    /// The title bar's face, and the title patch behind the text.
    public static let face: UInt32 = 0xCCCCCC
    /// The frame band's shadowed edge.
    public static let bandShadow: UInt32 = 0x999999
    /// The widget recess's shadowed edge, and the widget's own inner shadow.
    public static let recessShadow: UInt32 = 0x888888
    /// The dark racing stripe. **Not one of the ported seven greys** — the
    /// renderer had no `777777` at all, and drew this row as `CCCCCC`.
    public static let stripeDark: UInt32 = 0x777777
    /// A widget's outline and its glyph. Also not one of the seven; the
    /// renderer drew widget outlines in pure black.
    public static let widgetInk: UInt32 = 0x222222

    /// The anti-diagonal ramp inside every widget, lightest at the
    /// bottom-right. Seven steps, and the machine steps once every TWO
    /// diagonals — see `widgetRampIndex`.
    public static let widgetRamp: [UInt32] = [
        0x999999, 0xAAAAAA, 0xBBBBBB, 0xCCCCCC, 0xDDDDDD, 0xEEEEEE, 0xFFFFFF,
    ]

    // MARK: - Rows

    /// Rows of the title bar band, as offsets from `win.rect.t`.
    public enum Row {
        /// The window's outer black frame — two rows above the scene rect.
        public static let outerFrame = -2
        public static let litEdge = -1
        public static let stripesTop = 2
        public static let stripesBottom = 13     // inclusive
        public static let bandShadow = 18
        public static let contentFrame = 19
        /// What `SceneBuilder` already calls the title-bar height.
        public static let contentTop = 20
    }

    /// Twelve rows, `t+2 … t+13`.
    public static let stripeRows = Row.stripesBottom - Row.stripesTop + 1

    // MARK: - Widgets

    /// A widget is eleven pixels square. Measured on every window in the
    /// corpus that has one; never 12, never 13.
    public static let widgetSize = 11

    /// The close box's left edge, measured on eleven windows: `l - 1`.
    ///
    /// It hangs one pixel OUTSIDE the content rect, which is why the old
    /// `l + 1` both drew and hit-tested two pixels right of the machine's.
    public static func closeBox(_ r: Rect) -> Rect {
        widget(at: r.l - 1, r)
    }

    /// The zoom box: `r - 26 … r - 16`.
    public static func zoomBox(_ r: Rect) -> Rect {
        widget(at: r.r - 26, r)
    }

    /// The collapse (windowshade) box, the rightmost: `r - 10 … r`.
    ///
    /// Its right edge is the content rect's `r`, i.e. one pixel outside the
    /// last content column, mirroring the close box on the left.
    public static func collapseBox(_ r: Rect) -> Rect {
        widget(at: r.r - 10, r)
    }

    private static func widget(at x: Int, _ r: Rect) -> Rect {
        Rect(l: x, t: r.t + 3, r: x + widgetSize, b: r.t + 3 + widgetSize)
    }

    /// The recess a widget sits in: one pixel of `recessShadow` along its top
    /// and left, one of `lit` along its bottom and right, each offset by one.
    /// The widget looks pressed INTO the bar, not raised out of it.
    public static func widgetRecess(_ box: Rect) -> Rect {
        Rect(l: box.l - 1, t: box.t - 1, r: box.r + 1, b: box.b + 1)
    }

    /// Which of `widgetRamp`'s seven steps lands at `(u, v)` inside a widget's
    /// 7×7 core, `u` and `v` both `0…6`.
    ///
    /// The machine advances one step every two diagonals — `(u + v) / 2` — so
    /// the corner pixels are `999999` and `FFFFFF` and the centre is `CCCCCC`.
    /// Checked against every pixel of four widgets on two windows.
    public static func widgetRampIndex(u: Int, v: Int) -> Int {
        min(widgetRamp.count - 1, max(0, (u + v) / 2))
    }

    // MARK: - The striped field

    /// Where the racing stripes run on a **light** row, given the window rect
    /// and the leftmost of the right-hand widgets.
    ///
    /// Left edge is `l + 15` — six pixels clear of the close box's right edge
    /// (`l + 9`). Right edge is seven pixels clear of the first right-hand
    /// widget's left edge. Both hold on all eleven windows.
    ///
    /// A **dark** row is the same run shifted one pixel right, and so is the
    /// title patch punched out of it. That one-pixel phase is measured, not
    /// explained: every light row in the corpus starts at `l + 15` and every
    /// dark row at `l + 16`, on eleven windows, without exception.
    public static func stripeRun(_ r: Rect,
                                 firstRightWidgetLeft: Int,
                                 dark: Bool) -> (from: Int, to: Int) {
        let phase = dark ? 1 : 0
        return (r.l + 15 + phase, firstRightWidgetLeft - 7 + phase)
    }

    /// The face-coloured patch the title sits on, punched out of the stripes.
    ///
    /// Four pixels of padding each side (`patchPad`), centred on the window,
    /// spanning the full height of the striped field. `titleWidth` is the ink
    /// width of the title as the renderer will draw it — so a substituted face
    /// widens the patch exactly as it widens the text, which is the honest
    /// behaviour: the patch is sized to what is actually drawn.
    public static let patchPad = 4

    public static func titlePatch(_ r: Rect, titleWidth: Int,
                                  dark: Bool) -> Rect {
        let w = titleWidth + 2 * patchPad
        let left = (r.l + r.r) / 2 - w / 2 + (dark ? 0 : -1)
        return Rect(l: left, t: r.t + Row.stripesTop,
                    r: left + w, b: r.t + Row.stripesBottom + 1)
    }

    /// The title's baseline, as an offset from `win.rect.t`.
    ///
    /// Measured from five titles with no descender, whose ink ends at `t+12`.
    /// Cap tops land on `t+4`; descenders reach `t+14`.
    public static let titleBaseline = 13
}
