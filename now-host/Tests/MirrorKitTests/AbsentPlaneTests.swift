import XCTest
@testable import MirrorKit

/// The three states of a plane: **absent** (this producer does not report
/// it), **empty** (it walked and found none), **populated**. They are three
/// different claims about the machine, and this suite is the reason the port
/// can be pointed at NOW's guest at all.
///
/// Upstream's decode knew two of them. `Scene.Window.controls` was a
/// non-optional `[Control]` with only a `CodingKeys` enum, so a scene that
/// omitted the key did not decode to `[]` — it *failed*, and every test below
/// whose JSON leaves a key out was red before the fix. The mutation is worth
/// stating exactly because it is this suite's own proof: put `controls` back
/// to a plain synthesized decode and `testControlsAbsentDecodes` throws
/// `keyNotFound`.
///
/// The second half is subtler and is the reason the fix is not just a
/// `decodeIfPresent`. Defaulting absence to `[]` and stopping there makes the
/// two indistinguishable *after* the decode, so the first re-encode publishes
/// "I looked and found none" on behalf of a producer that never looked. The
/// `…Present` flags carry the distinction through, and the round-trip cases
/// are what hold that.
final class AbsentPlaneTests: XCTestCase {

    // MARK: - Scene JSON, assembled a plane at a time

    /// The keys every scene carries. NOW's guest writes all of these
    /// unconditionally (`now-guest-ppc/src/scene/scene_json.c`), and so does
    /// upstream's builder, so requiring them is a claim both producers meet.
    private static let sceneHead = """
        "version": 1, "seq": 3, "source": "peek", "capturedAt": 12.5,
        "screen": {"w": 640, "h": 480}
        """

    private static let window = """
        "id": "0.1/W#0", "app": "Finder", "psn": "0.1",
        "title": "Macintosh HD", "rect": {"l": 0, "t": 0, "r": 100, "b": 80},
        "front": true, "z": 0, "visible": true
        """

    private static let control = """
        {"ref": "c1", "role": "control", "title": "OK", "enabled": true,
         "visible": true, "checked": false}
        """

    /// A scene whose single window carries `controlsJSON` — or, when that is
    /// nil, no `controls` key at all.
    private static func scene(controls controlsJSON: String?) -> Data {
        let controlsKey = controlsJSON.map { ", \"controls\": \($0)" } ?? ""
        return Data("""
            {\(sceneHead),
             "apps": [], "windows": [{\(window)\(controlsKey)}],
             "meta": {"errors": []}}
            """.utf8)
    }

    private static func decode(_ data: Data) throws -> Scene {
        try JSONDecoder().decode(Scene.self, from: data)
    }

    /// Re-encodes and reads the result back as a dictionary, which is how a
    /// consumer downstream of us would see it — key present or not, rather
    /// than a Swift value that has already made up its mind.
    private static func reEncodedWindow(_ scene: Scene) throws -> [String: Any] {
        let data = try JSONEncoder().encode(scene)
        let root = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let windows = try XCTUnwrap(root["windows"] as? [[String: Any]])
        return try XCTUnwrap(windows.first)
    }

    // MARK: - controls: the field the port exists to fix

    func testControlsAbsentDecodes() throws {
        let scene = try Self.decode(Self.scene(controls: nil))
        let window = try XCTUnwrap(scene.windows.first)
        XCTAssertEqual(window.controls, [],
                       "consumers read this as an array; absence gives them "
                       + "an empty one rather than a decode failure")
        XCTAssertFalse(window.controlsPresent,
                       "…but the scene still knows nobody looked")
    }

    func testControlsEmptyDecodesAndIsNotAbsence() throws {
        let scene = try Self.decode(Self.scene(controls: "[]"))
        let window = try XCTUnwrap(scene.windows.first)
        XCTAssertEqual(window.controls, [])
        XCTAssertTrue(window.controlsPresent,
                      "an empty array is the walk saying it found none")
    }

    func testControlsPopulatedDecodes() throws {
        let scene = try Self.decode(Self.scene(controls: "[\(Self.control)]"))
        let window = try XCTUnwrap(scene.windows.first)
        XCTAssertEqual(window.controls.count, 1)
        XCTAssertEqual(window.controls.first?.title, "OK")
        XCTAssertTrue(window.controlsPresent)
    }

