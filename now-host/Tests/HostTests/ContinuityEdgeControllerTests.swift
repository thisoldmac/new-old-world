import AppKit
import MirrorKit
import MirrorKitUI
import XCTest
@testable import Host

@MainActor
final class ContinuityEdgeControllerTests: XCTestCase {
    private let host = HostDisplayDescriptor(
        id: 41, name: "Studio Display",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)

    func testEdgeControllerHidesDrivesAndReturnsAtSameBoundary() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: 3, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(controller.state, .arming)
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 24, y: 300))
        XCTAssertTrue(environment.hidden.isEmpty,
                      "the host cursor stays visible until the guest owns it")

        controller.transportPhaseChanged(.active)
        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(environment.hidden, [host.id])

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: 12, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 36, y: 300))

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: -60, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
        XCTAssertEqual(environment.shown, [host.id])
        XCTAssertEqual(environment.moves.last?.point.x, 1439)
        XCTAssertEqual(environment.moves.last?.point.y, 300)
    }

    func testNativeHostClickIsSentWithoutRelinquishingGuestControl() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.emit(.init(kind: .primaryDown,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: true))
        environment.emit(.init(kind: .primaryUp,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: false))

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(driver.leftCount, 0)
        XCTAssertEqual(driver.downPoints, [MirrorKit.Point(x: 24, y: 450)])
        XCTAssertEqual(driver.upPoints, [MirrorKit.Point(x: 24, y: 450)])
        XCTAssertTrue(environment.shown.isEmpty)
        XCTAssertEqual(environment.moves.last?.displayID, host.id)
    }

    /// **Losing the press origin is said out loud, at error.**
    ///
    /// A held return with no origin sends no release at all, so the Mac
    /// keeps the press — and the old code reached that outcome through a
    /// `if held, let origin = pressOrigin` whose else-branch was silence.
    /// The sibling on the file path was worse: `pressOrigin ??
    /// ownership.guestPoint` makes the fallback the CROSS point, so a lost
    /// origin becomes "the origin was the screen edge" and the Finder
    /// completes a real move there.
    ///
    /// Both read, from outside, exactly like the guest ignoring a correct
    /// settle — which is what a metal round on 2026-08-15 spent its evidence
    /// distinguishing. This side must name which one it is.
    func testALostPressOriginIsNamedAtErrorRatherThanSilentlyDefaulted() {
        var lines: [(HostLog.LogLevel, String)] = []
        let layout = makeLayout()
        let driver = Driver()
        driver.consumesPrimaryDown = false
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { lines.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.emit(.init(kind: .primaryDown,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: true))
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 300, y: 0),
                               buttonsDown: true))
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: -400, y: 0),
                               buttonsDown: true))

        XCTAssertEqual(controller.state, .ready, "the pointer crossed back")
        XCTAssertTrue(driver.upPoints.isEmpty,
                      "with no origin there is nothing safe to release at, "
                        + "and releasing at the cross point moves the file")
        XCTAssertTrue(lines.contains {
            $0.0 == .error
                && $0.1.contains("the press origin was lost before this held "
                                    + "return")
                && $0.1.contains("the Mac keeps the press")
        }, "origin loss must be loud: silence here is indistinguishable from "
            + "a guest that ignored a correct settle")
    }

    func testContinuityEdgeClassifiesGuestMenuBar() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 0, y: 440),
                               buttonsDown: false))

        environment.emit(.init(kind: .primaryDown,
                               location: CGPoint(x: 1439, y: 890),
                               delta: .zero, buttonsDown: true,
                               eventUptime: 123))

        XCTAssertEqual(driver.downPoints.last, MirrorKit.Point(x: 24, y: 10))
        XCTAssertEqual(driver.menuBarDowns.last, true)
    }

    func testHeldHostMotionDragsOnGuestWithoutRelinquishingControl() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.emit(.init(kind: .primaryDown,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: true))
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 8, y: -5),
                               buttonsDown: true))

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(driver.leftCount, 0)
        XCTAssertEqual(driver.draggedPoints,
                       [MirrorKit.Point(x: 32, y: 455)])
        XCTAssertTrue(environment.shown.isEmpty)
    }

    func testHostCursorWarpIsNotIntegratedAsGuestMotion() {
        var now: TimeInterval = 100
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            uptime: { now })
        controller.start()
        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1439, y: 450),
            delta: CGPoint(x: 2, y: 0), buttonsDown: false))
        controller.transportPhaseChanged(.active)

        now += 0.01
        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1439, y: 450),
            delta: CGPoint(x: -600, y: 0), buttonsDown: false,
            eventUptime: now))

        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(driver.leftCount, 0)
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 24, y: 450))

        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1451, y: 450),
            delta: CGPoint(x: 12, y: 0), buttonsDown: false,
            eventUptime: now + 0.01))
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 36, y: 450))
    }

    func testRestoreWarpCannotImmediatelyReenterGuest() {
        var now: TimeInterval = 200
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            uptime: { now })
        controller.start()
        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1439, y: 450),
            delta: CGPoint(x: 2, y: 0), buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1420, y: 450),
            delta: CGPoint(x: -60, y: 0), buttonsDown: false))
        XCTAssertEqual(controller.state, .ready)

        now += 0.01
        environment.emit(.init(
            kind: .moved, location: CGPoint(x: 1439, y: 450),
            delta: CGPoint(x: 40, y: 0), buttonsDown: false,
            eventUptime: now))

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
    }

    func testKeyboardIsForwardedAndSuppressedWhileGuestOwnsPointer() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        let sample = HostKeySample(action: .down, code: 12,
                                   character: 113, modifiers: 0x300)
        XCTAssertTrue(keyboard.emit(sample))
        XCTAssertEqual(driver.keys, [sample])
        XCTAssertEqual(controller.state, .active)
    }

    func testEscapeShortcutReturnsAllControlWithoutForwardingChord() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertTrue(keyboard.emit(.init(
            action: .down, code: 53, character: 27,
            modifiers: (1 << 11) | (1 << 12))))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
        XCTAssertTrue(driver.keys.isEmpty)
        XCTAssertEqual(environment.shown, [host.id])
        XCTAssertEqual(keyboard.stopCount, 1)
    }

    func testKeyboardToggleLeavesHostInputUntouchedButEscapeStillWorks() {
        let layout = makeLayout()
        let driver = Driver()
        driver.keyboardForwardingEnabled = false
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertFalse(keyboard.emit(.init(action: .down, code: 12,
                                            character: 113, modifiers: 0)))
        XCTAssertTrue(driver.keys.isEmpty)
        XCTAssertTrue(keyboard.emit(.init(
            action: .down, code: 53, character: 27,
            modifiers: (1 << 11) | (1 << 12))))
        XCTAssertEqual(controller.state, .ready)
    }

    /// The discrimination the whole plane rests on, asserted as one table so
    /// that a change to any single arm shows up beside the others: what the
    /// chord claims, what is forwarded, and — separately — what is swallowed.
    /// Forwarding and swallowing are two decisions and were one boolean until
    /// a modifier needed to cross while staying on this machine.
    func testEveryDispositionSaysBothWhetherItForwardsAndWhetherItSwallows() {
        let policy = ContinuityKeyboardCapturePolicy(
            forwardingEnabled: true, escapeShortcut: .controlOptionEscape)
        let chord = HostKeySample(
            action: .down, code: 53, character: 27,
            modifiers: (1 << 11) | (1 << 12))
        let key = HostKeySample(action: .down, code: 12, character: 113,
                                modifiers: 0)
        let flags = HostKeySample(action: .modifiers, code: 0, character: 0,
                                  modifiers: 1 << 11)

        XCTAssertEqual(policy.disposition(chord), .chord)
        XCTAssertFalse(ContinuityKeyDisposition.chord.forwards)
        XCTAssertTrue(ContinuityKeyDisposition.chord.consumesOnHost)

        XCTAssertEqual(policy.disposition(key), .forwarded)
        XCTAssertTrue(ContinuityKeyDisposition.forwarded.forwards)
        XCTAssertTrue(ContinuityKeyDisposition.forwarded.consumesOnHost)

        XCTAssertEqual(policy.disposition(flags), .modifierState)
        XCTAssertTrue(ContinuityKeyDisposition.modifierState.forwards)
        XCTAssertFalse(
            ContinuityKeyDisposition.modifierState.consumesOnHost,
            "a modifier is state: swallowing it leaves macOS's own idea of "
                + "what is held wrong for as long as the guest owns the "
                + "pointer, and wrong when control returns")

        let off = ContinuityKeyboardCapturePolicy(
            forwardingEnabled: false, escapeShortcut: .controlOptionEscape)
        XCTAssertEqual(off.disposition(key), .ignored)
        XCTAssertEqual(off.disposition(flags), .ignored)
        XCTAssertEqual(off.disposition(chord), .chord,
                       "the way out never depends on the forwarding switch")
    }

    /// The (a) regression: a Command combination must cross whole.
    ///
    /// Command-Backspace is Move To Trash in the guest Finder, and it reaches
    /// that menu only through `EventRecord.modifiers`. The chord matcher is
    /// the thing in a position to eat it — it is the only rule on this side
    /// that reads the modifier word — so what is pinned here is that a
    /// Command combination it does not match is forwarded UNCHANGED rather
    /// than partially matched, downgraded, or stripped of its modifiers.
    func testACommandCombinationTheChordDoesNotMatchCrossesWithItsModifiers() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        // Command down on its own, then Command-Backspace, then the release.
        let commandDown = HostKeySample(action: .modifiers, code: 0,
                                        character: 0, modifiers: 1 << 8)
        let backspace = HostKeySample(action: .down, code: 51, character: 8,
                                      modifiers: 1 << 8)
        let commandUp = HostKeySample(action: .modifiers, code: 0,
                                      character: 0, modifiers: 0)
        XCTAssertTrue(keyboard.emit(commandDown))
        XCTAssertTrue(keyboard.emit(backspace))
        XCTAssertTrue(keyboard.emit(commandUp))

        XCTAssertEqual(driver.keys, [commandDown, backspace, commandUp])
        XCTAssertEqual(driver.keys.dropFirst().first?.modifiers, 1 << 8,
                       "Command must survive the crossing intact")
        XCTAssertEqual(controller.state, .active,
                       "a Command combination is not a way out")
        XCTAssertEqual(driver.leftCount, 0)
    }

    /// Coexistence, stated as a sequence rather than as two separate claims:
    /// the modifiers the chord itself is made of travel to the guest as
    /// state, and the chord still fires on the key that completes it — which
    /// is not forwarded.
    func testTheChordStillFiresAfterItsOwnModifiersHaveBeenForwarded() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertTrue(keyboard.emit(.init(action: .modifiers, code: 0,
                                          character: 0,
                                          modifiers: 1 << 12)))
        XCTAssertTrue(keyboard.emit(.init(
            action: .modifiers, code: 0, character: 0,
            modifiers: (1 << 11) | (1 << 12))))
        XCTAssertEqual(driver.keys.count, 2)

        XCTAssertTrue(keyboard.emit(.init(
            action: .down, code: 53, character: 27,
            modifiers: (1 << 11) | (1 << 12))))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
        XCTAssertEqual(driver.keys.count, 2,
                       "the chord key itself is never forwarded")
    }

    /// The tap mask is the one link in this chain no unit test can reach:
    /// `AppKitContinuityKeyboardEnvironment` builds a real CGEventTap, so
    /// every test above drives a stub and would stay green with flagsChanged
    /// dropped from the mask — the plane would then be correct about a
    /// modifier change it is never handed. A source guard is a poor test and
    /// a better one than nothing at all, which is what covered it before.
    func testTheEventTapAsksForFlagsChanged() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent(
                "now-host/Sources/Host/ContinuityKeyboard.swift"),
            encoding: .utf8)
        XCTAssertTrue(
            source.contains("1 << CGEventType.flagsChanged.rawValue"),
            "the CGEventTap must ask for flagsChanged; without it a modifier "
                + "pressed while no key moves never reaches this host at all")
    }

    func testKeyboardCapturePolicyOwnsBothCommandOEdges() {
        let policy = ContinuityKeyboardCapturePolicy(
            forwardingEnabled: true,
            escapeShortcut: .controlOptionEscape)
        XCTAssertTrue(policy.captures(.init(
            action: .down, code: 31, character: 111,
            modifiers: 1 << 8)))
        XCTAssertTrue(policy.captures(.init(
            action: .up, code: 31, character: 111,
            modifiers: 1 << 8)))
    }

    func testGuestFileCrossingBackStartsNativeCopyDrag() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.configureFileDragging(
            guestFileAtPoint: { _ in
                HostFileDragItem(writer: NSPasteboardItem(),
                                 image: NSImage(size: NSSize(width: 32,
                                                            height: 32)))
            },
            hostFilesDropped: { _, _ in false })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.emit(.init(kind: .primaryDown,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: true))
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 50, y: 0), buttonsDown: true))
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: -100, y: 0),
                               buttonsDown: true),
                         event: Self.mouseEvent())

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
        XCTAssertEqual(environment.fileDrags.count, 1)
        XCTAssertEqual(environment.fileDrags.first?.point.x, 1439)
        XCTAssertTrue(controller.status.contains("guest file"))
    }

    func testHostFileAtEdgeDrivesGuestTargetAndCopiesOnRelease() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        var droppedAt: MirrorKit.Point?
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, point in
                droppedAt = point
                return true
            })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450)))
        XCTAssertEqual(controller.state, .arming)
        controller.transportPhaseChanged(.active)
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 100, y: -50),
                               buttonsDown: true))

        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertEqual(droppedAt, MirrorKit.Point(x: 124, y: 500))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(driver.leftCount, 1)
        XCTAssertTrue(driver.draggedPoints.isEmpty,
                      "a host file moves the target cursor, not a guest item")
    }

    func testMirrorCursorAndContinuityExposeMutuallyExclusiveEntrySurfaces()
        throws {
        let rig = try MirrorModuleLayoutRenderTests.sharedRig()
        defer { rig.source.stop() }

        XCTAssertNil(rig.source.continuityInputDriver)
        rig.source.mirrorCursorEnabled = true
        XCTAssertTrue(rig.source.continuityInputDriver
                      === rig.source.continuity)

        rig.source.continuity.beginEdgeMode()
        XCTAssertNil(rig.source.continuityInputDriver,
                     "edge mode owns the pointer; the in-picture cursor "
                     + "stands down")
        XCTAssertTrue(rig.source.continuity.isEnabled)

        rig.source.continuity.endEdgeMode(reason: "test")
        XCTAssertTrue(rig.source.continuityInputDriver
                      === rig.source.continuity,
                      "ending edge mode restores the Mirror's own cursor")
        XCTAssertTrue(rig.source.continuity.isEnabled,
                      "the mirror-cursor request survives edge mode ending")
    }

    func testGuestOwnershipDetachesTheHostCursorAndCapturesHostInput() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        XCTAssertTrue(environment.associationChanges.isEmpty,
                      "arming is not ownership; the mouse is still the host's")
        XCTAssertEqual(environment.captureStarts, 0)

        controller.transportPhaseChanged(.active)
        XCTAssertEqual(environment.associationChanges, [false])
        XCTAssertEqual(environment.captureStarts, 1)

        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        XCTAssertEqual(driver.downPoints, [MirrorKit.Point(x: 24, y: 450)],
                       "a consumed click must still reach the guest")
        XCTAssertEqual(controller.state, .active)
    }

    /// Every exit is asserted here rather than only the one a change happens
    /// to touch: a dissociation left armed is a host mouse that cannot be
    /// moved, which is the worst failure this seam can produce.
    func testEveryOwnershipExitReattachesTheCursorAndDropsTheCapture() {
        typealias Exit = (ContinuityEdgeController, Environment,
                          KeyboardEnvironment) -> Void
        let exits: [(name: String, run: Exit)] = [
            ("shared edge crossed", { _, environment, _ in
                environment.emitCaptured(.init(
                    kind: .moved, location: CGPoint(x: 1420, y: 450),
                    delta: CGPoint(x: -60, y: 0), buttonsDown: false))
            }),
            ("escape shortcut", { _, _, keyboard in
                _ = keyboard.emit(.init(
                    action: .down, code: 53, character: 27,
                    modifiers: (1 << 11) | (1 << 12)))
            }),
            ("guest hung up", { controller, _, _ in
                controller.transportEnded(reason: "guest hung up")
            }),
            ("transport went idle", { controller, _, _ in
                controller.transportPhaseChanged(.idle)
            }),
            ("continuity switched off", { controller, _, _ in
                controller.stop()
            }),
        ]
        for exit in exits {
            let layout = makeLayout()
            let driver = Driver()
            let environment = Environment()
            let keyboard = KeyboardEnvironment()
            let controller = ContinuityEdgeController(
                layout: layout, driver: driver, environment: environment,
                keyboardEnvironment: keyboard)
            controller.start()
            environment.emit(.init(kind: .moved,
                                   location: CGPoint(x: 1439, y: 450),
                                   delta: CGPoint(x: 2, y: 0),
                                   buttonsDown: false))
            controller.transportPhaseChanged(.active)
            XCTAssertEqual(environment.associationChanges, [false], exit.name)
            XCTAssertEqual(environment.captureStarts, 1, exit.name)

            exit.run(controller, environment, keyboard)

            XCTAssertEqual(
                environment.associationChanges, [false, true],
                "\(exit.name) left the host cursor detached from the mouse")
            XCTAssertEqual(
                environment.captureStops, 1,
                "\(exit.name) left host input captured")
        }
    }

    func testGuestFileReturnAlsoReattachesTheHostCursor() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.configureFileDragging(
            guestFileAtPoint: { _ in
                HostFileDragItem(writer: NSPasteboardItem(),
                                 image: NSImage(size: NSSize(width: 32,
                                                             height: 32)))
            },
            hostFilesDropped: { _, _ in false })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true),
                                 event: Self.mouseEvent())

        XCTAssertEqual(environment.fileDrags.count, 1,
                       "the native copy drag still starts")
        XCTAssertEqual(environment.associationChanges, [false, true],
                       "a file handed back must not keep the mouse detached")
        XCTAssertEqual(environment.captureStops, 1)
    }

    /// A host file drag is a real host drag: the human is holding a real
    /// cursor over a real drag session, so nothing may be detached or eaten.
    func testHostFileDragNeverDetachesTheCursorOrCapturesInput() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.configureFileDragging(guestFileAtPoint: { _ in nil },
                                         hostFilesDropped: { _, _ in true })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450)))
        controller.transportPhaseChanged(.active)
        XCTAssertTrue(environment.associationChanges.isEmpty)
        XCTAssertEqual(environment.captureStarts, 0)

        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(environment.associationChanges.isEmpty,
                      "nothing was detached, so nothing is re-attached")
    }

    func testWithoutInputCaptureOwnershipDegradesToTheObservingMonitor() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertEqual(controller.state, .active,
                       "a refused tap is degraded, not broken")
        XCTAssertTrue(audits.contains { $0.1.contains("Accessibility") },
                      "the leak must be named, not left silent")
        XCTAssertTrue(controller.status.contains("Accessibility"))

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 12, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 36, y: 450))

        controller.stop()
        XCTAssertEqual(environment.associationChanges, [false, true],
                       "the cursor is handed back even when the tap failed")
    }

    /// macOS reads Accessibility trust at process start for this API: a
    /// tap that still fails to create while the process IS trusted cannot
    /// be fixed by retrying in place, and the honest thing to say is that
    /// the app needs a relaunch — not to repeat the permission message,
    /// which would send the person straight back to a Settings pane that
    /// already lists this app as trusted.
    func testTrustedButStillFailingTapNamesRelaunchNotPermission() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        accessibility.trusted = true
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertTrue(controller.status.contains("relaunch"),
                      "trusted-but-failing must say relaunch, not permission")
        XCTAssertFalse(controller.status.contains("Accessibility permission"))
        XCTAssertTrue(audits.contains {
            $0.1.contains("relaunch") && $0.1.contains("trusted")
        })
    }

    /// The person should not have to toggle Continuity off and on after
    /// granting Accessibility in System Settings: coming back to the app
    /// (`applicationDidBecomeActive`) retries the tap on its own, without
    /// waiting for the next edge crossing to call `startConsumingTap` again.
    func testActivationRetriesCaptureOnceTrustIsGranted() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        XCTAssertEqual(environment.captureAttempts, 1,
                       "the first attempt failed and used up its try")
        XCTAssertEqual(environment.captureStarts, 0)

        // Not trusted yet: coming back to the app must not retry early.
        controller.retryInputCaptureAfterBecomingActive()
        XCTAssertEqual(environment.captureAttempts, 1)

        // The person grants permission in System Settings and macOS
        // activates this app again.
        accessibility.trusted = true
        environment.captureAvailable = true
        controller.retryInputCaptureAfterBecomingActive()

        XCTAssertEqual(environment.captureAttempts, 2,
                       "granted trust must retry without a new edge crossing")
        XCTAssertEqual(environment.captureStarts, 1,
                       "the retry must be the one that actually succeeded")
        XCTAssertFalse(controller.status.contains("Accessibility permission"),
                       "a successful retry must clear the degraded status")

        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        XCTAssertEqual(driver.downPoints, [MirrorKit.Point(x: 24, y: 450)],
                       "the recovered tap must actually be driving the guest")
    }

    /// A retry that is itself trusted-but-still-failing must not be
    /// attempted again on every subsequent activation: the reason it failed
    /// is not one another retry can fix, and looping it would just repeat
    /// the same failed tap creation forever.
    func testActivationDoesNotLoopRetriesAfterATrustedFailure() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility)
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        XCTAssertEqual(environment.captureAttempts, 1)

        // Trusted now, but the tap creation itself keeps failing (the
        // relaunch case) — the retry consumes its one attempt and fails.
        accessibility.trusted = true
        controller.retryInputCaptureAfterBecomingActive()
        XCTAssertEqual(environment.captureAttempts, 2)
        XCTAssertTrue(controller.status.contains("relaunch"))

        // A further activation must not keep hammering the tap.
        controller.retryInputCaptureAfterBecomingActive()
        controller.retryInputCaptureAfterBecomingActive()
        XCTAssertEqual(environment.captureAttempts, 2,
                       "a trusted-but-failing retry must not loop")
    }

    /// The Continuity page shows its Open Accessibility Settings control
    /// off THIS value, so which reason a failure records is a UI decision
    /// and not only a retry decision. An untrusted Mac gets the control;
    /// a trusted Mac whose tap still refuses gets a relaunch message
    /// instead, because sending that person to the Accessibility pane
    /// shows them a checkbox that is already on.
    func testCaptureFailureReasonDistinguishesPermissionFromRelaunch() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility, audit: { _, _ in })
        XCTAssertNil(controller.captureFailureReason,
                     "nothing has failed yet; the page must offer nothing")
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        XCTAssertEqual(controller.captureFailureReason, .missingPermission,
                       "an untrusted Mac is the case the Settings control "
                       + "exists for")

        // The same failure on a process macOS DOES trust: not a permission
        // problem, and the page must not offer the pane for it.
        let trusted = AccessibilityFake()
        trusted.trusted = true
        let secondEnvironment = Environment()
        secondEnvironment.captureAvailable = false
        let relaunch = ContinuityEdgeController(
            layout: makeLayout(), driver: Driver(),
            environment: secondEnvironment,
            accessibility: trusted, audit: { _, _ in })
        relaunch.start()
        secondEnvironment.emit(.init(kind: .moved,
                                     location: CGPoint(x: 1439, y: 450),
                                     delta: CGPoint(x: 2, y: 0),
                                     buttonsDown: false))
        relaunch.transportPhaseChanged(.active)

        XCTAssertEqual(relaunch.captureFailureReason, .relaunchNeeded)
    }

    /// The 2026-08-15 metal round, turned into a guard. Michelle granted
    /// Accessibility, System Settings showed the app switched ON, and the
    /// running process still logged the untrusted branch every arm —
    /// because the grant was on `/Applications/New Old World.app` while
    /// PID 82098 was `/Volumes/New Old World 10/New Old World.app`. Same
    /// identifier, same team, same signing time, different copy. Nothing
    /// in the log said which executable was speaking, so the round could
    /// only be resolved by screenshots and `ps`.
    ///
    /// One fact ends that exchange, and this asserts the log carries it.
    func testUntrustedCaptureFailureNamesTheCopyItIsRunningFrom() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: AccessibilityFake(),
            runningCopy: RunningCopy(
                path: "/Volumes/New Old World 10/New Old World.app"),
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        let permission = audits.filter {
            $0.1.contains("could not capture host input (Accessibility")
        }
        XCTAssertFalse(permission.isEmpty, "the leak must still be named")
        XCTAssertTrue(permission.allSatisfy {
            $0.1.contains("/Volumes/New Old World 10/New Old World.app")
        }, "every permission failure must name the running copy: \(audits)")
        XCTAssertTrue(permission.allSatisfy { $0.1.contains("per copy") },
                      "the path alone does not explain itself; the line "
                      + "must say the grant is per copy")
    }

    /// The bounded test the page's extra remedy hangs off. Blunt on
    /// purpose: it asks only whether this copy is somewhere a person would
    /// plausibly have granted, never where the grant actually went.
    func testRunningCopyRecognisesWhereAGrantedCopyLives() {
        XCTAssertTrue(RunningCopy(path: "/Applications/New Old World.app")
            .isInApplicationsFolder)
        XCTAssertFalse(RunningCopy(
            path: "/Volumes/New Old World 10/New Old World.app")
            .isInApplicationsFolder,
            "a copy running from a mounted disk image is the case that "
            + "cost the 2026-08-15 round")
        XCTAssertFalse(RunningCopy(
            path: "/Users/michelle/Downloads/New Old World.app")
            .isInApplicationsFolder)
    }

    /// And it clears on recovery — a stale control offering a permission
    /// the person has already granted is its own small lie.
    func testCaptureFailureReasonClearsWhenTheTapRecovers() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.captureAvailable = false
        let accessibility = AccessibilityFake()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            accessibility: accessibility, audit: { _, _ in })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        XCTAssertEqual(controller.captureFailureReason, .missingPermission)

        accessibility.trusted = true
        environment.captureAvailable = true
        controller.retryInputCaptureAfterBecomingActive()

        XCTAssertNil(controller.captureFailureReason,
                     "a recovered tap must take the control away again")
    }

    func testDisabledInputTapIsReportedAndOwnershipSurvivesIt() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)

        environment.captureTapDisabled?("timeout")
        XCTAssertTrue(audits.contains { $0.1.contains("timeout") })
        XCTAssertEqual(controller.state, .active)
    }

    /// **Edge mode alone must have somewhere for a file to land.**
    ///
    /// The regression this pins: the callbacks were installed inside the
    /// Mirror runtime's lazy source, so starting edge mode from the
    /// Continuity module — which never constructs Mirror — left
    /// `refreshFileEdge` refusing to create ANY AppKit destination. Nothing
    /// logged, nothing refused; the strip simply was not there.
    ///
    /// Nothing here constructs a Mirror. The destination must exist anyway,
    /// and the dependency Mirror really does own — the scene — must be
    /// refused BY NAME rather than by being absent.
    func testEdgeModeWithoutMirrorStillHasALiveDropDestination() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let listener = GuestListener(
            identity: .init(version: "test", name: "Host"))
        defer { listener.stop() }
        var audits: [(HostLog.LogLevel, String)] = []
        /* Held for the length of the test: the seam keeps the file lane
           weakly, the way the app owns it. */
        let fileTransfer = MirrorFileTransferModel(listener: listener)
        ContinuityFileDrag.configure(
            edge: controller,
            fileTransfer: fileTransfer,
            /* No Mirror runtime exists in this test, which is the point. */
            scene: { nil },
            audit: { audits.append(($0, $1)) })
        controller.start()

        let callbacks = try XCTUnwrap(
            environment.fileCallbacks,
            "edge mode with no Mirror had no AppKit drop destination")
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450)),
                      "the strip must accept the drag to be steerable")
        controller.transportPhaseChanged(.active)

        XCTAssertFalse(callbacks.dropped(.init(name: .drag)),
                       "with no scene there is no honest drop target")
        XCTAssertTrue(
            audits.contains { $0.1.contains(ContinuityFileDrag.noSceneReason) },
            "the refusal must name what is missing, not fail silently")
        XCTAssertEqual(controller.state, .ready)
    }

    /// The same claim against the REAL wiring: the app installs the seam on
    /// its own edge controller, with no module page touched. The test above
    /// proves the seam behaves; this proves somebody actually installs it,
    /// which is the half the regression broke.
    func testAppInstallsTheFileSeamWithoutConstructingMirror() {
        let suite = "ContinuityFileSeam.\(UUID().uuidString)"
        // swiftlint:disable:next force_unwrapping
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let state = HostAppState(registry: .standard, defaults: defaults)
        defer { state.shutDownModules() }

        XCTAssertTrue(state.continuity.edge.fileDraggingConfigured,
                      "edge mode would start with no drop destination")
    }

    /// The tap path has no NSEvent, and used to reach `beginFileDrag`
    /// through a mutable field that was nil there — a synthesized gesture
    /// AppKit never owned. Absence is now a parameter, and it is named.
    ///
    /// What CHANGED at slice 4 is the remedy, not the law: absence used to
    /// end the handoff on the spot, and now it waits for the first real
    /// event the dying tap stops swallowing. The law is the same one either
    /// way — no drag session is ever started from an invented event — and
    /// that is what this asserts. The wait's own ending, when the button
    /// comes up before any real event, is pinned in ContinuityGuestDragTests.
    func testGuestFileCrossingWithoutARealEventNeverInventsOne() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { audits.append(($0, $1)) })
        controller.configureFileDragging(
            guestFileAtPoint: { _ in
                HostFileDragItem(writer: NSPasteboardItem(),
                                 image: NSImage(size: NSSize(width: 32,
                                                             height: 32)))
            },
            hostFilesDropped: { _, _ in false })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true))

        XCTAssertTrue(environment.fileDrags.isEmpty,
                      "no real event means no drag session at all")
        XCTAssertTrue(audits.contains {
            $0.1.contains("waiting for the catch surface and the first real "
                + "host mouse event")
        }, "a drag that cannot start yet must say so")
        XCTAssertEqual(environment.associationChanges, [false, true],
                       "the pass still hands the mouse back")
    }

    /// A real event reaches AppKit unchanged: the seed is built from it, so
    /// a test that only counted drags would not notice it being invented.
    func testHostDragCarriesTheRealSourceEvent() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.configureFileDragging(
            guestFileAtPoint: { _ in
                HostFileDragItem(writer: NSPasteboardItem(),
                                 image: NSImage(size: NSSize(width: 32,
                                                             height: 32)))
            },
            hostFilesDropped: { _, _ in false })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        let event = Self.mouseEvent(eventNumber: 4242)
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true),
                                 event: event)

        XCTAssertEqual(environment.fileDrags.count, 1)
        XCTAssertEqual(environment.fileDrags.first?.event.eventNumber, 4242)
    }

    /// **A held button belongs to nobody, so this app keeps holding it.**
    ///
    /// Metal, 2026-08-14: a host window touching the shared edge got DRAGGED
    /// when the pointer came back with the button down. The consuming tap
    /// swallowed the physical mouse-down, so no application owns that press;
    /// the moment the tap dies, whatever is under the returning pointer
    /// inherits the gesture. Custody keeps the tap alive until the physical
    /// release.
    func testAHeldReturnKeepsConsumingUntilTheButtonIsReleased() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true))

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(environment.captureStops, 0,
                       "the tap died with the button still down; the next "
                        + "window under the pointer inherits the press")
        XCTAssertTrue(audits.contains {
            $0.1.contains("came back with the button held")
        })

        /* Held motion while custody holds must reach nothing — including
           the guest, which would otherwise be re-entered. */
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1200, y: 450),
                                       delta: CGPoint(x: -40, y: 0),
                                       buttonsDown: true))
        XCTAssertEqual(controller.state, .ready)

        environment.emitCaptured(.init(kind: .primaryUp,
                                       location: CGPoint(x: 1200, y: 450),
                                       delta: .zero, buttonsDown: false))
        XCTAssertEqual(environment.captureStops, 1,
                       "the mouse must come back the instant it is released")
        XCTAssertTrue(audits.contains {
            $0.1.contains("held-button custody ended")
                && $0.1.contains("swallowed=1")
        })
    }

    /// The ordinary return is unchanged: no button, no custody, the tap
    /// goes down where it always did.
    func testAnOrdinaryReturnStillGivesTheMouseBackImmediately() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: false))

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(environment.captureStops, 1)
        XCTAssertFalse(audits.contains {
            $0.1.contains("came back with the button held")
        }, "custody is for held returns only")
    }

    /// The escape chord is the other way out, and the keyboard tap cannot
    /// see the mouse: a chord pressed mid-drag ends ownership with the
    /// button still down, which is the same loose gesture.
    func testTheEscapeChordWithAHeldButtonAlsoTakesCustody() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let keyboard = KeyboardEnvironment()
        var audits: [(HostLog.LogLevel, String)] = []
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            keyboardEnvironment: keyboard,
            audit: { audits.append(($0, $1)) })
        controller.start()
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))

        _ = keyboard.emit(.init(
            action: .down, code: ContinuityEscapeShortcut
                .controlOptionEscape.code, character: 0,
            modifiers: ContinuityEscapeShortcut
                .controlOptionEscape.modifiers))

        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(environment.captureStops, 0,
                       "the chord let go of a press nobody owns")
        XCTAssertTrue(audits.contains {
            $0.1.contains("came back with the button held")
                && $0.1.contains("escape shortcut")
        })
    }

    /// A real host mouse event, which the CGEvent tap can never supply.
    private static func mouseEvent(eventNumber: Int = 7) -> NSEvent {
        // swiftlint:disable:next force_unwrapping
        NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 12, windowNumber: 0, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: 1)!
    }

    private func makeLayout() -> ContinuityDisplayLayout {
        ContinuityDisplayLayout(hostDisplays: [host],
                                guestSize: CGSize(width: 800, height: 600),
                                defaults: nil, observeScreens: false)
    }
}

