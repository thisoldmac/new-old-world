import XCTest
@testable import MirrorKit

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
            [.qmpClick(x: 100, y: 100)])
        // The front window's content click stays a semantic wire click.
        XCTAssertEqual(
            ActionModel.click(on: .content(windowID: doc.id, psn: doc.psn,
                                           front: true, x: 100, y: 100)),
            [.click(x: 100, y: 100, count: 1, mods: 0)])
        // A title-bar click raises via a real click at that point.
        XCTAssertEqual(
            ActionModel.click(on: .titlebar(windowID: doc.id, psn: doc.psn,
                                            x: 50, y: 5)),
            [.qmpClick(x: 50, y: 5)])
    }

    func testDoubleClickOpensViaQmpDoubleClick() throws {
        let scene = try fixtureScene("05-axtree-front-save-dialog")
        let doc = scene.windows.first { $0.kind == 8 }!
        // Double-clicking window content or the desktop → a real QMP
        // double-click (opens the item), not two wire clicks.
        XCTAssertEqual(
            ActionModel.click(on: .content(windowID: doc.id, psn: doc.psn,
                                           front: true, x: 40, y: 40),
                              count: 2),
            [.qmpDoubleClick(x: 40, y: 40)])
        XCTAssertEqual(
            ActionModel.click(on: .desktop(x: 700, y: 40), count: 2),
            [.qmpDoubleClick(x: 700, y: 40)])
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
            scene, x: menus[fileIndex].left + 5, y: 8) else {
            return XCTFail("expected a menubar title")
        }
        XCTAssertEqual(index, fileIndex)
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

    /// **A ⌘ item goes through the Portal too**, and this is the assertion
    /// that keeps it there.
    ///
    /// It used to go as a keystroke. `key` on this Mac cannot carry a
    /// modifier at all — CarbonLib has no `PPostEvent`, so the queue
    /// element's modifiers are unreachable — and `availability(.key)` says
    /// so. The routing that survived the port therefore sent the ORDINARY
    /// menu item down the one path NOW cannot serve, and the shortcut-less
    /// one down the path it can: a person clicking File▸Open got silence
    /// and the same person clicking File▸Page Setup… reached the machine,
    /// with nothing to tell them which half they were in.
    func testAShortcutItemAlsoGoesThroughThePortal() {
        let openItem = Scene.MenuItem(title: "Open…", index: 2,
                                      separator: false, enabled: true,
                                      mark: false, cmd: "O")
        let menu = Scene.Menu(title: "File", apple: false, left: 38,
                              id: 129, items: [openItem])

        let actions = ActionModel.menuSelect(menu: menu, item: openItem)

        XCTAssertEqual(actions,
                       [MirrorAction.menuInvoke(menuID: 129, itemIndex: 2,
                                                titleLeft: 38)])
        for action in actions {
            XCTAssertTrue(
                ActionModel.availability(action).isAvailable,
                "\(action) is what a person clicking a ⌘ menu item now "
                    + "gets, and NOW cannot send it. A route to an act the "
                    + "contract does not carry is a silent no-op wearing a "
                    + "menu.")
        }
    }

    func testFrontWindowWidgetsAndGrowBox() throws {
        let scene = try fixtureScene("06-axtree-all-graphcalc")
        let front = scene.windows.first { $0.front }!
        // Hit the center of each widget's WindowChrome box (the same box the
        // renderer draws) and expect that widget back.
        for widget in WindowChrome.Widget.allCases {
            let box = WindowChrome.widgetBox(front, widget)!
            let c = WindowChrome.center(box)
            guard case .widget(_, let kind, let ax, let ay) =
                HitTester.hitTest(scene, x: c.x, y: c.y) else {
                return XCTFail("expected \(widget) at its box center")
            }
            XCTAssertEqual(kind, widget)
            // What a press on the box MEANS is still a press at its centre —
            // that is the gesture, and the base overload keeps saying so.
            XCTAssertEqual(ActionModel.click(
                on: .widget(windowID: front.id, kind: kind, x: ax, y: ay)),
                [.qmpClick(x: c.x, y: c.y)])
            /* **What NOW SENDS is a window act**, and that is the overload
               the pane calls: there is no emulator on the other end of a NOW
               connection, and `winact` answers the application's own
               FindWindow for exactly two of these three boxes. The
               windowshade is the third and gets nothing — `winact` has four
               actions and rolling a window up is not one of them, so an act
               naming `zoom` for it would be this side deciding the two are
               alike. */
            let sent = ActionModel.click(
                on: .widget(windowID: front.id, kind: kind, x: ax, y: ay),
                in: scene)
            let target = ActionModel.target(for: front, in: scene)!
            switch kind {
            case .close:
                XCTAssertEqual(sent, [.windowAct(window: target, op: .close)])
            case .zoom:
                XCTAssertEqual(sent, [.windowAct(window: target, op: .zoom)])
            case .collapse:
                XCTAssertTrue(sent.isEmpty)
            }
        }
        // Grow box at the bottom-right corner.
        let grow = WindowChrome.growBox(front)!
        let gc = WindowChrome.center(grow)
        guard case .growBox = HitTester.hitTest(scene, x: gc.x, y: gc.y) else {
            return XCTFail("expected the grow box")
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

    // MARK: - What NOW's contract can carry

    /// The QMP arms are unavailable, unconditionally, and their reason says
    /// why rather than which target they are missing.
    ///
    /// **This test used to assert the opposite half of the same idea.** It
    /// built a `MirrorTarget` with a `qmp` socket path and checked that the
    /// drag arms were `.available` on it — the emulator was a *supported*
    /// target, and the metal machine was the degraded one. NOW has no
    /// emulator on the other end by assumption and no rule that would let it
    /// inject a mouse if it did, so there is no target that makes these
    /// available and no target parameter at all.
    func testTheInjectedMouseArmsAreUnavailableWithNoTargetToMakeThemOtherwise() {
        let injected: [MirrorAction] = [
            .drag(x0: 0, y0: 0, x1: 10, y1: 10),
            .thumbDrag(x0: 0, y0: 0, x1: 0, y1: 40),
            .qmpClick(x: 5, y: 5),
            .qmpDoubleClick(x: 5, y: 5),
        ]
        for action in injected {
            guard case .unavailable(let reason)
                = ActionModel.availability(action) else {
                return XCTFail("""
                    \(action) is host-side mouse injection and this says it \
                    can be sent. Its executor was deleted with QmpClient; \
                    anything that made this available again would be a \
                    second way to touch a machine.
                    """)
            }
            XCTAssertFalse(reason.isEmpty,
                           "a refusal with no reason is a silent no-op")
        }
    }

    /// The one act that crosses whole, and the one that cannot be addressed.
    ///
    /// `menuact` takes three numbers a scene already carries. `ctlact` and
    /// `textset` take an opaque reference an observation mints, and NOW's
    /// scene producer emits controls with no ref — so a control can be drawn
    /// and cannot be clicked, which is a fact about the two planes rather
    /// than a defect in either.
    func testTheActsNOWCarriesAreNamedAndTheOnesItCannotAddressSaySo() {
        XCTAssertEqual(
            ActionModel.availability(
                .menuInvoke(menuID: 130, itemIndex: 2, titleLeft: 38)),
            .available(command: "menuact"))
        XCTAssertEqual(
            ActionModel.availability(.activate(psn: "1.2")),
            .available(command: "activate"))

        guard case .needsObservation(let click, _)
            = ActionModel.availability(.axdo(ref: "ax2:1")),
              case .needsObservation(let write, _)
            = ActionModel.availability(
                .axdo(ref: "ax2:1", count: 1, mods: 0, text: "hello")) else {
            return XCTFail("""
                a control act reads as sendable from a scene. A scene's \
                controls arrive with ref "" from NOW's producer, so a call \
                built from one would be refused by the guest for naming \
                nothing — after a person had already been shown it working.
                """)
        }
        XCTAssertEqual(click, "ctlact")
        XCTAssertEqual(write, "textset")
    }

    /// A keystroke has no home in NOW's contract, and that is a hole rather
    /// than a rule — asserted separately so the day one lands, this fails and
    /// says where to look.
    func testAKeystrokeIsUnavailableAndIsNotClassifiedAsCheating() {
        guard case .unavailable(let reason)
            = ActionModel.availability(.key(code: 0, char: 97, mods: 256)),
              case .unavailable = ActionModel.availability(
                .type(text: "hi")) else {
            return XCTFail("NOW's contract declares no keystroke command")
        }
        XCTAssertTrue(reason.contains("keystroke"),
                      "the reason must name what is missing: \(reason)")
    }
}
