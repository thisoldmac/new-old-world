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
        guard let pngURL = AssetPack.url(
                forResource: face, withExtension: "png", subdirectory: "fonts"),
              let jsonURL = AssetPack.url(
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
        /* **THE PEN LANDS ON A WHOLE PIXEL, and that is faithful rather
           than tidy.** QuickDraw has no sub-pixel pen: a bitmap strike on
           the real machine is blitted at an integer position, and every
           glyph offset in this type is already an integer. Only the
           caller's origin could be fractional — a centred window title is
           `(l + r)/2 - width/2` and lands on a half pixel whenever the
           two parities differ.

           It did not visibly matter while the sheet was drawn smoothed,
           because a half-pixel offset merely blurred. Under
           nearest-neighbour it CORRUPTS: the clip sits at the fractional
           box while the sample snaps to whichever source pixel is
           nearest, so a glyph picks up a column of the sheet cell BESIDE
           it. Watched on 2026-08-07 as a "c" in a centred window title
           growing a stray dot, in one render of a pair whose other half
           was pixel-identical — and `IslandRenderTests` caught it,
           because that pair is compared byte for byte. */
        var pen = x.rounded()
        let top = baselineY.rounded() - CGFloat(ascent)
        var boxes: [(dst: CGRect, g: Glyph)] = []
        for ch in string {
            let g = glyphs[ch] ?? space
            if g.w > 0, g.h > 0 {
                // The sheet cell's top sits (ascent) above the baseline.
                let dst = CGRect(x: pen + CGFloat(g.left),
                                 y: top,
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
                gg.draw(Image(decorative: sheet, scale: 1)
                            .interpolation(.none),
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
        "charcoal": [9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22,
                     23, 24],
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
    ///
    /// Charcoal is the opposite case and the reason the rounding exists at
    /// all. It has no bitmap strike on the guest either, so the pack
    /// rasterises it from its own TrueType outlines at every ppem Apple's
    /// `hdmx` table carries device metrics for — 9 through 24, which is
    /// every size the corpus has ever seen the system font drawn at. A
    /// request outside that range still rounds, and rounds small.
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

    /// The system font at 12 — menus, window titles, buttons, group-box
    /// labels: everything the guest draws as font id 0.
    ///
    /// **That is Charcoal, not Chicago**, on every Mac OS 8.5 and later
    /// system, and this line reading `chicago-12` was the largest
    /// text-fidelity gap in the product. Chicago is the System 7 system
    /// font and is a few percent wider per glyph, so every run the guest
    /// had already MEASURED in Charcoal — the clip it set around a
    /// checkbox label, the band it erased out of a group-box frame to put
    /// a title in — came back too long: "Use a Network Time Server" lost
    /// its "r" to the clip, and group titles met the frame line the guest
    /// had deliberately left standing on either side of the band. Two
    /// symptoms, one substitution.
    ///
    /// Falls back to Chicago 12 for a pack extracted before 2026-08-07,
    /// which is the substitution again — but a named one.
    public static var system: BitmapFont? {
        font("charcoal-12") ?? font("chicago-12")
    }
    /// Geneva 10 — the app/content font (Finder labels, item text).
    public static var app: BitmapFont? { font("geneva-10") }
    /// Geneva 9 — the smallest UI text (shelf, generic labels). Falls back
    /// to Geneva 10 if the 9 strike isn't bundled.
    public static var small: BitmapFont? { font("geneva-9") ?? font("geneva-10") }
}

/// The extracted default desktop pattern ('ppat' 16 "Mac OS Default"), tiled.
/// **What the guest's desktop actually is, or the honest admission that we
/// do not know.**
///
/// This used to be one line — tile `patterns/desktop.png` across the
/// screen, and fill `Platinum.desktopBlue` if the pack had none. Both
/// halves were guesses, and lane C of plan 018 measured how wrong:
///
/// - **Wrong art.** `ppat` 16 is "Mac OS Default", a shipped DEFAULT and
///   not a setting. Under Appearance the desktop is chosen in a control
///   panel that writes neither the System file nor a theme file, so the
///   System resource sits at its factory value forever while the screen
///   shows something else. On the stage image the desktop is an 800×600
///   JPEG, "Indigo Foam".
/// - **Wrong operation.** A picture is drawn ONCE, at the origin. Tiling
///   it is a claim the machine does not make.
///
/// So the answer comes from the pack's own `manifest.json`, where the
/// extractor records what it read out of the guest's
/// `Desktop Pictures Prefs` — and where it cannot, this reports `.unknown`
/// and the renderer marks the surface rather than painting a plausible
/// purple. Rule 1 of plan 018: a stable honest gap beats an unstable
/// plausible answer, and the desktop is the largest rectangle in the
/// picture to be wrong about.
///
/// **The limit, carried rather than hidden.** This is true for a guest
/// booted from the image the pack was extracted from and not changed
/// since. Only `GetTheme` with `kThemeDesktopPictureNameTag` on a RUNNING
/// guest closes that gap (CarbonLib 1.0+, inside our floor; `LMGetDeskCPat`
/// is not available in Carbon at all). It is not closed today, and
/// `Answer.confidence` carries the sentence that says so.
public enum DesktopPattern {

    /// What to draw for the desktop surface.
    public enum Answer: Equatable {
        /// A picture the size of the screen: draw it once, at the origin,
        /// unscaled.
        case picture(CGImage)
        /// A named pattern with art in the pack: tile it.
        case pattern(CGImage)
        /// Nobody could say. The renderer marks it.
        case unknown(String)
    }

    /// The pack's `manifest.json`, read once.
    private static let manifest: [String: Any]? = {
        guard let root = AssetPack.root,
              let data = try? Data(contentsOf:
                root.appendingPathComponent("manifest.json")),
              let object = try? JSONSerialization.jsonObject(with: data)
        else { return nil }
        return object as? [String: Any]
    }()

    private static func image(_ relative: String) -> CGImage? {
        guard let root = AssetPack.root else { return nil }
        let url = root.appendingPathComponent(relative)
        guard let data = try? Data(contentsOf: url),
              let src = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    /// Resolve the desktop for a screen of this size.
    ///
    /// The size test is the load-bearing part and it is not fussiness:
    /// Mac OS 9 ships desktop pictures at 800×600, 1024×768 AND 832×624,
    /// and the alignment field that says what to do with a mismatch is
    /// recorded as `null` by the offline route. Drawing an 832×624 picture
    /// on an 800×600 screen at the origin would silently crop it and look
    /// like a render bug; scaling it would look like a different picture.
    /// Neither is a fact, so a mismatch is an unknown.
    public static func answer(screen: CGSize) -> Answer {
        guard let desktop = manifest?["desktop"] as? [String: Any] else {
            return .unknown("the asset pack does not say what this guest's "
                            + "desktop is")
        }
        let kind = desktop["kind"] as? String
        let file = desktop["file"] as? String
        switch kind {
        case "picture":
            guard let w = desktop["w"] as? Int, let h = desktop["h"] as? Int
            else { return .unknown("the desktop picture has no size") }
            guard CGFloat(w) == screen.width, CGFloat(h) == screen.height
            else {
                return .unknown("the desktop picture is \(w)×\(h) and this "
                                + "screen is \(Int(screen.width))×"
                                + "\(Int(screen.height)); the alignment that "
                                + "would say what to do was not readable")
            }
            guard let file, let art = image(file) else {
                return .unknown("the desktop picture's art is not in the pack")
            }
            return .picture(art)
        case "pattern":
            guard let name = desktop["name"] as? String,
                  let art = image("patterns/appearance/\(name).png") else {
                return .unknown("this guest's pattern is not in the pack")
            }
            return .pattern(art)
        default:
            return .unknown("the pack does not name a desktop kind")
        }
    }

    /// Retired, and deliberately left as a name that answers nil. Nothing
    /// may go back to tiling one file unconditionally; ``answer(screen:)``
    /// is the question.
    @available(*, deprecated, message: "use answer(screen:); a tiled ppat 16 is a guess, not the guest's desktop")
    public static var tile: CGImage? { nil }
}
