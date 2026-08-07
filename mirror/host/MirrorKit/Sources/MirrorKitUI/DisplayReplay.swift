import SwiftUI
import MirrorKit

/// Replays a window's captured QuickDraw ops (`Scene.Window.display`) into its
/// content area — the QDPeek content plane made visible. Text draws through the
/// extracted NFNT strikes at the op's exact pen position (closing M1's
/// positional reconstruction into pixel-honest glyphs); primitives draw as
/// Canvas paths; STATE ops set the current colours, origin and clip. Erase
/// operations use the guest's background colour: without that rule, repeated
/// repaints accumulate instead of replacing the pixels that came before.
///
/// Ops are port-local (window content coords); a `state`/`origin` op shifts
/// them. Structured ops are replayed in order, like the guest framebuffer,
/// clipped to the content rect. CopyBits is the deliberate exception: because
/// the semantic core carries only its destination geometry, its unavailable
/// marker is a background annotation rather than substitute pixels. Drawing
/// those markers first keeps missing bitmap data visible without allowing it
/// to cover text and controls the guest did report.
///
/// THE PLACEHOLDER GRADING BELOW IS ONE PLANE ANSWERING ANOTHER'S
/// SILENCE, not a local heuristic, and the rule it implements is
/// docs/render-composition.md — read that before adding another case.
/// A placeholder is a CLAIM about the machine and must be no stronger
/// than the evidence: "missing" only for content nobody could reach,
/// "a control" for a control-shaped blit, and never a more precise type
/// than the drawing stream supports, because typing controls is P2's
/// job and where P2 knows, P2 draws.
public enum DisplayReplay {

    /// **What the replay actually put ink on.**
    ///
    /// A placeholder is a claim about the machine, and the strongest one
    /// available — the generic "Visual unavailable" hatch — was being
    /// painted over regions the guest's own drawing had already filled.
    /// The claim was not merely redundant there, it was false: the visual
    /// WAS available, and this host had just drawn it. NOW's own Workshop
    /// sidebar lost all fourteen of its icons that way, and Date & Time
    /// lost its date and its time (2026-08-06 screenshots).
    ///
    /// Nothing downstream could tell, because the replay reported one
    /// Bool for a whole window. This is the missing per-region answer.
    ///
    /// **An ERASE is not ink.** That is the load-bearing distinction and
    /// the reason this is not simply "the ops' bounding boxes": a
    /// composite repaint opens with a full-window erase, so counting
    /// erases would mark every rectangle of every window as covered and
    /// silence every placeholder, which is this defect inverted. Only
    /// operations that add something a person can see are recorded —
    /// text, lines, frames, paints, fills, inverts, and the placed art or
    /// plates a blit resolves to.
    ///
    /// The replay's OWN unavailable-bitmap marker counts as covered. It
    /// has already said the honest thing about that rectangle, and a
    /// second hatch on top of it states nothing new.
    public final class Coverage {
        public private(set) var inked: [CGRect] = []

        /// **The per-rectangle owner map, in the order it was decided.**
        ///
        /// The ladder resolves every rectangle it is asked about; this is
        /// simply the resolution written down instead of thrown away. It
        /// costs one append per drawing operation and only exists when a
        /// caller passes a `Coverage` at all, which the live render does
        /// and nothing else has to.
        ///
        /// It is here rather than in a new type because the alternative is
        /// a second traversal of the same ops reaching the same answers by
        /// a parallel route — which is how two halves of one rule drift
        /// apart, and this file's own history is the argument.
        ///
        /// Sweep-shaped readers want it because "the render was stable"
        /// and "the render was stable AND every rectangle had the same
        /// owner both times" are different claims, and only the second one
        /// is what plan 018 promised.
        public private(set) var owners: [(rect: CGRect,
                                          rung: ProvenanceLadder.Rung)] = []
        public init() {}

        func add(_ rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            inked.append(rect)
        }

        func attribute(_ rect: CGRect, _ rung: ProvenanceLadder.Rung) {
            guard rect.width > 0, rect.height > 0 else { return }
            owners.append((rect, rung))
        }

        /// Who owns a rectangle, last decision wins — the render draws in
        /// order, so the last claim on a rectangle is the one visible.
        public func owner(of frame: CGRect) -> ProvenanceLadder.Rung? {
            owners.last { $0.rect.intersects(frame) }?.rung
        }