private extension ContinuityEdgeControllerTests {
    final class Driver: ContinuityEdgeDriving {
        var keyboardForwardingEnabled = true
        var escapeShortcut = ContinuityEscapeShortcut.controlOptionEscape
        var points: [MirrorKit.Point] = []
        var leftCount = 0
        var downPoints: [MirrorKit.Point] = []
        var menuBarDowns: [Bool] = []
        var draggedPoints: [MirrorKit.Point] = []
        var settledPoints: [MirrorKit.Point] = []
        var upPoints: [MirrorKit.Point] = []
        var keys: [HostKeySample] = []
        /// The guest can decline a press — a dead epoch, a cycle already
        /// held. The controller then remembers no origin at all, which is
        /// the state the loudness guard exists for.
        var consumesPrimaryDown = true

        func pointerMoved(to point: MirrorKit.Point) { points.append(point) }
        func pointerLeft() { leftCount += 1 }
        func primaryDown(at point: MirrorKit.Point,
                         inMenuBar: Bool,
                         sourceUptime: TimeInterval?) -> Bool {
            _ = sourceUptime
            downPoints.append(point)
            menuBarDowns.append(inMenuBar)
            return consumesPrimaryDown
        }
        func primaryDragged(to point: MirrorKit.Point) -> Bool {
            draggedPoints.append(point)
            return true
        }
        func settleHeldPosition(to point: MirrorKit.Point) -> Bool {
            settledPoints.append(point)
            return true
        }
        func primaryUp(at point: MirrorKit.Point) -> Bool {
            upPoints.append(point)
            return true
        }
        func keyboardEvent(_ sample: HostKeySample) -> Bool {
            keys.append(sample)
            return true
        }
    }

