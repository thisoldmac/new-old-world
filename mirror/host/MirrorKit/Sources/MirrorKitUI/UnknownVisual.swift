import SwiftUI

/// The marked unknown — rung 4 of the provenance ladder, in ONE place.
///
/// A rectangle nobody can claim gets this drawing, and the whole point of
/// plan 018 is that it gets exactly this drawing, every time, from every
/// call site. Before this file there were two copies of the fill (the
/// scene renderer's and the display replay's), identical by coincidence
/// and free to drift; the ladder needs one definition it can swap.
///
/// ## Why it is quiet
///
/// The previous look was a 1px diagonal stroke every 6px in `g2` on a `g1`
/// ground, a dashed `g3` border, and the words "Bitmap unavailable" in
/// `g4`. Three separate alarms per rectangle. On a real capture that reads
/// as damage: the Monitors panel alone shows eight of them at once and the
/// panel looks broken rather than partly known. Michelle, driving the live
/// app on 2026-08-06, called it "excessive hatching", and half of that
/// complaint is not the NUMBER of gaps — honest gaps are the plan's
/// deliberate choice — but the LOUDNESS of each one.
///
/// So the requirement was stated as a design brief: sit back the way an
/// unloaded image does in a browser, while staying unmistakably "we do not
/// know" rather than "this is blank". Four candidates were rendered over
/// two real sweep-A captures and compared side by side. The sheets are in
/// the out-of-git store — `tools/unknown-style-mock` regenerates them, and
/// they stay out of git because they are renders of Apple's bitmaps:
///
///     tools/unknown-style-mock \
///       ~/Lab/Assets/now-mirror-assets/sweep-2026-08-07-a/p1/renders/panels/monitors.png \
///       ~/Lab/Assets/now-mirror-assets/unknown-style-2026-08-07/02-monitors.png \
///       140,150,660,440
///
/// The four:
///
/// - **A, the diagonal hatch.** The baseline. Loud, and — a defect nobody
///   had noticed — drawn as an ANTIALIASED vector stroke into a render
///   that is otherwise pixel-exact, so its greys are 0xD6/0xE2 blends that
///   exist nowhere in the Platinum palette.
/// - **B, flat fill with a hairline.** Quiet, and it LIES: an empty Finder
///   window with a flat interior is a claim that the folder is empty, and
///   a flat rounded plate inside Monitors reads as a disabled control.
///   Rejected on rule 1 — a stable wrong answer is still a wrong answer.
/// - **C, this one.** A flat ground with a 25% ordered stipple and a
///   hairline edge. It recedes at a glance and resolves into "placeholder"
///   on a look, because nothing in Platinum is textured this way.
/// - **D, flat with corner ticks.** The ticks read as Platinum control
///   detail rather than as a marker, and on the small rectangles — which
///   is most of them — four ticks consume the whole rectangle.
///
/// The pick is C, made by this lane rather than deferred, because lane A
/// was holding a placeholder for it. It is one struct of constants
/// precisely so overruling it is an edit here and nowhere else.
///
/// ## Why the stipple is anchored to the context, not to the rectangle
///
/// The dots land on even device columns and even device rows, computed
/// from absolute coordinates. A rectangle that moves by one pixel between
/// frames therefore does not make its texture crawl, and two adjacent
/// unknowns share one continuous field instead of showing a seam. Rule 2:
/// the same window state renders the same way every time.
public enum UnknownVisual {

    // MARK: - The definition (swap here, nowhere else)

    /// The ground. A half-step lighter than `g1`, so an unknown sitting on
    /// a Platinum window face is distinguishable from the face without
    /// being brighter than it.
    public static let ground = Color(hex: 0xEFEFEF)

    /// The stipple dot. 16 levels under the ground: legible as texture at
    /// reading distance, gone at a glance.
    public static let stipple = Color(hex: 0xDCDCDC)

    /// The edge. Solid, not dashed — a dashed border is warning tape, and
    /// the extent of the unknown is information, not an alarm.
    public static let edge = Color(hex: 0xD2D2D2)

    /// The caption, when there is room for one. Quieter than the old `g4`
    /// (0x888888) by design: the texture is the marker, the word is only
    /// there for whoever looks closely.
    public static let caption = Color(hex: 0xAFAFAF)

    /// Device-space period of the stipple lattice, in points.
    public static let stipplePeriod: CGFloat = 2

    /// A caption is drawn only on a LARGE unknown. The old thresholds (60
    /// or 92 wide, 14 tall) captioned nearly everything, and the mock made
    /// the cost obvious: Monitors' eight gaps became four repetitions of
    /// the same sentence stacked down one panel, which is the loudness
    /// problem again wearing different clothes. At 200x40 exactly one
    /// region in Monitors and one in the Finder window carry the word, and
    /// the rest are carried by the texture — which is the intent, since
    /// the texture is the marker and the word is the footnote.
    public static let minCaptionWidth: CGFloat = 200
    public static let minCaptionHeight: CGFloat = 40

    /// Left inset of the caption from the rectangle's leading edge.
    public static let captionInset: CGFloat = 4

    // MARK: - Drawing

    /// Fill `frame` as a marked unknown, without its caption.
    ///
    /// Callers draw their own caption — the scene renderer and the display
    /// replay reach the bitmap fonts by different routes — but they ask
    /// this type WHETHER and WHERE, so the answer stays single.
    public static func drawGround(in ctx: GraphicsContext, frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        var clipped = ctx
        clipped.clip(to: Path(frame))
        clipped.fill(Path(frame), with: .color(ground))

        /* The lattice as dashed horizontal hairlines: one stroke per even
           row with a [1,1] dash phased onto even columns. A per-pixel fill
           would be tens of thousands of rects for a full-window unknown;
           this is height/2 strokes and lands on the same pixels. */
        let firstRow = (frame.minY / stipplePeriod).rounded(.up) * stipplePeriod
        let startX = frame.minX.rounded(.down)
        let phase = startX.truncatingRemainder(dividingBy: stipplePeriod)
        var y = firstRow
        while y < frame.maxY {
            var row = Path()
            row.move(to: CGPoint(x: frame.minX, y: y + 0.5))
            row.addLine(to: CGPoint(x: frame.maxX, y: y + 0.5))
            clipped.stroke(row, with: .color(stipple),
                           style: StrokeStyle(lineWidth: 1, dash: [1, 1],
                                              dashPhase: phase))
            y += stipplePeriod
        }

        clipped.stroke(Path(frame.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(edge), lineWidth: 1)
    }

    /// Where the caption's baseline goes, or nil if the rectangle is too
    /// small to carry one honestly.
    ///
    /// `ascent` is the strike's ascent so the word sits on the rectangle's
    /// optical centre rather than its baseline centre.
    public static func captionOrigin(in frame: CGRect,
                                     ascent: CGFloat) -> CGPoint? {
        guard frame.width >= minCaptionWidth,
              frame.height >= minCaptionHeight else { return nil }
        return CGPoint(x: frame.minX + captionInset,
                       y: (frame.midY + ascent / 2).rounded())
    }
}
