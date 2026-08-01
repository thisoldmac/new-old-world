import SwiftUI
import MirrorKit

/// Replays a window's captured QuickDraw ops (`Scene.Window.display`) into its
/// content area — the QDPeek content plane made visible. Text draws through the
/// extracted NFNT strikes at the op's exact pen position (closing M1's
/// positional reconstruction into pixel-honest glyphs); primitives draw as
/// Canvas paths; STATE ops set the current colour and origin.
///
/// Ops are port-local (window content coords); a `state`/`origin` op shifts
/// them. They're replayed in order — later ops paint over earlier, like the
/// guest framebuffer — clipped to the content rect.
public enum DisplayReplay {

    /// Draw `ops` into `content` (mirror-space rect for the window's content
    /// area). Returns true if anything was drawn (so the renderer can skip its
    /// placeholder).
    @discardableResult
    public static func draw(_ ops: [MirrorKit.DisplayOp], in ctx: GraphicsContext,
                            content: CGRect) -> Bool {
        guard !ops.isEmpty else { return false }
        var g = ctx
        g.clip(to: Path(content))

        var fg = Color.black
        var originH = 0
        var originV = 0

        func pt(_ h: Int, _ v: Int) -> CGPoint {
            CGPoint(x: content.minX + CGFloat(h - originH),
                    y: content.minY + CGFloat(v - originV))
        }

        var drew = false
        for op in ops {
            switch op.op {
            case "state":
                switch op.kind {
                case "origin":
                    if let o = op.origin, o.count == 2 { originH = o[0]; originV = o[1] }
                case "fg":
                    if let c = op.rgb, c.count == 3 { fg = rgb(c) }
                default:
                    break   // clip/bg tracked by the guest; not needed to draw
                }
            case "text":
                guard let s = op.text, !s.isEmpty, let p = op.pen, p.count == 2
                else { continue }
                let font = strike(font: op.font ?? 3, size: op.size ?? 12)
                let where0 = pt(p[0], p[1])
                if let font {
                    font.draw(s, in: g, x: where0.x, baselineY: where0.y,
                              color: fg)
                } else {
                    g.draw(g.resolve(Text(s)
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
                g.stroke(path, with: .color(fg), lineWidth: 1)
                drew = true
            case "rect", "rrect", "oval":
                guard let r = op.rect, r.count == 4 else { continue }
                let rect = rectFrom(r, pt: pt)
                switch op.verb ?? 0 {
                case 0:   // frame
                    g.stroke(Path(rect), with: .color(fg), lineWidth: 1)
                    drew = true
                case 1, 4:  // paint / fill
                    g.fill(Path(rect), with: .color(fg))
                    drew = true
                default:   // erase (usually bg) / invert — skip to avoid noise
                    break
                }
            default:
                break   // arc/poly/rgn/bits — v1 skips (M3 composes bits pixels)
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