    final class Environment: ContinuityPointerEnvironment {
        final class Token: NSObject {}
        var handler: ContinuityPointerEnvironment.SampleHandler?
        var hidden: [UInt32] = []
        var shown: [UInt32] = []
        var moves: [(displayID: UInt32, point: CGPoint)] = []
        var fileCallbacks: ContinuityFileEdge.Callbacks?
        var fileDrags: [(item: HostFileDragItem, point: CGPoint,
                         event: NSEvent)] = []
        var associationChanges: [Bool] = []
        var catchChanges: [Bool] = []
        var captureStarts = 0
        var captureStops = 0
        var syntheticButtonPosts: [(down: Bool, point: CGPoint)] = []

        func postSyntheticPrimaryButton(down: Bool,
                                        at screenPoint: CGPoint) -> Bool {
            syntheticButtonPosts.append((down, screenPoint))
            return true
        }
        /// Every call in, whether or not it succeeded — `captureStarts`
        /// only counts the ones that did, so a test proving a RETRY was
        /// attempted (and refused again) needs this instead.
        var captureAttempts = 0
        var captureHandler: ContinuityPointerEnvironment.SampleHandler?
        var captureTapDisabled: (@MainActor (String) -> Void)?
        /// Set false to stand in for a Mac without Accessibility permission.
        var captureAvailable = true

