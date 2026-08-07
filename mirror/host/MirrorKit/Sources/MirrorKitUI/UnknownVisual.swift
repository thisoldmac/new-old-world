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
        let small = frame.width < minCaptionWidth
            || frame.height < minCaptionHeight
        clipped.fill(Path(frame),
                     with: .tiledImage(small ? closeTile : tile))
        clipped.stroke(Path(frame.insetBy(dx: 0.5, dy: 0.5)),
                       with: .color(small ? closeEdge : edge), lineWidth: 1)
    }

    /// **The loudness budget is per RECTANGLE, and it scales with area.**
    ///
    /// The quiet style above was chosen against the Monitors panel, where
    /// eight unknowns each 200×40 or larger read as damage. At icon
    /// scale it fails the other half of its own brief: a 32×32 square of
    /// 0xDC dots on 0xEF, with no room for a caption, is not
    /// distinguishable from a flat plate at reading distance — and a flat
    /// plate is candidate B, the one rejected because *it lies*. Michelle
    /// read nine Finder folders and both `?` buttons as blank plates on
    /// 2026-08-07 and filed them as "a plate claims something is there";
    /// they were already rung 4, drawn exactly as this file specifies.
    ///
    /// So the DOTS and the EDGE step up on a rectangle too small to carry
    /// a caption — the same texture, enough contrast to read as texture —
    /// and every rectangle large enough for the word is untouched, which
    /// is precisely the population the quiet style was chosen for. One
    /// style, graded by the only thing that made it too loud in the first
    /// place: how much of the picture it covers.
    public static let closeStipple = Color(hex: 0xC4C4C4)
    public static let closeEdge = Color(hex: 0xB8B8B8)

    private static let closeTile = lattice(dot: 0xC4C4C4)

    /// The quiet tile — the one every rectangle large enough for a caption
    /// wears. See `lattice(dot:)` for why it is an image rather than strokes.
    private static let tile: Image = lattice(dot: 0xDCDCDC)

    /// The 2×2 lattice cell: one dot, three ground.
    ///
    /// Built as an image and tiled rather than drawn. The first attempt
    /// stroked hairlines on even rows with a `[1, 1]` dash to get the same
    /// lattice in `height/2` strokes — and `GraphicsContext` DREW THE DASH
    /// SOLID, which the render test caught by counting: 8 dots in a 4x4
    /// block instead of 4. The result was 1px horizontal rulings at 50%
    /// coverage, which is not merely twice as loud as intended but
    /// specifically wrong, because Platinum's own title bars are horizontal
    /// pinstripes and an unknown must not wear the machine's own texture.
    ///
    /// Tiling also gets what the strokes could not promise: the lattice is
    /// anchored to the CONTEXT's origin, not to the rectangle, so a
    /// rectangle that moves a pixel between frames does not make its
    /// texture crawl and two adjacent unknowns share one field.
    private static func lattice(dot: UInt32) -> Image {
        let cell = 2
        var bytes = [UInt8](repeating: 0, count: cell * cell * 4)
        func put(_ i: Int, _ hex: UInt32) {
            bytes[i * 4 + 0] = UInt8((hex >> 16) & 0xFF)
            bytes[i * 4 + 1] = UInt8((hex >> 8) & 0xFF)
            bytes[i * 4 + 2] = UInt8(hex & 0xFF)
            bytes[i * 4 + 3] = 0xFF
        }
        put(0, dot); put(1, 0xEFEFEF)
        put(2, 0xEFEFEF); put(3, 0xEFEFEF)
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        let cg = CGImage(
            width: cell, height: cell, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: cell * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent)!
        // `.interpolation(.none)` is not decoration: a 2×2 tile resampled
        // smooth stops being a lattice and becomes a grey wash, which is
        // candidate B (the flat plate) arrived at by accident.
        return Image(decorative: cg, scale: 1).interpolation(.none)
    }

    /// The lattice cell, shared with `ProvisionalVisual` — which is the whole
    /// reason it is not `private` any more. Two textures for one idea is the
    /// defect this arc has merged away twice; a sibling that says "not yet
    /// real" must be visibly the same family as the one that says "not
    /// known", or the two become separate vocabularies by drift.
    static var latticeTile: Image { tile }

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

