import XCTest
@testable import MirrorKit
import MirrorOracleKit

/// Hit-testing + action-model tests against the captured fixture scenes —
/// the same real geometry the renderer draws.
final class HitActionTests: XCTestCase {

    private func fixtureScene(_ name: String) throws -> Scene {
        guard let url = Bundle.module.url(forResource: "Fixtures",
                                          withExtension: nil) else {
            throw XCTSkip("Fixtures resource directory missing")
        }
        let data = try Data(contentsOf:
            url.appendingPathComponent("\(name).raw.json"))
        return try FixtureEnvelope.scene(from: data)
    }

    private func center(_ win: Scene.Window,
                        _ ctl: Scene.Control) -> (x: Int, y: Int) {
        let r = ctl.rect!
        return (win.rect.l + (r.l + r.r) / 2,
                win.rect.t + HitTester.titlebar + (r.t + r.b) / 2)
    }

    // MARK: - Hit-testing (05: Save dialog front, doc behind)

    func testDialogControlHit() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let dialog = scene.windows.first { $0.kind == 2 }!
        let save = dialog.controls.first { $0.title == "Save" }!
        let p = center(dialog, save)
        guard case .control(let winID, let hit) =
            HitTester.hitTest(scene, x: p.x, y: p.y) else {
            return XCTFail("expected the Save control")
        }
        XCTAssertEqual(winID, dialog.id)
        XCTAssertEqual(hit.ref, save.ref)
    }

    /// A DITL item and its ControlRecord legitimately occupy the same box.
    /// The thing drawn on top is the Dialog Manager item, so that identity
    /// must win the hit too. Date & Time exposed this: the visible Date
    /// Formats button used to resolve as an unknown structural control.
    func testDialogItemWinsOverItsOverlappingControlRecord() throws {
        var scene = try fixtureScene("05-axtree-front-save-dialog")
        scene.version = 2
        let index = scene.windows.firstIndex { $0.kind == 2 }!
        let save = scene.windows[index].controls.first { $0.title == "Save" }!
        scene.windows[index].dialogItems = [
            .init(number: 4, title: "Save", rect: save.rect!, enabled: true,
                  visible: true, ref: save.ref,
                  semantic: .init(
                    knowledge: .known, kind: "pushButton", action: "press",
                    provenance: "guest-ditl", completeness: .complete)),
        ]
        let p = center(scene.windows[index], save)

        guard case .dialogItem(let windowID, let item) =
            HitTester.hitTest(scene, x: p.x, y: p.y) else {
            return XCTFail("the visible DITL item must win its shared box")
        }
        XCTAssertEqual(windowID, scene.windows[index].id)
        XCTAssertEqual(item.number, 4)

        guard case .dialogItem(let object) = ObjectResolver.object(
            at: Point(x: p.x, y: p.y), in: scene) else {
            return XCTFail("the hit must retain Dialog Manager identity")
        }
        XCTAssertEqual(object.ref, save.ref)
        XCTAssertTrue(object.isSemanticallyActionable)
    }

    func testDialogHasNoTitlebar() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let dialog = scene.windows.first { $0.kind == 2 }!
        // A point in the top strip of a dialog is content, not titlebar.
        let target = HitTester.hitTest(scene, x: dialog.rect.l + 30,
                                       y: dialog.rect.t + 5)
        if case .titlebar = target {
            XCTFail("kind==2 dialogs have no title bar")
        }
    }

    func testBackgroundWindowTitlebarHit() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let doc = scene.windows.first { $0.kind == 8 }!
        // A titlebar point outside the dialog's box.
        let target = HitTester.hitTest(scene, x: doc.rect.l + 30,
                                       y: doc.rect.t + 5)
        guard case .titlebar(let winID, let psn, _, _) = target else {
            return XCTFail("expected the doc titlebar, got \(target)")
        }
        XCTAssertEqual(winID, doc.id)
        XCTAssertEqual(psn, doc.psn)
    }

    // MARK: - Hit-testing (06: invisible controls, desktop backdrop)

    func testInvisibleControlFallsThrough(){
        let scene = try! fixtureScene("06-axtree-all-graphcalc")
        let front = scene.windows.first!
        let hidden = front.controls.first { !$0.visible && $0.rect != nil }!
        let p = center(front, hidden)
        guard case .content = HitTester.hitTest(scene, x: p.x, y: p.y) else {
            return XCTFail("invisible control must not be hit")
        }
    }

    func testDesktopBackdropIsDesktop() throws {
        let scene = try fixtureScene("06-axtree-all-graphcalc")
        let backdrop = scene.windows.first { $0.title == "Desktop" }!
        // A point inside the backdrop strip but outside real windows.
        let x = backdrop.rect.r - 10
        let y = backdrop.rect.b - 10
        guard case .desktop = HitTester.hitTest(scene, x: x, y: y) else {
            return XCTFail("the Finder backdrop is desktop, not a window")
        }
    }

    /// NOW's self scene contains its own Workshop window but not the
    /// Finder's backdrop. The Process Manager signature still identifies
    /// the desktop owner, so clicking bare desktop must not decay to a
    /// deselect in the already-front application.
    func testDesktopOwnerFallsBackToFinderSignatureWithoutBackdrop() throws {
        var scene = try fixtureScene("06-axtree-all-graphcalc")
        scene.windows.removeAll(where: HitTester.isDesktopBackdrop)
        scene.apps = [
            .init(psn: "0.7", name: "New Old World", front: true,
                  error: nil),
            .init(psn: "0.3", name: "Finder", front: false, error: nil),
        ]
        scene.processes = [
            .init(psn: "0.7", name: "New Old World", front: true,
                  signature: "NOW!"),
            .init(psn: "0.3", name: "Finder", front: false,
                  signature: "MACS"),
        ]

        guard case .desktop(let owner) = ObjectResolver.resolve(
            .desktop(x: 700, y: 500),
            in: scene)
        else { return XCTFail("bare desktop must remain an object") }
        XCTAssertEqual(owner?.psn, "0.3")
        XCTAssertEqual(
            InteractionPolicy.plan(for: .init(
                object: .desktop(owner),
                gesture: .click(count: 1, mods: 0,
                                at: Point(x: 700, y: 500)))),
            .activateApp(psn: "0.3"))
    }

    // MARK: - Action model

    func testControlClickMapsToAxdo() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let dialog = scene.windows.first { $0.kind == 2 }!
        let cancel = dialog.controls.first { $0.title == "Cancel" }!
        let actions = ActionModel.click(
            on: .control(windowID: dialog.id, control: cancel))
        XCTAssertEqual(actions,
                       [.axdo(ref: cancel.ref, count: 1, mods: 0, text: nil)])
    }

    func testDisabledControlIsInert() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let dialog = scene.windows.first { $0.kind == 2 }!
        let eject = dialog.controls.first { $0.title == "Eject" }!
        XCTAssertFalse(eject.enabled)
        XCTAssertEqual(ActionModel.click(
            on: .control(windowID: dialog.id, control: eject)), [])
    }

    func testMenuItemShortcutCarriesKeycode() throws {
        let scene = try fixtureScene("04-axtree-front-simpletext-doc")
        let file = scene.menubar!.menus.first { $0.title == "File" }!
        let newItem = file.items.first { $0.title.hasPrefix("New") }!
        XCTAssertEqual(newItem.cmd.lowercased(), "n")
        XCTAssertEqual(ActionModel.menuItem(newItem),
                       [.key(code: 45, char: 110, mods: 256)])
    }

    func testBackgroundWindowClickRaisesViaRealClick() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let doc = scene.windows.first { $0.kind == 8 }!
        XCTAssertFalse(doc.front)
        // A background window's content click raises it via a real (QMP)
        // click — SetFrontProcess can't raise a specific window.
        XCTAssertEqual(
            ActionModel.click(on: .content(windowID: doc.id, psn: doc.psn,
                                           front: false, x: 100, y: 100)),
            [.deviceClick(x: 100, y: 100)])
        // The front window's content click stays a semantic wire click.
        XCTAssertEqual(
            ActionModel.click(on: .content(windowID: doc.id, psn: doc.psn,
                                           front: true, x: 100, y: 100)),
            [.click(x: 100, y: 100, count: 1, mods: 0)])
        // A title-bar click raises via a real click at that point.
        XCTAssertEqual(
            ActionModel.click(on: .titlebar(windowID: doc.id, psn: doc.psn,
                                            x: 50, y: 5)),
            [.deviceClick(x: 50, y: 5)])
    }

    func testDoubleClickOpensViaDeviceDoubleClick() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let doc = scene.windows.first { $0.kind == 8 }!
        // Double-clicking window content or the desktop → a real QMP
        // double-click (opens the item), not two wire clicks.
        XCTAssertEqual(
            ActionModel.click(on: .content(windowID: doc.id, psn: doc.psn,
                                           front: true, x: 40, y: 40),
                              count: 2),
            [.deviceDoubleClick(x: 40, y: 40)])
        XCTAssertEqual(
            ActionModel.click(on: .desktop(x: 700, y: 40), count: 2),
            [.deviceDoubleClick(x: 700, y: 40)])
        // Single clicks stay as before.
        XCTAssertEqual(
            ActionModel.click(on: .desktop(x: 700, y: 40), count: 1),
            [.click(x: 700, y: 40, count: 1, mods: 0)])
    }

    // MARK: - Menubar / widgets / grow (slice 7)

    func testMenubarTitleHitByWireLeft() throws {
        let scene = try fixtureScene("04-axtree-front-simpletext-doc")
        let menus = scene.menubar!.menus
        // File sits at left 38; a point inside its span resolves to it.
        let fileIndex = menus.firstIndex { $0.title == "File" }!
        guard case .menuTitle(let index) = HitTester.hitTest(
            scene, x: menus[fileIndex].left! + 5, y: 8) else {
            return XCTFail("expected a menubar title")
        }
        XCTAssertEqual(index, fileIndex)
    }

    func testRightAlignedApplicationMenuDoesNotCollapseHelpHitBox() throws {
        var scene = try fixtureScene("04-axtree-front-simpletext-doc")
        let appMenu = Scene.Menu(
            title: "", apple: false, left: 0,
            id: ObjectResolver.applicationMenuID, items: [])
        scene.menubar?.menus.append(appMenu)
        let menus = try XCTUnwrap(scene.menubar?.menus)
        let helpIndex = try XCTUnwrap(
            menus.lastIndex(where: { $0.title == "Help" }))

        guard case .menuTitle(let index) = HitTester.hitTest(
            scene, x: menus[helpIndex].left! + 5, y: 8) else {
            return XCTFail("the right-aligned switcher must not swallow Help")
        }
        XCTAssertEqual(index, helpIndex)
    }

    func testApplicationMenuUsesGuestLeftForDrawingAndHits() throws {
        var scene = try fixtureScene("04-axtree-front-simpletext-doc")
        /* SceneBuilder deliberately drops the old fixture's non-printable
           Application-menu title. Reinsert the measured wire geometry; the
           self collector now emits this same record with a usable title. */
        scene.menubar?.menus.append(.init(
            title: "", apple: false, left: 716,
            id: ObjectResolver.applicationMenuID, items: []))
        let menus = try XCTUnwrap(scene.menubar?.menus)
        let appIndex = try XCTUnwrap(menus.firstIndex {
            $0.id == ObjectResolver.applicationMenuID
        })
        XCTAssertEqual(menus[appIndex].left, 716,
                       "fixture is the measured Mac OS 9 MenuList")
        XCTAssertEqual(HitTester.appMenuWidth(scene), 84,
                       "the guest's geometry must beat a host font estimate")
        guard case .menuTitle(let hitIndex) = HitTester.hitTest(
            scene, x: 720, y: 8) else {
            return XCTFail("the guest-positioned Application menu must hit")
        }
        XCTAssertEqual(hitIndex, appIndex)
    }

    func testApplicationMenuLeftZeroDoesNotStealAppleSlot() throws {
        var scene = try fixtureScene("04-axtree-front-simpletext-doc")
        scene.menubar?.menus.removeAll(where: \.apple)
        let appMenu = Scene.Menu(
            title: "", apple: false, left: 0,
            id: ObjectResolver.applicationMenuID, items: [])
        scene.menubar?.menus.append(appMenu)

        XCTAssertEqual(HitTester.hitTest(scene, x: 10, y: 8),
                       .menubarBackground)
        XCTAssertEqual(ActionModel.click(on: .menubarBackground), [])
    }

    func testMissingApplicationMenuDoesNotSynthesizeASecondSelector() throws {
        var scene = try fixtureScene("04-axtree-front-simpletext-doc")
        scene.menubar?.menus.removeAll {
            $0.id == ObjectResolver.applicationMenuID
        }

        XCTAssertEqual(
            HitTester.hitTest(scene, x: scene.screen.w - 4, y: 8),
            .menubarBackground,
            "missing guest menu state must stay inert, not become an app-only selector")
    }

    func testMenuSelectShortcutlessGoesThroughThePortal() {
        // CHANGED 2026-07-31, deliberately. A shortcut-less item used to fall
        // back to a QMP menu drag; it now goes through the Portal, which answers
        // the application's own MenuSelect by identity.
        //
        // The drag was wrong twice over: it was emulator-only, and it aimed at a
        // row computed from a uniform-16px assumption the guest has since
        // disproved — separators are 6px, so every item below one was off, which
        // is why selection landed on the wrong command.
        let shortcutless = Scene.MenuItem(title: "Page Setup…", index: 6,
                                          separator: false, enabled: true,
                                          mark: false, cmd: "")
        let menu = Scene.Menu(title: "File", apple: false, left: 38, id: 129,
                              items: [shortcutless])
        let actions = ActionModel.menuSelect(menu: menu, item: shortcutless)
        XCTAssertEqual(actions,
                       [MirrorAction.menuInvoke(menuID: 129, itemIndex: 6,
                                                titleLeft: 38)])
    }

    func testFrontWindowWidgetsAndGrowBox() throws {
        let scene = try fixtureScene("06-axtree-all-graphcalc")
        let front = scene.windows.first { $0.front }!
        // Hit the center of each widget's WindowChrome box (the same box the
        // renderer draws) and expect that widget back.
        /* The zoom box is absent HERE because this fixture's producer never
           reported one — it predates `windows[].zoomBox`. `kind` cannot
           stand in (Extensions Manager is kind 2 and has a zoom box, Memory
           is kind 2 and has none), so the mirror does not offer an
           affordance it cannot prove. See WindowChrome.zoomBox. */
        XCTAssertNil(WindowChrome.widgetBox(front, .zoom),
                     "a zoom box the guest has not reported is not offered")

        /* AND THE HALF THAT MATTERS FOR THE ACT PLANE: once the guest DOES
           report one, the hit-tester finds it at its measured box, so a zoom
           act lands on the widget instead of in the racing stripes — which
           the Window Manager reads as the start of a window DRAG. Asserting
           only the nil case would leave the mirror permanently unable to
           zoom and nothing would say so. */
        var proven = front
        proven.zoomBox = true
        var provenScene = scene
        provenScene.windows = scene.windows.map {
            $0.id == front.id ? proven : $0
        }
        let zoom = try XCTUnwrap(WindowChrome.widgetBox(proven, .zoom))
        XCTAssertEqual(zoom.l, PlatinumTitleBar.zoomBox(front.rect).l)
        let zc = WindowChrome.center(zoom)
        guard case .widget(_, let zoomKind, _, _) =
            HitTester.hitTest(provenScene, x: zc.x, y: zc.y) else {
            return XCTFail("a proven zoom box must be hit-testable")
        }
        XCTAssertEqual(zoomKind, .zoom)
        for widget in WindowChrome.Widget.allCases where widget != .zoom {
            let box = WindowChrome.widgetBox(front, widget)!
            let c = WindowChrome.center(box)
            guard case .widget(_, let kind, let ax, let ay) =
                HitTester.hitTest(scene, x: c.x, y: c.y) else {
                return XCTFail("expected \(widget) at its box center")
            }
            XCTAssertEqual(kind, widget)
            // Actuation point is the box center → QMP press-release there.
            XCTAssertEqual(ActionModel.click(
                on: .widget(windowID: front.id, kind: kind, x: ax, y: ay)),
                [.deviceClick(x: c.x, y: c.y)])
        }
        /* The grow box is DELIBERATELY absent too, and this test force-
           unwrapped it until 2026-08-07 for the same reason it force-unwrapped
           the zoom box. `growBox` guarded on `kind != 2`, which fidelity sweep
           D measured wrong in BOTH directions against the guest's own pixels:
           Appearance (kind 2000) was drawn one the machine does not draw,
           Extensions Manager (kind 2) was denied one it does. Resizability is
           a WDEF variant and IR v1 does not carry it. See WindowChrome.growBox
           and docs/known-wrong.md's history. */
        XCTAssertNil(WindowChrome.growBox(front),
                     "a grow box the guest has not reported is not offered")
        let r = front.rect
        let corner = (x: r.r - WindowChrome.growBoxSpan / 2,
                      y: r.b - WindowChrome.growBoxSpan / 2)
        if case .growBox = HitTester.hitTest(scene, x: corner.x, y: corner.y) {
            XCTFail("the hit-tester still reports a grow box target at the "
                    + "bottom-right corner. Nothing may offer one while "
                    + "WindowChrome.growBox cannot establish it — a drag from "
                    + "there is a drag inside the content region.")
        }
    }

    /// The renderer's boxes and the hit-tester's zones are the same
    /// WindowChrome rects — a click on a drawn box's center hits it.
    func testDrawAndHitShareWidgetGeometry() throws {
        let scene = try fixtureScene("06-axtree-all-graphcalc")
        let front = scene.windows.first { $0.front }!
        let close = WindowChrome.widgetBox(front, .close)!
        // Every point strictly inside the drawn box resolves to .close.
        for x in (close.l + 1)..<(close.r - 1) {
            for y in (close.t + 1)..<(close.b - 1) {
                guard case .widget(_, .close, _, _) =
                    HitTester.hitTest(scene, x: x, y: y) else {
                    return XCTFail("drawn close pixel (\(x),\(y)) didn't hit")
                }
            }
        }
    }

    func testBackgroundWindowHasNoWidgets() throws {
        let scene = try fixtureScene("06-axtree-all-graphcalc")
        let back = scene.windows.first { !$0.front && $0.kind == 8 }!
        // Only the exposed sliver of a covered window is hittable, so probe
        // a synthetic scene where it's on top: its own titlebar-left point
        // must be .titlebar, not .widget, because it isn't front.
        var solo = scene
        solo.windows = [back]
        guard case .titlebar = HitTester.hitTest(
            solo, x: back.rect.l + 10, y: back.rect.t + 9) else {
            return XCTFail("inactive windows draw no widgets")
        }
    }

    // MARK: - Multi-app: Finder folder windows render (slice-7 fix)

    func testFinderFolderWindowIsNotDesktopBackdrop() throws {
        let scene = try fixtureScene("07-axtree-all-finder-window")
        let hd = scene.windows.first { $0.title == "Macintosh HD" }!
        // A real Finder folder window is kind 20 but must NOT be treated as
        // the desktop backdrop (the bug that hid every open Finder window).
        XCTAssertEqual(hd.kind, 20)
        XCTAssertFalse(HitTester.isDesktopBackdrop(hd))
        // The desktop window itself still is.
        let desktop = scene.windows.first { $0.title == "Desktop" }!
        XCTAssertTrue(HitTester.isDesktopBackdrop(desktop))
    }

    func testDesktopBackmostAndNeverFront() throws {
        let scene = try fixtureScene("07-axtree-all-finder-window")
        // Finder is the front app; its real folder window is front, not the
        // desktop backdrop (which used to steal the slot).
        let desktop = scene.windows.first { $0.title == "Desktop" }!
        XCTAssertFalse(desktop.front)
        // The backdrop sinks to the highest z (backmost).
        let maxZ = scene.windows.map(\.z).max()!
        XCTAssertEqual(desktop.z, maxZ)
        // Exactly one window is front, and it's the front app's real window.
        let fronts = scene.windows.filter { $0.front }
        XCTAssertEqual(fronts.count, 1)
        XCTAssertEqual(fronts.first?.app, "Finder")
        XCTAssertEqual(fronts.first?.title, "Macintosh HD")
    }

    // MARK: - Typed input-device availability

    func testDragAvailability() {
        let deviceActions: [MirrorAction] = [
            .deviceDrag(x0: 0, y0: 0, x1: 10, y1: 10),
            .deviceClick(x: 5, y: 5),
            .menuTracking(menuLeft: 38, itemIndex: 6),
        ]
        for action in deviceActions {
            XCTAssertEqual(ActionModel.availability(action, planes: .deviceDriven),
                           .available)
            guard case .inputDeviceUnavailable = ActionModel.availability(
                action, planes: .residentActPlane) else {
                return XCTFail("\(action) without a device adapter must be "
                               + "typed unavailable")
            }
            // …and the dispatcher refuses fail-closed, before any wire I/O.
            XCTAssertThrowsError(
                try ActionDispatcher(target: MirrorTarget(
                    host: "h", port: 1, machine: "pb1400c")).perform(action))
        }
    }
}
