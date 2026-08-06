import SwiftUI
import CoreGraphics
import ImageIO

/// A Tier-2 Platinum bitmap font: a packed glyph sheet + per-glyph metrics
/// from the extracted platinum-pack (`fonts/<face>-<size>.{png,json}`). Draws
/// pixel-honest OS 9 text — the same NFNT strikes the guest renders (finding
/// `platinum-asset-extraction`: sheet vs live capture IoU 1.0).
///
/// The sheet is transparent-background black glyphs; text is drawn by using
/// the glyph coverage as an alpha mask and filling it with the wanted color,
/// so one strike serves every Platinum gray.
public final class BitmapFont {
    struct Glyph {
        let x, y, w, h, advance, left: Int
    }

    public let ascent: Int
    public let descent: Int
    public let leading: Int
    /// Full line height (cell) — advance the pen by this between rows.
    public let cellHeight: Int
    /// The face and point size this strike REALLY is, straight out of the
    /// extracted metrics rather than out of the name the caller asked for.
    /// A caller that asked for a size the pack does not carry gets the
    /// nearest one, and this is how it finds out which it got.
    public let face: String
    public let pointSize: Int

    private let sheet: CGImage
    private let sheetW: CGFloat
    private let sheetH: CGFloat
    private let glyphs: [Character: Glyph]
    private let space: Glyph

    public init?(face: String) {
        guard let pngURL = Bundle.module.url(
                forResource: face, withExtension: "png", subdirectory: "fonts"),
              let jsonURL = Bundle.module.url(
                forResource: face, withExtension: "json", subdirectory: "fonts"),
              let data = try? Data(contentsOf: pngURL),
              let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let meta = try? JSONSerialization.jsonObject(
                with: Data(contentsOf: jsonURL)) as? [String: Any] else {
            return nil
        }
        sheet = img
        sheetW = CGFloat(img.width)
        sheetH = CGFloat(img.height)
        ascent = (meta["ascent"] as? Int) ?? 0
        descent = (meta["descent"] as? Int) ?? 0
        leading = (meta["leading"] as? Int) ?? 0
        cellHeight = (meta["cellHeight"] as? Int)
            ?? (ascent + descent + leading)
        self.face = (meta["face"] as? String) ?? face
        pointSize = (meta["pointSize"] as? Int) ?? 0

        var table: [Character: Glyph] = [:]
        for (key, value) in (meta["glyphs"] as? [String: [String: Int]] ?? [:]) {
            guard let ch = key.first, key.count == 1 else { continue }
            table[ch] = Glyph(
                x: value["x"] ?? 0, y: value["y"] ?? 0,
                w: value["w"] ?? 0, h: value["h"] ?? 0,
                advance: value["advance"] ?? 0, left: value["left"] ?? 0)
        }
        glyphs = table
        space = table[" "] ?? Glyph(x: 0, y: 0, w: 0, h: 0, advance: 4, left: 0)
    }

    /// Whether this strike carries a glyph for `ch` at all. A strike that
    /// does not draws `ch` as blank space, which is why anything choosing
    /// its own characters (rather than the guest's) should ask first.
    public func has(_ ch: Character) -> Bool { glyphs[ch] != nil }

    /// The ellipsis this strike can ACTUALLY draw. `…` where the strike
    /// carries it, three periods where it does not — never the single
    /// character silently, because in an ASCII-only strike that renders
    /// as a blank, and a truncation mark nobody can see is the defect it
    /// exists to cure.
    public var ellipsis: String { has("…") ? "…" : "..." }

    /// Pixel width of a string on one line.
    public func width(_ string: String) -> Int {
        var w = 0
        for ch in string { w += (glyphs[ch] ?? space).advance }
        return w
    }

