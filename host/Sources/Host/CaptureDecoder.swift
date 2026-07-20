import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Rebuilds a guest screen capture from the wire format: rows top-to-bottom,
/// optionally PackBits-compressed with a big-endian u16 length per row, and
/// (for indexed depths) a leading palette of RGB triples. PICT is the guest's
/// disk format — macOS can no longer decode it — so the wire uses this.
struct CaptureFormat: Equatable {
    var width: Int
    var height: Int
    var depth: Int
    var rowBytes: Int
    var bytes: Int
    var paletteBytes: Int
    var packed: Bool
    var captureMs: Int
    var encodeMs: Int
}

enum CaptureDecodeError: Error, Equatable {
    case truncated
    case unsupportedDepth(Int)
    case badRowLength
}

enum CaptureDecoder {
    /// Classic PackBits: a control byte n. 0...127 => copy n+1 literal
    /// bytes; -1...-127 => repeat the next byte 1-n times; -128 is a no-op.
    /// Decodes exactly one row of `expected` bytes.
    static func unpackBits(_ src: ArraySlice<UInt8>,
                           expected: Int) throws -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(expected)
        var i = src.startIndex
        while i < src.endIndex && out.count < expected {
            let control = Int8(bitPattern: src[i])
            i += 1
            if control >= 0 {
                let count = Int(control) + 1
                guard i + count <= src.endIndex else {
                    throw CaptureDecodeError.truncated
                }
                out.append(contentsOf: src[i..<(i + count)])
                i += count
            } else if control != -128 {
                // PackBits: control -1...-127 repeats the next byte 1-n times.
                let count = 1 - Int(control)
                guard i < src.endIndex else {
                    throw CaptureDecodeError.truncated
                }
                out.append(contentsOf: repeatElement(src[i], count: count))
                i += 1
            }
        }
        guard out.count >= expected else {
            throw CaptureDecodeError.truncated
        }
        return Array(out.prefix(expected))
    }

    /// Splits the blob into the palette and the fully-unpacked pixel rows.
    static func decodeRows(_ blob: [UInt8],
                           format: CaptureFormat) throws
        -> (palette: [UInt8], pixels: [UInt8]) {
        guard blob.count >= format.paletteBytes else {
            throw CaptureDecodeError.truncated
        }
        let palette = Array(blob.prefix(format.paletteBytes))
        var pixels: [UInt8] = []
        pixels.reserveCapacity(format.rowBytes * format.height)

        if !format.packed {
            let needed = format.rowBytes * format.height
            let body = blob.dropFirst(format.paletteBytes)
            guard body.count >= needed else {
                throw CaptureDecodeError.truncated
            }
            pixels = Array(body.prefix(needed))
            return (palette, pixels)
        }

        var i = blob.index(blob.startIndex, offsetBy: format.paletteBytes)
        for _ in 0..<format.height {
            guard i + 2 <= blob.endIndex else {
                throw CaptureDecodeError.truncated
            }
            let packedLength = Int(blob[i]) << 8 | Int(blob[i + 1])
            i += 2
            guard packedLength > 0, i + packedLength <= blob.endIndex else {
                throw CaptureDecodeError.badRowLength
            }
            let row = try unpackBits(blob[i..<(i + packedLength)],
                                     expected: format.rowBytes)
            pixels.append(contentsOf: row)
            i += packedLength
        }
        return (palette, pixels)
    }

    /// Expands the guest's pixels to 32-bit RGBA and wraps them in a CGImage.
    static func makeImage(blob: [UInt8],
                          format: CaptureFormat) throws -> CGImage {
        let (palette, pixels) = try decodeRows(blob, format: format)
        let width = format.width
        let height = format.height
        var rgba = [UInt8](repeating: 255, count: width * height * 4)

        func setPixel(_ x: Int, _ y: Int, _ r: UInt8, _ g: UInt8, _ b: UInt8) {
            let o = (y * width + x) * 4
            rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = b; rgba[o + 3] = 255
        }
        func paletteColor(_ index: Int) -> (UInt8, UInt8, UInt8) {
            let o = index * 3
            guard o + 2 < palette.count else { return (0, 0, 0) }
            return (palette[o], palette[o + 1], palette[o + 2])
        }

        for y in 0..<height {
            let rowStart = y * format.rowBytes
            guard rowStart + format.rowBytes <= pixels.count else {
                throw CaptureDecodeError.truncated
            }
            for x in 0..<width {
                switch format.depth {
                case 1, 2, 4:
                    let perByte = 8 / format.depth
                    let byte = pixels[rowStart + x / perByte]
                    let shift = (perByte - 1 - (x % perByte)) * format.depth
                    let mask = (1 << format.depth) - 1
                    let index = (Int(byte) >> shift) & mask
                    // 1-bit classic Mac: 0 = white, 1 = black.
                    if palette.isEmpty && format.depth == 1 {
                        let v: UInt8 = index == 0 ? 255 : 0
                        setPixel(x, y, v, v, v)
                    } else {
                        let (r, g, b) = paletteColor(index)
                        setPixel(x, y, r, g, b)
                    }
                case 8:
                    let index = Int(pixels[rowStart + x])
                    let (r, g, b) = paletteColor(index)
                    setPixel(x, y, r, g, b)
                case 16:
                    let o = rowStart + x * 2
                    let v = Int(pixels[o]) << 8 | Int(pixels[o + 1])
                    // RGB555, big-endian.
                    let r = UInt8(((v >> 10) & 0x1F) * 255 / 31)
                    let g = UInt8(((v >> 5) & 0x1F) * 255 / 31)
                    let b = UInt8((v & 0x1F) * 255 / 31)
                    setPixel(x, y, r, g, b)
                case 32:
                    let o = rowStart + x * 4
                    // xRGB8888: skip the unused high byte.
                    setPixel(x, y, pixels[o + 1], pixels[o + 2], pixels[o + 3])
                default:
                    throw CaptureDecodeError.unsupportedDepth(format.depth)
                }
            }
        }

        let provider = CGDataProvider(data: Data(rgba) as CFData)!
        guard let image = CGImage(
            width: width, height: height, bitsPerComponent: 8,
            bitsPerPixel: 32, bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue:
                CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false,
            intent: .defaultIntent) else {
            throw CaptureDecodeError.truncated
        }
        return image
    }

    static func pngData(_ image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