        /// Whether the replay drew anything inside `frame`.
        ///
        /// The question a PLACEHOLDER asks: any ink at all means the
        /// visual was available and is underneath, so "unavailable" over
        /// it would be a false claim rather than a weak one.
        public func covers(_ frame: CGRect) -> Bool {
            inked.contains { $0.intersects(frame) }
        }

        /// Whether the replay drew the SUBSTANCE of `frame` — a single
        /// inked rectangle covering at least half of it.
        ///
        /// A different question from ``covers(_:)``, and separating them
        /// cost Date & Time both of its check boxes. A semantic row that
        /// would otherwise duplicate the machine's own drawing must yield
        /// to it — but the row's little mark box sits a pixel from the
        /// group box's left frame line, and "does any ink intersect this
        /// 12×12 square" answers yes to a line that merely runs past it.
        /// The label beside it is genuinely covered by the text run and
        /// genuinely must yield; the box is not and must not.
        ///
        /// Half, and a single rectangle rather than a union, because the
        /// union of a hundred small rects is expensive to compute per
        /// row and the cases this decides are not close: a replayed text
        /// run covers its row almost exactly, and a frame line clipping
        /// a corner covers a few per cent.
        ///
        /// **And the ink must be ABOUT this rectangle.** A window-scale
        /// paint — the panel face, which every control panel opens with —
        /// covers every row in the window completely, and counting it
        /// would silence the whole semantic plane on the grounds that
        /// something was painted underneath it. That is the same mistake
        /// `isBackgroundKind` refuses one plane over: a background names
        /// nothing. So an inked rectangle more than four times the area
        /// of the piece is swept-over ground rather than evidence about
        /// it. Date & Time's two check boxes are what measured the rule:
        /// their only "cover" was the panel's own 366×343 face.
        public func mostlyCovers(_ frame: CGRect) -> Bool {
            let area = frame.width * frame.height
            guard area > 0 else { return false }
            return inked.contains {
                guard $0.width * $0.height <= area * 4 else { return false }
                let hit = $0.intersection(frame)
                guard !hit.isNull else { return false }
                return hit.width * hit.height >= area / 2
            }
        }
    }

