import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// The marked unknown is rung 4 of plan 018's provenance ladder, and the
/// plan's first rule is that it looks the same way every time from every
/// call site. Two things can break that and neither is visible in a diff:
/// a call site growing its own copy of the fill again (there were two, and
/// they were identical only by coincidence), and the fill quietly reverting
/// to the loud diagonal hatch Michelle asked to be rid of.
///
/// So this renders offscreen through the real composition path and reads
/// the pixels back. A palette asserted in source proves nothing about what
/// a person sees — the same reason `DisplayReplayInvertTests` exists.
@MainActor
final class UnknownVisualRenderTests: XCTestCase {

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

    /// A CopyBits destination whose source pixels never crossed. This is the
    /// commonest unknown in a real capture — the whole interior of a Finder
    /// window in the 2026-08-07 sweep is one of them.
    private func unknownWindow(rect: Rect, dst: [Int]) -> Scene.Window {
        var bits = DisplayOp(op: "bits", ticks: 1)
        bits.src = [0, 0, dst[2] - dst[0], dst[3] - dst[1]]
        bits.dst = dst
        return Scene.Window(id: "1.0/Unknown#0", app: "Unknown", psn: "1.0",
                            title: "Unknown", kind: 0, rect: rect,
                            front: true, z: 0, visible: true, controls: [],
                            text: nil, items: nil, display: [bits])
    }

    /// The lattice is the marker. Sampling one pixel would pass on a flat
    /// fill, so this samples a 4x4 block and asserts two things about it:
    /// that every pixel belongs to the unknown's own two-colour palette,
    /// and that the texture is present but in the minority.
    ///
    /// It does NOT assert the exact lattice phase. The fill is anchored in
    /// the CONTEXT's space and the content context is translated by the
    /// window origin, so a phase assertion here would be pinning the test
    /// fixture's window position rather than the style.
    ///
    /// It EARNED ITS KEEP before it was committed. The first implementation
    /// stroked the lattice as dashed hairlines and `GraphicsContext` drew
    /// the dash solid; this test reported 8 dots where 4 were intended,
    /// which is how the horizontal-ruling collision with Platinum's
    /// title-bar pinstripe was found at all. Watched failing by mutation
    /// two further ways — flattening the tile to all-ground (`dots` 0), and
    /// restoring the 6px antialiased diagonal (its 0xD6/0xE2 blends land in
    /// `foreign`).
    func testTheMarkedUnknownDrawsTheQuietStippleAndNotTheLoudHatch() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        let png = try RenderShot.png(
            scene: scene([unknownWindow(rect: r, dst: [20, 40, 360, 240])]))

        let x0 = r.l + 20 + 40          // well inside the dst rect
        let y0 = r.t + Int(Platinum.contentTop) + 40 + 40
        // Snap onto the device lattice the fill is anchored to.
        let ax = x0 - (x0 % 2), ay = y0 - (y0 % 2)