/// **The provisional drag — rung 4's sibling, and the same decision made
/// once.**
///
/// The presentation contract Michelle gave for slice 10.5:
///
/// 1. Do not wait for confirmation to begin showing the drag — the item moves
///    with the pointer immediately.
/// 2. Until the select is confirmed, the item shows as **provisional** —
///    visible at a glance as not yet real.
/// 3. Releasing before confirmation snaps the item back home.
/// 4. A failed select response also snaps it back home.
///
/// Rules 3 and 4 are `LiveMirrorView`'s; this file owns rule 2, and owns it
/// alone. It lives beside `UnknownVisual` rather than in the drag code
/// because they are one idea in two tenses — *we do not know this* and *we do
/// not know this YET* — and the arc has twice had to merge away a second
/// visual vocabulary for a decision that already had one.
///
/// ## Why it is not simply the marked unknown
///
/// Because a marked unknown is a hole in a picture and a provisional drag is
/// an OBJECT. The unknown replaces content nobody can supply; the provisional
/// item has perfectly good content — the icon and its name — and what is in
/// doubt is not the drawing but the STATE. So the item is drawn, in full, and
/// the marking sits around and under it: it is recognisably the thing being
/// dragged, recognisably not yet placed.
///
/// ## The anchoring decision, which is the trap
///
/// `UnknownVisual`'s stipple is anchored to the **context** origin,
/// deliberately: a static rectangle that shifts a pixel between frames must
/// not make its texture crawl, and two adjacent unknowns should share one
/// continuous field.
///
/// **A provisional item inherits that and swims.** It moves with the pointer
/// by definition, so a context-anchored lattice would stay nailed to the
/// screen while the item slid across it — the texture would visibly flow
/// through the object, which reads as a rendering fault rather than as a
/// state. The same property that makes the unknown stable makes the ghost
/// wrong.
///
/// So this one is anchored to the **rectangle**: the context is translated to
/// the ghost's top-left before the tile is laid, which puts the lattice
/// origin on the object. The texture then rides with the item and the ghost
/// reads as one moving thing.
///
/// Both anchorings are correct, for opposite reasons, and the reason is the
/// same in both cases: *the texture belongs to whatever the reader will
/// perceive as holding still.* For a hole in a window, that is the window.
/// For an item under the pointer, it is the item. `ProvisionalDragRenderTests`
/// pins the pair, because nothing else about the two files would notice if a
/// later edit unified them.
public enum ProvisionalVisual {

    // MARK: - The definition (swap here, nowhere else)

    /// The dragged item's own art, dimmed. Classic Mac drag feedback is a
    /// 50%-grey outline of the icon; this is the same idea in a medium that
    /// has alpha, and it keeps the item identifiable — a person needs to see
    /// WHICH file is in flight.
    public static let itemOpacity: Double = 0.55

    /// The plate the ghost sits on, carrying the unknown's own lattice so the
    /// two read as one family.
    public static let ground = UnknownVisual.ground

    /// The edge. A shade firmer than the unknown's, because this rectangle is
    /// an object with a boundary rather than the extent of a gap.
    public static let edge = Color(hex: 0xA0A0A0)

    /// The corner glyph's ink — the "not yet real" mark itself.
    public static let markInk = Color(hex: 0x808080)

    /// Side of the square the mark occupies, at the ghost's top-left.
    public static let markSize: CGFloat = 9

    /// Padding around the item's art, so the plate is visible as a plate.
    public static let inset: CGFloat = 2

    // MARK: - Drawing

