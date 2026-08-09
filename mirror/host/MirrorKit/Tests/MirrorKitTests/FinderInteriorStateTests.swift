import XCTest
@testable import MirrorKit

final class FinderInteriorStateTests: XCTestCase {
    private static func window(scroll: Int = 0) -> Scene.Window {
        let vertical = Scene.Control(
            ref: "vertical", role: "scrollbar", title: "",
            rect: Rect(l: 389, t: 41, r: 405, b: 204),
            enabled: true, visible: true, value: scroll,
            min: 0, max: 300, checked: false)
        let horizontal = Scene.Control(
            ref: "horizontal", role: "scrollbar", title: "",
            rect: Rect(l: -1, t: 203, r: 390, b: 219),
            enabled: true, visible: true, value: 0,
            min: 0, max: 0, checked: false)
        return Scene.Window(
            id: "finder-window", app: "Finder", psn: "0.1",
            title: "Macintosh HD", kind: 20,
            rect: Rect(l: 48, t: 83, r: 452, b: 321),
            front: true, z: 0, visible: true,
            controls: [vertical, horizontal], text: nil,
            items: [.init(name: "System Folder", kind: "folder",
                          type: nil, creator: nil, x: 22, y: 43,
                          placed: true, alias: false, invisible: false,
                          w: 16, h: 16)],
            finder: .init(path: "Macintosh HD:", view: .name),
            display: nil)
    }

    private static func scene(scroll: Int = 0) -> Scene {
        Scene(version: IR.version, seq: scroll + 1, source: "axtree",
              capturedAt: 0, screen: .init(w: 800, h: 600),
              apps: [.init(psn: "0.1", name: "Finder", front: true,
                           error: nil)],
              processes: nil, menubar: nil, windows: [window(scroll: scroll)],
              desktopItems: nil,
              meta: .init(latencyMs: nil, bytes: nil, errors: [], plane: nil))
    }

    func testSelectionProjectsImmediatelyWithoutMutatingGuestScene() {
        let guest = Self.scene()
        var state = FinderInteriorState()
        state.select("System Folder", in: "finder-window")

        let shown = state.projecting(guest)

        XCTAssertEqual(shown.windows[0].finder?.selectedNames,
                       ["System Folder"])
        XCTAssertEqual(guest.windows[0].finder?.selectedNames, [])
    }

    func testPageScrollMovesItemsAndThumbBeforeGuestSettles() throws {
        let guest = Self.scene()
        let window = guest.windows[0]
        let control = try XCTUnwrap(window.controls.first)
        var state = FinderInteriorState()

        state.previewScroll(in: window, control: control, part: .pageDown)
        let shown = state.projecting(guest)

        let value = try XCTUnwrap(shown.windows[0].controls.first?.value)
        XCTAssertGreaterThan(value, 0)
        XCTAssertEqual(shown.windows[0].items?.first?.y,
                       43 - value)
        XCTAssertEqual(guest.windows[0].items?.first?.y, 43)
    }

    func testGuestScrollRetiresTheLocalPreview() throws {
        let guest = Self.scene()
        let window = guest.windows[0]
        let control = try XCTUnwrap(window.controls.first)
        var state = FinderInteriorState()
        state.previewScroll(in: window, control: control, part: .lineDown)
        XCTAssertNotEqual(state.projecting(guest).windows[0].items?.first?.y,
                          43)

        state.reconcile(with: Self.scene(scroll: 16))
        XCTAssertEqual(state.projecting(Self.scene(scroll: 16))
            .windows[0].items?.first?.y, 43,
            "the source has already projected the guest's new value; the "
                + "optimistic delta must not be applied twice")
    }
}
