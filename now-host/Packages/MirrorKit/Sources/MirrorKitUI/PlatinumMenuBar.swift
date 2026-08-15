import SwiftUI
import CoreGraphics
import ImageIO

/// The outer Platinum menu-bar bezel and its image-backed system marks.
///
/// This is a measured procedure, not a generic rounded rectangle. A stable
/// 800x600 Mac OS 8.6 + CarbonLib 1.6 SheepShaver capture shows a 20-row
/// bar: the face is `#DDDDDD`, row 18 is the `#999999` lower bevel, and row
/// 19 is the black frame. The first eight rows carry asymmetric illuminated
/// and shadowed caps. Keeping those runs here makes the evidence readable
/// and lets a pixel test name a moved row; a Core Graphics rounded rectangle
/// produces blended pixels that are close in a screenshot and unlike the
/// machine at every corner.
///
/// The rainbow Apple is different: it is Apple-owned bitmap art, so it lives
/// in the external asset pack as `chrome/apple-menu.png`, never in source.
/// `tools/mirror-oracle extract-chrome` regenerates it from an attributed
/// oracle capture. A missing pack returns nil and the renderer uses the
/// extracted Chicago Apple glyph as a monochrome, explicitly provisional
/// fallback.
public enum PlatinumMenuBar {
    public static let face = Color(hex: 0xDDDDDD)
    public static let lowerBevel = Color(hex: 0x999999)

    private static let c22 = Color(hex: 0x222222)
    private static let c55 = Color(hex: 0x555555)
    private static let c77 = Color(hex: 0x777777)
    private static let c88 = Color(hex: 0x888888)
    private static let cAA = Color(hex: 0xAAAAAA)
    private static let cBB = Color(hex: 0xBBBBBB)
    private static let cCC = Color(hex: 0xCCCCCC)

    /// Draw the exact 20-row outer bezel for an arbitrary guest width.
    public static func drawChrome(in ctx: GraphicsContext, width: CGFloat) {
        guard width >= 16 else { return }
        ctx.fill(Path(CGRect(x: 0, y: 0, width: width, height: 20)),
                 with: .color(.black))

        func run(_ y: CGFloat, _ left: CGFloat, _ right: CGFloat,
                 _ color: Color) {
            guard right > left else { return }
            ctx.fill(Path(CGRect(x: left, y: y, width: right - left, height: 1)),
                     with: .color(color))
        }
        func pixel(_ y: CGFloat, _ x: CGFloat, _ color: Color) {
            run(y, x, x + 1, color)
        }

        run(0, 8, width - 8, .white)
        pixel(0, 5, c55); pixel(0, 6, cAA); pixel(0, 7, face)
        pixel(0, width - 8, face); pixel(0, width - 7, cAA)
        pixel(0, width - 6, c55); pixel(0, width - 5, c22)

        run(1, 8, width - 7, face)
        pixel(1, 3, c55); pixel(1, 4, cAA); run(1, 5, 8, .white)
        pixel(1, width - 7, cCC); pixel(1, width - 6, cBB)
        pixel(1, width - 5, c88); pixel(1, width - 4, c55)

        run(2, 5, width - 5, face)
        pixel(2, 2, c55); pixel(2, 3, face); pixel(2, 4, .white)
        pixel(2, width - 5, cBB); pixel(2, width - 4, c88)
        pixel(2, width - 3, c55)

        run(3, 4, width - 4, face)
        pixel(3, 1, c55); pixel(3, 2, face); pixel(3, 3, .white)
        pixel(3, width - 4, cBB); pixel(3, width - 3, c88)
        pixel(3, width - 2, c55)

        run(4, 3, width - 3, face)
        pixel(4, 1, cAA); pixel(4, 2, .white)
        pixel(4, width - 3, cBB); pixel(4, width - 2, c88)
        pixel(4, width - 1, c22)

        run(5, 2, width - 2, face)
        pixel(5, 0, c55); pixel(5, 1, .white)
        pixel(5, width - 2, cAA); pixel(5, width - 1, c55)

        run(6, 2, width - 2, face)
        pixel(6, 0, cAA); pixel(6, 1, .white)
        pixel(6, width - 2, cBB); pixel(6, width - 1, c77)

        run(7, 2, width - 2, face)
        pixel(7, 0, face); pixel(7, 1, .white)
        pixel(7, width - 2, cCC); pixel(7, width - 1, c88)

        for y in 8..<18 {
            run(CGFloat(y), 1, width - 1, face)
            pixel(CGFloat(y), 0, .white)
            pixel(CGFloat(y), width - 1, lowerBevel)
        }
        pixel(18, 0, face)
        run(18, 1, width, lowerBevel)
        // Row 19 stays black from the ground fill.
    }

    /// The six-pixel separator immediately left of the application menu.
    /// Its diagonal grip and white/shadow rails are present in every row of
    /// the 8.6 Finder oracle and are neither clock text nor application art.
    public static func drawApplicationDivider(in ctx: GraphicsContext,
                                              appLeft: CGFloat) {
        func run(_ x: CGFloat, _ y: CGFloat, _ height: CGFloat, _ color: Color) {
            ctx.fill(Path(CGRect(x: x, y: y, width: 1, height: height)),
                     with: .color(color))
        }
        run(appLeft - 6, 0, 18, .white)
        // The top highlight stops at the shadow rail in the 8.6 capture;
        // restore the face pixel that the outer bezel laid underneath it.
        run(appLeft - 1, 0, 1, face)
        run(appLeft - 1, 1, 18, lowerBevel)
        for y in stride(from: 4, through: 13, by: 3) {
            ctx.fill(Path(CGRect(x: appLeft - 4, y: CGFloat(y),
                                 width: 1, height: 1)), with: .color(c88))
            ctx.fill(Path(CGRect(x: appLeft - 3, y: CGFloat(y),
                                 width: 1, height: 1)), with: .color(cAA))
            ctx.fill(Path(CGRect(x: appLeft - 4, y: CGFloat(y + 1),
                                 width: 1, height: 1)), with: .color(cBB))
            ctx.fill(Path(CGRect(x: appLeft - 3, y: CGFloat(y + 1),
                                 width: 1, height: 1)), with: .color(.white))
        }
    }

    private static func load(_ name: String) -> CGImage? {
        guard let url = AssetPack.url(forResource: name,
                                      withExtension: "png",
                                      subdirectory: "chrome"),
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil)
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    private static let appleMenuImage = load("apple-menu")
    private static let finderApplicationMenuImage = load("application-menu-MACS")

    /// The attributed, private rainbow mark, when the selected pack has it.
    public static var appleMenu: CGImage? { appleMenuImage }

    /// Profile-specific system application-menu art keyed by reported OSType.
    public static func applicationMenuIcon(signature: String?) -> CGImage? {
        signature == "MACS" ? finderApplicationMenuImage : nil
    }
}