    /// Draw `string` in `color` with its left baseline at (x, baselineY).
    /// One clip layer masks all glyphs, then a single fill tints them — so
    /// any Platinum gray comes from the same black strike.
    public func draw(_ string: String, in ctx: GraphicsContext,
                     x: CGFloat, baselineY: CGFloat, color: Color) {
        var pen = x
        var boxes: [(dst: CGRect, g: Glyph)] = []
        for ch in string {
            let g = glyphs[ch] ?? space
            if g.w > 0, g.h > 0 {
                // The sheet cell's top sits (ascent) above the baseline.
                let dst = CGRect(x: pen + CGFloat(g.left),
                                 y: baselineY - CGFloat(ascent),
                                 width: CGFloat(g.w), height: CGFloat(g.h))
                boxes.append((dst, g))
            }
            pen += CGFloat(g.advance)
        }
        guard !boxes.isEmpty else { return }
        let union = boxes.dropFirst().reduce(boxes[0].dst) { $0.union($1.dst) }
        var layer = ctx
        layer.clipToLayer { inner in
            for (dst, g) in boxes {
                var gg = inner
                gg.clip(to: Path(dst))
                // Position the whole sheet so this glyph's (x,y) lands at dst.
                gg.draw(Image(decorative: sheet, scale: 1),
                        in: CGRect(x: dst.minX - CGFloat(g.x),
                                   y: dst.minY - CGFloat(g.y),
                                   width: sheetW, height: sheetH))
            }
        }
        layer.fill(Path(union), with: .color(color))
    }

    /// Draw centered horizontally on `centerX`, vertically centered on
    /// `centerY` (the cap band), a convenience for titles/labels.
    public func drawCentered(_ string: String, in ctx: GraphicsContext,
                             centerX: CGFloat, centerY: CGFloat, color: Color) {
        let w = CGFloat(width(string))
        let baseline = centerY + CGFloat(ascent - (ascent + descent) / 2)
        draw(string, in: ctx, x: centerX - w / 2, baselineY: baseline,
             color: color)
    }
}

/// Loads and caches the Platinum strikes; the renderer asks the book for a
/// role. If the pack isn't bundled every lookup is nil and callers fall back
/// to SwiftUI Text (mock-platinum).
public enum FontBook {
    private static var cache: [String: BitmapFont?] = [:]

    public static func font(_ face: String) -> BitmapFont? {
        if let cached = cache[face] { return cached }
        let loaded = BitmapFont(face: face)
        cache[face] = loaded
        return loaded
    }

    /// Which strike SIZES this bundle actually carries, per face. Stated
    /// once, here, because `nearest` and the gate that checks it must not
    /// disagree about what is on disk — the extracted pack ships more
    /// sizes than the bundle does, and a table that drifts from the
    /// Resources directory is a silent metric error, which is the exact
    /// shape of the defect this rounding exists to cure.
    public static let bundledSizes: [String: [Int]] = [
        "chicago": [12],
        "geneva": [9, 10, 12, 14, 18, 20, 24],
    ]

    /// The strike for `face` at `size` — or, when the pack has no strike
    /// at that size, the NEAREST one it does have.
    ///
    /// WHAT IT DOES WHEN THE EXACT SIZE IS ABSENT, said plainly: it
    /// rounds to the nearest bundled size, and **a tie goes to the
    /// smaller strike**. The two errors are not symmetric. A run drawn
    /// too wide overruns the control it labels and spills past the
    /// window's edge onto the desktop — the artifact a viewer reads as a
    /// broken mirror, and the whole of R1 in the 2026-08-06 fidelity
    /// sweep. A run drawn too narrow merely sits loose inside its own
    /// box. So where the pack cannot be exact, it errs small.
    ///
    /// Chicago is the case that bites: the pack carries ONE strike, at
    /// 12, so any Chicago request answers at 12 and the caller is not
    /// told. That is honest rounding, not a claim the size was honoured.
    public static func nearest(face: String, size: Int) -> BitmapFont? {
        if let exact = font("\(face)-\(size)") { return exact }
        guard let sizes = bundledSizes[face], !sizes.isEmpty else {
            return nil
        }
        let pick = sizes.min {
            (abs($0 - size), $0) < (abs($1 - size), $1)
        } ?? 12
        return font("\(face)-\(pick)")
    }

    /// Chicago 12 — the system font (menus, window titles, buttons).
    public static var system: BitmapFont? { font("chicago-12") }
    /// Geneva 10 — the app/content font (Finder labels, item text).
    public static var app: BitmapFont? { font("geneva-10") }
    /// Geneva 9 — the smallest UI text (shelf, generic labels). Falls back
    /// to Geneva 10 if the 9 strike isn't bundled.
    public static var small: BitmapFont? { font("geneva-9") ?? font("geneva-10") }
}

/// The extracted default desktop pattern ('ppat' 16 "Mac OS Default"), tiled.
public enum DesktopPattern {
    public static let tile: CGImage? = {
        guard let url = Bundle.module.url(forResource: "desktop",
                                          withExtension: "png",
                                          subdirectory: "patterns"),
              let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }()
}