    /// Draw `ops` into `content` (mirror-space rect for the window's content
    /// area). Returns true if anything was drawn (so the renderer can skip its
    /// placeholder); `coverage`, when given, collects WHERE — see ``Coverage``.
    @discardableResult
    public static func draw(_ ops: [MirrorKit.DisplayOp], in ctx: GraphicsContext,
                            content: CGRect,
                            excluding semanticFrames: [CGRect] = [],
                            ladder: ProvenanceLadder? = nil,
                            coverage: Coverage? = nil) -> Bool {
        /* THE LADDER IS THE POLICY; this replay is one of its two readers.
           Given none, it falls back to a ladder that names nothing — which
           makes every unjoined blit an unknown. That default is the honest
           one: a caller that has not said what the semantic plane knows has
           not earned a claim about any rectangle. */
        let ladder = ladder ?? ProvenanceLadder(owning: semanticFrames)
        guard !ops.isEmpty else { return false }
        var g = ctx
        g.clip(to: Path(content))

        var fg = Color.black
        var bg = Color.white
        var originH = 0
        var originV = 0
        /* THE CLIP IS PORT-LOCAL AND MOVES WITH THE ORIGIN, so it is held
           as the guest's own four integers and resolved against whatever
           origin is current when something draws — never frozen into a
           mirror-space rectangle when the clip op arrives.
           `SetOrigin` offsets a port's visRgn but NOT its clipRgn: the
           clip keeps its local coordinates, so shifting the origin slides
           it across the pixels. That is not a corner case, it is the
           idiom for drawing a row of identical cells — set the clip once,
           then move the origin per cell — and Sherlock 2's channel grid
           is exactly it: one `SetClip (0,0,51,46)`, then sixteen origins.
           Freezing the rectangle pinned the clip to the FIRST cell, so
           fifteen wells and eight channel icons were clipped away and the
           grid rendered as empty boxes. */
        var clip: [Int]?
        /// The most recent painted/filled rectangle and the colour it was
        /// painted in — the evidence `textInk` needs to recognise a
        /// highlight it is about to write invisible text into.
        var lastFill: (rect: CGRect, color: Color)?

        func pt(_ h: Int, _ v: Int) -> CGPoint {
            CGPoint(x: content.minX + CGFloat(h - originH),
                    y: content.minY + CGFloat(v - originV))
        }

        func drawingContext() -> GraphicsContext {
            var draw = g
            if let clip, clip.count == 4 {
                let bounded = rectFrom(clip, pt: pt).intersection(content)
                if !bounded.isNull { draw.clip(to: Path(bounded)) }
            }
            return draw
        }

        /* ONLY AN UNJOINED BLIT MAY BE SILENCED, which is rung 1's own
           exclusion said in code.
           `docs/render-composition.md` states the ladder as "rung 1 beats
           rung 2", and "the reversal is safe because of what rung 1
           excludes: an unjoined blit is not ink". This predicate was the
           half that never got there: it silenced TEXT, LINES and SHAPES
           inside a semantic rectangle too, and those are the machine's
           own drawing — the strongest evidence there is about what the
           window looks like.

           What it cost, and why it is the most dangerous of the five
           defects slice 16 found: NOW's own Workshop sidebar drew
           "Capture and stre…" on the guest — the application's own
           `TruncString`, because the row is 92 points wide — and the
           mirror printed "Capture and stream", because the DITL row that
           silenced the drawn run carries the untruncated title. The
           render looked BETTER than the machine and was a divergence
           from it, which nobody would report as a bug.

           The second gate is unchanged and still separate: whether a
           semantic row may DRAW OVER ink is `Coverage`'s question, not
           this one (`SceneRenderer.drawDialogItem`). A row that no
           longer silences the drawing must not then paint on top of it,
           or the two answers stack. */
        func semanticOwns(_ op: MirrorKit.DisplayOp) -> Bool {
            guard op.op == "bits", let r = op.dst, r.count == 4 else {
                return false
            }
            let bounds = rectFrom(r, pt: pt)
            return semanticFrames.contains { $0.contains(bounds) }
        }

        var drew = false

        // CopyBits carries geometry but no pixels. Replay just the state that
        // locates and clips those destinations, then paint their unavailable
        // markers below every structured op. Guest order remains authoritative
        // among the structured ops in the second pass.
        var bitsOriginH = 0
        var bitsOriginV = 0
        var bitsClip: [Int]?
        func bitsPoint(_ h: Int, _ v: Int) -> CGPoint {
            CGPoint(x: content.minX + CGFloat(h - bitsOriginH),
                    y: content.minY + CGFloat(v - bitsOriginV))
        }
        for op in ops {
            if op.op == "state" {
                switch op.kind {
                case "origin":
                    if let o = op.origin, o.count == 2 {
                        bitsOriginH = o[0]; bitsOriginV = o[1]
                    }
                case "clip":
                    if let r = op.rect, r.count == 4 { bitsClip = r }
                default:
                    break
                }
                continue
            }
            guard op.op == "bits", let d = op.dst, d.count == 4 else {
                continue
            }
            /* A BLIT THIS PASS WILL NOT ANSWER MUST NOT BE RECORDED AS
               INKED. The second loop yields an unjoined blit to the
               semantic row that contains it and draws nothing; this loop
               recorded coverage for it anyway, so `Coverage.covers` said
               "the replay drew here" about a rectangle nothing had
               drawn. Date & Time's two check boxes vanished on exactly
               that: the row yielded to a claim of ink, and the ink was
               never put down. */
            guard !semanticOwns(op) else { continue }
            var draw = g
            if let bitsClip, bitsClip.count == 4 {
                let bounded = rectFrom(bitsClip, pt: bitsPoint)
                    .intersection(content)
                if !bounded.isNull { draw.clip(to: Path(bounded)) }
            }
            let frame = rectFrom(d, pt: bitsPoint)
            /* WHICH PASS A BLIT IS ANSWERED IN IS A DRAW-ORDER QUESTION,
               NOT A PROVENANCE ONE, and the two must not be confused
               again. The ladder decides WHAT is drawn — art or the marked
               unknown — and that answer is identical in both passes. This
               only decides WHEN.

               Small answers go in stream order (pass 2) because a
               composite repaint opens with a full-window erase and
               anything drawn before it is wiped: that is why Sherlock 2's
               channel cells rendered as bare background the first time
               rung 4 was wired, and `DrawnCellGridTests` said so.
               Window-scale answers stay here, ahead of everything, for the
               original reason — a mark that large drawn in order would
               cover text the guest DID report. */
            if !Self.answeredInStreamOrder(frame) {
                if ladder.owner(ofUnjoinedBlit: frame) == .unknown {
                    drawUnavailableBits(in: draw, frame: frame)
                    coverage?.add(frame)
                    coverage?.attribute(frame, .unknown)
                    drew = true
                }
                continue
            }
            coverage?.add(frame)
            drew = true
        }

        for op in ops {
            /* State always flows: a control-local draw may establish the
               colour/origin/clip used by the next app-owned operation. Only
               concrete drawing wholly contained by one semantic rectangle
               yields to P2. Large background erases still cross that region
               and therefore remain P3-owned. */
            if semanticOwns(op) { continue }
            switch op.op {
            case "state":
                switch op.kind {
                case "origin":
                    if let o = op.origin, o.count == 2 { originH = o[0]; originV = o[1] }
                case "fg":
                    if let c = op.rgb, c.count == 3 { fg = rgb(c) }
                case "bg":
                    if let c = op.rgb, c.count == 3 { bg = rgb(c) }
                case "clip":
                    if let r = op.rect, r.count == 4 { clip = r }
                default:
                    break
                }
            case "text":
                guard let s = op.text, !s.isEmpty, let p = op.pen, p.count == 2
                else { continue }
                let font = strike(font: op.font ?? 3, size: op.size ?? 12)
                let shown = Self.shownText(s, truncated: op.trunc == true,
                                           in: font)
                let where0 = pt(p[0], p[1])
                let draw = drawingContext()
                let ink = Self.textInk(fg: fg, bg: bg, at: where0,
                                       lastFill: lastFill)
                if let font {
                    font.draw(shown, in: draw, x: where0.x,
                              baselineY: where0.y, color: ink)
                    coverage?.add(CGRect(
                        x: where0.x,
                        y: where0.y - CGFloat(font.ascent),
                        width: CGFloat(font.width(shown)),
                        height: CGFloat(font.ascent + font.descent)))
                    coverage?.attribute(CGRect(
                        x: where0.x,
                        y: where0.y - CGFloat(font.ascent),
                        width: CGFloat(font.width(shown)),
                        height: CGFloat(font.ascent + font.descent)), .ink)
                } else {
                    draw.draw(draw.resolve(Text(shown)
                        .font(.system(size: CGFloat(op.size ?? 12)))
                        .foregroundColor(ink)),
                        at: CGPoint(x: where0.x, y: where0.y), anchor: .bottomLeading)
                    coverage?.add(CGRect(
                        x: where0.x,
                        y: where0.y - CGFloat(op.size ?? 12),
                        width: CGFloat(shown.count * (op.size ?? 12)) / 2,
                        height: CGFloat(op.size ?? 12)))
                    coverage?.attribute(CGRect(
                        x: where0.x,
                        y: where0.y - CGFloat(op.size ?? 12),
                        width: CGFloat(shown.count * (op.size ?? 12)) / 2,
                        height: CGFloat(op.size ?? 12)), .ink)
                }
                drew = true
            case "line":
                guard let f = op.from, let t = op.to,
                      f.count == 2, t.count == 2 else { continue }
                /* THE HALF PIXEL. QuickDraw's `MoveTo(h,v); LineTo(…)` with
                   a 1×1 pen inks the PIXEL whose top-left corner is (h,v);
                   Core Graphics strokes a line CENTRED on the coordinate.
                   Stroking at an integer therefore spreads one black row
                   across two rows at half coverage, and every 1-pixel frame
                   and bevel in every window came out as two rows of mid
                   grey. Measured on the Appearance panel's pane frame,
                   2026-08-07: `#D9D9D9` where the machine draws `#000000`,
                   and its two bevel rows `#EEEEEE`/`#F7F7F7` where the
                   machine draws `#CCCCCC`/`#FFFFFF`. Moving to the pixel's
                   centre is the whole fix, and it applies to the frame verb
                   just above for the same reason. */
                var path = Path()
                path.move(to: pt(f[0], f[1]).applying(Self.pixelCentre))
                path.addLine(to: pt(t[0], t[1]).applying(Self.pixelCentre))
                let draw = drawingContext()
                /* AND A SQUARE CAP, for the other half of the same defect.
                   `LineTo` inks BOTH endpoints, so a line from h to h2
                   covers h2 - h + 1 pixels; a butt-capped stroke between
                   their centres covers half a pixel less at each end. The
                   Appearance panel's tab top edge lost its first and last
                   column to exactly that — `#777777` where the machine has
                   `#000000`, one pixel wide, at both ends of every line in
                   every window. */
                draw.stroke(path, with: .color(fg),
                            style: StrokeStyle(lineWidth: 1, lineCap: .square))
                coverage?.add(path.boundingRect.insetBy(dx: -0.5, dy: -0.5))
                coverage?.attribute(path.boundingRect.insetBy(dx: -0.5, dy: -0.5), .ink)
                drew = true
            case "bits":
                /* RUNG 3, AND IT IS ADDRESSED BY IDENTITY. An unjoined
                   blit carries geometry and no pixels, so the only thing
                   that can say what belongs here is the semantic plane.
                   Where it named the rectangle, its art is drawn — here,
                   in stream order, so the composite's own erases precede
                   it instead of wiping it. Where it did not, the honest
                   answer was already drawn as an unknown in the pass
                   above.

                   WHAT THIS REPLACED: `iconSized`, which painted a
                   generic DOCUMENT over any near-square blit between 12
                   and 36 points. Sweep A found that firing on Mouse's
                   three tracking pictures, Sherlock 2's nine channel
                   buttons, two alert icons and the Finder's 16×16 scroll
                   arrows — a confident wrong answer every time, and never
                   once on an actual document. Size is not identity. */
                guard let d = op.dst, d.count == 4 else { break }
                let frame = rectFrom(d, pt: pt)
                switch ladder.art(at: frame) {
                case .icon:
                    guard let icon = IconAtlas.namedIcon(
                        "document", size: IconAtlas.Size.fitting(frame))
                    else { break }
                    let draw = drawingContext()
                    draw.draw(Image(decorative: icon, scale: 1), in: frame)
                    coverage?.add(frame)
                    coverage?.attribute(frame, .namedArt)
                    drew = true
                case .control:
                    drawControlPlate(in: drawingContext(), frame: frame)
                    coverage?.add(frame)
                    coverage?.attribute(frame, .namedArt)
                    drew = true
                case nil:
                    /* Rung 4, in stream order. A window-scale unknown was
                       already marked in the pre-pass; anything smaller is
                       marked here so a composite's own erase precedes it
                       instead of wiping it. */
                    guard Self.answeredInStreamOrder(frame) else { break }
                    drawUnavailableBits(in: drawingContext(), frame: frame)
                    coverage?.add(frame)
                    coverage?.attribute(frame, .unknown)
                    drew = true
                }
            case "rect", "rrect", "oval", "rgn":
                guard let r = op.rect, r.count == 4 else { continue }
                let rect = rectFrom(r, pt: pt)
                let draw = drawingContext()
                /* A REGION'S BOX IS NOT ALWAYS ITS SHAPE, and since the
                   contract gained the shape discriminator
                   (`MirrorKit.RegionShape`) the host can finally tell
                   which. The PIXELS are deliberately unchanged by that
                   knowledge, and the decision is worth stating because
                   the obvious move is to paint the doubt:

                   - Every one of the 39 region ops in the measured
                     capture corpus is an ERASE, and for an erase the
                     bounding box is the same area approximated. Painting
                     a marker over it would replace a probably-right
                     background with a certainly-wrong annotation.
                   - Frame, paint and fill of a NON-rectangular region
                     are the cases where a hard rectangle really is a
                     claim stronger than the evidence — and there are
                     zero of them to look at. Grading a placeholder
                     nobody has a capture of is how the replay acquired
                     its arbitrary local heuristics before
                     docs/render-composition.md existed.

                   So the honesty lives where it can be checked: the
                   deferred-op inventory names an approximated region as
                   such, and separates it from one whose box is exact and
                   from one whose resident never said. When a capture
                   with a non-rectangular fill exists, grade it then,
                   against it. */
                switch op.verb ?? 0 {
                case 0:   // frame
                    draw.stroke(Path(rect.insetBy(dx: 0.5, dy: 0.5)),
                                with: .color(fg), lineWidth: 1)
                    coverage?.add(rect)
                    coverage?.attribute(rect, .ink)
                    drew = true
                case 1, 4:  // paint / fill
                    draw.fill(Path(rect), with: .color(fg))
                    /* Remembered for the text that may land on top of it —
                       see `textInk`. Only the LAST fill is kept: a
                       highlight is painted immediately before the run it
                       highlights, and a fill further back in the stream
                       has had every chance to be covered. */
                    lastFill = (rect, fg)
                    coverage?.add(rect)
                    coverage?.attribute(rect, .ink)
                    drew = true
                case 2:   // erase uses the port's current background colour
                    draw.fill(Path(rect), with: .color(bg))
                    drew = true
                case 3:
                    invert(rect, in: draw)
                    coverage?.add(rect)
                    coverage?.attribute(rect, .ink)
                    drew = true
                default:
                    break
                }
            default:
                /* AN OP THIS RENDERER CANNOT DRAW IS STILL SOMETHING THE
                   MACHINE DREW, and until now it left no trace at all.
                   `poly` is the arrow family — Memory's fourteen are
                   8x4 and 8x5 paints, which is a stepper's two triangles
                   and a popup's chevron — so every stepper, scroll and
                   popup arrow in the corpus simply was not there. Slice
                   2 deleted the size-based classification that used to
                   paint a document icon over them, which was right, and
                   left nothing in its place, which was not: "an arrow
                   that draws nothing where it used to draw a wrong
                   document icon is progress, but rung 4 should still
                   mark it" (plan 018 slice 16, defect 5).

                   The marked unknown and NOT a triangle. The op carries
                   a bounding rect and a verb and no shape, so drawing a
                   triangle in it is the region defect one family over: a
                   plausible guess with no evidence, on a rectangle small
                   enough that the guess would read as fact. Rung 4 says
                   the true thing — something is drawn here and this host
                   cannot say what — and the deferred-op inventory keeps
                   counting it so the gap stays measurable.

                   An ERASE is exempt, for the same reason `Coverage`
                   does not count one: it removes rather than adds, and
                   marking it would claim missing content where the
                   machine cleared the ground. */
                guard op.verb != 2, let r = op.rect, r.count == 4 else {
                    break
                }
                let frame = rectFrom(r, pt: pt)
                drawUnavailableBits(in: drawingContext(), frame: frame)
                coverage?.add(frame)
                coverage?.attribute(frame, .unknown)
                drew = true
            }
        }

        /* TABS, AFTER EVERYTHING ELSE, AND THAT ORDER IS LOAD-BEARING.
           `DrawThemeTab` leaks its label boxes, their bevel and their
           titles through the bottlenecks but not its slanted end caps, so
           the mirror has drawn tab labels floating on flat grey for as long
           as anyone has looked (fidelity sweep 2026-08-07-a, verdict 4).
           `DrawnTabStrip` recovers the caps' geometry from the boxes that
           DID arrive; this places them.

           It runs last because the front tab must ERASE one row of the
           pane's own frame line, and the replay draws that line. Running
           the pass earlier would put the caps down and then stroke the
           pane straight through them. The title is protected by a clip
           inside `PlatinumTab.draw`, not by ordering. */
        for strip in MirrorKit.DrawnTabStrip.derive(from: ops) {
            PlatinumTab.draw(strip, in: g,
                             origin: { h, v in
                                 CGPoint(x: content.minX + CGFloat(h),
                                         y: content.minY + CGFloat(v))
                             },
                             coverage: coverage)
            drew = true
        }
        return drew
    }

