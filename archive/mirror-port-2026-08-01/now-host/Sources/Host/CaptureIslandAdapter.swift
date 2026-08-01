import Foundation
import CoreGraphics
import MirrorKit

/// Turns a decoded capture into the pixel-island fallback's raw material.
///
/// **Why a CGImage -> RGBA8 raster step, and not a second wire decoder.**
/// Upstream's `PixelIsland` fetch decoded the wire's own pixel formats
/// (rgb555be / gray8 / mono1) directly. NOW does not repeat that decode
/// here: `CaptureDecoder.renderImage` already turns every depth this
/// guest sends into a `CGImage`, and `PixelIsland.swift`'s own porting
/// note names the reason a second decoder was rejected once already —
/// "a second PackBits decoder beneath a second transport" — when the
/// upstream `WireClient` fetch was deleted in favour of NOW's existing
/// `GuestListener.requestCapture` + `CaptureDecoder`. Re-deriving the
/// per-format math here would be exactly that defect one layer further
/// on. Reading back the CGImage's own raster is one CGContext draw, not
/// a decoder, and it is the smallest step that reuses the incumbent.
extension GuestListener.CaptureDelivery {
    enum PixelIslandAdaptError: Error, CustomStringConvertible {
        case noRasterData

        var description: String {
            switch self {
            case .noRasterData:
                return "capture: could not rasterize the decoded image"
            }
        }
    }

    /// Renders this capture's image into a tight RGBA8 buffer and pairs
    /// it with the origin/scale `capture.begin` carried (`format.originX`
    /// / `originY` / `scale`) — a `PixelIsland` ready for
    /// `SceneIslands.attach`'s `Capture` closure.
    ///
    /// `noneSkipLast` throughout, matching both `CaptureDecoder`'s own
    /// encode and `SceneRenderer.cgImage`'s decode: the 4th byte per
    /// pixel is never read as alpha on either side, so what it holds
    /// here is immaterial.
    func makePixelIsland() throws -> PixelIsland {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else {
            throw PixelIslandAdaptError.noRasterData
        }
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        let rasterized: Bool = rgba.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
            else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: width, height: height))
            return true
        }
        guard rasterized else { throw PixelIslandAdaptError.noRasterData }
        return PixelIsland(width: width, height: height, rgba: Data(rgba),
                           originX: format.originX, originY: format.originY,
                           scale: format.scale)
    }
}
