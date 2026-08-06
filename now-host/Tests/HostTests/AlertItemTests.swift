import XCTest
import AppKit
import MirrorKit
import MirrorKitUI

/// A modal alert, drawn and answered.
///
/// ## The defect these pin
///
/// Michelle, driving the Mirror on 2026-08-06: a guest alert "renders the
/// wrong buttons, and they dont work". `scene-ie-error-alert.json` is that
/// alert captured from a live emulated G4 (guest build `711abdbd25ec`) at
/// the same moment as a QMP screendump of the machine. The machine showed
/// a stop icon, one line of text, and ONE **OK** button wearing the default
/// ring. The Mirror showed two hatched "Visual unavailable" boxes side by
/// side, the ring around one of them, and no button.
///
/// The guest was right about all of it. Its eight DITL items name item 1 as
/// an enabled `pushButton` titled OK with `isDefault: true`, and items 7 and
/// 8 as `userItem`s — item 7 being the Dialog Manager's default-outline
/// slot, declared AFTER the button and laid over it. The renderer painted a
/// placeholder for every kind it does not draw, so the outline slot erased
/// the button; the hit tester takes the topmost item, so a click resolved to
/// that same slot, which carries no action and no reference, and the mirror
/// refused it. One defect, both halves.
///
/// The act plane was never the problem: `ditemact` addressed to item 1's own
/// reference dismissed this very alert, `dispatched-but-unconfirmed`, and
/// the next screendump showed it gone.
@MainActor
final class AlertItemTests: XCTestCase {