    /// `invertVerb` (GrafVerb 3), replayed for real.
    ///
    /// This was skipped for most of the plane's life with the note
    /// "invert needs destination pixels we do not carry", and that was
    /// TRUE of the mirror it was written for — a renderer that placed a
    /// pixel island had no addressable destination of its own. It stopped
    /// being true when the host began compositing its own canvas: the
    /// pixels under the rect are pixels this replay just drew, so the
    /// operation QuickDraw performs against the framebuffer is available
    /// as a difference blend against the layer.
    ///
    /// Filling with WHITE under `.difference` is exactly `1 - dst` per
    /// channel, which is what `InvertRect` does on the guest. It is
    /// correct only because the renderer paints the content face opaque
    /// before the replay runs (`SceneRenderer`); over a transparent layer
    /// a difference blend would paint white and claim a highlight that is
    /// not there.
    ///
    /// PARITY IS THE SEMANTIC, not a defect. Invert is how classic Mac OS
    /// draws a text caret, and a drain holding N blinks of one caret ends
    /// visibly on or off according to N's parity — Sherlock 2's search
    /// caret arrives 22 times in one live capture and 11 in another, and
    /// replaying every one of them reproduces the state the machine was
    /// actually in at the end of that stream. Coalescing them would be a
    /// prettier picture of a machine nobody watched.
    private static func invert(_ rect: CGRect, in ctx: GraphicsContext) {
        guard rect.width > 0, rect.height > 0 else { return }
        var flip = ctx
        flip.blendMode = .difference
        flip.fill(Path(rect), with: .color(.white))
    }

