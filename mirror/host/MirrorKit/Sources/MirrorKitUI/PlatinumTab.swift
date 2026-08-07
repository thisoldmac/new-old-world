import SwiftUI
import MirrorKit

/// Draws the part of a Platinum tab the guest's drawing stream does not
/// carry: the two slanted end caps, the outline around them, and the join
/// where the front tab interrupts the pane's top frame line.
///
/// ## What this draws, and what it deliberately does not
///
/// `DrawnTabStrip` explains where the numbers come from. This file is only
/// the shape, and it obeys `docs/render-composition.md`'s rule for a derived
/// element: **draw only the difference between what P3 said and what you
/// know.** The label box, its three-row top bevel and the title are the
/// replay's — they arrived as ops and are already on the canvas when this
/// runs. The label box interior is clipped OUT before anything is filled, so
/// a tab whose title the replay drew keeps it.
///
/// ## The shape, measured rather than styled
///
/// Read off the guest's own pixels (QMP screendump of the Mac OS 9.1
/// Appearance control panel, sweep A pass 1, `appearance-guest.ppm`), tab
/// "Themes", label box x 182…231, y 100…, pane top y 121:
///
/// - The cap runs the full height of the tab and reaches `capsWidth` (12 px
///   there) horizontally at the bottom, meeting the pane's frame line.
/// - The bottom 17 rows are a STRAIGHT slant covering 7 px — a 1-in-3
///   diagonal, stepping one pixel left every third row without exception.
/// - The top 4 rows are a corner, covering the remaining 5 px.
/// - Just inside the black outline, along the top and the left slant only,
///   runs a one-pixel highlight: white on the front tab, one grey step
///   lighter than the face on the others. Both colours are in the stream —
///   they are the third of the three lines the guest drew across the label
///   box — so neither is chosen here.
///
/// ``Shape/cornerHeight`` and ``Shape/cornerWidth`` are the two numbers that
/// are neither in the stream nor in `Appearance.h`. They are measured, they
/// are named, and they are the only place this drawer is guessing.
///
/// ## The residual, stated up front
///
/// Apple's caps are ANTI-ALIASED — the diagonal carries `#222222`, `#444444`,
/// `#BBBBBB` blend pixels, which classic QuickDraw does not produce, so
/// `DrawThemeTab` is compositing a prepared stencil rather than stroking a
/// line. This draws the same geometry and lets Core Graphics anti-alias it.
/// The shape matches; the individual blend values along the diagonal do not,
/// and `docs/deriving-a-drawn-procedure.md` reports the measured delta.
public enum PlatinumTab {

    /// The two measured constants the stream cannot supply.
    public struct Shape: Equatable, Sendable {
        /// How many rows at the top of the cap are curve rather than slant.
        public var cornerHeight: CGFloat
        /// How much of `capsWidth` that curve consumes.
        public var cornerWidth: CGFloat

        public init(cornerHeight: CGFloat = 4, cornerWidth: CGFloat = 5) {
            self.cornerHeight = cornerHeight
            self.cornerWidth = cornerWidth
        }

        /// Measured on Mac OS 9.1, Apple platinum, large tabs.
        public static let platinum = Shape()
    }

