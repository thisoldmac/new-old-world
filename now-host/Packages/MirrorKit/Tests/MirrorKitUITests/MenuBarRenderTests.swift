import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// Pixel guards for the first surface SheepShaver made independently
/// measurable: the Finder menu bar under Mac OS 8.6 + CarbonLib 1.6.
///
/// These assert measured structure, not an in-source screenshot. The oracle
/// remains external; the values and rows below are the procedure derived
/// from the attributed 2026-08-11 native capture recorded in the oracle
/// workflow. Moving the old flat `#EEEEEE` fill back into SceneRenderer makes
/// the structural tests fail for the rows they name.
@MainActor
final class MenuBarRenderTests: XCTestCase {
    private func scene() -> Scene {
        let menus = [
            Scene.Menu(title: "", apple: true, left: 10, id: 1, items: []),
            Scene.Menu(title: "File", apple: false, left: 43, id: 2, items: []),
            Scene.Menu(title: "Edit", apple: false, left: 78, id: 3, items: []),
            Scene.Menu(title: "Special", apple: false, left: 114, id: 4, items: []),
            Scene.Menu(title: "", apple: false, left: 300,
                       id: ObjectResolver.applicationMenuID, items: []),
        ]
        var app = Scene.AppRef(psn: "0:1", name: "Finder", front: true,
                               incarnation: nil, backgroundOnly: false,
                               error: nil)
        app.front = true
        return Scene(version: 2, seq: 1, source: "oracle-case", capturedAt: 0,
                     screen: .init(w: 400, h: 80), apps: [app], processes: nil,
                     menubar: .init(app: "Finder", menus: menus), windows: [],
                     desktopItems: nil, meta: .init(errors: []))
    }

    private func render() throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(data: RenderShot.png(scene: scene())))
    }

    private func rgb(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> UInt32 {
        guard let color = rep.colorAt(x: x, y: y) else { return 0 }
        let r = UInt32((color.redComponent * 255).rounded())
        let g = UInt32((color.greenComponent * 255).rounded())
        let b = UInt32((color.blueComponent * 255).rounded())
        return r << 16 | g << 8 | b
    }

    func testFaceAndBottomBevelOccupyTheMeasuredRows() throws {
        let rep = try render()
        XCTAssertEqual(rgb(rep, 220, 10), 0xDDDDDD, "menu face")
        XCTAssertEqual(rgb(rep, 220, 18), 0x999999, "lower bevel row")
        XCTAssertEqual(rgb(rep, 220, 19), 0x000000, "bottom frame row")
        XCTAssertNotEqual(rgb(rep, 220, 20), 0x000000,
                          "the former extra black row must remain desktop")
    }

    func testRaisedCapsCarryTheMeasuredAsymmetricBevel() throws {
        let rep = try render()
        XCTAssertEqual(rgb(rep, 8, 0), 0xFFFFFF)
        XCTAssertEqual(rgb(rep, 0, 8), 0xFFFFFF)
        XCTAssertEqual(rgb(rep, 399, 8), 0x999999)
        XCTAssertEqual(rgb(rep, 0, 0), 0x000000)
        XCTAssertEqual(rgb(rep, 5, 0), 0x555555)
        XCTAssertEqual(rgb(rep, 394, 0), 0x555555)
    }

    func testApplicationMenuDividerCarriesRailsAndDiagonalGrip() throws {
        let rep = try render()
        XCTAssertEqual(rgb(rep, 294, 8), 0xFFFFFF, "left rail")
        XCTAssertEqual(rgb(rep, 299, 8), 0x999999, "right rail")
        XCTAssertEqual(rgb(rep, 296, 4), 0x888888, "grip dark step")
        XCTAssertEqual(rgb(rep, 297, 5), 0xFFFFFF, "grip lit step")
    }

    func testOrdinaryMenuInkKeepsItsMeasuredVerticalBand() throws {
        let rep = try render()
        var darkRows: Set<Int> = []
        for y in 0..<18 {
            for x in 43..<158 where rgb(rep, x, y) == 0x000000 {
                darkRows.insert(y)
            }
        }
        // NSBitmapImageRep exposes the extracted strike one raster row above
        // SwiftUI's approximate fallback. The pack-backed band is the one
        // independently checked against the native framebuffer; the no-pack
        // value makes honest degradation deterministic without calling it a
        // pixel claim.
        let measured = Set(4...14)
        let fallback = Set(5...15)
        XCTAssertTrue(darkRows == measured || darkRows == fallback,
                      "File/Edit menu ink moved outside both explicit bands: "
                        + "\(darkRows.sorted())")
    }
}
