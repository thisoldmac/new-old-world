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

    /// `updateEdgeGeometry` is the one funnel both configurable numbers go
    /// through: this pins that a changed entry inset actually reaches the
    /// NEXT crossing (no restart needed) and that an out-of-range request
    /// arrives clamped rather than applied verbatim — the published value a
    /// settings UI would bind to must be what was actually applied, not
    /// what was asked for.
    func testUpdatedEdgeGeometryReachesTheNextCrossingClamped() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()

        controller.updateEdgeGeometry(
            ContinuityEdgeGeometry(entryInsetPixels: 0, deadzoneDepth: 999_000))

        XCTAssertEqual(controller.edgeGeometry.entryInsetPixels, 0,
                       "zero is legal and must survive exactly")
        XCTAssertEqual(controller.edgeGeometry.deadzoneDepth,
                       ContinuityEdgeGeometry.deadzoneDepthRange.upperBound,
                       "an absurd request is clamped, not honoured verbatim")

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: 3, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 0, y: 300),
                       "the zeroed inset must reach this crossing without a "
                        + "restart")
    }

    /// `reportFileGrabOutcome` is the seam `ContinuityFileDrag.configure`
    /// wires a grab's terminal `notice` into — see
    /// `ContinuityGuestDragTests.testAWrongFileRefusalReachesTheOutcomeSinkInPlainWords`
    /// for the sink firing with the right words. This pins the other half:
    /// that firing it actually reaches the same `status` the page draws.
    func testFileGrabOutcomeReachesTheOrdinaryStatusLine() {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.start()

        /* Composed through MachineNaming rather than spelled out, for the
           same reason as `ContinuityGuestDragTests
           .testAWrongFileRefusalReachesTheOutcomeSinkInPlainWords`: the
           literal is what this assertion is FOR, so it must not also be
           the second place the product's noun for the driven machine is
           written down. */
        let message = MachineNaming.startingSentence(
            "the selection on \(MachineNaming.simpleReference) changed "
            + "before the file could be copied.")

        controller.reportFileGrabOutcome(message)

        XCTAssertEqual(controller.status, message)
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
        let staged = NSPasteboard(name: .init("now.test.staged.h"))
        controller.stageHostFiles = { _ in staged }
        var droppedAt: MirrorKit.Point?
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, point in
                droppedAt = point
                return true
            })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        XCTAssertEqual(controller.state, .arming)
        /* The drop this Mac caused at the crossing, which ends the host's
           own drag and stages the file. It is deliberately NOT the
           transfer any more (2026-08-16). */
        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertNil(droppedAt, "the edge stages; it does not transfer")
        controller.transportPhaseChanged(.active)
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 100, y: -50),
                               buttonsDown: true))

        environment.emit(.init(kind: .primaryUp,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: false))
        XCTAssertEqual(droppedAt, MirrorKit.Point(x: 124, y: 500),
                       "the release on the guest is the commit, and it lands "
                        + "where the pointer had got to")
        XCTAssertEqual(controller.state, .active,
                       "and the person is still on the guest afterwards, "
                        + "exactly like any other crossing")
        XCTAssertEqual(driver.leftCount, 0)
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

    /// **A drag whose host session cannot be ended is still untouchable.**
    ///
    /// This was the rule for every host file drag until 2026-08-16; it is
    /// now the rule for the ones this Mac declines to end at the crossing —
    /// a drag carrying nothing that outlives its own session (a promise-only
    /// drag), where `stageHostFiles` answers nil. The human is holding a
    /// real cursor over a real, still-live foreign session, so nothing may
    /// be detached, warped or eaten, and the gesture behaves exactly as it
    /// did before that change.
    func testAHostFileDragThatCannotBeStagedIsLeftEntirelyAlone() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        controller.stageHostFiles = { _ in nil }
        controller.configureFileDragging(guestFileAtPoint: { _ in nil },
                                         hostFilesDropped: { _, _ in true })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        controller.transportPhaseChanged(.active)
        XCTAssertTrue(environment.syntheticHIDButtonPosts.isEmpty,
                      "nothing this Mac can hold past the session means no "
                        + "release is posted to end it")
        XCTAssertTrue(environment.associationChanges.isEmpty)
        XCTAssertEqual(environment.captureStarts, 0)

        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertEqual(controller.state, .ready)
        XCTAssertTrue(environment.associationChanges.isEmpty,
                      "nothing was detached, so nothing is re-attached")
    }

    /// **THE SPEC CHANGED HERE, DELIBERATELY.** Until 2026-08-16 a host file
    /// drag was pinned to "never detach, never warp, never capture" because
    /// the session belonged to Finder. Michelle's attended evidence that day
    /// — badge gone, ghost and cursor still clamped at the physical edge,
    /// and the edge triggering a Spaces switch — settled that the session
    /// has to END at the crossing instead. From that instant there is no
    /// foreign session, so the pass takes exactly the custody an ordinary
    /// crossing takes, and this test asserts that custody rather than its
    /// absence.
    func testHostFileDragEndsTheHostDragAtTheCrossingAndStagesTheFile()
        throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.a"))
        controller.stageHostFiles = { _ in staged }
        var dropped: [(NSPasteboard, MirrorKit.Point)] = []
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { board, point in
                dropped.append((board, point))
                return true
            })
        var arrived = 0
        var departed = 0
        controller.configureHostDragPresentation(
            arrived: { _ in arrived += 1 },
            departed: { departed += 1 })
        controller.start()
        let callbacks = try XCTUnwrap(environment.fileCallbacks)

        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450),
                                        .init(name: .drag)))
        XCTAssertEqual(arrived, 1)
        XCTAssertEqual(environment.syntheticHIDButtonPosts.count, 1,
                       "one release, posted at the HID level, ends the host "
                        + "drag at the crossing")
        XCTAssertEqual(environment.syntheticHIDButtonPosts.first?.down, false)
        XCTAssertEqual(environment.syntheticHIDButtonPosts.first?.point,
                       CGPoint(x: 1439, y: 450),
                       "posted where the cursor is — over this app's own "
                        + "catch surface, so the drop lands on us")
        XCTAssertEqual(environment.catchChanges.last, true,
                       "the strip widens first so the drop has somewhere of "
                        + "ours to land")

        /* The drop this Mac caused. It is a staging: the guest is still
           drawing the drag, nothing is transferred, and ownership is not
           returned. */
        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertEqual(departed, 0,
                       "the person is still carrying the file; the guest "
                        + "keeps drawing it")
        XCTAssertTrue(dropped.isEmpty, "nothing is transferred at the edge")
        XCTAssertEqual(environment.catchChanges.last, false,
                       "the strip narrows again once the drop has landed")

        controller.transportPhaseChanged(.active)
        XCTAssertEqual(environment.associationChanges, [false],
                       "with the foreign session gone the pass detaches the "
                        + "cursor exactly like an ordinary crossing")
        XCTAssertEqual(environment.captureStarts, 1,
                       "and captures host input, which is what turns the "
                        + "person's real release into a sample this "
                        + "controller sees")
        XCTAssertFalse(environment.moves.isEmpty,
                       "and pins the real cursor off the physical edge")

        let entry = try XCTUnwrap(driver.points.first)
        environment.emitCaptured(.init(kind: .primaryUp,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: false))
        XCTAssertEqual(dropped.count, 1,
                       "THE GUEST RELEASE IS THE COMMIT")
        XCTAssertEqual(dropped.first?.1, entry,
                       "and it lands where the pointer was on the guest")
        XCTAssertEqual(departed, 1,
                       "the guest stops drawing the carried file at the "
                        + "release, not before")
    }

    /// The abort. A cross back with no release on the guest transfers
    /// nothing: the staging is a pasteboard, so letting it go is the whole
    /// of the undo and no partial file can exist on the guest.
    func testCrossingBackWithoutAGuestReleaseTransfersNothing() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.b"))
        controller.stageHostFiles = { _ in staged }
        var dropped = 0
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, _ in dropped += 1; return true })
        controller.start()
        let callbacks = try XCTUnwrap(environment.fileCallbacks)

        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450),
                                        .init(name: .drag)))
        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        controller.transportPhaseChanged(.active)

        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -200, y: 0),
                                       buttonsDown: true))

        XCTAssertEqual(dropped, 0, "no guest release, no transfer")
        XCTAssertEqual(controller.state, .ready)
        XCTAssertEqual(environment.associationChanges, [false, true],
                       "and the mouse is given back")
    }

    /// The window server refused the release. The gesture falls back to the
    /// pre-2026-08-16 behaviour rather than half-ending: nothing staged,
    /// the strip narrowed again, and the ordinary drop path intact.
    func testARefusedSyntheticReleaseFallsBackToTheOldGesture() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        environment.syntheticHIDPostsSucceed = false
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.c"))
        controller.stageHostFiles = { _ in staged }
        var dropped = 0
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, _ in dropped += 1; return true })
        var departed = 0
        controller.configureHostDragPresentation(arrived: { _ in },
                                                 departed: { departed += 1 })
        controller.start()
        let callbacks = try XCTUnwrap(environment.fileCallbacks)

        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450),
                                        .init(name: .drag)))
        XCTAssertEqual(environment.syntheticHIDButtonPosts.count, 1)
        XCTAssertEqual(environment.catchChanges.last, false,
                       "the widen is undone when the post is refused")
        controller.transportPhaseChanged(.active)
        XCTAssertTrue(environment.associationChanges.isEmpty,
                      "a still-live foreign session is still untouchable")

        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        XCTAssertEqual(dropped, 1, "the drop on the strip is a real drop "
                        + "again, exactly as before this change")
        XCTAssertEqual(departed, 1)
        XCTAssertEqual(controller.state, .ready)
    }

    // MARK: - The staged carry owns the button

    /* All six tests below describe ONE moment: a person holding a file over
       the guest after this Mac ended their Finder drag at the crossing.
       Every expectation is taken from the contract the 2026-08-16 attended
       round found broken (F1 ledger, D2/D4/D5), not from the code that now
       implements it. */

    /// **THE PHYSICAL RELEASE COMMITS.** This Mac posts a `leftMouseUp` at
    /// the HID level to end Finder's session at the crossing, which sets the
    /// system's global button state UP while the person's finger is still
    /// down — so their real lift produces no transition, no event, and the
    /// commit never fires. Six of seven metal carries died there. The fix is
    /// the guest→host lane's own mechanism pointed the other way: a
    /// synthetic DOWN that re-arms the button, posted only once the
    /// consuming tap is in front of it.
    func testThePhysicalReleaseAfterTheSyntheticUpCommitsTheStagedFile()
        throws {
        let carry = try Carry(layout: makeLayout())

        XCTAssertEqual(carry.environment.syntheticHIDButtonPosts.map(\.down),
                       [false, true],
                       "the release that ENDS the host drag, then the down "
                        + "that re-arms the button it lied about")
        XCTAssertEqual(carry.environment.syntheticHIDButtonPosts.last?.point,
                       CGPoint(x: 1439, y: 450),
                       "posted where the crossing ended the drag — this "
                        + "Mac's own catch surface")
        let armed = try XCTUnwrap(carry.firstIndex(of: "consuming tap armed"))
        let rearmed = try XCTUnwrap(carry.firstIndex(of: "button re-armed"))
        XCTAssertLessThan(armed, rearmed,
                          "a synthetic press with nothing in front of it is "
                            + "this app pressing a button in another "
                            + "application: the tap comes first")

        carry.releaseOnGuest()

        XCTAssertEqual(carry.dropped.count, 1,
                       "the person's own release commits the staged file — "
                        + "without pressing the button a second time")
    }

    /// Without a consuming tap there is no re-arm at all, and the log says
    /// so. The rule this protects is older than the defect: this app does
    /// not press a button in another application, and a degraded carry is a
    /// better answer than a synthetic down landing on the Finder desktop.
    func testTheButtonReArmIsDeclinedWhenNothingWouldSwallowIt() throws {
        let carry = try Carry(layout: makeLayout(), captureAvailable: false)

        XCTAssertEqual(carry.environment.syntheticHIDButtonPosts.map(\.down),
                       [false],
                       "no tap, no synthetic press")
        XCTAssertTrue(carry.lines(containing: "button re-arm DECLINED")
            .contains { $0.contains("another application") },
            "and the reason is named, with the consequence for the carry: "
                + "\(carry.recorder.lines)")
    }

    /// **NO CLICK REACHES THE GUEST WHILE A FILE IS STAGED.** On metal three
    /// bursts of forwarded presses landed on the guest desktop inside its
    /// own double-click window, which is how a drag came to open Classilla.
    /// A press during a carry is the person completing a drop, and the only
    /// thing that decides anything is the release.
    func testAPressDuringAStagedCarryIsNeverForwardedToTheGuest() throws {
        let carry = try Carry(layout: makeLayout())

        carry.pressOnGuest()
        carry.pressOnGuest()

        XCTAssertTrue(carry.driver.downPoints.isEmpty,
                      "a forwarded press is a click on the guest, and two "
                        + "inside its double-click window open whatever is "
                        + "under the pointer")
        XCTAssertEqual(carry.dropped.count, 0, "and none of them commits")
        XCTAssertFalse(carry.lines(containing: "button forwarding suppressed")
                        .isEmpty,
                       "the suppression is audited, or the next report of "
                        + "this reads as a carry that silently did nothing")

        carry.releaseOnGuest()
        XCTAssertEqual(carry.dropped.count, 1)
        XCTAssertTrue(carry.driver.upPoints.isEmpty,
                      "the guest-side release is ours to synthesise at the "
                        + "commit — the drop is the transfer, not a click")
    }

    /// The backstop, for the release the window server may yet decline to
    /// emit as an event. It reads the hardware rather than waiting, and it
    /// is armed only once the HID has confirmed the re-arm took — before
    /// that, "not held" is this Mac's own synthetic release answering.
    func testTheHIDBackstopCommitsWhenNoReleaseEventEverArrives() throws {
        let carry = try Carry(layout: makeLayout())

        carry.moveOnGuest()
        XCTAssertEqual(carry.dropped.count, 0,
                       "held, so nothing has been let go of yet")

        carry.buttonHeld = false
        carry.moveOnGuest()

        XCTAssertEqual(carry.dropped.count, 1,
                       "the hardware says the button went up and no event "
                        + "carried it; the carry still commits")
    }

    /// **A DEPARTURE NEEDS MOTION, NOT A BUTTON STATE.** Every failed metal
    /// carry was reported as "crossed back to this Mac without a release on
    /// the guest" while `buttonsDown=0`. A staged carry must not be
    /// abandoned by samples that merely claim the button is up — that field
    /// is derived from event state this app's own tap starves — and only a
    /// real crossing ends it.
    func testAStagedCarryIsNotAbandonedByAButtonStateWithoutACrossing()
        throws {
        let carry = try Carry(layout: makeLayout())

        for _ in 0..<3 {
            carry.environment.emitCaptured(
                .init(kind: .moved, location: CGPoint(x: 1439, y: 450),
                      delta: CGPoint(x: 4, y: 1), buttonsDown: false))
        }

        XCTAssertEqual(carry.controller.state, .active,
                       "the pass is still carrying the file")
        XCTAssertTrue(carry.lines(containing: "let go without a transfer")
                        .isEmpty,
                      "no crossing happened, so nothing was let go of")
        carry.releaseOnGuest()
        XCTAssertEqual(carry.dropped.count, 1,
                       "and the release still commits afterwards")
    }

    /// **CUSTODY SPEAKS, ON EVERY TRANSITION.** The attended round's
    /// lockup window was unreadable because hide, detach, park and the tap
    /// wrote nothing at all. This is a deliverable, so it is pinned: one
    /// line each, in and out, and every one carrying the position that pairs
    /// it with the gesture a person remembers making.
    func testEveryCustodyTransitionIsAudited() throws {
        let carry = try Carry(layout: makeLayout())
        carry.releaseOnGuest()
        carry.controller.transportEnded(reason: "test")

        for transition in ["host cursor hidden",
                           "pointer detached from the mouse",
                           "cursor parked at the anchor",
                           "consuming tap armed",
                           "button re-armed",
                           "consuming tap disarmed",
                           "host cursor restored",
                           "pointer re-attached to the mouse"] {
            let lines = carry.lines(containing: transition)
            XCTAssertFalse(lines.isEmpty,
                           "\(transition) is silent: \(carry.recorder.lines)")
            XCTAssertTrue(lines.allSatisfy { $0.contains("host=") },
                          "\(transition) says nothing about where it "
                            + "happened, which is the one question a wild "
                            + "cursor asks")
        }
    }

    /// The visible-layer hide, which still exists for the instants between
    /// the crossing and the host drag actually ending, and which is still
    /// balanced by a show on the way out. The hide/show COUNTS now include
    /// the ordinary custody's own pair, because from the cross this pass is
    /// an ordinary pass.
    func testHostFileDragHidesCursorVisibleLayerAndRestoresItOnRelease()
        throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.d"))
        controller.stageHostFiles = { _ in staged }
        controller.configureFileDragging(guestFileAtPoint: { _ in nil },
                                         hostFilesDropped: { _, _ in true })
        var arrived = 0
        var departed = 0
        controller.configureHostDragPresentation(
            arrived: { _ in arrived += 1 },
            departed: { departed += 1 })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        XCTAssertEqual(arrived, 1)
        XCTAssertEqual(environment.hidden, [host.id],
                       "the visible cursor layer hides once the guest starts "
                        + "drawing the carried file")
        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        controller.transportPhaseChanged(.active)
        XCTAssertEqual(environment.hidden, [host.id, host.id],
                       "and the ordinary custody hides it again for the "
                        + "length of the pass")

        environment.emitCaptured(.init(kind: .primaryUp,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: false))
        XCTAssertEqual(departed, 1)
        XCTAssertEqual(environment.shown, [host.id],
                       "the release gives back the drag's own hide")

        controller.transportEnded(reason: "test")
        XCTAssertEqual(environment.shown, [host.id, host.id],
                       "and the end of the pass gives back the other one")
        XCTAssertEqual(environment.associationChanges, [false, true],
                       "detach and re-attach balance across the whole pass")
    }

    /// The same balance, off the "drag left without dropping" exit
    /// (`hostFileExited`, AppKit's `draggingExited`) rather than a release
    /// on the guest — and this is also the path that reports the synthetic
    /// release NOT coming back as a drop, which is the fallback observation
    /// an attended run needs.
    func testHostFileDragCursorIsRestoredWhenTheDragLeavesWithoutDropping()
        throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.e"))
        controller.stageHostFiles = { _ in staged }
        var dropped = 0
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, _ in dropped += 1; return true })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        XCTAssertEqual(environment.hidden, [host.id])

        callbacks.exited()

        XCTAssertEqual(environment.shown, [host.id],
                       "leaving the edge without a drop still restores the "
                        + "visible cursor layer")
        XCTAssertEqual(dropped, 0,
                       "a release that never came back as a drop on our own "
                        + "strip transfers nothing")
        XCTAssertEqual(environment.catchChanges.last, false,
                       "and the widened strip is narrowed again")
    }

    /// The defensive half: a host file drag that is still announced when
    /// ownership ends some OTHER way (transport loss, here) must not leave
    /// the cursor hidden — or a file staged. This exit never visits
    /// `hostFileExited` at all; it is exactly the gap `endOwnership`'s
    /// unconditional teardown exists to close.
    func testHostFileDragCursorIsRestoredWhenTransportEndsMidDrag() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.f"))
        controller.stageHostFiles = { _ in staged }
        var dropped = 0
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, _ in dropped += 1; return true })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
        controller.transportPhaseChanged(.active)
        XCTAssertTrue(environment.shown.isEmpty,
                      "not restored yet: transport has not ended")

        controller.transportEnded(reason: "guest hung up mid-drag")

        XCTAssertEqual(environment.shown, [host.id, host.id],
                       "transport loss restores both hides even though this "
                        + "path never calls hostFileExited")
        XCTAssertEqual(dropped, 0,
                       "and a staged file whose gesture died transfers "
                        + "nothing")
        XCTAssertEqual(environment.associationChanges, [false, true])
    }

    /// Each gesture hides and shows in balance, and a second gesture after
    /// the first fully ends hides again rather than being treated as a stale
    /// no-op. Guards against the balance being accidentally one-shot (a flag
    /// that never resets) as much as against it being unbalanced.
    func testHostFileDragCursorBalanceHoldsAcrossConsecutiveGestures() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let staged = NSPasteboard(name: .init("now.test.staged.g"))
        controller.stageHostFiles = { _ in staged }
        var dropped = 0
        controller.configureFileDragging(
            guestFileAtPoint: { _ in nil },
            hostFilesDropped: { _, _ in dropped += 1; return true })
        controller.start()
        let callbacks = try XCTUnwrap(environment.fileCallbacks)

        for _ in 0..<2 {
            XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450),
                                            .init(name: .drag)))
            XCTAssertTrue(callbacks.dropped(.init(name: .drag)))
            controller.transportPhaseChanged(.active)
            environment.emitCaptured(.init(kind: .primaryUp,
                                           location: CGPoint(x: 1439, y: 450),
                                           delta: .zero, buttonsDown: false))
            controller.transportEnded(reason: "end of gesture")
        }

        XCTAssertEqual(environment.hidden.count, 4,
                       "a second gesture hides again rather than staying a "
                        + "no-op from the first gesture's teardown")
        XCTAssertEqual(environment.shown.count, 4)
        XCTAssertEqual(dropped, 2, "and each gesture commits once, at its "
                        + "own release on the guest")
        XCTAssertEqual(environment.syntheticHIDButtonPosts.map(\.down),
                       [false, true, false, true],
                       "each gesture posts a release to END the host drag "
                        + "and then a down to RE-ARM the button, so the "
                        + "person's own lift is a real HID transition again "
                        + "— and the pair balances per gesture the same way "
                        + "the hides do")
        XCTAssertEqual(environment.associationChanges,
                       [false, true, false, true])
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
            path: "/Volumes/Scratch/Downloads/New Old World.app")
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
        /* Deterministic staging: the default reads the real system drag
           pasteboard, whose contents are whatever this Mac last dragged. */
        let staged = NSPasteboard(name: .init("now.test.staged.i"))
        controller.stageHostFiles = { _ in staged }
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
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)),
                      "the strip must accept the drag to be steerable")
        controller.transportPhaseChanged(.active)

        _ = callbacks.dropped(.init(name: .drag))
        /* The drop at the edge only stages now; the release on the guest is
           what asks the seam where the file is going. */
        environment.emit(.init(kind: .primaryUp,
                               location: CGPoint(x: 1439, y: 450),
                               delta: .zero, buttonsDown: false))
        /* THE RULING, PINNED (Michelle, 2026-08-16): "the mirror required
           thing is weird. it shouldn't be needed, either from a technical
           perspective or a product perspective." No Continuity file path may
           make the Mirror a precondition, and this is the path that did.
           With no scene the drop now aims at the guest DESKTOP — resolved
           from the crossing, which knows the guest coordinate continuously —
           rather than refusing. */
        XCTAssertTrue(
            audits.contains {
                $0.1.contains("file drop landing on the guest desktop")
            },
            "with no scene the drop must land on the guest desktop, not be "
                + "refused: \(audits.map(\.1))")
        XCTAssertFalse(
            audits.contains { $0.1.contains("needs the Mirror") },
            "no Continuity file path may name the Mirror as a requirement: "
                + "\(audits.map(\.1))")
        XCTAssertEqual(controller.state, .active,
                       "the release lands the file and leaves the person on "
                        + "the guest, the way any crossing does")
    }

    /// The refusal this used to pin is GONE, and its absence is the guard.
    ///
    /// It was the host→guest sibling of the grab-side refusal-sink test:
    /// with no scene, a file dragged toward the guest was refused, and the
    /// test's job was to prove the refusal reached a person rather than only
    /// the log. Michelle's 2026-08-16 ruling retired the refusal itself —
    /// a missing Mirror is not a reason a file cannot cross — so the seam
    /// must now stay SILENT on this path. A refusal surfaced to a person for
    /// a drop that is going to work anyway is worse than the log line was.
    func testAMissingSceneNoLongerSurfacesARefusalToAnybody() throws {
        let layout = makeLayout()
        let driver = Driver()
        let environment = Environment()
        let controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment)
        let listener = GuestListener(
            identity: .init(version: "test", name: "Host"))
        defer { listener.stop() }
        let fileTransfer = MirrorFileTransferModel(listener: listener)
        var refusals: [String] = []
        ContinuityFileDrag.configure(
            edge: controller,
            fileTransfer: fileTransfer,
            scene: { nil },
            refusal: { refusals.append($0) })
        controller.start()

        let callbacks = try XCTUnwrap(environment.fileCallbacks)
        XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)))
        controller.transportPhaseChanged(.active)

        _ = callbacks.dropped(.init(name: .drag))
        XCTAssertEqual(refusals, [],
                       "a missing scene is no longer a refusal, so nothing "
                           + "may be surfaced to a person for one: "
                           + "\(refusals)")
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
    final class AuditRecorder {
        var lines: [(HostLog.LogLevel, String)] = []
    }

    /// **One carried gesture, taken to the moment the person is holding a
    /// staged file over the guest** — the crossing has ended their Finder
    /// drag, this Mac has custody, and the only thing left is where they let
    /// go. Every gesture in the 2026-08-16 attended round was in exactly
    /// this state when it failed, so every test about that round starts
    /// here rather than rebuilding the approach six times.
    @MainActor
    final class Carry {
        let driver = Driver()
        let environment = Environment()
        let controller: ContinuityEdgeController
        let recorder = AuditRecorder()
        var dropped: [(NSPasteboard, MirrorKit.Point)] = []
        var departed = 0
        /// What the HARDWARE says about the primary button. True by
        /// default: the person is holding a file, which is the whole
        /// premise of a carry.
        var buttonHeld = true

        init(layout: ContinuityDisplayLayout,
             captureAvailable: Bool = true) throws {
            environment.captureAvailable = captureAvailable
            let recorder = self.recorder
            controller = ContinuityEdgeController(
                layout: layout, driver: driver, environment: environment,
                audit: { recorder.lines.append(($0, $1)) })
            let staged = NSPasteboard(
                name: .init("now.test.carry.\(UUID().uuidString)"))
            controller.stageHostFiles = { _ in staged }
            controller.physicalPrimaryButtonHeld = { [weak self] in
                self?.buttonHeld ?? false
            }
            controller.configureFileDragging(
                guestFileAtPoint: { _ in nil },
                hostFilesDropped: { [weak self] board, point in
                    self?.dropped.append((board, point))
                    return true
                })
            controller.configureHostDragPresentation(
                arrived: { _ in },
                departed: { [weak self] in self?.departed += 1 })
            controller.start()

            let callbacks = try XCTUnwrap(environment.fileCallbacks)
            XCTAssertTrue(callbacks.entered(CGPoint(x: 1439, y: 450),
                                            .init(name: .drag)))
            XCTAssertTrue(callbacks.dropped(.init(name: .drag)),
                          "the release this Mac posted comes back as a drop "
                            + "on its own strip: the file is staged")
            controller.transportPhaseChanged(.active)
        }

        /// The release the person makes on the guest, delivered through the
        /// consuming tap — which is where it arrives once the button has
        /// been re-armed and the physical lift is a real transition again.
        func releaseOnGuest() {
            environment.emitCaptured(
                .init(kind: .primaryUp, location: CGPoint(x: 1439, y: 450),
                      delta: .zero, buttonsDown: false))
        }

        func pressOnGuest() {
            environment.emitCaptured(
                .init(kind: .primaryDown, location: CGPoint(x: 1439, y: 450),
                      delta: .zero, buttonsDown: true))
        }

        /// Held motion on the guest, well short of the boundary.
        func moveOnGuest() {
            environment.emitCaptured(
                .init(kind: .moved, location: CGPoint(x: 1439, y: 450),
                      delta: CGPoint(x: 6, y: 2), buttonsDown: true))
        }

        func lines(containing text: String) -> [String] {
            recorder.lines.map(\.1).filter { $0.contains(text) }
        }

        func firstIndex(of text: String) -> Int? {
            recorder.lines.firstIndex { $0.1.contains(text) }
        }
    }

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
        /// The HID-level release that ENDS a host drag at the crossing,
        /// recorded apart from the session-level one above: the two answer
        /// different questions and a test that confused them would prove
        /// nothing.
        var syntheticHIDButtonPosts: [(down: Bool, point: CGPoint)] = []
        /// Set false to stand in for a window server that refused the post,
        /// which is one of the two ways ending the drag at the cross
        /// declines.
        var syntheticHIDPostsSucceed = true

        func postSyntheticPrimaryButtonAtHID(down: Bool,
                                             at screenPoint: CGPoint) -> Bool {
            syntheticHIDButtonPosts.append((down, screenPoint))
            return syntheticHIDPostsSucceed
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
        var catchThicknesses: [CGFloat] = []

        func showFileEdge(_ edge: ContinuitySharedEdge,
                          catchThickness: CGFloat,
                          callbacks: ContinuityFileEdge.Callbacks)
            -> AnyObject {
            _ = edge
            catchThicknesses.append(catchThickness)
            fileCallbacks = callbacks
            return Token()
        }
        func updateFileEdge(_ token: AnyObject,
                            edge: ContinuitySharedEdge,
                            catchThickness: CGFloat,
                            callbacks: ContinuityFileEdge.Callbacks) {
            _ = token
            _ = edge
            catchThicknesses.append(catchThickness)
            fileCallbacks = callbacks
        }
        func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool) {
            _ = token
            catchChanges.append(catching)
        }
        var dropsThroughChanges: [Bool] = []
        func setFileEdgeDropsThroughOwnSession(_ token: AnyObject,
                                               _ dropsThrough: Bool) {
            _ = token
            dropsThroughChanges.append(dropsThrough)
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
