import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// The interior defect that was a RENDERER gap rather than a contract one.
///
/// `DisplayReplay` skipped GrafVerb 3 for most of the plane's life under the
/// note "invert needs destination pixels we do not carry". That was true of
/// the renderer it was written for. It stopped being true when the host began
/// compositing its own canvas — the pixels beneath an invert are pixels this
/// replay just drew — and until it was fixed the mirror was silently showing
/// an unselected, uncaretted, unpressed version of every window it drew.
///
/// These render offscreen (`RenderShot`) and read the pixels back, because a
/// blend-mode claim that is only asserted in the op stream proves nothing
/// about what a person sees.
@MainActor
final class DisplayReplayInvertTests: XCTestCase {

    private func window(_ display: [DisplayOp], rect: Rect) -> Scene.Window {
        Scene.Window(id: "1.0/Invert#0", app: "Invert", psn: "1.0",
                     title: "Invert", kind: 0, rect: rect, front: true, z: 0,
                     visible: true, controls: [], text: nil, items: nil,
                     display: display, island: nil)
    }

    private func scene(_ windows: [Scene.Window]) -> Scene {
        Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: windows, desktopItems: nil,
              meta: .init(errors: []))
    }

    private func pixel(_ png: Data, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let rep = NSBitmapImageRep(data: png),
              let color = rep.colorAt(x: x, y: y) else { return nil }
        return (Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    private func op(_ name: String, verb: Int, rect: [Int],
                    ext: [Int]? = nil) -> DisplayOp {
        var value = DisplayOp(op: name, ticks: 1)
        value.verb = verb
        value.rect = rect
        value.ext = ext
        return value
    }

    private func fill(_ rect: [Int], rgb: [Int]) -> [DisplayOp] {
        var colour = DisplayOp(op: "state", ticks: 0)
        colour.kind = "fg"
        colour.rgb = rgb
        return [colour, op("rect", verb: 1, rect: rect)]
    }

    /// A window rect big enough that content coordinates are unambiguous,
    /// plus the mirror-space origin of its content area.
    private let frame = Rect(l: 100, t: 100, r: 400, b: 340)
    private var contentOrigin: (x: Int, y: Int) {
        (frame.l + 1, frame.t + Int(Platinum.contentTop))
    }

    /// Invert over black gives white and over white gives black — the
    /// operation the guest performs against its own framebuffer, performed
    /// against the canvas the host composited.
    func testInvertFlipsThePixelsBeneathIt() throws {
        var display = fill([10, 10, 110, 110], rgb: [0, 0, 0])
        display.append(op("rect", verb: 3, rect: [10, 10, 60, 110]))
        let png = try RenderShot.png(scene: scene([window(display,
                                                          rect: frame)]))
        let (x, y) = contentOrigin
        let flipped = try XCTUnwrap(pixel(png, x: x + 30, y: y + 60))
        let untouched = try XCTUnwrap(pixel(png, x: x + 85, y: y + 60))
        XCTAssertEqual(flipped.0, 255, "black under an invert reads white")
        XCTAssertEqual(flipped.1, 255)
        XCTAssertEqual(flipped.2, 255)
        XCTAssertEqual(untouched.0, 0, "and only under the invert's rect")
    }

    /// The caret Sherlock 2 actually draws: a 1×16 `InvertRect` in its search
    /// field, arriving 22 times in one live capture and 11 in another. It is
    /// the whole of that window's invert traffic, and before this it was the
    /// whole of what the mirror dropped there.
    func testAOnePixelCaretIsVisible() throws {
        var display = fill([0, 0, 200, 200], rgb: [65535, 65535, 65535])
        display.append(op("rect", verb: 3, rect: [33, 116, 34, 132]))
        let png = try RenderShot.png(scene: scene([window(display,
                                                          rect: frame)]))
        let (x, y) = contentOrigin
        let caret = try XCTUnwrap(pixel(png, x: x + 33, y: y + 124))
        XCTAssertEqual(caret.0, 0, "the caret column is inverted to black")
        let beside = try XCTUnwrap(pixel(png, x: x + 36, y: y + 124))
        XCTAssertEqual(beside.0, 255, "and it is one column wide")
    }

    /// PARITY IS THE SEMANTIC. A blinking caret's drain holds N inverts of
    /// one rect, and replaying every one of them ends in the state the
    /// machine was actually in. Coalescing them would be a prettier picture
    /// of a machine nobody watched — so two inverts must cancel.
    func testAnEvenNumberOfInvertsCancels() throws {
        var display = fill([0, 0, 200, 200], rgb: [0, 0, 0])
        display.append(op("rect", verb: 3, rect: [33, 116, 34, 132]))
        display.append(op("rect", verb: 3, rect: [33, 116, 34, 132]))
        let png = try RenderShot.png(scene: scene([window(display,
                                                          rect: frame)]))
        let (x, y) = contentOrigin
        let caret = try XCTUnwrap(pixel(png, x: x + 33, y: y + 124))
        XCTAssertEqual(caret.0, 0,
                       "two inverts of one rect leave the pixels alone")
    }

    /// Invert respects the port clip like every other drawing op.
    func testInvertIsClippedLikeAnyOtherOp() throws {
        var display = fill([0, 0, 200, 200], rgb: [0, 0, 0])
        var clip = DisplayOp(op: "state", ticks: 2)
        clip.kind = "clip"
        clip.rect = [0, 0, 50, 200]
        display.append(clip)
        display.append(op("rect", verb: 3, rect: [10, 10, 150, 40]))
        let png = try RenderShot.png(scene: scene([window(display,
                                                          rect: frame)]))
        let (x, y) = contentOrigin
        XCTAssertEqual(try XCTUnwrap(pixel(png, x: x + 30, y: y + 25)).0, 255,
                       "inside the clip, inverted")
        XCTAssertEqual(try XCTUnwrap(pixel(png, x: x + 100, y: y + 25)).0, 0,
                       "outside the clip, untouched")
    }

    // MARK: - Regions: the box is drawn, and its confidence is honest

    /// THE SHAPE DISCRIMINATOR CHANGES WHAT THE HOST KNOWS, NOT WHAT IT
    /// PAINTS, and this is the gate on that decision rather than an
    /// accident nobody pinned down.
    ///
    /// Every one of the 39 region ops in the measured capture corpus is an
    /// erase, and for an erase the bounding box is the same area
    /// approximated — a marker painted over it would replace a
    /// probably-right background with a certainly-wrong annotation. The
    /// verbs where a hard rectangle IS a claim stronger than the evidence
    /// are frame, paint and fill of a non-rectangular region, and there
    /// are zero of those to look at. Grading a placeholder against no
    /// capture is exactly how the replay acquired the arbitrary local
    /// heuristics docs/render-composition.md exists to stop.
    ///
    /// So all three shape states render identically, and the honesty lives
    /// in `QDTraceDecode.undrawn` where it can be counted.
    /// Samples the interior and the outside of an erased region box. Area
    /// fills rather than 1px strokes on purpose: `ImageRenderer` does not
    /// place a hairline's antialiasing identically from one pass to the
    /// next, so a stroke comparison would be a flaky gate on a decision
    /// that is not about strokes.
    private func erasedBox(shape ext: [Int]?) throws -> (in: Int, out: Int) {
        var display = fill([0, 0, 200, 200], rgb: [0, 0, 0])
        var bg = DisplayOp(op: "state", ticks: 2)
        bg.kind = "bg"
        bg.rgb = [65535, 65535, 65535]
        display.append(bg)
        display.append(op("rgn", verb: 2, rect: [20, 20, 120, 120],
                          ext: ext))
        let png = try RenderShot.png(scene: scene([window(display,
                                                          rect: frame)]))
        let (x, y) = contentOrigin
        return (try XCTUnwrap(pixel(png, x: x + 70, y: y + 70)).0,
                try XCTUnwrap(pixel(png, x: x + 150, y: y + 70)).0)
    }

    // MARK: - The blit grading bound, held to the corpus that set it

    /// Sherlock 2's magnifier is a 48×48 unjoined CopyBits, and the old
    /// icon bound of 48 painted a generic DOCUMENT icon over a round
    /// button — a placeholder typed more precisely than the drawing stream
    /// allows. It reads as an untyped control plate now.
    ///
    /// The sizes below are the whole near-square blit census of the nine
    /// committed captures, so this fails if anyone widens the bound back
    /// over a real control or narrows it under a real icon.
    /// **The size bound survived; the CLAIM it used to make did not.**
    ///
    /// `iconSized` and `controlSized` answered "what is at this rectangle"
    /// from its dimensions. Sweep A priced that: four wrong page icons in
    /// fifteen windows, plus the Finder's 16×16 scroll arrows. Identity now
    /// comes from the semantic plane (`ProvenanceLadder`), and the numbers
    /// below survive only as a DRAW-ORDER rule — small answers go in stream
    /// order so a composite's own erase does not wipe them.
    ///
    /// Kept as a test because the range is measured against the committed
    /// captures and a regression in it would move ink around invisibly.
    func testTheStreamOrderBoundCoversEveryRealIconAndControl() {
        for size in [CGSize(width: 12, height: 12),
                     CGSize(width: 16, height: 16),
                     CGSize(width: 18, height: 18),
                     CGSize(width: 21, height: 20),
                     CGSize(width: 32, height: 24),
                     CGSize(width: 32, height: 32),
                     CGSize(width: 48, height: 48)] {
            XCTAssertTrue(
                DisplayReplay.answeredInStreamOrder(
                    CGRect(origin: .zero, size: size)),
                "\(size) is small enough that a composite erase wipes it")
        }
        XCTAssertFalse(
            DisplayReplay.answeredInStreamOrder(
                CGRect(x: 0, y: 0, width: 404, height: 218)),
            "a window-scale composite is marked AHEAD of the stream, or a "
            + "mark that large would cover text the guest did report")
    }

    func testAllThreeRegionShapeStatesRenderTheSamePixels() throws {
        for (name, ext) in [("rectangular", [10, 0]),
                            ("irregular", [42, 0]),
                            ("unreported", [0, 0]),
                            ("absent", nil)] as [(String, [Int]?)] {
            let sample = try erasedBox(shape: ext)
            XCTAssertEqual(sample.in, 255,
                           "\(name): the box is erased, approximation and all")
            XCTAssertEqual(sample.out, 0,
                           "\(name): and only the box")
        }
    }
}
