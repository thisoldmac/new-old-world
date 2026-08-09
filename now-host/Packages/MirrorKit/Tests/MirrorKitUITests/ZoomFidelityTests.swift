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
/// **2026-08-07 — this file lost its measurement, and says so rather than
/// pretending.** The nearest-neighbour assertion drew a pixel island of
/// alternating one-pixel rows and compared the 200% render against the
/// doubled 100% render. Pixel islands are gone
/// (`archive/pixel-islands-2026-08-07/`), and with them the only raw-bitmap
/// path the renderer had — so there is currently nothing in a render whose
/// resampling this could measure. The test was deleted rather than weakened;
/// a version that constructs its own bitmap outside the render path would
/// test `CGImage`, not the Mirror.
///
/// What survives is the arithmetic the zoom rests on, which is real and
/// still load-bearing. When the pack's art is drawn at zoom, the
/// nearest-neighbour claim becomes measurable again and belongs here.
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
}
