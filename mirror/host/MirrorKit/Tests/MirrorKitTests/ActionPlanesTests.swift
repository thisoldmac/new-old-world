import XCTest
@testable import MirrorKit

/// One gesture, two drivers, two honest answers.
///
/// ## Why the vocabulary grew instead of forking
///
/// Mirror's agent reaches a scroll arrow by pressing the mouse on it, so
/// `ActionModel` resolved a scrollbar hit to `qmpClick` — the emulator's
/// input plane, and nothing else. That is correct for that driver and
/// fatal for a real Macintosh, where there is no QMP: a mirror driven
/// that way cannot scroll, resize, move or close anything.
///
/// NOW can serve those semantically, by a reference the guest minted.
/// The choice was between a second action model beside this one and one
/// model that knows what its driver can do. A gesture layer forked per
/// target is where a behavioural difference becomes invisible in review
/// and obvious to a person's hand, so: `ActionPlanes`.
///
/// These tests pin the three properties that make that safe — the agent's
/// behaviour is untouched, the act plane gets the semantic form, and
/// **nothing is silently substituted** when a driver cannot serve an act.
final class ActionPlanesTests: XCTestCase {

    // MARK: - A scene with a real scrollbar and a closable window

    private let bar = Scene.Control(
        ref: "now-element-bar", role: "scrollbar", title: "",
        rect: Rect(l: 380, t: 0, r: 396, b: 180),
        enabled: true, visible: true, value: 10, min: 0, max: 500,
        checked: false)

    private func scene(windowRef: String? = "now-window-doc") -> Scene {
        let win = Scene.Window(
            id: "0.1/Doc#0", app: "Finder", psn: "0.1", title: "Doc",
            kind: 8, rect: Rect(l: 20, t: 40, r: 420, b: 300),
            front: true, z: 0, visible: true,
            controls: [bar], ref: windowRef)
        return Scene(version: IR.version, seq: 1, source: "peek",
                     capturedAt: 1, screen: .init(w: 800, h: 600),
                     apps: [.init(psn: "0.1", name: "Finder", front: true,
                                  error: nil)],
                     processes: [], menubar: nil, windows: [win],
                     desktopItems: nil,
                     meta: .init(latencyMs: nil, bytes: nil, errors: [],
                                 plane: nil))
    }

    /// The down arrow's own centre, in global coordinates.
    private func downArrow(_ s: Scene) -> (x: Int, y: Int) {
        let w = s.windows[0], r = bar.rect!
        return (w.rect.l + (r.l + r.r) / 2,
                w.rect.t + SceneBuilder.titleBarHeight + r.b - 8)
    }

    // MARK: - The agent is untouched

    func testTheAgentStillPressesTheScrollArrow() {
        let s = scene()
        let p = downArrow(s)
        let hit = HitTester.hitTest(s, x: p.x, y: p.y)
        guard case .scrollbar(_, _, let part, _, _) = hit else {
            return XCTFail("expected a scrollbar hit, got \(hit)")
        }
        XCTAssertEqual(part, .lineDown)

        // Both the old signature and an explicit `.agent` must be the
        // behaviour every existing caller was written against.
        for actions in [ActionModel.click(on: hit),
                        ActionModel.click(on: hit, planes: .agent, in: s)] {
            guard case .qmpClick = actions.first else {
                return XCTFail("the agent must still press: \(actions)")
            }
        }
    }

    // MARK: - The act plane gets the semantic form

    func testTheActPlaneGetsAControlPart() {
        let s = scene()
        let p = downArrow(s)
        let hit = HitTester.hitTest(s, x: p.x, y: p.y)
        let actions = ActionModel.click(on: hit, planes: .residentActPlane,
                                        in: s)
        guard case .controlPart(let ref, let part, _) = actions.first else {
            return XCTFail("expected a control part, got \(actions)")
        }
        XCTAssertEqual(ref, bar.ref)
        /* 21 is the Control Manager's down arrow, and the number is the
           GUEST's: `ctlact` quotes 20 up, 21 down, 22/23 page, 129 the
           indicator in its own refusal text. */
        XCTAssertEqual(part, 21)
    }

    func testTheThumbStaysADrag() {
        let s = scene()
        let w = s.windows[0], r = bar.rect!
        // Mid-track, where a proportional thumb sits at value 10 of 500.
        let y = w.rect.t + SceneBuilder.titleBarHeight + (r.t + r.b) / 2
        let hit = HitTester.hitTest(s, x: w.rect.l + (r.l + r.r) / 2, y: y)
        guard case .scrollbar(_, _, let part, _, _) = hit else {
            return XCTFail("expected a scrollbar hit")
        }
        guard part == .thumb else { return }   // not over the thumb; fine
        XCTAssertTrue(
            ActionModel.click(on: hit, planes: .residentActPlane,
                              in: s).isEmpty,
            "the thumb's DROP POSITION is the value; a part code presses "
            + "rather than positions, so a click on it must stay empty and "
            + "let the drag path serve it")
    }

