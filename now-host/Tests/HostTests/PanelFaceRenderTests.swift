import XCTest
import AppKit
import MirrorKit
import MirrorKitUI
@testable import Host

/// **The face a Dialog Manager window is erased with.**
///
/// The renderer filled every non-modal window's content with `Platinum.g0`
/// — pure white — so everything a control panel's semantic pass did not
/// draw over read as unfinished paper. Against the guest's own screendump
/// the same region is the Appearance Manager's dialog grey, and the gap is
/// most of why a captured panel and its render look like different
/// products.
///
/// The fixture is the scene half of the 019 integration pair
/// (`019-integration/date-and-time-scene.json`), whose guest screendump
/// sits beside it. It carries NO display ops — the panel is drawn wholly
/// from semantics — which is exactly why the base fill is the whole
/// picture here and not a detail under a replay.
@MainActor
final class PanelFaceRenderTests: XCTestCase {

    private func scene() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(Bundle.module.url(
            forResource: "now-scene-019-date-and-time",
            withExtension: "json", subdirectory: "Fixtures"))
        return try NOWMirrorSceneDecoder.decode(
            irVersion: 2, document: Data(contentsOf: url))
    }

    /// Every pixel of `box`, as 8-bit RGB triples.
    private func pixels(_ scene: MirrorKit.Scene, in box: CGRect) throws
        -> [(UInt8, UInt8, UInt8)] {
        /* THE STORED SAMPLES, not `colorAt` — which hands back an
           NSColor in the representation's own space and re-converts on
           the way out, so a face written as 0xDDDDDD reads back 228.
           These are the bytes a person's eye and `tools/fidelity-pair.py`
           both see. */
        let png = try RenderShot.png(scene: scene)
        let rep = try XCTUnwrap(NSBitmapImageRep(data: png))
        let bytes = try XCTUnwrap(rep.bitmapData)
        let stride = rep.bytesPerRow
        let sample = rep.bitsPerPixel / 8
        var out: [(UInt8, UInt8, UInt8)] = []
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                let o = y * stride + x * sample
                out.append((bytes[o], bytes[o + 1], bytes[o + 2]))
            }
        }
        return out
    }

    /// The front window's interior, inset past the frame and title bar so
    /// nothing chrome contributes. Taken from the scene's own rect rather
    /// than written down, so a fixture that moves does not silently start
    /// measuring the desktop.
    private func interior(_ scene: MirrorKit.Scene) throws -> CGRect {
        let win = try XCTUnwrap(scene.windows.first(where: \.front))
        return CGRect(x: CGFloat(win.rect.l) + 8,
                      y: CGFloat(win.rect.t) + 30,
                      width: CGFloat(win.rect.r - win.rect.l) - 16,
                      height: CGFloat(win.rect.b - win.rect.t) - 40)
    }

    /// **The panel's face is the dialog grey, not white.**
    ///
    /// Asserted the way the guest was measured — as the interior's dominant
    /// colour — rather than at a hand-picked pixel, because a probe point
    /// lands inside whichever control the layout happens to put there and
    /// stops meaning anything the moment the fixture changes.
    func testAControlPanelsFaceIsTheDialogGreyAndNotWhite() throws {
        let scene = try scene()
        let panel = try XCTUnwrap(scene.windows.first(where: \.front))
        XCTAssertEqual(panel.kind, 2,
                       "this fixture is only interesting because the guest "
                       + "reported windowKind 2 for it")
        let px = try pixels(scene, in: try interior(scene))
        XCTAssertGreaterThan(px.count, 1000)

        var counts: [String: Int] = [:]
        for p in px { counts["\(p.0),\(p.1),\(p.2)", default: 0] += 1 }
        let (top, topCount) = try XCTUnwrap(counts.max { $0.value < $1.value })
        let white = counts["255,255,255"] ?? 0

        XCTAssertEqual(top, "221,221,221", """
            the dominant colour of the panel's interior is \(top) \
            (\(topCount) of \(px.count) px). The guest's own screendump for \
            this exact scene is 221,221,221 across the same region — the \
            Appearance Manager's kThemeBrushDialogBackgroundActive. See \
            Platinum.dialogFace.
            """)
        XCTAssertLessThan(white, px.count / 4, """
            \(white) of \(px.count) interior pixels are pure white. A \
            Dialog Manager window is erased with the dialog brush; white \
            here is the renderer's own constant showing through.
            """)
    }

    /// **The knockouts follow the face.**
    ///
    /// A group box paints over its own rule to make room for its title.
    /// That patch was filling with white because white was what the face
    /// happened to be — so fixing the face alone would have turned every
    /// group box into a visible white plate on exactly the windows the
    /// first fix was for.
    ///
    /// SYNTHETIC ON PURPOSE, and this is the part worth reading: not one
    /// committed fixture carries a control the guest has identified as a
    /// `groupBox`, so a test written against a fixture passes with the
    /// knockout left at `Platinum.g0` and proves nothing. It was written
    /// that way first and watched pass under the mutation it exists to
    /// catch. The scene below adds the one control no capture has yet
    /// produced.
    func testAGroupBoxTitleBandIsKnockedOutInTheWindowsOwnFace() throws {
        var scene = try scene()
        let index = try XCTUnwrap(scene.windows.firstIndex(where: \.front))
        let box = MirrorKit.Rect(l: 20, t: 40, r: 320, b: 140)
        scene.windows[index].controls.append(
            MirrorKit.Scene.Control(
                ref: "now-control-synthetic-groupbox", role: "control",
                title: "Time Zone", rect: box, enabled: true, visible: true,
                semantic: .init(knowledge: .known, kind: "groupBox")))
        // Clear everything that would draw over it — this test is about one
        // patch, and a passing render must not depend on layout luck.
        scene.windows[index].dialogItems = nil
        scene.windows[index].display = nil

        let win = scene.windows[index]
        // The band the group box knocks out: along its own top rule.
        let probe = CGRect(x: CGFloat(win.rect.l + box.l) + 10,
                           y: CGFloat(win.rect.t + box.t) + 22,
                           width: 60, height: 8)
        let px = try pixels(scene, in: probe)
        let white = px.filter { $0 == (255, 255, 255) }.count
        XCTAssertLessThan(white, px.count / 10, """
            \(white) of \(px.count) pixels in a group box's title band are \
            pure white on a dialog-grey face. drawGroup knocks its own rule \
            out to make room for the title and must fill that hole with the \
            window's face, not with Platinum.g0.
            """)
    }
}