    private func alert() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "scene-ie-error-alert",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    private func timeZone() throws -> MirrorKit.Scene {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: "scene-plane-held",
                              withExtension: "json",
                              subdirectory: "Fixtures"))
        return try JSONDecoder().decode(MirrorKit.Scene.self,
                                        from: Data(contentsOf: url))
    }

    private func alertWindow(_ scene: MirrorKit.Scene) throws
        -> MirrorKit.Scene.Window {
        try XCTUnwrap(scene.windows.first { $0.title == "Error" })
    }

    /// The premise, stated so a later capture cannot quietly change it.
    func testTheCaptureStillHasAnOutlineSlotOverTheButton() throws {
        let win = try alertWindow(try alert())
        let items = try XCTUnwrap(win.dialogItems)
        let ok = try XCTUnwrap(items.first { $0.number == 1 })
        let slot = try XCTUnwrap(items.first { $0.number == 7 })

        XCTAssertEqual(ok.semantic.kind, "pushButton")
        XCTAssertEqual(ok.title, "OK")
        XCTAssertTrue(ok.enabled)
        XCTAssertEqual(ok.semantic.isDefault, true)
        XCTAssertEqual(slot.semantic.kind, "userItem")
        XCTAssertNil(slot.semantic.action,
                     "an outline slot carries no action; that is why a click "
                     + "resolved to it does nothing")
        XCTAssertTrue(
            slot.rect.l <= ok.rect.l && slot.rect.t <= ok.rect.t
                && slot.rect.r >= ok.rect.r && slot.rect.b >= ok.rect.b,
            "the fixture no longer has item 7 wrapping item 1, so it no "
            + "longer reproduces the defect these tests exist for")
    }

    /// CONTENT, which is a gate. The alert's whole message was missing from
    /// the mirror because the guest reported item 4 as an empty
    /// `staticText`: a DITL carries the resource's template, and Internet
    /// Explorer had written the real line into the item's HANDLE with
    /// `SetDialogItemText`. The guest now reads it back (see
    /// `now-guest-ppc/src/scene/dialog_text.h`); this pins that the document
    /// carries it and that the renderer draws it.
    func testTheAlertsMessageCrossesAndIsDrawn() throws {
        let scene = try alert()
        let win = try alertWindow(scene)
        let message = try XCTUnwrap(win.dialogItems?.first { $0.number == 4 })

        XCTAssertEqual(message.semantic.kind, "staticText")
        XCTAssertEqual(message.title,
                       "Security failure.  The server reply is invalid.",
                       "the machine's own screen shows this line; a scene "
                       + "without it renders an alert with no message in it")

        var silent = scene
        for w in silent.windows.indices where silent.windows[w].id == win.id {
            for i in silent.windows[w].dialogItems?.indices ?? (0..<0)
            where silent.windows[w].dialogItems?[i].number == 4 {
                silent.windows[w].dialogItems?[i].title = ""
            }
        }
        XCTAssertNotEqual(try RenderShot.png(scene: scene),
                          try RenderShot.png(scene: silent),
                          "the message text reached the frame and changed "
                          + "nothing — it is not being drawn")
    }

    /// FIDELITY. Rendering the alert must be identical to rendering it with
    /// the two user items deleted: whatever the mirror knows about an
    /// application-drawn slot, it is not permission to paint over the button
    /// underneath. A placeholder restored here changes the pixels and fails.
    func testTheOutlineSlotDrawsNothingOverTheButton() throws {
        let scene = try alert()
        var stripped = scene
        for index in stripped.windows.indices {
            stripped.windows[index].dialogItems?.removeAll {
                $0.semantic.kind == "userItem"
            }
        }
        XCTAssertEqual(try RenderShot.png(scene: scene),
                       try RenderShot.png(scene: stripped), """
            The alert's user items changed the frame. They are the Dialog \
            Manager's outline slots, laid over the OK button; drawing \
            anything for them is what put two "Visual unavailable" boxes \
            where the machine showed one button.
            """)
    }

    /// BEHAVIOUR, and it is the same defect. A click anywhere in the outline
    /// slot must reach the button it outlines — with the reference and item
    /// number `ditemact` was proven to answer to.
    func testAClickOnTheOutlineSlotAnswersTheButton() throws {
        let scene = try alert()
        let win = try alertWindow(scene)
        let items = try XCTUnwrap(win.dialogItems)
        let ok = try XCTUnwrap(items.first { $0.number == 1 })
        let slot = try XCTUnwrap(items.first { $0.number == 7 })
        // The button's own centre — where a person aims. It is inside the
        // outline slot too, because the slot wraps it, and topmost-first
        // resolution handed the click to the slot.
        let x = win.rect.l + (ok.rect.l + ok.rect.r) / 2
        let y = win.rect.t + Int(Platinum.titlebarHeight)
            + (ok.rect.t + ok.rect.b) / 2
        XCTAssertTrue(slot.rect.t < ok.rect.t, "the slot must wrap the button")

        guard case .dialogItem(_, let hit) = HitTester.hitTest(
            scene, x: x, y: y) else {
            return XCTFail("a click in the alert resolved to no dialog item")
        }
        XCTAssertEqual(hit.number, 1,
                       "the topmost item is the outline slot; the ANSWERABLE "
                       + "one under it is the button")

        let object = ObjectResolver.resolve(
            .dialogItem(windowID: win.id, item: hit), in: scene)
        let plan = InteractionPolicy.plan(for: .init(
            object: try XCTUnwrap(object),
            gesture: .click(count: 1, mods: 0, at: .init(x: x, y: y))))
        guard case .dialogItem(let ref, let number) = plan else {
            return XCTFail("the mirror refused the alert's only button: "
                           + "\(plan)")
        }
        XCTAssertEqual(number, 1)
        XCTAssertEqual(ref, ok.ref)
    }

    /// The sibling case, from the same evening: Date & Time's Set Time Zone
    /// reports item 1 `Done` as the default AND as disabled, while the
    /// machine greys Done and rings Cancel. `aDefItem` is initialised to 1
    /// and only `SetDialogDefaultItem` moves it, so it goes stale exactly
    /// here. Rendering the ring on a disabled item asserts something the
    /// machine contradicts, so the ring is withheld — which makes the frame
    /// identical to one where the guest never claimed a default at all.
    func testADisabledDefaultItemWearsNoRing() throws {
        let scene = try timeZone()
        var unclaimed = scene
        for w in unclaimed.windows.indices {
            guard unclaimed.windows[w].title == "Set Time Zone" else { continue }
            for i in unclaimed.windows[w].dialogItems?.indices ?? (0..<0)
            where unclaimed.windows[w].dialogItems?[i].number == 1 {
                unclaimed.windows[w].dialogItems?[i].semantic.isDefault = false
            }
        }
        let win = try XCTUnwrap(
            scene.windows.first { $0.title == "Set Time Zone" })
        let done = try XCTUnwrap(win.dialogItems?.first { $0.number == 1 })
        XCTAssertEqual(done.title, "Done")
        XCTAssertFalse(done.enabled)
        XCTAssertEqual(done.semantic.isDefault, true)

        XCTAssertEqual(try RenderShot.png(scene: scene),
                       try RenderShot.png(scene: unclaimed), """
            A default ring was drawn on a DISABLED button. The machine's own \
            screen puts it on Cancel; `aDefItem` still says Done.
            """)
    }
}
