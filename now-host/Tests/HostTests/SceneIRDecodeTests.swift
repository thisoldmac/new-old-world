import XCTest
import MirrorKit

/// NOW's scene, decoded by the type whose IR it claims to speak.
///
/// ## Why this exists
///
/// `now-guest-ppc/src/scene/scene_json.c` emits a document it labels IR
/// v1 — the envelope literally carries `"irVersion": 1` — and until
/// 2026-08-02 **nothing had ever parsed one with `MirrorKit.Scene`**,
/// the type that IR belongs to. It did not decode. Five separate
/// required fields were missing:
///
///   `apple` on a menu, `cmd` on a menu item, `role` on a control, and
///   the `controls` and `items` arrays whenever a list had not been
///   walked.
///
/// Each was found by staging an emulator and reading the failure, six
/// minutes a cycle, one field at a time. Every one of them would have
/// been caught here in a millisecond, all five at once.
///
/// That is `two-halves-never-met-in-a-test` with one project playing
/// both halves — the finding this repository has paid for more than any
/// other, and the reason a producer of a NAMED contract must be parsed
/// by that contract's own consumer in a gate, not by a person on a
/// machine.
///
/// ## What the fixture is
///
/// A real scene, captured off an emulated Power Mac G4 with the Finder
/// in front, About This Computer open (three controls), and NOW's own
/// window present — so the document exercises a foreign process's
/// windows and controls, a menu bar with items, and the self process
/// whose sub-planes are deliberately absent.
///
/// **Refresh it from a real machine, never by hand.** A fixture edited
/// to make a test pass is a fixture that no longer describes anything,
/// and this one's whole value is that a guest actually emitted it.
final class SceneIRDecodeTests: XCTestCase {

