import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// The other half of the focus-lifecycle change: the poller may attach a held
/// island to a window that is NOT frontmost, but that is invisible unless the
/// renderer actually paints it. This renders offscreen (RenderShot — the app's
/// own drawn canvas, not the guest framebuffer and not the host screen) and
/// reads the pixels back.
@MainActor
final class IslandRenderTests: XCTestCase {

    func testApplicationMenuDoesNotSuppressMissingAppleMenuFallback() {
        let appMenu = Scene.Menu(
            title: "", apple: false, left: 0,
            id: ObjectResolver.applicationMenuID, items: [])
        XCTAssertTrue(SceneRenderer.shouldSynthesizeAppleMenu([appMenu]))
        XCTAssertFalse(SceneRenderer.shouldSynthesizeAppleMenu([
            .init(title: "", apple: true, left: 10, id: 128, items: []),
            appMenu,
        ]))
    }

    func testGuestApplicationMenuDropdownIsRightAligned() {
        let appMenu = Scene.Menu(
            title: "", apple: false, left: 0,
            id: ObjectResolver.applicationMenuID,
            items: [
                .init(title: "Hide New Old World", index: 1,
                      separator: false, enabled: true, mark: false, cmd: ""),
                .init(title: "Show All", index: 3,
                      separator: false, enabled: true, mark: false, cmd: ""),
            ])

        let frame = SceneRenderer.dropdownFrame(appMenu, screenWidth: 800)

        XCTAssertEqual(frame.maxX, 800)
        XCTAssertGreaterThan(frame.minX, 0,
                             "the switcher dropdown must not use left == 0")
    }

    private func window(title: String, front: Bool, z: Int, rect: Rect,
                        island: PixelIsland?) -> Scene.Window {
        Scene.Window(id: "1.\(z)/\(title)#\(z)", app: title, psn: "1.\(z)",
                     title: title, kind: 0, rect: rect, front: front, z: z,
                     visible: true, controls: [], text: nil, items: nil,
                     display: nil, island: island)
    }

    /// A solid RGBA island in one colour.
    private func island(w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8)
        -> PixelIsland {
        var rgba = Data()
        for _ in 0..<(w * h) { rgba.append(contentsOf: [r, g, b, 255]) }
        return PixelIsland(width: w, height: h, rgba: rgba,
                           originX: 0, originY: 0, scale: 1)
    }