    /// The three states are three values, not two values and a hint. If these
    /// compared equal, every consumer that diffs scenes would see the guest
    /// start reporting a plane as "no change".
    func testTheThreeStatesAreThreeDistinctScenes() throws {
        let absent = try Self.decode(Self.scene(controls: nil))
        let empty = try Self.decode(Self.scene(controls: "[]"))
        let full = try Self.decode(Self.scene(controls: "[\(Self.control)]"))
        XCTAssertNotEqual(absent, empty)
        XCTAssertNotEqual(empty, full)
        XCTAssertNotEqual(absent, full)
    }

    // MARK: - The round trip, where a default would do its damage

    func testAnAbsentPlaneReEncodesAbsent() throws {
        let window = try Self.reEncodedWindow(
            try Self.decode(Self.scene(controls: nil)))
        XCTAssertNil(window["controls"],
                     "re-encoding must not publish a claim the producer "
                     + "never made")
    }

    func testAnEmptyPlaneReEncodesEmpty() throws {
        let window = try Self.reEncodedWindow(
            try Self.decode(Self.scene(controls: "[]")))
        let controls = try XCTUnwrap(window["controls"] as? [Any])
        XCTAssertTrue(controls.isEmpty)
    }

    func testAPopulatedPlaneSurvivesTheRoundTrip() throws {
        let window = try Self.reEncodedWindow(
            try Self.decode(Self.scene(controls: "[\(Self.control)]")))
        let controls = try XCTUnwrap(window["controls"] as? [[String: Any]])
        XCTAssertEqual(controls.count, 1)
        XCTAssertEqual(controls.first?["title"] as? String, "OK")
    }

    /// A scene built in memory reports what it holds — the flag defaults to
    /// `true`, so nothing that never went through a decoder silently claims
    /// to be a partial producer.
    func testAnInMemorySceneReportsItsPlanes() throws {
        let scene = try Self.decode(Self.scene(controls: "[]"))
        var window = try XCTUnwrap(scene.windows.first)
        window.controls = []
        XCTAssertTrue(Scene.Window(
            id: "x", app: "a", psn: "0.1", title: "t",
            rect: Rect(l: 0, t: 0, r: 1, b: 1), front: false, z: 1,
            visible: true, controls: []).controlsPresent)
    }

    // MARK: - Every other non-optional collection, same three states

    func testApplistThreeStates() throws {
        func scene(_ apps: String?) -> Data {
            let key = apps.map { ", \"apps\": \($0)" } ?? ""
            return Data("""
                {\(Self.sceneHead)\(key), "windows": [],
                 "meta": {"errors": []}}
                """.utf8)
        }
        XCTAssertFalse(try Self.decode(scene(nil)).appsPresent)
        XCTAssertEqual(try Self.decode(scene(nil)).apps, [])
        XCTAssertTrue(try Self.decode(scene("[]")).appsPresent)
        let full = try Self.decode(
            scene("""
                [{"psn": "0.1", "name": "Finder", "front": true}]
                """))
        XCTAssertEqual(full.apps.first?.name, "Finder")
        XCTAssertTrue(full.appsPresent)
    }

    func testWindowsThreeStates() throws {
        func scene(_ windows: String?) -> Data {
            let key = windows.map { ", \"windows\": \($0)" } ?? ""
            return Data("""
                {\(Self.sceneHead), "apps": []\(key),
                 "meta": {"errors": []}}
                """.utf8)
        }
        XCTAssertFalse(try Self.decode(scene(nil)).windowsPresent)
        XCTAssertEqual(try Self.decode(scene(nil)).windows, [])
        XCTAssertTrue(try Self.decode(scene("[]")).windowsPresent)
        let full = try Self.decode(scene("[{\(Self.window)}]"))
        XCTAssertEqual(full.windows.count, 1)
        XCTAssertTrue(full.windowsPresent)
    }

    func testMenubarMenusThreeStates() throws {
        func scene(_ menus: String?) -> Data {
            let key = menus.map { ", \"menus\": \($0)" } ?? ""
            return Data("""
                {\(Self.sceneHead), "apps": [], "windows": [],
                 "menubar": {"app": "Finder"\(key)},
                 "meta": {"errors": []}}
                """.utf8)
        }
        let absent = try XCTUnwrap(try Self.decode(scene(nil)).menubar)
        XCTAssertEqual(absent.menus, [])
        XCTAssertFalse(absent.menusPresent)
        XCTAssertTrue(try XCTUnwrap(try Self.decode(scene("[]")).menubar)
            .menusPresent)
        let full = try XCTUnwrap(try Self.decode(scene("""
            [{"title": "File", "apple": false, "left": 40, "id": 128}]
            """)).menubar)
        XCTAssertEqual(full.menus.first?.title, "File")
        XCTAssertTrue(full.menusPresent)
    }

