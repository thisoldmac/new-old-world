import XCTest
import Combine
import AppKit
@testable import Host
@testable import MirrorKit

/// **The Mirror's two axes, and the four ways they used to be one.**
///
/// Until 019 a window WAS the poll: `show()` started it and
/// `windowWillClose` stopped it. That was defensible while a window was
/// the only way to look at a mirror, and it stopped being defensible the
/// moment the Mirror gained a pane and a headless face — `now_semantic_ui_act`
/// and the fidelity sweep read the same source with no window in the
/// picture, and every one of them refuses while `running` is false.
///
/// Everything here is aimed at that seam. The failures it is built to
/// catch are all SILENT: nothing errors when closing a window kills an
/// agent's drive, or when a Start button freezes because the property it
/// reads is not published.
@MainActor
final class MirrorContainerTests: XCTestCase {

    private func testListener() -> GuestListener {
        GuestListener(identity: .init(version: "test", name: "Test Host"))
    }

    private func testAct(_ listener: GuestListener)
        -> AgentIntegrationActControl {
        AgentIntegrationActControl(
            listener: listener, currentSessionID: { nil })
    }

    private func suite(_ name: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    // MARK: - Where it is shown

    func testTheZoomAndTheContainerEachRememberTheirOwnAnswer() {
        let name = "test.mirror.presentation.\(UUID().uuidString)"
        let first = MirrorPresentation(defaults: suite(name))
        XCTAssertFalse(first.isDetached)
        XCTAssertEqual(first.zoom, .fit)

        first.isDetached = true
        first.zoom = .double

        let second = MirrorPresentation(defaults: UserDefaults(suiteName: name)!)
        XCTAssertTrue(second.isDetached,
                      "detached is one of the two axes and must survive a "
                      + "relaunch on its own")
        XCTAssertEqual(second.zoom, .double)
        UserDefaults().removePersistentDomain(forName: name)
    }

    /// An unreadable stored zoom is `fit`, not 100%. An 832×624 guest at
    /// 100% does not fit the main window's default detail column, so a
    /// first run that defaulted to `actual` would greet a person with a
    /// scrollbar where a Macintosh should be.
    func testAnUnreadableStoredZoomFallsBackToFitRatherThanActual() {
        XCTAssertEqual(MirrorPresentation.sanitised(nil), .fit)
        XCTAssertEqual(MirrorPresentation.sanitised("three-halves"), .fit)
        XCTAssertEqual(MirrorPresentation.sanitised("quadruple"), .quadruple)
    }

    /// Every numbered stop is a power of two, so nearest-neighbour maps
    /// each guest pixel onto a whole number of host pixels. A stop that
    /// was not could not be pixel-exact under any sampling mode.
    func testEveryNumberedZoomStopIsAPowerOfTwo() {
        for stop in MirrorZoom.allCases {
            guard let factor = stop.factor else {
                XCTAssertEqual(stop, .fit,
                               "only fit may be fractional; it is the stop "
                               + "that means 'all of it' rather than 'exactly'")
                continue
            }
            let log = (Foundation.log2(Double(factor)))
            XCTAssertEqual(log, log.rounded(), accuracy: 1e-12,
                           "\(stop.label) is not a power of two, so no "
                           + "sampling mode can make it pixel-exact")
        }
    }

    // MARK: - Whether it is running

    /// **The button would have rendered once and frozen.**
    ///
    /// `running` was a plain stored property; the thing a button watched
    /// was `NOWMirrorWindow.isOpen`. Watched failing by mutation:
    /// dropping `@Published` from `NOWMirrorSource.running` makes this
    /// time out with no value delivered.
    func testRunningIsPublishedSoAControlBoundToItCanChange() throws {
        let key = GuestKey.synthetic("published-running")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600,
            cycleIO: harness.io)

        var seen: [Bool] = []
        let token = source.$running.sink { seen.append($0) }
        source.start()
        source.stop()
        token.cancel()

        XCTAssertEqual(seen, [false, true, false],
                       "a Start/Stop control observes this property; if it "
                       + "does not publish, the label says Start over a poll "
                       + "that has been running for a minute")
    }

