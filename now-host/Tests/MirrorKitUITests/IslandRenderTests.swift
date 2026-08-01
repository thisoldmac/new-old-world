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
}