    /// What to DRAW for a run the guest declared truncated.
    ///
    /// The capture is honest and the render was not: a text record carries
    /// `len`, `fullLen` and `trunc`, and the Appearance panel's description
    /// arrives as 64 of its 69 bytes with `trunc: true`. Drawing those 64
    /// characters unmarked states that they are the whole string — a false
    /// claim about the machine, and the same class of mistake as hatching
    /// "Bitmap unavailable" over a control that was never missing.
    ///
    /// AN ELLIPSIS, and the argument for it over the alternatives: it is
    /// what the Mac itself draws for a string that did not fit (`TruncString`
    /// puts one exactly here), so it reads as truncation to the only
    /// audience that matters without a legend; it costs the width of one
    /// glyph rather than a badge's worth of chrome; and it cannot be
    /// mistaken for content, because no run in this corpus ends in one it
    /// did not ask for. The rejected alternatives were a marker outside the
    /// text (invisible at a glance, and the run's own rect is the only place
    /// a viewer looks) and raising the 64-byte cap (a ring bound that should
    /// move on a measurement, not to hide its own symptom).
    ///
    /// `fullLen` is deliberately NOT rendered. It rides on the op for
    /// whoever can use it — a tooltip, an accessibility string, a semantic
    /// join — and painting "69" beside the text would be the mirror talking
    /// about itself inside a picture of the machine.
    static func shownText(_ text: String, truncated: Bool,
                          in font: BitmapFont?) -> String {
        guard truncated else { return text }
        return text + (font?.ellipsis ?? "…")
    }