    func testTheRunControlAlwaysStartsOffButResumesWithinOneLaunch() {
        let name = "test.mirror.run.\(UUID().uuidString)"
        let defaults = suite(name)
        let key = GuestKey.synthetic("resume")
        let harness = MirrorCycleHarness(activeKey: key)
        let listener = testListener()
        let source = NOWMirrorSource(
            listener: listener, engineRegistry: MirrorStateEngineRegistry(),
            act: testAct(listener), interval: 3_600, cycleIO: harness.io)

        defaults.set(true, forKey: "mirrorWantsRunning")
        let run = MirrorRunControl(source: source, defaults: defaults)
        XCTAssertFalse(run.wantsRunning)
        XCTAssertNil(defaults.object(forKey: "mirrorWantsRunning"),
                     "the retired launch bit must not remain for an older "
                     + "host build to interpret")
        run.start()
        XCTAssertTrue(run.running)
        XCTAssertTrue(run.wantsRunning)

        run.stop()
        XCTAssertFalse(run.running)
        XCTAssertFalse(run.wantsRunning)
        UserDefaults().removePersistentDomain(forName: name)
    }

    // MARK: - The seam between them, read from the source

    /// **A9, the edit most likely to be reverted by a persuasive comment.**
    ///
    /// `close()` and `windowWillClose` both called `source.stop()`, and
    /// the docstring argued for it well: a mirror nobody is looking at
    /// should not keep taking the guest's one transfer lane. The argument
    /// is right about cost and wrong about who is looking — an agent on
    /// the MCP socket is looking and never opens a window. Closing the
    /// detached window re-attaches; it does not stop the machine.
    func testClosingTheDetachedWindowDoesNotStopThePoll() throws {
        let window = try GateSource.hostSwift(
            "now-host/Sources/Host/NOWMirrorWindow.swift")
        XCTAssertFalse(window.contains("source.stop()"),
                       "NOWMirrorWindow must not stop the poll. Closing the "
                       + "detached window re-attaches the Mirror to its "
                       + "module; stopping is MirrorRunControl's, and it has "
                       + "its own control on that page.")
        XCTAssertFalse(window.contains("source.start()"),
                       "and it must not start it either — an open window is "
                       + "not a running poll, which is how --open-mirror "
                       + "once left a window standing over a source that "
                       + "never ran")
        XCTAssertTrue(window.contains("presentation.isDetached = false"),
                      "closing must put the Mirror back in its pane, or the "
                      + "picture simply disappears with nothing saying where")
    }

    /// **B2, which the scope called the single most important edit.**
    ///
    /// Showing used to imply starting, because a window was the only
    /// container and its `show()` called `source.start()`. With the axes
    /// split, a `showmirror` from the guest against a stopped Mirror puts
    /// a frozen picture in front of somebody and refuses every act behind
    /// it — which is `docs/open-issues.md`'s "a window over a stopped
    /// poll" arriving through a new door. The one implementation behind
    /// all four faces has to resolve BOTH axes, and start first.
    func testShowingTheMirrorStartsItBeforePuttingItAnywhere() throws {
        let state = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorHostModule.swift")
        let show = try XCTUnwrap(state.range(of: "func show()"))
        let end = try XCTUnwrap(
            state.range(of: "\n    }", range: show.upperBound..<state.endIndex))
        let body = String(state[show.upperBound..<end.lowerBound])

        let started = try XCTUnwrap(
            body.range(of: "run.start()"),
            "showMirror must START the Mirror. Every face — the guest's "
            + "button, the Window menu, now_semantic_ui_start, --open-mirror — "
            + "ends here, and none of them can be left showing a Mirror "
            + "that is not running.")
        let shown = try XCTUnwrap(
            body.range(of: "window.show("),
            "and it must still put it where it can be seen")
        XCTAssertLessThan(
            started.lowerBound, shown.lowerBound,
            "start comes FIRST. Showing a stopped Mirror and starting it "
            + "afterwards is the same defect with a shorter window.")
        XCTAssertTrue(body.contains("context.selectModule(\"mirror\")"),
                      "when the Mirror is attached, 'show it' means select "
                      + "its module — there is no window to raise")
    }

    /// **Backgrounding must do NOTHING.** `HostRootView` is a `switch` in a
    /// `ViewBuilder`, so the pane's view is destroyed on every module
    /// change and the rendering cost of backgrounding is already zero. If
    /// anything on the way to that view also stopped the poll, an agent
    /// drive that worked a second ago would start refusing with nothing on
    /// either machine naming the cause.
    func testNoMirrorViewStopsThePollWhenItGoesAway() throws {
        for path in ["now-host/Sources/Host/MirrorPaneView.swift",
                     "now-host/Sources/Host/MirrorModuleView.swift",
                     "now-host/Sources/Host/HostRootView.swift"] {
            let text = try GateSource.hostSwift(path)
            XCTAssertFalse(text.contains("onDisappear"),
                           "\(path) reacts to going away. The Mirror's poll "
                           + "is deliberately independent of whether anybody "
                           + "is looking: every now_semantic_ui_* projection and "
                           + "the whole fidelity sweep refuse while it is "
                           + "stopped, and none of them owns a window.")
        }
    }

