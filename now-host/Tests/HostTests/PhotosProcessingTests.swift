import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Host

/// The image half of the Photos pipelines, static and library-free:
/// processedJPEG (the get pipeline's resize-per-setting) and rgbPixels
/// (the preview pipeline's decode-fit-strip), against images generated
/// in-test. What only a granted library can prove — the PHImageManager
/// fetch itself — is ledgered in docs/open-issues.md, not claimed here.
@MainActor
final class PhotosProcessingTests: XCTestCase {

    /// A synthetic photo: a horizontal red-to-blue ramp, encoded into
    /// the asked container.
    private func image(width: Int, height: Int,
                       as type: UTType) throws -> Data {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        for x in 0..<width {
            let share = CGFloat(x) / CGFloat(max(1, width - 1))
            context.setFillColor(CGColor(red: 1 - share, green: 0,
                                         blue: share, alpha: 1))
            context.fill(CGRect(x: x, y: 0, width: 1, height: height))
        }
        let cg = context.makeImage()!
        let out = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            out, type.identifier as CFString, 1, nil) else {
            throw XCTSkip("no encoder for \(type.identifier) here")
        }
        CGImageDestinationAddImage(destination, cg, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw XCTSkip("could not encode \(type.identifier) here")
        }
        return out as Data
    }

    private func properties(of data: Data) -> (type: String, width: Int,
                                               height: Int) {
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let type = CGImageSourceGetType(source)! as String
        let info = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)!
            as! [CFString: Any]
        return (type, info[kCGImagePropertyPixelWidth] as! Int,
                info[kCGImagePropertyPixelHeight] as! Int)
    }

    // MARK: - The get pipeline's Downloads setting

    func testFit640ShrinksALargePhotoIntoTheBox() throws {
        let big = try image(width: 2000, height: 1000, as: .jpeg)
        let out = try PhotosCloudProvider.processedJPEG(big, size: .fit640)
        let info = properties(of: out)
        XCTAssertEqual(info.type, UTType.jpeg.identifier)
        XCTAssertEqual(info.width, 640)
        XCTAssertEqual(info.height, 320, "aspect preserved, fit by width")
    }

    func testAPhotoAlreadyInsideTheBoxIsNotResized() throws {
        let small = try image(width: 320, height: 240, as: .jpeg)
        let out = try PhotosCloudProvider.processedJPEG(small,
                                                       size: .fit640)
        XCTAssertEqual(out, small, "a JPEG already inside the box "
                       + "passes through byte-identical — no recompress")
    }

    func testOriginalKeepsEveryPixelButStillTranscodesHEIC() throws {
        let heic = try image(width: 800, height: 600, as: .heic)
        let out = try PhotosCloudProvider.processedJPEG(heic,
                                                       size: .original)
        let info = properties(of: out)
        XCTAssertEqual(info.type, UTType.jpeg.identifier,
                       "the classic side's decoders stop around its era")
        XCTAssertEqual(info.width, 800)
        XCTAssertEqual(info.height, 600)
    }

    func testFit1024AppliesToHEICToo() throws {
        let heic = try image(width: 4000, height: 3000, as: .heic)
        let out = try PhotosCloudProvider.processedJPEG(heic,
                                                       size: .fit1024)
        let info = properties(of: out)
        XCTAssertEqual(info.type, UTType.jpeg.identifier)
        XCTAssertEqual(info.width, 1024)
        XCTAssertEqual(info.height, 768)
    }

    // MARK: - The preview pipeline's front half

    func testRgbPixelsFitsAndStripsToPackedRGB() throws {
        let heic = try image(width: 1600, height: 1200, as: .heic)
        let (rgb, width, height) = try PhotosCloudProvider.rgbPixels(
            heic, fitting: 300, 200)
        // The bounded thumbnail decode may land a pixel or two off the
        // ideal 300-long side before the fit runs, so the property is
        // the FIT, not one exact integer: inside the box, aspect held.
        XCTAssertEqual(height, 200)
        XCTAssertEqual(Double(width), 266.0, accuracy: 2.0,
                       "fit by height: ~1600 * 200 / 1200")
        XCTAssertEqual(rgb.count, width * height * 3)
        // The ramp survives the trip: left edge red-ish, right blue-ish.
        XCTAssertGreaterThan(rgb[0], 200)
        XCTAssertLessThan(rgb[2], 60)
        let lastPixel = (height - 1) * width * 3 + (width - 1) * 3
        XCTAssertLessThan(rgb[lastPixel], 60)
        XCTAssertGreaterThan(rgb[lastPixel + 2], 200)
    }

    func testUnreadableBytesRefuseInTheContractsVocabulary() {
        XCTAssertThrowsError(try PhotosCloudProvider.processedJPEG(
            Data("not an image".utf8), size: .fit640)) {
            XCTAssertEqual(CloudFault.from($0).code, "io-error")
        }
        XCTAssertThrowsError(try PhotosCloudProvider.rgbPixels(
            Data("not an image".utf8), fitting: 300, 200)) {
            XCTAssertEqual(CloudFault.from($0).code, "io-error")
        }
    }
}
