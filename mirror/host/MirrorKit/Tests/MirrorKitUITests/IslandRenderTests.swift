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

    func testPartialSemanticContainersDoNotEraseGuestDisplayContent() {
        func control(_ kind: String, value: String? = nil) -> Scene.Control {
            .init(ref: "now-element-1", role: "control", title: "",
                  rect: .init(l: 0, t: 0, r: 120, b: 60),
                  enabled: true, visible: true,
                  semantic: .init(knowledge: .known, kind: kind,
                                  value: value,
                                  provenance: "guest",
                                  completeness: .partial))
        }

        XCTAssertFalse(SceneRenderer.semanticOwnsDisplay(control("groupBox")))
        XCTAssertTrue(SceneRenderer.semanticSupersedesResource(
            control("groupBox")))
        XCTAssertFalse(SceneRenderer.semanticOwnsDisplay(control("listBox")))
        XCTAssertFalse(SceneRenderer.semanticOwnsDisplay(control("popupMenu")))
        XCTAssertTrue(SceneRenderer.semanticOwnsDisplay(
            control("popupMenu", value: "Long Date")))
    }

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

    /// Sherlock's data-browser and channel controls are typed even before
    /// their private payload is understood. That progress must be visible as
    /// a bounded unavailable region, never another empty dashed shell.
    func testTypedUnsupportedContentDrawsABoundedPlaceholder() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Sherlock 2", front: true, z: 0, rect: r,
                       island: nil)
        w.display = []
        w.controls = [.init(
            ref: "browser", role: "control", title: "",
            rect: Rect(l: 40, t: 50, r: 300, b: 220),
            enabled: true, visible: true,
            semantic: .init(knowledge: .known, kind: "dataBrowser",
                            value: "Data browser content unavailable",
                            provenance: "guest-semantic-assist",
                            completeness: .partial))]

        let png = try RenderShot.png(scene: scene([w]))
        let contentX = r.l + 1
        let contentY = r.t + Int(Platinum.contentTop)
        let inside = try XCTUnwrap(pixel(png, x: contentX + 120,
                                         y: contentY + 110))
        let outside = try XCTUnwrap(pixel(png, x: contentX + 20,
                                          y: contentY + 110))
        XCTAssertFalse(inside.0 == 255 && inside.1 == 255 && inside.2 == 255,
                       "typed unsupported content needs a visible placeholder")
        XCTAssertTrue(outside.0 == 255 && outside.1 == 255
                        && outside.2 == 255,
                      "the placeholder must stay inside the guest control")
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

    /// P2 semantics own exact control rectangles while P3 owns the surrounding
    /// content. This prevents both CopyBits placeholders and raw QuickDraw
    /// titles from painting underneath a control we can render and actuate.
    func testSettledDisplayClipsOutSemanticControlPixels() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var semanticOnly = window(title: "Generic App", front: true, z: 0,
                                  rect: r, island: nil)
        semanticOnly.display = []
        semanticOnly.controls = [.init(
            ref: "button", role: "button", title: "Do It",
            rect: Rect(l: 20, t: 30, r: 140, b: 52),
            enabled: true, visible: true,
            semantic: .init(knowledge: .known, kind: "pushButton",
                            action: "press", provenance: "guest-semantic-assist",
                            completeness: .complete))]
        var withDisplay = semanticOnly
        var fill = DisplayOp(op: "rect", ticks: 1)
        fill.verb = 1
        fill.rect = [20, 30, 140, 52]
        var label = DisplayOp(op: "text", ticks: 2)
        label.text = "Wrong copy"
        label.pen = [25, 46]
        label.font = 0
        label.size = 12
        withDisplay.display = [fill, label]

        XCTAssertEqual(try RenderShot.png(scene: scene([withDisplay])),
                       try RenderShot.png(scene: scene([semanticOnly])),
                       "P3 must not paint beneath a P2-owned control rectangle")
    }

    func testGuestEraseMakesRepeatedRepaintsReplacePriorDrawing() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        func op(_ name: String, _ ticks: Int,
                _ configure: (inout DisplayOp) -> Void) -> DisplayOp {
            var value = DisplayOp(op: name, ticks: ticks)
            configure(&value)
            return value
        }
        let first: [DisplayOp] = [
            op("state", 1) {
                $0.kind = "bg"; $0.rgb = [56_797, 56_797, 56_797]
            },
            op("rect", 2) { $0.verb = 2; $0.rect = [0, 0, 200, 100] },
            op("state", 3) { $0.kind = "fg"; $0.rgb = [0, 0, 0] },
            op("text", 4) {
                $0.text = "Old"; $0.pen = [20, 30]
                $0.font = 3; $0.size = 9
            },
        ]
        var second = first
        second[3].text = "Current"
        second[3].pen = [80, 30]
        var twice = window(title: "Generic App", front: true, z: 0,
                           rect: r, island: nil)
        twice.display = first + second
        var once = twice
        once.display = second

        XCTAssertEqual(try RenderShot.png(scene: scene([twice])),
                       try RenderShot.png(scene: scene([once])),
                       "a later guest erase must clear the previous repaint")
    }

    func testRegionEraseUsesItsReportedBounds() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        var w = window(title: "Generic App", front: true, z: 0,
                       rect: r, island: nil)
        var black = DisplayOp(op: "rect", ticks: 1)
        black.verb = 1; black.rect = [0, 0, 80, 80]
        var bg = DisplayOp(op: "state", ticks: 2)
        bg.kind = "bg"; bg.rgb = [65_535, 65_535, 65_535]
        var erase = DisplayOp(op: "rgn", ticks: 3)
        erase.verb = 2; erase.rect = [0, 0, 80, 80]
        w.display = [black, bg, erase]

        let png = try RenderShot.png(scene: scene([w]))
        let sample = try XCTUnwrap(pixel(
            png, x: r.l + 1 + 40,
            y: r.t + Int(Platinum.contentTop) + 40))
        XCTAssertGreaterThan(sample.0, 245)
        XCTAssertGreaterThan(sample.1, 245)
        XCTAssertGreaterThan(sample.2, 245)
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

    func testBoundedListCellsSupersedeTheUnknownResourceDialogItem() throws {
        let r = Rect(l: 100, t: 100, r: 500, b: 400)
        let list = Scene.Control(
            ref: "cities", role: "listBox", title: "",
            rect: Rect(l: 20, t: 40, r: 260, b: 140), enabled: true,
            visible: true,
            semantic: .init(
                knowledge: .known, kind: "listBox", value: "Abu Dhabi",
                listCells: [
                    .init(row: 1, column: 0, text: "Abu Dhabi", selected: true),
                    .init(row: 1, column: 1, text: "U.A.E.", selected: true),
                    .init(row: 2, column: 0, text: "Accra", selected: false),
                    .init(row: 2, column: 1, text: "Ghana", selected: false),
                ],
                listTotalCount: 4,
                provenance: "guest-semantic-assist",
                completeness: .complete))
        var expected = window(title: "Set Time Zone", front: true, z: 0,
                              rect: r, island: nil)
        expected.display = []
        expected.controls = [list]

        var withResourceItem = expected
        withResourceItem.dialogItems = [Scene.DialogItem(
            number: 1, title: "", rect: Rect(l: 20, t: 40, r: 260, b: 140),
            enabled: true, visible: true, ref: "cities",
            semantic: .init(knowledge: .unknown,
                            provenance: "guest-ditl",
                            completeness: .complete))]

        XCTAssertEqual(try RenderShot.png(scene: scene([withResourceItem])),
                       try RenderShot.png(scene: scene([expected])),
                       "a proven list must replace its unknown DITL resource shell")
    }
}
