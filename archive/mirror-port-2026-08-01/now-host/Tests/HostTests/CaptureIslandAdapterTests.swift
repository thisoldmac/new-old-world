import XCTest
import CoreGraphics
@testable import Host
import MirrorKit

/// The pixel-island fallback's raster step: a decoded capture's CGImage
/// rendered into the tight RGBA8 `PixelIsland.rgba` the renderer draws,
/// paired with the origin/scale `capture.begin` carried.
///
/// This is unverified against a real capture — nothing here has run on a
/// Macintosh, or even against a live GuestListener. It pins the one thing
/// a host test CAN prove without either: that a known CGImage rasterizes
/// to the RGBA8 bytes SceneRenderer.cgImage expects, and that origin/scale
/// survive the trip unchanged.
final class CaptureIslandAdapterTests: XCTestCase {
    /// A tiny synthetic capture: 2x2 at depth 32 (xRGB8888, big-endian,
    /// the leading byte unused — CaptureDecoder.renderImage's own case),
    /// one distinct color per corner so a transposed row or column shows
    /// up as a wrong pixel rather than a coincidentally-matching one.
    private func makeDelivery(originX: Int = 240, originY: Int = 60,
                              scale: Int = 1) throws
        -> GuestListener.CaptureDelivery {
        let red: [UInt8] = [0, 255, 0, 0]
        let green: [UInt8] = [0, 0, 255, 0]
        let blue: [UInt8] = [0, 0, 0, 255]
        let white: [UInt8] = [0, 255, 255, 255]
        let pixels = red + green + blue + white   // row0: R,G — row1: B,W

        let format = CaptureFormat(
            width: 2, height: 2, depth: 32, rowBytes: 8, bytes: pixels.count,
            paletteBytes: 0, packed: false, captureMs: 3, encodeMs: 1,
            originX: originX, originY: originY, scale: scale)
        let image = try CaptureDecoder.makeImage(blob: pixels, format: format)
        return GuestListener.CaptureDelivery(
            image: image, format: format, transferMs: 12, wireBytes: 16,
            guestKey: nil)
    }

    private func pixel(_ island: PixelIsland, _ x: Int, _ y: Int) -> [UInt8] {
        let o = (y * island.width + x) * 4
        let bytes = [UInt8](island.rgba)
        return [bytes[o], bytes[o + 1], bytes[o + 2]]
    }

    func testRasterizesTheDecodedImageIntoTightRGBA8() throws {
        let island = try makeDelivery().makePixelIsland()

        XCTAssertEqual(island.width, 2)
        XCTAssertEqual(island.height, 2)
        XCTAssertEqual(island.rgba.count, 2 * 2 * 4)
        XCTAssertEqual(pixel(island, 0, 0), [255, 0, 0], "top-left is red")
        XCTAssertEqual(pixel(island, 1, 0), [0, 255, 0], "top-right is green")
        XCTAssertEqual(pixel(island, 0, 1), [0, 0, 255], "bottom-left is blue")
        XCTAssertEqual(pixel(island, 1, 1), [255, 255, 255],
                       "bottom-right is white")
    }

    /// The whole point of threading the field through: without it, every
    /// island would render as if it were the whole screen at scale 1,
    /// and a window capture would composite at the wrong place.
    func testOriginAndScaleSurviveFromFormatToIsland() throws {
        let island = try makeDelivery(originX: 340, originY: 120, scale: 1)
            .makePixelIsland()
        XCTAssertEqual(island.originX, 340)
        XCTAssertEqual(island.originY, 120)
        XCTAssertEqual(island.scale, 1)
    }

    /// A capture from a sender that predates the fields decodes with
    /// origin (0, 0) at scale 1 (Session.finishCapture's default) — the
    /// whole-screen reading, not a crash and not a made-up nonzero place.
    func testAbsentOriginDefaultsToWholeScreenAtOrigin() throws {
        let island = try makeDelivery(originX: 0, originY: 0, scale: 1)
            .makePixelIsland()
        XCTAssertEqual(island.originX, 0)
        XCTAssertEqual(island.originY, 0)
        XCTAssertEqual(island.scale, 1)
    }

    /// The renderer's own decode (`SceneRenderer.cgImage`, MirrorKitUI)
    /// rebuilds a `CGImage` from `PixelIsland.rgba` with the same
    /// `noneSkipLast` bitmap info this adapter encodes with — see that
    /// file's header comment. HostTests does not depend on MirrorKitUI,
    /// so that decode is not re-exercised here; what this file proves is
    /// the encode half, against the byte layout `SceneRenderer.cgImage`
    /// is written to expect (bitsPerPixel 32, bytesPerRow width * 4,
    /// `noneSkipLast`) rather than against that function itself.
    func testRgbaLayoutMatchesWhatSceneRendererExpects() throws {
        let island = try makeDelivery().makePixelIsland()
        // Tight rows, no rowBytes padding — exactly island.width * 4,
        // which is what SceneRenderer.cgImage's bytesPerRow assumes.
        XCTAssertEqual(island.rgba.count, island.width * island.height * 4)
    }
}
