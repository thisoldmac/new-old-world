import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// W0.1: the process shelf came off the render canvas entirely — it now
/// lives in the Mirror module's host chrome (`MirrorModuleView`), never
/// painted over the guest scene. This is a behavioural check on the
/// renderer's own output, not a string search over `SceneRenderer.swift`:
/// it proves the canvas reclaimed the full 92pt band the shelf used to
/// occupy, with a `processes`-bearing scene that would previously have
/// triggered the shelf to draw.
@MainActor
final class ProcessShelfRemovedTests: XCTestCase {

    private func scene(windows: [Scene.Window], processes: [Scene.ProcessRef]?)
        -> Scene {
        Scene(version: 0, seq: 1, source: "mock", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: processes,
              menubar: nil, windows: windows, desktopItems: nil,
              meta: .init(errors: []))
    }

    private func island(w: Int, h: Int, r: UInt8, g: UInt8, b: UInt8)
        -> PixelIsland {
        var rgba = Data()
        for _ in 0..<(w * h) { rgba.append(contentsOf: [r, g, b, 255]) }
        return PixelIsland(width: w, height: h, rgba: rgba,
                           originX: 0, originY: 0, scale: 1)
    }

    private func pixel(_ png: Data, x: Int, y: Int) -> (Int, Int, Int)? {
        guard let rep = NSBitmapImageRep(data: png),
              let color = rep.colorAt(x: x, y: y) else { return nil }
        return (Int((color.redComponent * 255).rounded()),
                Int((color.greenComponent * 255).rounded()),
                Int((color.blueComponent * 255).rounded()))
    }

    /// A window whose content reaches to the screen's bottom edge, on a
    /// scene that reports live processes (front and background, exactly
    /// what used to make `drawShelf` paint a band over this exact area).
    /// Before W0.1, the bottom 92pt of an 800x600 canvas — y=508..600 —
    /// was the shelf's own gray band, not the window. Now it must be the
    /// window's own island pixels, right down to the last row.
    func testWindowContentReachesTheBottomEdgeWithProcessesPresent() throws {
        let rect = Rect(l: 0, t: 0, r: 800, b: 600)
        let win = Scene.Window(id: "1.0/Full#0", app: "Full", psn: "1.0",
                               title: "Full", kind: 0, rect: rect,
                               front: true, z: 0, visible: true,
                               controls: [], text: nil, items: nil,
                               display: nil,
                               island: island(w: rect.r - rect.l - 2,
                                              h: rect.b - rect.t - 23,
                                              r: 10, g: 200, b: 10))
        let procs: [Scene.ProcessRef] = [
            .init(psn: "1.0", name: "Full", front: true, signature: "FULL"),
            .init(psn: "1.1", name: "Helper", front: false, signature: "HELP"),
        ]
        let png = try RenderShot.png(scene: scene(windows: [win],
                                                  processes: procs))
        // Well inside where the old 92pt shelf band (y >= 508) would have
        // painted over the window: this must be the window's own island,
        // not the shelf's gray fill.
        let bottomBand = pixel(png, x: 400, y: 590)
        XCTAssertEqual(bottomBand?.1, 200,
                       "the canvas must reach the bottom edge with scene "
                       + "content — no shelf band painted over it")

        // And near the very last row.
        let lastRow = pixel(png, x: 400, y: 598)
        XCTAssertEqual(lastRow?.1, 200,
                       "no shelf band at the bottom-most rows either")
    }
}