        func start(_ handler: @escaping ContinuityPointerEnvironment
                    .SampleHandler) -> AnyObject {
            self.handler = handler
            return Token()
        }
        func stop(_ token: AnyObject) { _ = token }
        /// The witness lane. Available by default, so ordinary tests
        /// describe a Mac where the listen-only tap was granted; a test for
        /// the refusal sets `dragWitnessAvailable = false`.
        var dragWitnessAvailable = true
        var dragWitness = ContinuityDragWitness(installed: true)
        var dragWitnessStarts = 0
        var dragWitnessStops = 0

        func startDragWitness() -> AnyObject? {
            guard dragWitnessAvailable else { return nil }
            dragWitnessStarts += 1
            return Token()
        }
        func readDragWitness(_ token: AnyObject) -> ContinuityDragWitness {
            _ = token
            return dragWitness
        }
        func stopDragWitness(_ token: AnyObject) {
            _ = token
            dragWitnessStops += 1
        }
        func hideCursor(on displayID: UInt32) { hidden.append(displayID) }
        func showCursor(on displayID: UInt32) { shown.append(displayID) }
        func moveCursor(on displayID: UInt32, to point: CGPoint) {
            moves.append((displayID, point))
        }
        func setCursorMovementAssociated(_ associated: Bool) -> Bool {
            associationChanges.append(associated)
            return true
        }
        func startInputCapture(
            handler: @escaping ContinuityPointerEnvironment.SampleHandler,
            tapDisabled: @escaping @MainActor (String) -> Void
        ) -> AnyObject? {
            captureAttempts += 1
            guard captureAvailable else { return nil }
            captureStarts += 1
            captureHandler = handler
            captureTapDisabled = tapDisabled
            return Token()
        }
        func stopInputCapture(_ token: AnyObject) {
            _ = token
            captureStops += 1
            captureHandler = nil
        }
        /// Delivers through the consuming tap rather than the monitor. The
        /// tap has no NSEvent by construction — that is the whole reason the
        /// source event is an explicit parameter — so this delivers nil
        /// unless a test states otherwise.
        func emitCaptured(_ sample: HostPointerSample,
                          event: NSEvent? = nil) {
            captureHandler?(sample, event)
        }
        func showFileEdge(_ edge: ContinuitySharedEdge,
                          callbacks: ContinuityFileEdge.Callbacks)
            -> AnyObject {
            _ = edge
            fileCallbacks = callbacks
            return Token()
        }
        func updateFileEdge(_ token: AnyObject,
                            edge: ContinuitySharedEdge,
                            callbacks: ContinuityFileEdge.Callbacks) {
            _ = token
            _ = edge
            fileCallbacks = callbacks
        }
        func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool) {
            _ = token
            catchChanges.append(catching)
        }
        var catchSurfaceOwnsSeedPoint = true

