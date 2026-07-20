import XCTest
@testable import Host

final class CaptureDecoderTests: XCTestCase {
    /// Classic PackBits: control 0...127 => n+1 literals; 129...255 => repeat
    /// the next byte 257-n times. Encodes one row the way the guest's
    /// PackBits trap does, so the decoder is tested against the real shape.
    private func packRow(_ row: [UInt8]) -> [UInt8] {
        // Hand-encoded to stay independent of any Swift-side packer.
        var out: [UInt8] = []
        var i = 0
        while i < row.count {
            var runEnd = i
            while runEnd + 1 < row.count && row[runEnd + 1] == row[i] {
                runEnd += 1
            }
            let runLength = runEnd - i + 1
            if runLength >= 2 {
                out.append(UInt8(257 - min(runLength, 128)))
                out.append(row[i])
                i += min(runLength, 128)
            } else {
                var literals: [UInt8] = []
                while i < row.count && literals.count < 128 {
                    if i + 1 < row.count && row[i + 1] == row[i] { break }
                    literals.append(row[i])
                    i += 1
                }
                out.append(UInt8(literals.count - 1))
                out.append(contentsOf: literals)
            }
        }
        return out
    }

    func testUnpackBitsRoundTripsRunsAndLiterals() throws {
        let row: [UInt8] = [1, 2, 3, 4, 4, 4, 4, 4, 9, 8]
        let packed = packRow(row)
        XCTAssertLessThan(packed.count, row.count + 4)
        let out = try CaptureDecoder.unpackBits(packed[...],
                                                expected: row.count)
        XCTAssertEqual(out, row)
    }

    func testDecodesIndexedRowsThroughPaletteIntoAnImage() throws {
        // 4x2 at 8-bit: palette entry 1 is pure red, 2 is pure green.
        var palette = [UInt8](repeating: 0, count: 256 * 3)
        palette[1 * 3] = 255
        palette[2 * 3 + 1] = 255
        let rowA: [UInt8] = [1, 1, 1, 1]
        let rowB: [UInt8] = [2, 2, 2, 2]

        var blob = palette
        for row in [rowA, rowB] {
            let packed = packRow(row)
            blob.append(UInt8(packed.count >> 8))
            blob.append(UInt8(packed.count & 0xFF))
            blob.append(contentsOf: packed)
        }

        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: blob.count,
            paletteBytes: palette.count, packed: true,
            captureMs: 1, encodeMs: 2)
        let (decodedPalette, pixels) =
            try CaptureDecoder.decodeRows(blob, format: format)
        XCTAssertEqual(decodedPalette.count, 768)
        XCTAssertEqual(pixels, rowA + rowB)

        let image = try CaptureDecoder.makeImage(blob: blob, format: format)
        XCTAssertEqual(image.width, 4)
        XCTAssertEqual(image.height, 2)
        XCTAssertNotNil(CaptureDecoder.pngData(image))
    }

    func testRawEncodingNeedsNoRowPrefixes() throws {
        let pixels: [UInt8] = [0, 1, 2, 3, 4, 5, 6, 7]
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: pixels.count,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        let (palette, out) = try CaptureDecoder.decodeRows(pixels,
                                                          format: format)
        XCTAssertTrue(palette.isEmpty)
        XCTAssertEqual(out, pixels)
    }

    func testDeltaRectPatchesTheCanvas() throws {
        // 4x4 raw canvas of zeros; patch a 2x2 rect at row 1, col 1.
        let format = CaptureFormat(
            width: 4, height: 4, depth: 8, rowBytes: 4, bytes: 4,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        var canvas = [UInt8](repeating: 0, count: 16)
        let blob: [UInt8] = [7, 8, 9, 10]   // two rows of two bytes
        var cursor = 0
        try CaptureDecoder.applyRect([1, 2, 1, 2], blob: blob,
                                     cursor: &cursor, format: format,
                                     canvas: &canvas)
        XCTAssertEqual(cursor, 4)
        XCTAssertEqual(canvas, [0, 0, 0, 0,
                                0, 7, 8, 0,
                                0, 9, 10, 0,
                                0, 0, 0, 0])
    }

    func testDeltaRectOutOfBoundsIsRejected() {
        let format = CaptureFormat(
            width: 4, height: 4, depth: 8, rowBytes: 4, bytes: 4,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        var canvas = [UInt8](repeating: 0, count: 16)
        var cursor = 0
        // col span past the row edge
        XCTAssertThrowsError(try CaptureDecoder.applyRect(
            [0, 1, 3, 2], blob: [1, 2], cursor: &cursor,
            format: format, canvas: &canvas))
        // rows past the canvas
        XCTAssertThrowsError(try CaptureDecoder.applyRect(
            [3, 2, 0, 2], blob: [1, 2, 3, 4], cursor: &cursor,
            format: format, canvas: &canvas))
    }

    func testTruncatedTransferIsRejected() {
        let format = CaptureFormat(
            width: 4, height: 2, depth: 8, rowBytes: 4, bytes: 8,
            paletteBytes: 0, packed: false, captureMs: 0, encodeMs: 0)
        XCTAssertThrowsError(
            try CaptureDecoder.decodeRows([0, 1, 2], format: format))
    }
}