    /// The menu items case is per menu, not per bar: NOW's guest omits
    /// `items` for the one menu whose item walk hit a bound and reports the
    /// rest, so a scene can carry both states at once.
    func testMenuItemsThreeStatesWithinOneBar() throws {
        let data = Data("""
            {\(Self.sceneHead), "apps": [], "windows": [],
             "menubar": {"app": "Finder", "menus": [
               {"title": "File", "apple": false, "left": 40, "id": 128},
               {"title": "Edit", "apple": false, "left": 80, "id": 129,
                "items": []},
               {"title": "View", "apple": false, "left": 120, "id": 130,
                "items": [{"title": "as Icons", "index": 1,
                           "separator": false, "enabled": true,
                           "mark": false, "cmd": ""}]}]},
             "meta": {"errors": []}}
            """.utf8)
        let menus = try XCTUnwrap(try Self.decode(data).menubar).menus
        XCTAssertEqual(menus.count, 3)
        XCTAssertFalse(menus[0].itemsPresent)      // absent
        XCTAssertEqual(menus[0].items, [])
        XCTAssertTrue(menus[1].itemsPresent)       // empty
        XCTAssertEqual(menus[1].items, [])
        XCTAssertTrue(menus[2].itemsPresent)       // populated
        XCTAssertEqual(menus[2].items.count, 1)
    }

    func testMetaErrorsThreeStates() throws {
        func scene(_ errors: String?) -> Data {
            let key = errors.map { "\"errors\": \($0)" } ?? ""
            return Data("""
                {\(Self.sceneHead), "apps": [], "windows": [],
                 "meta": {\(key)}}
                """.utf8)
        }
        XCTAssertFalse(try Self.decode(scene(nil)).meta.errorsPresent)
        XCTAssertEqual(try Self.decode(scene(nil)).meta.errors, [])
        XCTAssertTrue(try Self.decode(scene("[]")).meta.errorsPresent)
        let full = try Self.decode(scene("[\"Finder: stale anchor\"]"))
        XCTAssertEqual(full.meta.errors, ["Finder: stale anchor"])
        XCTAssertTrue(full.meta.errorsPresent)
    }

    // MARK: - The document our own guest actually writes

    /// Shaped after `now-guest-ppc/src/scene/scene_json.c`: no `menubar` (the
    /// front process's menu list did not parse), no `controls`, no `kind`, no
    /// `text`, no `display`, no `items`. This is the scene that motivated the
    /// whole change, and before it the decode threw on `controls` alone.
    func testASceneShapedLikeNOWsGuestDecodes() throws {
        let data = Data("""
            {"version": 1, "seq": 7, "source": "peek", "capturedAt": 900.0,
             "screen": {"w": 800, "h": 600},
             "apps": [{"psn": "0.1", "name": "Finder", "front": true}],
             "processes": [{"psn": "0.1", "name": "Finder", "front": true,
                            "signature": "MACS"}],
             "windows": [{\(Self.window)}],
             "meta": {"errors": ["menubar omitted: the front process's menu \
            list did not parse"], "plane": "peek"}}
            """.utf8)
        let scene = try Self.decode(data)
        XCTAssertNil(scene.menubar, "the guest dropped the bar, honestly")
        let window = try XCTUnwrap(scene.windows.first)
        XCTAssertFalse(window.controlsPresent)
        XCTAssertNil(window.kind)
        XCTAssertNil(window.text)
        XCTAssertNil(window.display)
        XCTAssertEqual(scene.meta.errors.count, 1)
        XCTAssertTrue(scene.meta.errorsPresent)
        // And it survives being handed on unchanged.
        let again = try Self.decode(try JSONEncoder().encode(scene))
        XCTAssertEqual(again, scene)
    }

    /// The version gate still runs **before** the body, and relaxing the
    /// decode did not soften it: an unknown major is refused with the payload
    /// untouched, even though that payload would now decode fine.
    func testTheVersionGateStillRunsFirst() throws {
        let body = try JSONSerialization.jsonObject(
            with: Self.scene(controls: nil))
        XCTAssertThrowsError(
            try MirrorScene.decode(result: ["irVersion": 99, "scene": body])
        ) { error in
            XCTAssertEqual(error as? IR.CompatError, .unknownMajor(99))
        }
        let scene = try MirrorScene.decode(
            result: ["irVersion": 1, "scene": body])
        XCTAssertFalse(try XCTUnwrap(scene.windows.first).controlsPresent)
    }
}