    /// **Q7's rule, asserted rather than remembered: zoom lives in the
    /// container.** `SceneView` and `SceneRenderer` take their size from
    /// the layout system and hold no ambient state, which is exactly why
    /// `RenderShot` renders 1:1 whatever a person is looking at. A `zoom:`
    /// parameter threaded into either would reach the sweep.
    func testZoomNeverReachesTheRendererOrRenderShot() throws {
        for name in ["SceneView.swift", "SceneRenderer.swift"] {
            /* Comment-stripped: the renderer's own doc comment EXPLAINS
               the zoom stops, and a gate that reads raw text would fire
               on the explanation of why it must not know about them. */
            let text = try GateSource.hostSwift(
                "now-host/Packages/MirrorKit/Sources/MirrorKitUI/\(name)")
            /* Named for the HOST's type rather than for the word: a
               renderer that has heard of `MirrorZoom` has been given the
               UI's scale, whereas `.zoom` on its own is the Platinum
               window widget — the box in a title bar — and is unrelated. */
            XCTAssertFalse(text.contains("MirrorZoom"),
                           "\(name) has learned about the host's zoom stop. "
                           + "It must not: RenderShot sets scale = 1 and "
                           + "passes the logical size, and that is the only "
                           + "reason the fidelity sweep measures guest pixels "
                           + "rather than whatever the UI happened to show. "
                           + "Zoom is a frame in the container.")
        }
        let view = try GateSource.hostSwift(
            "now-host/Packages/MirrorKit/Sources/MirrorKitUI/SceneView.swift")
        XCTAssertTrue(view.contains("renderer.scale = 1"),
                      "RenderShot must keep rasterising at 1:1; a Retina 2× "
                      + "resample would silently move every pixel gate and "
                      + "every sweep measurement in this repository")
        XCTAssertTrue(
            view.contains("size ?? SceneRenderer(scene: scene).logicalSize"),
            "and it must keep defaulting to the GUEST's own screen size, "
            + "where FitTransform computes scale == 1 and offset == .zero")
        let pane = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorPaneView.swift")
        XCTAssertTrue(pane.contains(".frame(width: guestSize.width * factor"),
                      "the zoom stop is a frame around LiveMirrorView, which "
                      + "is the one shape of it that cannot reach RenderShot")
    }

    // MARK: - The keyboard

    /// **D2 was going to disable the host's own menu bar in silence.**
    ///
    /// `KeyCaptureView` forwards every ⌘ combination but three to the
    /// other Macintosh. Correct in a window of its own; in a pane it eats
    /// ⌘⇧M, ⌘0 and ⌘/ with nothing erroring. The reserved set is derived
    /// from the host's own menu rather than written down, so it cannot rot
    /// the first time somebody adds an item.
    func testTheReservedSetIsDerivedFromTheHostsOwnMenu() {
        let menu = NSMenu()
        let window = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        submenu.addItem(NSMenuItem(title: "Show Mirror", action: nil,
                                   keyEquivalent: "m"))
        submenu.addItem(NSMenuItem(title: "New Old World", action: nil,
                                   keyEquivalent: "0"))
        window.submenu = submenu
        menu.addItem(window)
        menu.addItem(NSMenuItem(title: "Ask the Guest", action: nil,
                                keyEquivalent: "/"))

        let reserved = MirrorPaneView.hostMenuCharacters(menu)

        for key in ["m", "0", "/"] {
            XCTAssertTrue(reserved.contains(key),
                          "⌘\(key.uppercased()) is a host menu shortcut and "
                          + "would otherwise be swallowed by the Mirror pane "
                          + "and sent to the classic Mac, with nothing "
                          + "erroring and the menu item simply not working")
        }
        for key in ["q", "w", "h"] {
            XCTAssertTrue(reserved.contains(key),
                          "the three escape hatches survive whatever the "
                          + "menu happens to carry")
        }
        XCTAssertFalse(reserved.contains("n"),
                       "over-reserving costs the guest a key; the set must "
                       + "be what the menu actually claims, not everything")
    }

    /// The pane shares its window and the detached one owns it. Stated as
    /// a property of the container rather than left to the reader, because
    /// getting it backwards is invisible until somebody's ⌘⇧M stops
    /// working.
    func testOnlyTheDetachedContainerMayOwnTheKeyboard() throws {
        let pane = try GateSource.hostSwift(
            "now-host/Sources/Host/MirrorPaneView.swift")
        XCTAssertTrue(pane.contains("case .detachedWindow:\n            return .ownsWindow"),
                      "a window of its own may take the keyboard outright")
        XCTAssertTrue(pane.contains("return .sharesWindow(hostReserved:"),
                      "a pane beside the host's own controls may not")
    }
}