    func testCloseBoxBecomesAWindowAct() {
        let s = scene()
        let box = WindowChrome.widgetBox(s.windows[0], .close)
        guard let box else { return XCTFail("no close box on a kind-8 window") }
        let c = WindowChrome.center(box)
        let hit = HitTester.hitTest(s, x: c.x, y: c.y)
        guard case .widget = hit else {
            return XCTFail("expected a widget hit, got \(hit)")
        }
        guard case .windowAct(let ref, let act) =
            ActionModel.click(on: hit, planes: .residentActPlane,
                              in: s).first else {
            return XCTFail("expected a window act")
        }
        XCTAssertEqual(ref, "now-window-doc")
        XCTAssertEqual(act, MirrorAction.WindowAct.close)
    }

    /// Without the window's reference there is no act to send, and the
    /// gesture must fall back rather than invent a token. This is the
    /// state every window was in until 2026-08-02, when `Scene.Window`
    /// started carrying the ref its producer had always sent.
    func testNoWindowRefFallsBackToTheHardwarePress() {
        let s = scene(windowRef: nil)
        let box = WindowChrome.widgetBox(s.windows[0], .close)!
        let c = WindowChrome.center(box)
        let hit = HitTester.hitTest(s, x: c.x, y: c.y)
        guard case .qmpClick = ActionModel.click(on: hit,
                                                 planes: .residentActPlane,
                                                 in: s).first else {
            return XCTFail("expected the press to stand in")
        }
    }

    // MARK: - Window management, which is the metal win

    func testDragsBecomeMoveAndResize() {
        let s = scene()
        let win = s.windows[0]
        let contentTop = win.rect.t + SceneBuilder.titleBarHeight

        guard case .windowAct(_, let moved) = ActionModel.titlebarDrag(
            from: (100, 50), to: (140, 90),
            window: win, planes: .residentActPlane).first else {
            return XCTFail("expected a move")
        }
        // The act names WHERE THE WINDOW GOES, not how far the pointer went.
        XCTAssertEqual(moved, MirrorAction.WindowAct.move(left: win.rect.l + 40,
                                    top: contentTop + 40))

        guard case .windowAct(_, let sized) = ActionModel.growDrag(
            from: (415, 295), to: (500, 400),
            window: win, planes: .residentActPlane).first else {
            return XCTFail("expected a resize")
        }
        XCTAssertEqual(sized, MirrorAction.WindowAct.resize(width: 500 - win.rect.l,
                                      height: 400 - contentTop))

        // And the agent keeps its drag.
        guard case .drag = ActionModel.titlebarDrag(
            from: (100, 50), to: (140, 90),
            window: win, planes: .agent).first else {
            return XCTFail("the agent must still drag")
        }
    }

    // MARK: - Nothing is substituted silently

    func testAnActATargetCannotServeIsRefusedByName() {
        // A semantic act against Mirror's agent: unsupported, not emu-only.
        let semantic = MirrorAction.controlPart(ref: "r", part: 21)
        guard case .unsupported = ActionModel.availability(semantic,
                                                           planes: .agent)
        else {
            return XCTFail("a semantic act needs an act plane, and the "
                           + "refusal must say so rather than blame the "
                           + "emulator")
        }
        XCTAssertEqual(ActionModel.availability(semantic,
                                                planes: .residentActPlane),
                       .available)

        /* A positional click against NOW: also unsupported, and this is the
           one that matters most. NOW's contract has no click-at-a-point
           verb (asyncapi.yaml states the omission deliberately), so a click
           on bare desktop has nowhere to go. It is still RETURNED by the
           policy so the refusal reaches a person - substituting something
           that lands nearby is how a mirror clicks the wrong thing while
           looking like it works. */
        let positional = MirrorAction.click(x: 10, y: 10)
        guard case .unsupported = ActionModel.availability(
            positional, planes: .residentActPlane) else {
            return XCTFail("NOW has no positional click verb")
        }
        XCTAssertEqual(ActionModel.availability(positional, planes: .agent),
                       .available)

        // QMP is about the MACHINE, and keeps saying so.
        guard case .emulatorOnly = ActionModel.availability(
            .qmpClick(x: 1, y: 1), planes: .residentActPlane) else {
            return XCTFail("a QMP act on a QMP-less target is emulatorOnly")
        }
    }

    func testTheDesktopClickIsStillProducedSoItCanBeRefused() {
        let s = scene()
        // Bottom-right of the screen, clear of the single window.
        let hit = HitTester.hitTest(s, x: 700, y: 500)
        guard case .desktop = hit else {
            return XCTFail("expected desktop, got \(hit)")
        }
        let actions = ActionModel.click(on: hit, planes: .residentActPlane,
                                        in: s)
        guard case .click = actions.first else {
            return XCTFail("the click must still be produced - a policy that "
                           + "returned [] here would make the refusal "
                           + "indistinguishable from an inert target")
        }
    }
}