        var dots = 0, grounds = 0, foreign: [String] = []
        for dy in 0..<4 {
            for dx in 0..<4 {
                let p = try XCTUnwrap(pixel(png, x: ax + dx, y: ay + dy),
                                      "sample fell outside the render")
                switch p {
                case (0xDC, 0xDC, 0xDC): dots += 1
                case (0xEF, 0xEF, 0xEF): grounds += 1
                default: foreign.append(String(format: "%02X%02X%02X", p.0, p.1, p.2))
                }
            }
        }
        /* PALETTE PURITY is the sharp half. The old hatch was an
           ANTIALIASED diagonal, so its pixels were 0xD6/0xE2 blends that
           appear nowhere in the Platinum greys — any of them landing in
           this block means a different fill is drawing here. */
        XCTAssertEqual(foreign, [],
                       "every pixel of a marked unknown is either its "
                       + "ground or its stipple; a foreign grey means "
                       + "another fill drew here, most likely the old "
                       + "antialiased diagonal hatch")
        XCTAssertEqual(dots, 4,
                       "a 4x4 block of the unknown carries exactly four "
                       + "stipple dots — 0 means a flat fill, which reads "
                       + "as 'this region is empty' and is a claim we "
                       + "cannot make; 8 means the lattice collapsed into "
                       + "rulings, which is Platinum's own title-bar "
                       + "pinstripe and must not mark an unknown")
        XCTAssertEqual(grounds, 12,
                       "the other twelve are ground; the texture stays a "
                       + "quarter of the region or it is loud again")
    }

    /// **An unknown too small to carry a caption must still read as one.**
    ///
    /// The quiet style was chosen against Monitors, where eight unknowns
    /// of 200×40 and larger read as damage. At icon scale it fails the
    /// other half of the same brief: 0xDC dots on 0xEF, with no room for
    /// the word, is not distinguishable from a flat plate — and a flat
    /// plate is candidate B, rejected because it LIES about the region
    /// being empty. Michelle read nine Finder folders and both `?`
    /// buttons as blank plates on 2026-08-07 (plan 018 slice 16, defect
    /// 2); every one of them was already rung 4.
    ///
    /// Watched failing by mutation: setting `closeTile` back to the
    /// 0xDC dot puts the contrast at 19 levels and this fails naming it.
    func testASmallUnknownIsLegibleRatherThanBlank() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        let png = try RenderShot.png(
            scene: scene([unknownWindow(rect: r, dst: [20, 40, 52, 72])]))
        let x0 = r.l + 20 + 8
        let y0 = r.t + Int(Platinum.contentTop) + 40 + 8
        let ax = x0 - (x0 % 2), ay = y0 - (y0 % 2)

        var dots = 0, grounds = 0, foreign: [String] = []
        for dy in 0..<4 {
            for dx in 0..<4 {
                let p = try XCTUnwrap(pixel(png, x: ax + dx, y: ay + dy))
                switch p {
                case (0xC4, 0xC4, 0xC4): dots += 1
                case (0xEF, 0xEF, 0xEF): grounds += 1
                default:
                    foreign.append(String(format: "%02X%02X%02X",
                                          p.0, p.1, p.2))
                }
            }
        }
        XCTAssertEqual(foreign, [],
                       "a small unknown is the same two-colour lattice, "
                       + "not a third appearance")
        XCTAssertEqual(dots, 4, "same 25% lattice, same phase rule")
        XCTAssertEqual(grounds, 12)
        /* THE POINT, stated as the number that failed: a marker a person
           cannot see is a flat plate wearing a texture's name. */
        XCTAssertGreaterThanOrEqual(0xEF - 0xC4, 40,
                                    "a small unknown needs contrast a "
                                    + "person can see at reading distance; "
                                    + "the large style's 19 levels do not "
                                    + "survive 32x32")
    }

    /// The old fill captioned anything 92x14 or larger, which put four
    /// repetitions of the same sentence down one Monitors panel. The
    /// threshold is part of the definition, so it is pinned here rather
    /// than left to whoever next tunes it.
    ///
    /// Watched failing by mutation: lowering `minCaptionWidth` back to 92
    /// makes the second case caption and the assertion names it.
    func testOnlyALargeUnknownCarriesItsCaption() {
        let ascent: CGFloat = 8
        XCTAssertNotNil(UnknownVisual.captionOrigin(
            in: CGRect(x: 0, y: 0, width: 340, height: 200), ascent: ascent),
            "a window-sized unknown must say what it is")
        XCTAssertNil(UnknownVisual.captionOrigin(
            in: CGRect(x: 0, y: 0, width: 208, height: 24), ascent: ascent),
            "a control-sized unknown is carried by its texture; captioning "
            + "every one of them is the loudness problem in new clothes")
        XCTAssertNil(UnknownVisual.captionOrigin(
            in: CGRect(x: 0, y: 0, width: 64, height: 64), ascent: ascent),
            "an icon-sized unknown has no room for prose at all")
    }

    /// THE DRIFT GATE. Both renderers drew their own copy of this fill for
    /// most of the plane's life, and the copies were identical only because
    /// nobody had touched either. Rung 4 has to be swappable in one place,
    /// so this reads the source and fails if a call site grows its own
    /// hatch again — the same shape of gate as `CommandParityTests`.
    ///
    /// Watched failing by mutation: pasting the old six-pixel stroke loop
    /// back into `SceneRenderer.drawUnavailableVisual` fails it by name.
    func testNoRendererDrawsItsOwnUnknownFill() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // MirrorKitUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // MirrorKit
            .appendingPathComponent("Sources/MirrorKitUI")

        for name in ["SceneRenderer.swift", "DisplayReplay.swift"] {
            let text = try String(contentsOf:
                ui.appendingPathComponent(name), encoding: .utf8)
            // The old fill's signature: a dashed stroke used as a border,
            // and the 6pt stripe advance. Neither has any other use here.
            XCTAssertFalse(text.contains("x += 6"),
                           "\(name) has grown its own hatch loop again — "
                           + "rung 4 of the ladder must be one definition, "
                           + "or the two renderers drift apart silently")
            XCTAssertTrue(text.contains("UnknownVisual.drawGround"),
                          "\(name) must draw the marked unknown through "
                          + "UnknownVisual, not by hand")
        }
    }
}