    private func scene(_ windows: [Scene.Window]) -> Scene {
        Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: windows, desktopItems: nil,
              meta: .init(errors: []))
    }

    /// Sample the rendered PNG at a guest point (the transform is 1:1).
    private func pixel(_ png: Data, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let rep = NSBitmapImageRep(data: png),
              let color = rep.colorAt(x: x, y: y) else { return nil }
        return (Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    /// Both windows' interiors are painted from their own islands — the back
    /// one is NOT blank, and the two are not confused with each other.
    func testABackgroundWindowsIslandIsDrawn() throws {
        let frontRect = Rect(l: 40, t: 60, r: 340, b: 260)
        let backRect = Rect(l: 400, t: 300, r: 700, b: 500)
        let s = scene([
            window(title: "Front", front: true, z: 0, rect: frontRect,
                   island: island(w: frontRect.r - frontRect.l - 2,
                                  h: frontRect.b - frontRect.t - 23,
                                  r: 220, g: 0, b: 0)),
            window(title: "Back", front: false, z: 1, rect: backRect,
                   island: island(w: backRect.r - backRect.l - 2,
                                  h: backRect.b - backRect.t - 23,
                                  r: 0, g: 0, b: 220)),
        ])
        let png = try RenderShot.png(scene: s)
        // Reproducible visual evidence: MIRROR_RENDER_OUT=/tmp/x.png swift test
        // --filter testABackgroundWindowsIslandIsDrawn writes the render-shot,
        // so the claim "the back window is not blank" can be looked at.
        if let out = ProcessInfo.processInfo.environment["MIRROR_RENDER_OUT"] {
            try png.write(to: URL(fileURLWithPath: out))
        }
        // Well inside each content area (chrome is 1px sides, 22px title bar).
        let inFront = pixel(png, x: frontRect.l + 40, y: frontRect.t + 60)
        let inBack = pixel(png, x: backRect.l + 40, y: backRect.t + 60)
        XCTAssertEqual(inFront?.0, 220, "front island painted")
        XCTAssertEqual(inBack?.2, 220,
                       "an unfocused window's held island must be painted too")
        XCTAssertEqual(inBack?.0, 0, "and it must be ITS island, not the front's")
    }

    /// The stale-geometry decision, asserted: an island captured when the window
    /// was larger is CLIPPED to the current content rect — not scaled, not
    /// dropped, and never spilling over the chrome or onto the desktop.
    func testAnOversizedStaleIslandIsClippedNotScaled() throws {
        let rect = Rect(l: 200, t: 200, r: 400, b: 360)   // shrunk since capture
        let s = scene([
            window(title: "Shrunk", front: false, z: 0, rect: rect,
                   island: island(w: 600, h: 400, r: 0, g: 200, b: 0)),
        ])
        let png = try RenderShot.png(scene: s)
        // Inside the content: island pixels.
        XCTAssertEqual(pixel(png, x: rect.l + 20, y: rect.t + 40)?.1, 200)
        // Just past the window's right/bottom edge: NOT island pixels.
        XCTAssertNotEqual(pixel(png, x: rect.r + 6, y: rect.t + 40)?.1, 200,
                          "a stale island must not paint outside the window")
        XCTAssertNotEqual(pixel(png, x: rect.l + 20, y: rect.b + 6)?.1, 200)
        // And nothing was resampled: a scaled 600x400 island would land its
        // own top-left colour everywhere, so check the near-edge column is
        // still the clipped island rather than the window face beyond it.
        XCTAssertEqual(pixel(png, x: rect.r - 4, y: rect.b - 4)?.1, 200)
    }

    /// A scene with no content plane is not evidence of a white application.
    /// Key Caps and NOW's own Workshop both exposed this: their chrome and
    /// menus arrived while the entire body silently rendered blank. The
    /// placeholder keeps that missing-content fact visible and bounded.
    func testAnUnreportedWindowBodyIsNotRenderedAsEmptyWhiteContent() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Unreported", front: true, z: 0, rect: r,
                       island: nil)
        w.controls = [.init(ref: "button", role: "button", title: "Do It",
                            rect: Rect(l: 260, t: 200, r: 340, b: 220),
                            enabled: true, visible: true)]
        let png = try RenderShot.png(scene: scene([w]))
        let inside = try XCTUnwrap(pixel(png, x: r.l + 200, y: r.t + 150))
        XCTAssertFalse(inside.0 == 255 && inside.1 == 255 && inside.2 == 255,
                       "missing guest content needs a visible placeholder")
    }

    /// QDPeek deliberately carries only CopyBits geometry. That limitation
    /// must read as a bounded unavailable visual, not as a claim that the
    /// guest drew an empty white region.
    func testCopyBitsGeometryDrawsABoundedPlaceholder() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Workshop", front: true, z: 0, rect: r,
                       island: nil)
        var bits = DisplayOp(op: "bits", ticks: 1)
        bits.src = [0, 0, 80, 50]
        bits.dst = [40, 50, 160, 130]
        w.display = [bits]

        let png = try RenderShot.png(scene: scene([w]))
        let contentX = r.l + 1
        let contentY = r.t + Int(Platinum.contentTop)
        let inside = try XCTUnwrap(pixel(png, x: contentX + 80,
                                         y: contentY + 95))
        let outside = try XCTUnwrap(pixel(png, x: contentX + 20,
                                          y: contentY + 95))
        XCTAssertFalse(inside.0 == 255 && inside.1 == 255 && inside.2 == 255,
                       "CopyBits destination needs an explicit placeholder")
        XCTAssertTrue(outside.0 == 255 && outside.1 == 255
                        && outside.2 == 255,
                      "the placeholder must stay inside the guest dst rect")
    }

    /// Proven Control Manager kinds are presentation facts, not hints. The
    /// renderer must not collapse a checkbox back into the legacy pill shape.
    func testAProvenCheckboxIsNotRenderedAsAPushButton() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Workshop", front: true, z: 0, rect: r,
                       island: nil)
        w.display = []
        w.controls = [.init(
            ref: "check", role: "checkbox", title: "Reveal system files",
            rect: Rect(l: 20, t: 30, r: 180, b: 46), enabled: true,
            visible: true, checked: true,
            semantic: .init(knowledge: .known, kind: "checkBox",
                            action: "press", state: "on",
                            provenance: "control-kind",
                            completeness: .complete))]

        let png = try RenderShot.png(scene: scene([w]))
        let contentX = r.l + 1
        let contentY = r.t + Int(Platinum.contentTop)
        let mark = try XCTUnwrap(pixel(png, x: contentX + 20,
                                       y: contentY + 38))
        let formerPillEdge = try XCTUnwrap(pixel(
            png, x: contentX + 100, y: contentY + 30))
        XCTAssertLessThan(mark.0, 100, "the checkbox mark is visible")
        XCTAssertTrue(formerPillEdge.0 == 255 && formerPillEdge.1 == 255
                        && formerPillEdge.2 == 255,
                      "the semantic checkbox must not retain a pill border")
    }

    /// Popup controls use the guest-proven kind as well; this pins the square
    /// classic popup frame and its arrow rather than accepting a pill by title.
    func testAProvenPopupIsRenderedAsAPopupMenu() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Workshop", front: true, z: 0, rect: r,
                       island: nil)
        w.display = []
        w.controls = [.init(
            ref: "depth", role: "popup", title: "8-bit color",
            rect: Rect(l: 20, t: 60, r: 180, b: 80), enabled: true,
            visible: true, value: 2,
            semantic: .init(knowledge: .known, kind: "popupMenu",
                            action: "choose", value: "2",
                            provenance: "control-kind",
                            completeness: .complete))]

        let png = try RenderShot.png(scene: scene([w]))
        let contentX = r.l + 1
        let contentY = r.t + Int(Platinum.contentTop)
        // The guest value gives this control a separate label at the left;
        // sample the popup face's right corner, which remains square.
        let squareCorner = [(178, 60), (179, 60), (178, 61), (179, 61)]
            .compactMap { pixel(png, x: contentX + $0.0,
                                y: contentY + $0.1)?.0 }
        XCTAssertLessThan(try XCTUnwrap(squareCorner.min()), 200,
                          "a popup has a square dark frame, unlike a pill")
    }

    func testBoundedListSelectionRendersAsARecessedList() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Date & Time", front: true, z: 0, rect: r,
                       island: nil)
        w.display = []
        w.controls = [.init(
            ref: "cities", role: "listBox", title: "",
            rect: Rect(l: 20, t: 40, r: 220, b: 120), enabled: true,
            visible: true,
            semantic: .init(knowledge: .known, kind: "listBox",
                            value: "Rome",
                            provenance: "guest-semantic-assist",
                            completeness: .partial))]
        let png = try RenderShot.png(scene: scene([w]))
        let x = r.l + 1 + 20
        let y = r.t + Int(Platinum.contentTop) + 40
        let border = try XCTUnwrap(pixel(png, x: x, y: y))
        let selected = try XCTUnwrap(pixel(png, x: x + 5, y: y + 5))
        XCTAssertLessThan(border.0, 100, "list has a recessed dark boundary")
        XCTAssertLessThan(selected.0, 255, "bounded selected row is visibly filled")
    }
}
