import Foundation
import XCTest
@testable import Host

/// The pure half of the preview pipeline, against fixtures generated
/// in-test: gradients and flats in, indexed rows out. What these hold
/// is the part the guest cannot check — that every byte is a valid
/// index, that dimensions and rowBytes agree with the contract's own
/// arithmetic, that the bytes are deterministic, and that the dither
/// actually diffuses error rather than thresholding (the property whose
/// mutation was watched failing: zeroing the diffusion weights turns a
/// mid-grey field into solid black, and the mean-preservation test
/// below names it).
final class ClassicDitherTests: XCTestCase {

    private func flat(_ r: UInt8, _ g: UInt8, _ b: UInt8,
                      width: Int, height: Int) -> [UInt8] {
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for _ in 0..<(width * height) { rgb += [r, g, b] }
        return rgb
    }

    private func gradient(width: Int, height: Int) -> [UInt8] {
        var rgb: [UInt8] = []
        rgb.reserveCapacity(width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let v = UInt8(x * 255 / max(1, width - 1))
                let w = UInt8(y * 255 / max(1, height - 1))
                rgb += [v, w, UInt8((Int(v) + Int(w)) / 2)]
            }
        }
        return rgb
    }

    // MARK: - The table itself

    func testTheSystemTableHas256UniqueEntriesWhiteFirstBlackLast() {
        let table = ClassicDither.systemCLUT8
        XCTAssertEqual(table.count, 256)
        XCTAssertTrue(table[0] == (0xFF, 0xFF, 0xFF), "index 0 is white")
        XCTAssertTrue(table[255] == (0, 0, 0), "black lives at 255")
        let packed = Set(table.map {
            Int($0.r) << 16 | Int($0.g) << 8 | Int($0.b)
        })
        XCTAssertEqual(packed.count, 256, "no entry repeats — the cube's "
                       + "own black slot must have been dropped for 255")
    }

    func testNearestIndexIsExactForEveryTableEntry() {
        for (index, entry) in ClassicDither.systemCLUT8.enumerated() {
            XCTAssertEqual(
                Int(ClassicDither.nearestIndex(r: Int(entry.r),
                                               g: Int(entry.g),
                                               b: Int(entry.b))),
                index, "a colour already in the table maps to itself")
        }
    }

    // MARK: - 8-bit

    func testDither8DimensionsAndPaletteOnlyOutput() {
        let out = ClassicDither.dither8(rgb: gradient(width: 31, height: 17),
                                        width: 31, height: 17)
        XCTAssertEqual(out.width, 31)
        XCTAssertEqual(out.height, 17)
        XCTAssertEqual(out.depth, 8)
        XCTAssertEqual(out.rowBytes, 31, "depth 8 rowBytes is the width")
        XCTAssertEqual(out.pixels.count, 31 * 17)
        // Every byte is an index by construction; what CAN go wrong is
        // the colours those indices name. Reconstruct and bound the
        // per-pixel error by the cube's own spacing.
        let source = gradient(width: 31, height: 17)
        for (i, index) in out.pixels.enumerated() {
            let entry = ClassicDither.systemCLUT8[Int(index)]
            let at = i * 3
            // Diffused error moves values around, so individual pixels
            // may sit a couple of levels off; a whole level-spacing of
            // three (153) would mean the lookup is broken.
            XCTAssertLessThan(abs(Int(entry.r) - Int(source[at])), 153)
        }
    }

    func testDither8IsDeterministic() {
        let rgb = gradient(width: 24, height: 24)
        let one = ClassicDither.dither8(rgb: rgb, width: 24, height: 24)
        let two = ClassicDither.dither8(rgb: rgb, width: 24, height: 24)
        XCTAssertEqual(one, two, "same bytes in, same bytes out — the "
                       + "wire and the tests both rely on it")
    }

    func testDither8FlatCubeColourIsSolid() {
        let out = ClassicDither.dither8(
            rgb: flat(0xCC, 0x66, 0x00, width: 8, height: 8),
            width: 8, height: 8)
        let expected = ClassicDither.nearestIndex(r: 0xCC, g: 0x66, b: 0)
        XCTAssertTrue(out.pixels.allSatisfy { $0 == expected },
                      "a colour the table holds exactly needs no dither")
    }

    /// The mutation-watched property. A dither that diffuses error
    /// preserves the mean: a field between two table greys must come
    /// out as a MIX whose average sits near the source. Zeroing the
    /// Floyd-Steinberg weights (the watched mutation) collapses the
    /// field to one grey and this fails naming the drift.
    func testDither8PreservesTheMeanOfAnOffTableGrey() {
        // 0x90 sits between grey ramp entries 0x88 and 0x99.
        let width = 64, height = 64
        let out = ClassicDither.dither8(
            rgb: flat(0x90, 0x90, 0x90, width: width, height: height),
            width: width, height: height)
        let mean = out.pixels.reduce(0.0) {
            $0 + Double(ClassicDither.systemCLUT8[Int($1)].r)
        } / Double(width * height)
        XCTAssertEqual(mean, 0x90, accuracy: 2.0,
                       "error diffusion must preserve the average level")
        let distinct = Set(out.pixels)
        XCTAssertGreaterThan(distinct.count, 1,
                             "an off-table grey must dither, not snap")
    }

    // MARK: - 1-bit

    func testDither1DimensionsAndPacking() {
        let out = ClassicDither.dither1(rgb: gradient(width: 30, height: 9),
                                        width: 30, height: 9)
        XCTAssertEqual(out.depth, 1)
        XCTAssertEqual(out.rowBytes, 4, "ceil(30 / 8) — the contract's "
                       + "own arithmetic")
        XCTAssertEqual(out.pixels.count, 4 * 9)
        // Bits past the row's width stay clear: the guest blits rowBytes
        // wide and stray set bits would draw as black specks.
        for y in 0..<9 {
            let lastByte = out.pixels[y * 4 + 3]
            XCTAssertEqual(lastByte & 0x03, 0,
                           "padding bits beyond pixel 29 must stay white")
        }
    }

    func testDither1BlackAndWhiteAreSolid() {
        let black = ClassicDither.dither1(
            rgb: flat(0, 0, 0, width: 16, height: 4), width: 16, height: 4)
        XCTAssertTrue(black.pixels.allSatisfy { $0 == 0xFF },
                      "1 is black, and pure black is every bit set")
        let white = ClassicDither.dither1(
            rgb: flat(255, 255, 255, width: 16, height: 4),
            width: 16, height: 4)
        XCTAssertTrue(white.pixels.allSatisfy { $0 == 0 },
                      "0 is white, and pure white is every bit clear")
    }

    /// Atkinson's version of the mean property: a mid-grey field comes
    /// out roughly half black — an even mix, not a wall. (Atkinson
    /// keeps only 6/8 of the error, so the tolerance is loose on
    /// purpose; what it must never be is 0% or 100%.)
    func testDither1MixesAMidGrey() {
        let width = 64, height = 64
        let out = ClassicDither.dither1(
            rgb: flat(128, 128, 128, width: width, height: height),
            width: width, height: height)
        var blackBits = 0
        for y in 0..<height {
            for x in 0..<width {
                let byte = out.pixels[y * out.rowBytes + x / 8]
                if byte & UInt8(0x80 >> (x % 8)) != 0 { blackBits += 1 }
            }
        }
        let share = Double(blackBits) / Double(width * height)
        XCTAssertGreaterThan(share, 0.25, "a mid-grey is not white")
        XCTAssertLessThan(share, 0.75, "a mid-grey is not black")
    }

    // MARK: - Fit

    func testFitPreservesAspectAndNeverUpscales() {
        XCTAssertTrue(ClassicDither.fit(width: 4032, height: 3024,
                                        maxWidth: 300, maxHeight: 200)
            == (266, 200))
        XCTAssertTrue(ClassicDither.fit(width: 100, height: 50,
                                        maxWidth: 300, maxHeight: 200)
            == (100, 50), "smaller than the box stays its own size")
        XCTAssertTrue(ClassicDither.fit(width: 3024, height: 4032,
                                        maxWidth: 300, maxHeight: 200)
            == (150, 200), "portrait fits by height")
    }
}