    /// The colour to draw a run in, given what was just painted under it.
    ///
    /// The replay tracks one foreground and one background colour per port
    /// and drew every run in `fg`. That is right until an application
    /// highlights: the Finder draws a selected icon's label by painting the
    /// label's rectangle and writing the text over it in the INVERSE
    /// colour, and the paint crosses while the inverse does not — so
    /// "System Folder" rendered as a solid black bar with the label
    /// swallowed inside it (R8 of the 2026-08-06 sweep), which a viewer
    /// reads as damage rather than as selection. The machine's own pixels
    /// for that moment show white text on the black bar.
    ///
    /// So: a run whose pen sits inside a rectangle just painted in the
    /// colour the run itself would use is drawn in the port's BACKGROUND
    /// colour instead. The rule is narrow on purpose — it fires only when
    /// the alternative is provably invisible, which is never a rendering
    /// anyone wanted.
    ///
    /// This is NOT the skipped-invert work and fixing invert will not cover
    /// it: this capture carries eleven paint ops and zero invert ops
    /// (`testTheFindersSelectionNeverReachesTheCapture`). The label was
    /// painted, never inverted.
    static func textInk(fg: Color, bg: Color, at pen: CGPoint,
                        lastFill: (rect: CGRect, color: Color)?) -> Color {
        guard let lastFill, lastFill.color == fg,
              lastFill.rect.contains(pen) else { return fg }
        return bg
    }

