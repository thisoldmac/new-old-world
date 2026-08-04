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
public enum DisplayReplay {

    /// Draw `ops` into `content` (mirror-space rect for the window's content
    /// area). Returns true if anything was drawn (so the renderer can skip its
    /// placeholder).
    @discardableResult
    public static func draw(_ ops: [MirrorKit.DisplayOp], in ctx: GraphicsContext,
                            content: CGRect,
                            excluding semanticFrames: [CGRect] = []) -> Bool {
        guard !ops.isEmpty else { return false }
        var g = ctx
        g.clip(to: Path(content))

        var fg = Color.black
        var bg = Color.white
        var originH = 0
        var originV = 0
        var clip: CGRect?

        func pt(_ h: Int, _ v: Int) -> CGPoint {
            CGPoint(x: content.minX + CGFloat(h - originH),
                    y: content.minY + CGFloat(v - originV))
        }

        func drawingContext() -> GraphicsContext {
            var draw = g
            if let clip {
                let bounded = clip.intersection(content)
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
        var bitsClip: CGRect?
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
                    if let r = op.rect, r.count == 4 {
                        bitsClip = rectFrom(r, pt: bitsPoint)
                    }
                default:
                    break
                }
                continue
            }
            guard op.op == "bits", let d = op.dst, d.count == 4 else {
                continue
            }
            var draw = g
            if let bitsClip {
                let bounded = bitsClip.intersection(content)
                if !bounded.isNull { draw.clip(to: Path(bounded)) }
            }
            drawUnavailableBits(in: draw, frame: rectFrom(d, pt: bitsPoint))
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
                    if let r = op.rect, r.count == 4 {
                        clip = rectFrom(r, pt: pt)
                    }
                default:
                    break
                }
            case "text":
                guard let s = op.text, !s.isEmpty, let p = op.pen, p.count == 2
                else { continue }
                let font = strike(font: op.font ?? 3, size: op.size ?? 12)
                let where0 = pt(p[0], p[1])
                let draw = drawingContext()
                if let font {
                    font.draw(s, in: draw, x: where0.x, baselineY: where0.y,
                              color: fg)
                } else {
                    draw.draw(draw.resolve(Text(s)
                        .font(.system(size: CGFloat(op.size ?? 12)))
                        .foregroundColor(fg)),
                        at: CGPoint(x: where0.x, y: where0.y), anchor: .bottomLeading)
                }
                drew = true
            case "line":
                guard let f = op.from, let t = op.to,
                      f.count == 2, t.count == 2 else { continue }
                var path = Path()
                path.move(to: pt(f[0], f[1]))
                path.addLine(to: pt(t[0], t[1]))
                let draw = drawingContext()
                draw.stroke(path, with: .color(fg), lineWidth: 1)
                drew = true
            case "bits":
                break // unavailable geometry was painted below this pass
            case "rect", "rrect", "oval", "rgn":
                guard let r = op.rect, r.count == 4 else { continue }
                let rect = rectFrom(r, pt: pt)
                let draw = drawingContext()
                switch op.verb ?? 0 {
                case 0:   // frame
                    draw.stroke(Path(rect), with: .color(fg), lineWidth: 1)
                    drew = true
                case 1, 4:  // paint / fill
                    draw.fill(Path(rect), with: .color(fg))
                    drew = true
                case 2:   // erase uses the port's current background colour
                    draw.fill(Path(rect), with: .color(bg))
                    drew = true
                default:   // invert needs destination pixels we do not carry
                    break
                }
            default:
                break   // arc/poly remain unsupported structured ops
            }
        }
        return drew
    }

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

    /// Map a guest font id + size to a bundled NFNT strike. Font 3 = Geneva
    /// (the app/content face) at the nearest bundled size; 0/1 = system
    /// (Chicago 12). Unknown ids fall back to Geneva.
    private static func strike(font: Int, size: Int) -> BitmapFont? {
        if font == 0 || font == 1 {
            return FontBook.system            // Chicago 12
        }
        // Geneva: exact size if bundled, else nearest.
        let sizes = [9, 10, 12, 14]
        let exact = "geneva-\(size)"
        if let f = FontBook.font(exact) { return f }
        let nearest = sizes.min(by: { abs($0 - size) < abs($1 - size) }) ?? 12
        return FontBook.font("geneva-\(nearest)") ?? FontBook.app
    }
}
