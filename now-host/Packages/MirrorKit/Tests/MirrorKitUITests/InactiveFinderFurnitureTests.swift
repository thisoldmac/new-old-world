import XCTest
import AppKit
@testable import MirrorKit
@testable import MirrorKitUI

/// Window activation is shared Finder furniture: it must change the headers,
/// both scrollbars, and the grow box together in every view that exposes them.
/// These measurements come from the deterministic Mac OS 8.6 Calculator-front
/// oracle case, rather than from a hand-authored approximation.
@MainActor
final class InactiveFinderFurnitureTests: XCTestCase {
    private let frame = Rect(l: 100, t: 100, r: 420, b: 340)

    private func window(front: Bool, scrollbarEnabled: Bool = true) -> Scene.Window {
        var window = Scene.Window(
            id: "1.0/Macintosh HD#0", app: "Finder", psn: "1.0",
            title: "Macintosh HD", kind: 0, rect: frame, front: front,
            z: front ? 0 : 1, visible: true,
            controls: [
                .init(ref: "name", role: "control", title: "Name",
                      rect: Rect(l: 0, t: 23, r: 180, b: 43),
                      enabled: true, visible: true,
                      semantic: .init(knowledge: .known,
                                      kind: "columnHeader")),
                .init(ref: "v", role: "scrollbar", title: "",
                      rect: Rect(l: 304, t: 43, r: 320, b: 204),
                      enabled: scrollbarEnabled, visible: true,
                      value: 3, min: 0, max: 10),
                .init(ref: "h", role: "scrollbar", title: "",
                      rect: Rect(l: 0, t: 204, r: 304, b: 220),
                      enabled: scrollbarEnabled, visible: true,
                      value: 3, min: 0, max: 10),
            ], text: nil, items: [], display: nil)
        window.finder = .init(path: "Macintosh HD:", view: .name)
        return window
    }

    private func scene(_ window: Scene.Window) -> Scene {
        Scene(version: 0, seq: 1, source: "fixture", capturedAt: 0,
              screen: .init(w: 800, h: 600), apps: [], processes: nil,
              menubar: nil, windows: [window], desktopItems: nil,
              meta: .init(errors: []))
    }

    private func render(_ window: Scene.Window) throws -> NSBitmapImageRep {
        try XCTUnwrap(NSBitmapImageRep(
            data: RenderShot.png(scene: scene(window))))
    }

    private func rgb(_ rep: NSBitmapImageRep, x: Int, y: Int) -> [Int] {
        guard let colour = rep.colorAt(x: x, y: y) else { return [] }
        return [colour.redComponent, colour.greenComponent,
                colour.blueComponent].map { Int(($0 * 255).rounded()) }
    }

    private func colours(_ rep: NSBitmapImageRep, in box: CGRect) -> Set<[Int]> {
        var result: Set<[Int]> = []
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                result.insert(rgb(rep, x: x, y: y))
            }
        }
        return result
    }

    private func differenceCount(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep,
                                 in box: CGRect) -> Int {
        var result = 0
        for y in Int(box.minY)..<Int(box.maxY) {
            for x in Int(box.minX)..<Int(box.maxX) {
                if rgb(a, x: x, y: y) != rgb(b, x: x, y: y) { result += 1 }
            }
        }
        return result
    }

    func testInactiveFinderWithdrawsScrollbarFurniture() throws {
        let active = try render(window(front: true))
        let inactive = try render(window(front: false))
        let vertical = CGRect(x: 404, y: 163, width: 16, height: 161)

        XCTAssertEqual(rgb(inactive, x: 404, y: 220), [160, 160, 160],
                       "the measured 0x55 frame rasterizes on a half pixel")
        XCTAssertEqual(rgb(inactive, x: 406, y: 220), [238, 238, 238],
                       "the inactive bar is one flat 0xEE trough")
        XCTAssertGreaterThan(differenceCount(active, inactive, in: vertical), 100,
                             "activation must withdraw arrows and thumb")
    }

    func testDisabledActiveScrollbarIsNotAnInactiveScrollbar() throws {
        let disabled = try render(window(front: true, scrollbarEnabled: false))
        let inactive = try render(window(front: false, scrollbarEnabled: false))
        let topArrow = CGRect(x: 404, y: 163, width: 16, height: 16)

        XCTAssertGreaterThan(differenceCount(disabled, inactive, in: topArrow), 10,
                             "an empty active Finder window retains dim arrows")
    }

    func testInactiveFinderUsesMeasuredHeaderPalette() throws {
        let active = try render(window(front: true))
        let inactive = try render(window(front: false))
        let header = CGRect(x: 100, y: 143, width: 180, height: 20)
        let palette = colours(inactive, in: header)

        XCTAssertTrue(palette.contains([187, 187, 187]), "measured 0xBB face")
        XCTAssertTrue(palette.contains([119, 119, 119]), "measured 0x77 frame")
        XCTAssertTrue(palette.contains([153, 153, 153]), "measured 0x99 shadow")
        XCTAssertGreaterThan(differenceCount(active, inactive, in: header), 100)
    }

    func testInactiveFinderHasNoGrowBox() throws {
        let active = try render(window(front: true))
        let inactive = try render(window(front: false))
        let corner = CGRect(x: 405, y: 325, width: 15, height: 15)

        XCTAssertGreaterThan(differenceCount(active, inactive, in: corner), 20,
                             "only the front Finder window has a grow box")
    }
}