        func catchSurfaceHitTest(_ token: AnyObject, at screenPoint: CGPoint)
            -> ContinuityCatchHitTest {
            _ = (token, screenPoint)
            return ContinuityCatchHitTest(
                serverTopWindowNumber: catchSurfaceOwnsSeedPoint ? 77 : 30,
                panelWindowNumber: 77)
        }
        func hideFileEdge(_ token: AnyObject) {
            _ = token
            fileCallbacks = nil
        }
        /// What the real environment would report about the session it
        /// started. Own-window by default, because that is what the fixed
        /// implementation does; a test that wants the failure sets it.
        var dragSeed: ContinuityDragSeed? = ContinuityDragSeed(
            eventType: 6, serverTopWindowNumber: 77, appActive: true,
            windowNumber: 77, panelWindowNumber: 77,
            resolvedToPanel: true, clickCount: 1, panelKey: true,
            panelCoversPoint: true)

        func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                           sourceEvent: NSEvent) -> ContinuityDragSeed? {
            fileDrags.append((item, screenPoint, sourceEvent))
            return dragSeed
        }
        func emit(_ sample: HostPointerSample, event: NSEvent? = nil) {
            handler?(sample, event)
        }
    }

    final class KeyboardEnvironment: ContinuityKeyboardEnvironment {
        final class Token: NSObject {}
        var policy: ContinuityKeyboardCapturePolicy?
        var handler: (@MainActor (HostKeySample) -> Void)?
        var tapDisabled: (@MainActor (String) -> Void)?
        var stopCount = 0

        func start(
            policy: ContinuityKeyboardCapturePolicy,
            handler: @escaping @MainActor (HostKeySample) -> Void,
            tapDisabled: @escaping @MainActor (String) -> Void
        ) -> AnyObject? {
            self.policy = policy
            self.handler = handler
            self.tapDisabled = tapDisabled
            return Token()
        }
        func stop(_ token: AnyObject) {
            _ = token
            stopCount += 1
            policy = nil
            handler = nil
            tapDisabled = nil
        }
        func emit(_ sample: HostKeySample) -> Bool {
            guard policy?.captures(sample) == true else { return false }
            handler?(sample)
            return true
        }
    }

    /// Fakes the two AX calls without ever touching the real system prompt:
    /// a test that called the genuine `AXIsProcessTrustedWithOptions` would
    /// either need real Accessibility trust granted to the test runner or
    /// would pop a real system dialog during `swift test`.
    final class AccessibilityFake: AccessibilityAuthorization, @unchecked Sendable {
        var trusted = false
        var promptCount = 0

        var openSettingsCount = 0

        func isProcessTrusted() -> Bool { trusted }
        func promptForTrust() { promptCount += 1 }
        func openAccessibilitySettings() { openSettingsCount += 1 }
    }
}