    /// **Whether a blit's answer is drawn in stream order, or ahead of
    /// everything. A DRAW-ORDER rule — it decides nothing about what the
    /// rectangle IS.**
    ///
    /// It is the same shape range that `controlSized` and `iconSized` used
    /// to classify by, and keeping the numbers while deleting the meaning
    /// is deliberate: they were always a good description of "small enough
    /// that a composite's erase will wipe it, and small enough that drawing
    /// it in order cannot swallow the window's own text". They were never a
    /// good answer to "what is this". Sweep A found the old claim wrong
    /// four times in fifteen windows; nobody has ever found the ORDER
    /// wrong.
    ///
    /// The bound is measured. Across the committed capture corpus every
    /// near-square blit is 12×12 through 32×32, every themed control is
    /// short and not window-spanning, and the things above the bound are
    /// composites the size of a window.
    static func answeredInStreamOrder(_ frame: CGRect) -> Bool {
        let controlish = frame.height >= 6 && frame.height <= 48
            && frame.width >= 8 && frame.width <= 460
            && !(frame.width > 200 && frame.height > 40)
        let iconish = frame.width >= 12 && frame.width <= 36
            && frame.height >= 12 && frame.height <= 36
        return controlish || iconish
    }

    /// A control-shaped blit, drawn as the Platinum plate it is: a face
    /// with a light bevel. Deliberately NOT typed as field-or-button —
    /// the drawing stream does not say which, and a plate is the honest
    /// shape both share. The semantic plane is what knows the type, and
    /// where it does, it draws over this.
    private static func drawControlPlate(in ctx: GraphicsContext,
                                         frame: CGRect) {
        guard frame.width > 2, frame.height > 2 else { return }
        ctx.fill(Path(frame), with: .color(Platinum.g1))
        ctx.stroke(Path(frame.insetBy(dx: 0.5, dy: 0.5)),
                   with: .color(Platinum.g4), lineWidth: 1)
        var light = Path()
        light.move(to: CGPoint(x: frame.minX + 1, y: frame.maxY - 1))
        light.addLine(to: CGPoint(x: frame.minX + 1, y: frame.minY + 1))
        light.addLine(to: CGPoint(x: frame.maxX - 1, y: frame.minY + 1))
        ctx.stroke(light, with: .color(Platinum.g0), lineWidth: 1)
    }

