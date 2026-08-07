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
        public init() {}

        func add(_ rect: CGRect) {
            guard rect.width > 0, rect.height > 0 else { return }
            inked.append(rect)
        }

        /// Whether the replay drew anything inside `frame`.
        public func covers(_ frame: CGRect) -> Bool {
            inked.contains { $0.intersects(frame) }
        }
    }

    /// Draw `ops` into `content` (mirror-space rect for the window's content
    /// area). Returns true if anything was drawn (so the renderer can skip its
    /// placeholder); `coverage`, when given, collects WHERE — see ``Coverage``.
    @discardableResult
    public static func draw(_ ops: [MirrorKit.DisplayOp], in ctx: GraphicsContext,
                            content: CGRect,
                            excluding semanticFrames: [CGRect] = [],
                            coverage: Coverage? = nil) -> Bool {
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

        func semanticOwns(_ op: MirrorKit.DisplayOp) -> Bool {
            func owns(_ bounds: CGRect) -> Bool {
                semanticFrames.contains { $0.contains(bounds) }
            }
            switch op.op {
            case "text":
                guard let p = op.pen, p.count == 2 else { return false }
                let point = pt(p[0], p[1])
                return semanticFrames.contains { $0.contains(point) }
            case "line":
                guard let from = op.from, let to = op.to,
                      from.count == 2, to.count == 2 else { return false }
                let a = pt(from[0], from[1])
                let b = pt(to[0], to[1])
                return semanticFrames.contains { $0.contains(a) && $0.contains(b) }
            case "bits":
                guard let r = op.dst, r.count == 4 else { return false }
                return owns(rectFrom(r, pt: pt))
            case "rect", "rrect", "oval", "rgn":
                guard let r = op.rect, r.count == 4 else { return false }
                return owns(rectFrom(r, pt: pt))
            default:
                return false
            }
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
            var draw = g
            if let bitsClip, bitsClip.count == 4 {
                let bounded = rectFrom(bitsClip, pt: bitsPoint)
                    .intersection(content)
                if !bounded.isNull { draw.clip(to: Path(bounded)) }
            }
            let frame = rectFrom(d, pt: bitsPoint)
            /* Icon-sized blits are NOT hatched here: they get the
               extracted generic icon in the second pass, IN STREAM
               ORDER, because a composite build opens with a full-window
               erase and anything this pass drew under it is wiped. The
               big placeholders stay in this pass for the original
               reason - they must never cover text the guest reported. */
            /* Control-shaped blits are theme art, not missing content;
               they are drawn as plates in the second pass, in stream
               order, for the same reason icons are. */
            if Self.iconSized(frame) || Self.controlSized(frame) { continue }
            drawUnavailableBits(in: draw, frame: frame)
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
                drew = true
            case "bits":
                /* An icon-sized blit gets the extracted generic icon (the
                   host's own icl8 pack) rather than nothing: identity is
                   deferred - PlotIconSuite interception - but a
                   recognisable stub at the right position beats an empty
                   cell. Drawn here, in stream order, so the composite's
                   own erases precede it instead of wiping it.

                   The SIZE is not a guess even though the identity is: a
                   16x16 destination is a list row, and OS 9 draws those
                   from the ics8 resource, which is its own hand-tuned
                   drawing rather than the icl8 shrunk. Picking by
                   destination stops the replay blurring a 32x32 into a
                   cell the machine fills crisply. */
                guard let d = op.dst, d.count == 4 else { break }
                let frame = rectFrom(d, pt: pt)
                if Self.iconSized(frame),
                   let icon = IconAtlas.namedIcon(
                       "document", size: IconAtlas.Size.fitting(frame)) {
                    let draw = drawingContext()
                    draw.draw(Image(decorative: icon, scale: 1), in: frame)
                    coverage?.add(frame)
                    drew = true
                } else if Self.controlSized(frame) {
                    drawControlPlate(in: drawingContext(), frame: frame)
                    coverage?.add(frame)
                    drew = true
                }
                // larger geometry was hatched before this pass
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
                    drew = true
                case 2:   // erase uses the port's current background colour
                    draw.fill(Path(rect), with: .color(bg))
                    drew = true
                case 3:
                    invert(rect, in: draw)
                    coverage?.add(rect)
                    drew = true
                default:
                    break
                }
            default:
                break   // arc/poly remain unsupported structured ops
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

    /// A blit the size and shape of an ordinary control.
    ///
    /// This exists because "Bitmap unavailable" was the wrong CLAIM for
    /// most of what a control panel blits. Under Appearance, a themed
    /// field, button or popup is DRAWN by blitting theme art — so Date
    /// & Time's every field arrived as a small CopyBits and the replay
    /// hatched each one as missing data. Nothing was missing: that
    /// window is chrome the host can draw natively, and a hatch saying
    /// otherwise is a false negative in the one direction that reads as
    /// a broken mirror.
    ///
    /// The bound is shape-based rather than a whitelist: a themed
    /// control is short and not window-spanning. Anything bigger keeps
    /// the honest hatch, because at that size an unjoined blit really
    /// is content we failed to reach.
    static func controlSized(_ frame: CGRect) -> Bool {
        frame.height >= 6 && frame.height <= 48
            && frame.width >= 8 && frame.width <= 460
            && !(frame.width > 200 && frame.height > 40)
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

    /// Roughly square and within the classic icon range (16×16 list rows
    /// up to 32×32 icon view, with margin for masks and badges).
    ///
    /// THE UPPER BOUND WAS 48 AND THAT MARGIN WAS DOING HARM. Sherlock 2's
    /// magnifier button is a 48×48 CopyBits at window-local (417,98) with no
    /// `blitsrc` — its source world is never hooked, so no pixels and no
    /// identity cross — and the old bound accepted it and painted a generic
    /// DOCUMENT icon over a round button. That is a placeholder typed more
    /// precisely than the drawing stream allows, which is the one rule
    /// docs/render-composition.md states about this layer.
    ///
    /// 36 is measured rather than picked: across all nine committed
    /// captures every near-square blit is 12×12, 16×16, 18×18, 21×20,
    /// 32×24 or 32×32 — and the only things above that are Sherlock's
    /// three magnifier blits. So the bound keeps every real icon and
    /// releases exactly the control, which then reads as the untyped
    /// Platinum plate `controlSized` already draws for theme art.
    static func iconSized(_ frame: CGRect) -> Bool {
        guard frame.width >= 12, frame.width <= 36,
              frame.height >= 12, frame.height <= 36 else { return false }
        let aspect = frame.width / max(frame.height, 1)
        return aspect > 0.7 && aspect < 1.4
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
        clipped.fill(Path(frame), with: .color(Platinum.g1))
        var x = frame.minX - frame.height
        while x < frame.maxX {
            var hatch = Path()
            hatch.move(to: CGPoint(x: x, y: frame.maxY))
            hatch.addLine(to: CGPoint(x: x + frame.height, y: frame.minY))
            clipped.stroke(hatch, with: .color(Platinum.g2), lineWidth: 1)
            x += 6
        }
        clipped.stroke(Path(frame), with: .color(Platinum.g3),
                       style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        guard frame.width >= 92, frame.height >= 14 else { return }
        let label = "Bitmap unavailable"
        if let font = FontBook.small {
            font.draw(label, in: clipped, x: frame.minX + 4,
                      baselineY: frame.midY + CGFloat(font.ascent) / 2,
                      color: Platinum.g4)
        }
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