    private func fixture() throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "now-scene-ir-v1",
                              withExtension: "json",
                              subdirectory: "Fixtures"),
            "the captured scene fixture is missing from the test bundle")
        return try Data(contentsOf: url)
    }

    /// The gate. If NOW's producer drops a field the IR requires, this
    /// fails here rather than on a Macintosh.
    func testANowSceneDecodesAsMirrorKitScene() throws {
        let scene: MirrorKit.Scene
        do {
            scene = try JSONDecoder().decode(MirrorKit.Scene.self,
                                             from: try fixture())
        } catch {
            XCTFail("""
                NOW's scene did not decode as the IR it claims to speak: \
                \(error)

                This is the producer and the consumer disagreeing about a \
                contract NOW names in its own envelope. Fix the emitter in \
                now-guest-ppc/src/scene/scene_json.c, or - if the field is \
                one no walk can honestly know - make the reader tolerant \
                and say why on the property, as Control.checked does.
                """)
            return
        }

        XCTAssertEqual(scene.version, 1, "the fixture is an IR v1 document")
        XCTAssertFalse(scene.windows.isEmpty,
                       "a scene with no windows would pass this test while "
                       + "proving nothing about window or control decoding")
    }

    /// The fixture must keep exercising the shapes that broke. A scene
    /// that decoded but carried no menu, or no control, would leave the
    /// fields those parts contain untested while still going green.
    func testTheFixtureStillExercisesTheFieldsThatBroke() throws {
        let scene = try JSONDecoder().decode(MirrorKit.Scene.self,
                                             from: try fixture())

        let menubar = try XCTUnwrap(scene.menubar,
                                    "no menu bar: `apple` and `cmd` would "
                                    + "go untested")
        XCTAssertFalse(menubar.menus.isEmpty, "no menus in the bar")
        XCTAssertTrue(menubar.menus.contains { $0.apple },
                      "no menu is flagged `apple` - the Apple menu is "
                      + "identified by that flag and not by its title glyph")
        XCTAssertTrue(menubar.menus.contains { !$0.items.isEmpty },
                      "every menu is empty, so `cmd` on an item is untested")

        let controls = scene.windows.flatMap(\.controls)
        XCTAssertFalse(controls.isEmpty,
                       "no window has a control, so `role` and `checked` "
                       + "are untested - recapture with a window that has "
                       + "some (About This Computer has three)")
        XCTAssertTrue(controls.allSatisfy { !$0.role.isEmpty },
                      "a control reached the wire with an empty role")

        /* A foreign process's window is the point of the whole plane: a
           scene of only NOW's own window is what this producer emitted
           for months while looking correct. */
        XCTAssertTrue(scene.windows.contains { $0.app != "New Old World" },
                      "the fixture has no FOREIGN window - it would pass "
                      + "while describing a machine NOW could not see")
    }

    func testV1IsApproximateReadOnlyAndCannotAuthorizeItsRole() throws {
        let scene = try JSONDecoder().decode(MirrorKit.Scene.self,
                                             from: try fixture())
        XCTAssertTrue(scene.isApproximateReadOnly)
        let window = try XCTUnwrap(scene.windows.first(where: {
            !$0.controls.isEmpty
        }))
        let control = try XCTUnwrap(window.controls.first)
        let object = try XCTUnwrap(ObjectResolver.resolve(
            .control(windowID: window.id, control: control), in: scene))
        let plan = InteractionPolicy.plan(for: .init(
            object: object,
            gesture: .click(count: 1, mods: 0, at: .init(x: 0, y: 0))))
        guard case .unsupported(let reason) = plan else {
            return XCTFail("a v1 guessed role authorized an action: \(plan)")
        }
        XCTAssertTrue(reason.contains("authoritative semantics"))
    }

    func testV2DecodesOnlyAfterTheMajorGateAndCarriesDialogTruth() throws {
        var body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture())
                as? [String: Any])
        body["version"] = 2
        var windows = try XCTUnwrap(body["windows"] as? [[String: Any]])
        var window = try XCTUnwrap(windows.first)
        window["dialogItems"] = [[
            "number": 1,
            "title": "Region:",
            "rect": ["l": 20, "t": 10, "r": 180, "b": 30],
            "enabled": true,
            "visible": true,
            "ref": "now-element-popup",
            "semantic": [
                "knowledge": "known",
                "kind": "popupMenu",
                "action": "choose",
                "value": "Custom",
                "provenance": "guest-ditl",
                "completeness": "complete",
            ],
        ]]
        windows[0] = window
        body["windows"] = windows

        let scene = try MirrorScene.decode(result: [
            "irVersion": 2,
            "scene": body,
        ])
        XCTAssertFalse(scene.isApproximateReadOnly)
        let item = try XCTUnwrap(scene.windows.first?.dialogItems?.first)
        XCTAssertEqual(item.semantic.kind, "popupMenu")
        XCTAssertEqual(item.semantic.value, "Custom")
        XCTAssertTrue(item.semantic.authorizesAction)

        XCTAssertThrowsError(try MirrorScene.decode(result: [
            "irVersion": 3,
            "scene": ["this": "must not be decoded"],
        ])) {
            XCTAssertEqual($0 as? IR.CompatError, .unknownMajor(3))
        }
    }

    func testV2DecodesBoundedListSelectionAsPartialPresentation() throws {
        var body = try XCTUnwrap(
            JSONSerialization.jsonObject(with: try fixture())
                as? [String: Any])
        body["version"] = 2
        var windows = try XCTUnwrap(body["windows"] as? [[String: Any]])
        var window = try XCTUnwrap(windows.first)
        var controls = try XCTUnwrap(window["controls"] as? [[String: Any]])
        var control = try XCTUnwrap(controls.first)
        control["role"] = "listBox"
        control["semantic"] = [
            "knowledge": "known", "kind": "listBox", "value": "Rome",
            "provenance": "guest-semantic-assist",
            "completeness": "partial",
        ]
        controls[0] = control; window["controls"] = controls
        windows[0] = window; body["windows"] = windows
        let scene = try MirrorScene.decode(result: ["irVersion": 2,
                                                     "scene": body])
        let list = try XCTUnwrap(scene.windows.first?.controls.first)
        XCTAssertEqual(list.semantic?.kind, "listBox")
        XCTAssertEqual(list.semantic?.value, "Rome")
        XCTAssertEqual(list.semantic?.completeness, .partial)
        XCTAssertFalse(list.semantic?.authorizesAction ?? true)
    }
}