    /// The plate a provisional item rides on: ground, rectangle-anchored
    /// stipple, edge. The caller draws the item's own art over it at
    /// `itemOpacity`, and then `drawMark`.
    ///
    /// Small enough that a caller could inline it, and that is exactly why it
    /// is here instead.
    public static func drawPlate(in ctx: GraphicsContext, frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        var plate = ctx
        plate.clip(to: Path(frame))
        /* THE ANCHORING. Translating first puts the tile's origin on the
           rectangle rather than on the context, so the lattice travels with
           the ghost instead of the ghost swimming through it. */
        plate.translateBy(x: frame.minX, y: frame.minY)
        let local = CGRect(origin: .zero, size: frame.size)
        plate.fill(Path(local), with: .tiledImage(UnknownVisual.latticeTile))
        plate.stroke(Path(local.insetBy(dx: 0.5, dy: 0.5)),
                     with: .color(edge), lineWidth: 1)
    }

    /// The mark: a small hollow square with a gap in its lower-right, drawn
    /// at the ghost's top-left corner.
    ///
    /// **Not a caption and not an alert triangle.** A word would repeat on
    /// every dragged item and would not survive a 16×16 list row, and a
    /// warning glyph says "something is wrong" when nothing is — the item is
    /// merely not confirmed yet. An open, unclosed box is the smallest thing
    /// that reads as *incomplete* rather than as *broken*, and it survives
    /// being drawn at 9 points.
    public static func drawMark(in ctx: GraphicsContext, frame: CGRect) {
        guard frame.width >= markSize * 2, frame.height >= markSize * 2 else {
            /* Too small to carry the mark honestly — a list row's 16×16 box.
               The plate and the dimmed art are still the marking there, which
               is the same bargain `UnknownVisual` strikes with its caption. */
            return
        }
        let box = CGRect(x: frame.minX + 1, y: frame.minY + 1,
                         width: markSize, height: markSize)
        var path = Path()
        path.move(to: CGPoint(x: box.midX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.maxY))
        path.addLine(to: CGPoint(x: box.minX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        path.addLine(to: CGPoint(x: box.maxX, y: box.midY))
        ctx.stroke(path, with: .color(markInk), lineWidth: 1)
    }
}

/// **The press — the same decision a third time, and the one where the
/// machine turned out to have no opinion at all.**
///
/// `UnknownVisual` says *we do not know this*; `ProvisionalVisual` says *we
/// do not know this yet*, for an item under the pointer. This says it for a
/// button: the person pressed, and until the guest answers we are showing
/// their intent rather than the machine's state.
///
/// ## What the machine says about its own pressed buttons: nothing
///
/// This drawing was supposed to be measured. The brief was to compare
/// against the guest's own pixels, because Platinum's pressed state is a
/// specific drawn procedure and not a darken filter. Three things were
/// found instead, on a live guest on 2026-08-07
/// (`tools/local-pressed-capture.py`, image sha256 `c466baa9…`):
///
/// 1. **No such capture exists anywhere**, and none can be taken the usual
///    way: every route screendumps *around* an act, and the one tool that
///    holds the button down never screendumps.
/// 2. **Holding the button down on a real push button changed zero pixels.**
///    The first run appeared to show 65 px of change; all of it was the
///    mouse cursor arriving in the rectangle, and it vanished when the
///    comparison was taken against a shot with the cursor in the same place.
///    A rig artefact that looked exactly like the answer being sought.
/// 3. **The guest says why, in its own words.** `ctlact` answers
///    `act-not-taken: armed, and the application never called TrackControl`,
///    and `"this application does not route it through TrackControl at all"`.
///    A Platinum pressed face is drawn by the application inside
///    `TrackControl`; an application that never enters that loop never draws
///    one, and `Scene.Control` accordingly has no `hilite` field for it to
///    be reported through.
///
/// So there is no guest-side pressed state to mirror, and the honest
/// conclusion is not "draw a Platinum pressed button anyway". **A drawing
/// that imitates the machine's own pressed face would be the mirror
/// asserting a state the machine is not in** — the same confident wrong
/// answer plan 018 removes everywhere else, and unfalsifiable besides,
/// since nothing can contradict it.
///
/// The mark is therefore deliberately the **provisional family's**, not
/// Platinum's: it is the host saying *we have your press and we are waiting*,
/// in the vocabulary this codebase already uses for exactly that claim. It
/// borrows `ProvisionalVisual`'s ink and `UnknownVisual`'s lattice so a
/// person who has learned what the stipple means anywhere learns it
/// everywhere.
///
/// Bounded to this application. NOW's own Carbon window is what was driven;
/// another application that *does* call `TrackControl` might well draw a
/// pressed face, and if someone photographs one this file is where the
/// measured drawing goes.
public enum PressedVisual {

    // MARK: - The definition (swap here, nowhere else)

    /// The pressed face, over the button's own drawing.
    ///
    /// A wash rather than a replacement: the button underneath still reads as
    /// itself, which matters because the person must see WHICH button they
    /// pressed. Deliberately NOT Platinum's own pressed grey — see above.
    public static let wash = Color(hex: 0x8899BB).opacity(0.28)

    /// The border that says "this one". `ProvisionalVisual`'s edge, because
    /// it is the same statement about the same kind of doubt.
    public static let edge = ProvisionalVisual.edge

    /// The wait indicator's ink and its track.
    public static let indicatorInk = ProvisionalVisual.markInk
    public static let indicatorTrack = UnknownVisual.stipple

    /// Height of the wait bar, and its inset from the button's bottom edge.
    public static let indicatorHeight: CGFloat = 3
    public static let indicatorInset: CGFloat = 2

    // MARK: - Drawing

    /// The pressed face: a wash and a firmer edge, over whatever the button
    /// already drew.
    public static func drawPressed(in ctx: GraphicsContext, frame: CGRect) {
        guard frame.width > 2, frame.height > 2 else { return }
        let path = Path(roundedRect: frame, cornerRadius: 7)
        ctx.fill(path, with: .color(wash))
        ctx.stroke(Path(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5),
                        cornerRadius: 7),
                   with: .color(edge), lineWidth: 1)
    }

    /// **The wait, drawn as a bar that fills toward a deadline the code
    /// actually honours.**
    ///
    /// Not a barber's pole and not a spinning gear. An indeterminate
    /// indicator says "working" forever and can never be wrong, which makes
    /// it precisely the wrong instrument here: the whole point of
    /// `PressSession.patience` is that the wait ENDS, and the indicator
    /// should show the person the end coming. A bar at 90% is a promise that
    /// something is about to be said.
    ///
    /// Drawn inside the button's own lower edge rather than floating over the
    /// middle, so it never covers the button's label — a person who cannot
    /// read which button is busy has been told less, not more.
    public static func drawWait(in ctx: GraphicsContext, frame: CGRect,
                                progress: Double) {
        let w = frame.width - indicatorInset * 2
        guard w > 4, frame.height > indicatorHeight + indicatorInset * 2 else {
            /* Too small to carry the bar honestly. The wash is still the
               marking, which is the same bargain the marked unknown strikes
               with its caption and the provisional plate with its corner
               mark. */
            return
        }
        let track = CGRect(x: frame.minX + indicatorInset,
                           y: frame.maxY - indicatorInset - indicatorHeight,
                           width: w, height: indicatorHeight)
        ctx.fill(Path(track), with: .color(indicatorTrack))
        let done = Swift.min(1, Swift.max(0, progress))
        guard done > 0 else { return }
        ctx.fill(Path(CGRect(x: track.minX, y: track.minY,
                             width: (track.width * done).rounded(),
                             height: track.height)),
                 with: .color(indicatorInk))
    }
}
