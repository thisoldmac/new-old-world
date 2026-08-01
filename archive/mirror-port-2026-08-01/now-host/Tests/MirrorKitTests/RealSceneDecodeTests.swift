import XCTest
@testable import MirrorKit

/// F2: the guest's REAL scenes, through the production entry point.
///
/// Every fixture elsewhere in this directory is a Python oracle's literal —
/// built and then parsed by the same code, which is exactly the shape of
/// test this repo's AGENTS.md warns proves nothing about a real producer.
/// `09-real-scene-mac99-20260801.json` is different: it is a live capture off
/// a real Mac OS 9.1 machine (`docs/local/wave3-live-scene.json`, captured
/// 2026-08-01, labelled "mac99" in that session's notes), fed through
/// `MirrorScene.decode` unmodified.
///
/// That decode used to throw. In order: `Scene.Menu.apple` (the guest never
/// asserts which menu is the Apple menu), then `Scene.MenuItem.cmd` (65 of
/// this capture's 85 real items have no shortcut), then `Scene.Control.role`
/// (the guest's walk cannot read a control's defProc). All three were
/// required keys behind a synthesized or partial decode — the same defect
/// `AbsentPlaneTests` fixed for `windows[].controls`, just not yet chased
/// into the leaves.
final class RealSceneDecodeTests: XCTestCase {

    private func fixtureData() throws -> Data {
        guard let dir = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        let url = dir.appendingPathComponent(
            "09-real-scene-mac99-20260801.json")
        return try Data(contentsOf: url)
    }

    /// The production entry point, not a bare `JSONDecoder` — `MirrorScene
    /// .decode(result:)` is what a consumer of `mirror.scene` actually calls,
    /// version gate included.
    private func decodeViaMirrorScene() throws -> Scene {
        let data = try fixtureData()
        let sceneDict = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let result: [String: Any] = ["irVersion": 1, "scene": sceneDict]
        return try MirrorScene.decode(result: result)
    }

    // MARK: - the decode itself must not throw

    func testRealSceneDecodesWithoutThrowing() throws {
        XCTAssertNoThrow(try decodeViaMirrorScene())
    }

    // MARK: - one rendered-relevant assertion per plane

    func testMenubarTitlesAndTheNeverAssertedAppleFlag() throws {
        let scene = try decodeViaMirrorScene()
        let menubar = try XCTUnwrap(scene.menubar)
        // Apple, File, Edit, View, Window, Special, Help, the app menu.
        XCTAssertEqual(menubar.menus.count, 8)
        XCTAssertEqual(menubar.menus.map(\.title)[1...4],
                       ["File", "Edit", "View", "Window"])
        // The guest never emits `apple` (scene_json.c says so explicitly);
        // absence must decode to `false`, not throw and not to `true`.
        XCTAssertEqual(menubar.menus.first?.apple, false)
    }

    func testAWindowDecodesItsGeometryAndTitle() throws {
        let scene = try decodeViaMirrorScene()
        let front = try XCTUnwrap(scene.windows.first { $0.front })
        XCTAssertEqual(front.title, "TimBotTu")
        XCTAssertEqual(front.rect, Rect(l: 15, t: 47, r: 432, b: 294))
    }

    func testAControlDecodesWithHonestDefaultsForNeverAssertedFields() throws {
        let scene = try decodeViaMirrorScene()
        let front = try XCTUnwrap(scene.windows.first { $0.front })
        let scrollbar = try XCTUnwrap(front.controls.first)
        // Present on the wire in this capture.
        XCTAssertEqual(scrollbar.ref,
                       "now-element-b903bede-8ace-7e7f-cdf9-49388341b5f9")
        XCTAssertEqual(scrollbar.value, -4)
        // Never on the wire at all — the honest defaults, not a crash.
        XCTAssertEqual(scrollbar.role, "control")
        XCTAssertEqual(scrollbar.checked, false)
    }

    /// The field the bug report named by count: 65 of 85 real items in this
    /// capture omit `cmd`. Both states must decode, distinctly.
    func testMenuItemsWithAndWithoutAShortcutBothDecode() throws {
        let scene = try decodeViaMirrorScene()
        let fileMenu = try XCTUnwrap(
            scene.menubar?.menus.first { $0.title == "File" })
        let newFolder = try XCTUnwrap(
            fileMenu.items.first { $0.title == "New Folder" })
        XCTAssertEqual(newFolder.cmd, "N")
        let moveToTrash = try XCTUnwrap(
            fileMenu.items.first { $0.title == "Move To Trash" })
        XCTAssertEqual(moveToTrash.cmd, "",
                       "no cmd key on the wire decodes to \"\", not a throw")
    }

    func testDesktopItemsDecodeIncludingTheUnplacedVolume() throws {
        let scene = try decodeViaMirrorScene()
        let items = try XCTUnwrap(scene.desktopItems)
        XCTAssertEqual(items.count, 18)
        let disk = try XCTUnwrap(items.first { $0.kind == "disk" })
        XCTAssertEqual(disk.name, "Macintosh HD")
        XCTAssertFalse(disk.placed,
                       "the guest never places a volume — see scene_desktop.c")
    }
}