    /// The outline of one tab, in the same space `content` is expressed in.
    ///
    /// `labelRect` is the guest's paint rect; the outline is `capsWidth`
    /// wider on each side and ends at the pane's frame line — one row past
    /// it for the front tab, which is exactly how the front tab erases the
    /// pane's top line under itself.
    ///
    /// `inset` shrinks the outline by that many pixels on the top and both
    /// slants, leaving the bottom where it is. The drawer stacks three of
    /// these — frame, lit edge, face — rather than stroking, because a
    /// stroked horizontal line at an integer y lands half in each of two
    /// rows and reads as two rows of mid-grey where the machine has one row
    /// of black. That is not a nicety: the first version of this drawer
    /// stroked, and its tab top edge measured `#404040` over `#777777`
    /// against a guest whose edge is `#000000`.
    public static func outline(labelRect: CGRect, paneTop: CGFloat,
                               capsWidth: CGFloat, isFront: Bool,
                               shape: Shape = .platinum,
                               inset: CGFloat = 0) -> Path {
        let l = labelRect.minX + inset
        let r = labelRect.maxX - inset
        let t = labelRect.minY + inset
        let capsWidth = max(1, capsWidth - inset)
        let bottom = paneTop + (isFront ? 1 : 0)
        let kw = min(shape.cornerWidth, capsWidth)
        let kh = min(shape.cornerHeight, max(1, bottom - t - 1))

        var p = Path()
        p.move(to: CGPoint(x: l - capsWidth, y: bottom))
        p.addLine(to: CGPoint(x: l - kw, y: t + kh))
        p.addQuadCurve(to: CGPoint(x: l, y: t),
                       control: CGPoint(x: l - kw, y: t))
        p.addLine(to: CGPoint(x: r, y: t))
        p.addQuadCurve(to: CGPoint(x: r + kw, y: t + kh),
                       control: CGPoint(x: r + kw, y: t))
        p.addLine(to: CGPoint(x: r + capsWidth, y: bottom))
        p.closeSubpath()
        return p
    }

    /// Draw every tab of `strip`. `origin` maps port-local coordinates into
    /// the context (the same transform the replay uses for its ops).
    ///
    /// Tabs are drawn back-to-front — non-front first, then the front one —
    /// so the front tab's caps overlap its neighbours' exactly as the
    /// Appearance Manager draws them.
    public static func draw(_ strip: DrawnTabStrip.Strip,
                            in ctx: GraphicsContext,
                            origin: (Int, Int) -> CGPoint,
                            shape: Shape = .platinum,
                            coverage: DisplayReplay.Coverage? = nil) {
        let caps = CGFloat(strip.capsWidth)
        let ordered = strip.tabs.filter { !$0.isFront } + strip.tabs.filter(\.isFront)

        for tab in ordered {
            let a = origin(tab.labelRect.l, tab.labelRect.t)
            let b = origin(tab.labelRect.r, tab.labelRect.b)
            let label = CGRect(x: a.x, y: a.y,
                               width: max(0, b.x - a.x),
                               height: max(0, b.y - a.y))
            guard label.width > 0, label.height > 0 else { continue }
            let paneTop = origin(tab.labelRect.l, strip.paneTop).y

            func ring(_ inset: CGFloat) -> Path {
                outline(labelRect: label, paneTop: paneTop, capsWidth: caps,
                        isFront: tab.isFront, shape: shape, inset: inset)
            }

            /* THE LABEL BOX IS NOT OURS. Everything inside it — the face,
               the three-row top bevel and the title — arrived as ops and is
               already on the canvas; the only thing missing was what lies
               OUTSIDE it. Clipping the box out is what keeps this a
               difference and not a repaint, and it is also why the bevel
               inside the box stays the guest's own three colours while the
               caps carry only frame and highlight, which is what the
               machine draws. */
            var g = ctx
            g.clip(to: Path(label), options: .inverse)

            g.fill(ring(0),
                   with: .color(tab.topLines.first.flatMap { $0 }
                       .map(color) ?? Platinum.g6))
            if let lit = tab.topLines.count == 3 ? tab.topLines[2] : nil {
                g.fill(ring(1), with: .color(color(lit)))
            }
            if let face = tab.face, face.count == 3 {
                g.fill(ring(tab.topLines.count == 3 ? 2 : 1),
                       with: .color(color(face)))
            }
            coverage?.add(ring(0).boundingRect)
        }
    }

    private static func color(_ c: [Int]) -> Color {
        Color(red: Double(c[0]) / 65535, green: Double(c[1]) / 65535,
              blue: Double(c[2]) / 65535)
    }
}
