import XCTest
@testable import MirrorKit

/// The MoveBits fast-path math (QDPEEK-SPEC refinement 1) — pure pixel work,
/// no guest: a scroll must move the pixels we already hold and report exactly
/// the band it exposed, since that band is the only thing worth re-fetching.
final class PixelIslandTests: XCTestCase {

    /// A 4x4 island whose every pixel encodes its own row, so a shift is visible.
    private func island(w: Int = 4, h: Int = 4) -> PixelIsland {
        var rgba = Data()
        for y in 0..<h {
            for _ in 0..<w { rgba.append(contentsOf: [UInt8(y + 1), 0, 0, 255]) }
        }
        return PixelIsland(width: w, height: h, rgba: rgba,
                           originX: 0, originY: 0, scale: 1)
    }

    private func rows(_ i: PixelIsland) -> [UInt8] {
        (0..<i.height).map { i.rgba[($0 * i.width) * 4] }   // red channel = row id
    }

    func testScrollUpMovesHeldPixelsAndExposesTheBottom() {
        // Content scrolled up by 2 (dy = -2): rows 3,4 rise to the top; the
        // bottom two rows are vacated and must be reported as exposed.
        let (moved, exposed) = island().shifted(dx: 0, dy: -2)
        XCTAssertEqual(rows(moved), [3, 4, 0, 0])
        XCTAssertEqual(exposed?.t, 2)
        XCTAssertEqual(exposed?.b, 4)
    }

    func testScrollDownExposesTheTop() {
        let (moved, exposed) = island().shifted(dx: 0, dy: 1)
        XCTAssertEqual(rows(moved), [0, 1, 2, 3])
        XCTAssertEqual(exposed?.t, 0)
        XCTAssertEqual(exposed?.b, 1)
    }

    func testNoMoveIsANoOp() {
        let (moved, exposed) = island().shifted(dx: 0, dy: 0)
        XCTAssertEqual(rows(moved), [1, 2, 3, 4])
        XCTAssertNil(exposed)
    }

    func testPatchFillsTheExposedBand() {
        let (moved, exposed) = island().shifted(dx: 0, dy: -2)
        let band = PixelIsland(width: 4, height: 2,
                               rgba: Data([UInt8](repeating: 9, count: 4 * 2 * 4)),
                               originX: 0, originY: 0, scale: 1)
        let patched = moved.patched(with: band, atX: 0, y: exposed!.t)
        XCTAssertEqual(rows(patched), [3, 4, 9, 9])   // moved pixels + new band
    }

    /// The REAL ops a live mac99 SimpleText page-down emitted (2026-07-17):
    /// one screen→screen slab move, three 16x16 scrollbar-arrow composites,
    /// and the window's own GWorld composites. Only the slab is a scroll.
    func testDetectsTheRealCapturedScroll() {
        let content = Rect(l: 4, t: 62, r: 441, b: 206)   // the live window
        func bits(_ src: [Int], _ dst: [Int], _ tick: Int) -> DisplayOp {
            var o = DisplayOp(op: "bits", ticks: tick); o.src = src; o.dst = dst; return o
        }
        let captured = [
            bits([0, 4, 430, 17], [0, 4, 430, 17], 1),        // composite
            bits([0, 0, 430, 21], [0, 0, 430, 21], 2),        // composite
            bits([0, 0, 16, 16], [422, 121, 438, 137], 3),    // scrollbar arrow
            bits([0, 0, 16, 17], [422, 105, 438, 122], 4),    // scrollbar arrow
            bits([4, 4, 418, 147], [4, -29, 418, 114], 5),    // THE scroll
        ]
        let mv = ScenePoller.newestMove(captured, content: content, since: 0)
        XCTAssertEqual(mv?.dy, -33, "content scrolled up 33px")
        XCTAssertEqual(mv?.dx, 0)
        XCTAssertEqual(mv?.tick, 5)
    }

    /// A scrollbar-arrow composite (small, src==dst) must NOT read as a scroll.
    func testMoveDetectionIgnoresCompositesAndTinyBlits() {
        let content = Rect(l: 0, t: 0, r: 400, b: 300)
        func bits(_ src: [Int], _ dst: [Int], _ tick: Int) -> DisplayOp {
            var o = DisplayOp(op: "bits", ticks: tick); o.src = src; o.dst = dst; return o
        }
        // GWorld composite (src == dst) and a 16x16 arrow: neither is a move.
        XCTAssertNil(ScenePoller.newestMove(
            [bits([0, 0, 400, 300], [0, 0, 400, 300], 1),
             bits([0, 0, 16, 16], [380, 100, 396, 116], 2)],
            content: content, since: 0))
        // A real scroll: same size, displaced, a big slab of the content.
        let mv = ScenePoller.newestMove(
            [bits([4, 4, 380, 280], [4, -29, 380, 247], 5)],
            content: content, since: 0)
        XCTAssertEqual(mv?.dy, -33)
        XCTAssertEqual(mv?.tick, 5)
        // Already accounted for -> not re-applied.
        XCTAssertNil(ScenePoller.newestMove(
            [bits([4, 4, 380, 280], [4, -29, 380, 247], 5)],
            content: content, since: 5))
    }
}