    /// From a QuickDraw pixel's top-left corner to its centre — see the
    /// note in the `line` case.
    static let pixelCentre = CGAffineTransform(translationX: 0.5, y: 0.5)

    private static func rgb(_ c: [Int]) -> Color {
        Color(red: Double(c[0]) / 65535, green: Double(c[1]) / 65535,
              blue: Double(c[2]) / 65535)
    }

    private static func rectFrom(_ r: [Int],
                                 pt: (Int, Int) -> CGPoint) -> CGRect {
        let a = pt(r[0], r[1]); let b = pt(r[2], r[3])
        return CGRect(x: a.x, y: a.y,
                      width: max(0, b.x - a.x), height: max(0, b.y - a.y))
    }

    private static func drawUnavailableBits(in ctx: GraphicsContext,
                                             frame: CGRect) {
        guard frame.width > 1, frame.height > 1 else { return }
        var clipped = ctx
        clipped.clip(to: Path(frame))
        /* One definition, in UnknownVisual — this used to be a second copy
           of the scene renderer's hatch, identical by coincidence. */
        UnknownVisual.drawGround(in: clipped, frame: frame)
        guard let font = FontBook.small,
              let at = UnknownVisual.captionOrigin(
                  in: frame, ascent: CGFloat(font.ascent)) else { return }
        font.draw("Bitmap unavailable", in: clipped, x: at.x, baselineY: at.y,
                  color: UnknownVisual.caption)
    }

    /// Map a guest font id + size to a bundled NFNT strike.
    ///
    /// The id is the port's own `txFont`, a QuickDraw font family number,
    /// and the two small ones are ROLES rather than faces: **0 is the
    /// system font** and **1 is `applFont`**, which on a US Mac OS 9
    /// system resolves to Geneva. Everything else is a family id, and
    /// Geneva is the fallback for the families this pack does not carry.
    ///
    /// Both halves of that used to be wrong, and it is R1 of the
    /// 2026-08-06 fidelity sweep. `applFont` was mapped to the system
    /// face, and the requested size was thrown away with it — so the
    /// Memory panel, which draws 251 of its 266 text ops as font 1 at
    /// size 9, rendered every one of them as Chicago 12: a third too
    /// large, overrunning its own controls and spilling past the
    /// window's right edge. The machine's own pixels for that panel are
    /// Geneva 9 (`memory-guest.ppm`).
    ///
    /// `txSize` 0 means "the port's default size", which QuickDraw
    /// resolves to 12; it is not a request for a zero-height strike.
    /// What happens when the pack has no strike at the wanted size is
    /// `FontBook.nearest`'s business, and it is documented there.
    /// Internal rather than private so the fidelity gate can ask which
    /// strike a captured op would be drawn in without rendering a pixel.
    static func strike(font: Int, size: Int) -> BitmapFont? {
        let wanted = size > 0 ? size : 12
        switch font {
        case 0:
            return FontBook.nearest(face: "chicago", size: wanted)
        default:
            return FontBook.nearest(face: "geneva", size: wanted)
        }
    }
}
