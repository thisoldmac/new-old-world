import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// **A zoomed mirror must still be a picture of a Macintosh.**
///
/// The host draws the Mirror at 50, 100, 200 and 400 percent, and every
/// one of those is a power of two so that each guest pixel lands on a
/// whole number of host pixels. That is only worth anything if the
/// bitmaps are sampled nearest-neighbour: with smoothing, a 1-pixel
/// Platinum rule at 200% becomes a two-pixel grey smear rather than a
/// two-pixel line, and **no similarity score can tell the difference** —
/// the picture stays 99% "the same" and stops being pixel-honest, which
/// is the whole claim the Mirror makes.
///
/// So this measures it instead of scoring it. The subject is a pixel
/// island of alternating one-pixel rows, drawn through
/// `SceneRenderer`'s image path; the assertion is that the 200% render
/// of it is EXACTLY the 100% render with every pixel doubled. A blurred
/// edge fails by producing an intermediate colour that appears in
/// neither source row.
///
/// Watched failing by mutation: removing `.interpolation(.none)` from
/// the island draw in `SceneRenderer` fails it naming the first blended
/// row.
@MainActor
final class ZoomFidelityTests: XCTestCase {

    private let screen = Scene.ScreenSize(w: 400, h: 300)

    /// The zoom stop IS the renderer's own scale, with nothing left over.
    ///
    /// The container frames the view at guest × factor and
    /// `SceneRenderer` builds `FitTransform(logical:view:)` from the size
    /// the layout system hands it — so this is the arithmetic the whole
    /// feature rests on, and it belongs in a test rather than in a
    /// comment.
    func testEveryZoomStopIsAnExactRendererScaleWithNoLetterbox() {
        let logical = CGSize(width: 832, height: 624)
        for factor in [0.5, 1.0, 2.0, 4.0] as [CGFloat] {
            let view = CGSize(width: logical.width * factor,
                              height: logical.height * factor)
            let fit = FitTransform(logical: logical, view: view)
            XCTAssertEqual(fit.scale, factor, accuracy: 1e-12,
                           "a \(factor * 100)% frame must make the "
                           + "renderer's own scale exactly \(factor)")
            XCTAssertEqual(fit.offset.x, 0, accuracy: 1e-12)
            XCTAssertEqual(fit.offset.y, 0, accuracy: 1e-12)
        }
    }

    func testDoublingTheSizeDoublesEveryIslandPixelRatherThanBlendingThem()
        throws {
        /* Alternating one-pixel rows: the worst case, and the exact thing
           a Platinum hairline is. Anything that resamples this produces a
           colour that is in neither row. */
        let w = 64, h = 32
        var rgba = Data()
        for y in 0..<h {
            let v: UInt8 = y % 2 == 0 ? 0 : 255
            for _ in 0..<w { rgba.append(contentsOf: [v, v, v, 255]) }
        }
        let island = PixelIsland(width: w, height: h, rgba: rgba,
                                 originX: 0, originY: 0, scale: 1)
        let win = Scene.Window(
            id: "1.0/Stripes#0", app: "Stripes", psn: "1.0",
            title: "Stripes", kind: 0,
            rect: Rect(l: 100, t: 100, r: 100 + w + 2, b: 160 + h),
            front: true, z: 0, visible: true, controls: [], text: nil,
            items: nil, display: nil, island: island)
        let scene = Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
                          screen: screen, apps: [], processes: nil,
                          menubar: nil, windows: [win], desktopItems: nil,
                          meta: .init(errors: []))

        let one = try raster(scene, factor: 1)
        let two = try raster(scene, factor: 2)
        XCTAssertEqual(two.pixelsWide, one.pixelsWide * 2)
        XCTAssertEqual(two.pixelsHigh, one.pixelsHigh * 2)

        /* The island's own rectangle only. The window chrome around it is
           VECTOR drawing, which is re-stroked at 2× rather than scaled and
           is therefore not expected to be a pixel doubling of anything —
           it cannot blur, so it is not what this measures. */
        var checked = 0
        for y in 0..<one.pixelsHigh where y >= 118 && y < 118 + h {
            for x in 0..<one.pixelsWide where x >= 101 && x < 101 + w {
                guard let src = one.colorAt(x: x, y: y) else { continue }
                for dy in 0..<2 {
                    for dx in 0..<2 {
                        guard let dst = two.colorAt(x: x * 2 + dx,
                                                    y: y * 2 + dy) else {
                            return XCTFail("no pixel at 2×(\(x),\(y))")
                        }
                        checked += 1
                        XCTAssertEqual(
                            component(dst), component(src),
                            "at 200% the pixel under guest (\(x),\(y)) is "
                            + "\(component(dst)) where the 100% render has "
                            + "\(component(src)). A zoom stop that is a "
                            + "power of two must REPLICATE pixels, not blend "
                            + "them: a blended one-pixel Platinum rule is a "
                            + "grey smear that every similarity score calls "
                            + "a match.")
                        if component(dst) != component(src) { return }
                    }
                }
            }
        }
        XCTAssertGreaterThan(checked, 4_000,
                             "the island rectangle was not actually sampled; "
                             + "a gate that checks nothing reads green")
    }

    private func component(_ color: NSColor) -> Int {
        Int((color.redComponent * 255).rounded())
    }

    private func raster(_ scene: Scene, factor: CGFloat) throws
        -> NSBitmapImageRep {
        let size = CGSize(width: CGFloat(screen.w) * factor,
                          height: CGFloat(screen.h) * factor)
        let png = try RenderShot.png(scene: scene, size: size)
        return try XCTUnwrap(NSBitmapImageRep(data: png))
    }
}
