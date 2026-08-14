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
                               buttonsDown: true))

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

        rig.source.surfaceMode = .continuity
        XCTAssertNil(rig.source.continuityInputDriver,
                     "the invisible Mirror must not remain a pointer entry")
        XCTAssertTrue(rig.source.continuity.isEnabled)

        rig.source.surfaceMode = .mirror
        XCTAssertTrue(rig.source.continuityInputDriver
                      === rig.source.continuity,
                      "returning to Mirror restores its own cursor feature")
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
                                       buttonsDown: true))

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
        var upPoints: [MirrorKit.Point] = []
        var keys: [HostKeySample] = []

        func pointerMoved(to point: MirrorKit.Point) { points.append(point) }
        func pointerLeft() { leftCount += 1 }
        func primaryDown(at point: MirrorKit.Point,
                         inMenuBar: Bool,
                         sourceUptime: TimeInterval?) -> Bool {
            _ = sourceUptime
            downPoints.append(point)
            menuBarDowns.append(inMenuBar)
            return true
        }
        func primaryDragged(to point: MirrorKit.Point) -> Bool {
            draggedPoints.append(point)
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
        var handler: (@MainActor (HostPointerSample) -> Void)?
        var hidden: [UInt32] = []
        var shown: [UInt32] = []
        var moves: [(displayID: UInt32, point: CGPoint)] = []
        var fileCallbacks: ContinuityFileEdge.Callbacks?
        var fileDrags: [(item: HostFileDragItem, point: CGPoint)] = []
        var associationChanges: [Bool] = []
        var captureStarts = 0
        var captureStops = 0
        var captureHandler: (@MainActor (HostPointerSample) -> Void)?
        var captureTapDisabled: (@MainActor (String) -> Void)?
        /// Set false to stand in for a Mac without Accessibility permission.
        var captureAvailable = true

        func start(_ handler: @escaping @MainActor (HostPointerSample) -> Void)
            -> AnyObject {
            self.handler = handler
            return Token()
        }
        func stop(_ token: AnyObject) { _ = token }
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
            handler: @escaping @MainActor (HostPointerSample) -> Void,
            tapDisabled: @escaping @MainActor (String) -> Void
        ) -> AnyObject? {
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
        /// Delivers through the consuming tap rather than the monitor.
        func emitCaptured(_ sample: HostPointerSample) {
            captureHandler?(sample)
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
        func hideFileEdge(_ token: AnyObject) {
            _ = token
            fileCallbacks = nil
        }
        func beginFileDrag(_ item: HostFileDragItem,
                           at screenPoint: CGPoint) -> Bool {
            fileDrags.append((item, screenPoint))
            return true
        }
        func emit(_ sample: HostPointerSample) { handler?(sample) }
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
}
