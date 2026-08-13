import AppKit
import MirrorKit
import XCTest
@testable import Host

@MainActor
final class ContinuityDisplayLayoutTests: XCTestCase {
    private let host = HostDisplayDescriptor(
        id: 41, name: "Studio Display",
        frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
        pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)

    func testHostArrangementIsReadFromDescriptorsAndGuestDefaultsToAnEdge() {
        let layout = makeLayout()

        XCTAssertEqual(layout.hostDisplays, [host])
        XCTAssertEqual(layout.guestSize, CGSize(width: 800, height: 600))
        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 300, width: 800, height: 600))
        XCTAssertEqual(layout.sharedEdge?.host.id, host.id)
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
        XCTAssertEqual(layout.sharedEdge?.overlap, 300 ... 900)
    }

    func testDefaultGuestUsesAnExteriorEdgeWhenHostsAlreadyTouch() {
        let builtIn = HostDisplayDescriptor(
            id: 42, name: "Built-in Retina Display",
            frame: CGRect(x: 1440, y: 0, width: 982, height: 638),
            pixelSize: CGSize(width: 3024, height: 1964), isPrimary: false)

        let layout = ContinuityDisplayLayout(
            hostDisplays: [host, builtIn],
            guestSize: CGSize(width: 800, height: 600), defaults: nil,
            observeScreens: false)

        XCTAssertEqual(layout.guestOrigin, CGPoint(x: 2422, y: 38))
        XCTAssertEqual(layout.sharedEdge?.host.id, builtIn.id)
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
    }

    func testScaleKeepsTheAttachedGuestEdgeFixed() {
        let layout = makeLayout()

        layout.selectScale(.half)

        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 300, width: 400, height: 300))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
    }

    func testMovingGuestNearHostSnapsItToARealSharedEdge() {
        let layout = makeLayout()
        layout.setGuestOrigin(CGPoint(x: 1410, y: 120))

        XCTAssertEqual(layout.guestOrigin, CGPoint(x: 1440, y: 120))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
    }

    func testMovingGuestNearHostAlsoAlignsNearbyScreenEdges() {
        let layout = makeLayout()

        layout.setGuestOrigin(CGPoint(x: 1410, y: 285))

        XCTAssertEqual(layout.guestOrigin, CGPoint(x: 1440, y: 300))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
    }

    func testGuestCannotOverlapAHostPastTheMagneticThreshold() {
        let layout = makeLayout()

        layout.setGuestOrigin(CGPoint(x: 800, y: 100))

        XCTAssertFalse(layout.guestFrame.intersects(host.frame))
        XCTAssertNotNil(layout.sharedEdge)
    }

    func testGuestCannotOverlapAnyDisplayInAHostArrangement() {
        let builtIn = HostDisplayDescriptor(
            id: 42, name: "Built-in Retina Display",
            frame: CGRect(x: 1440, y: 0, width: 982, height: 638),
            pixelSize: CGSize(width: 3024, height: 1964), isPrimary: false)
        let layout = ContinuityDisplayLayout(
            hostDisplays: [host, builtIn],
            guestSize: CGSize(width: 800, height: 600), defaults: nil,
            observeScreens: false)

        layout.setGuestOrigin(CGPoint(x: 1800, y: 50))

        XCTAssertFalse(layout.guestFrame.intersects(host.frame))
        XCTAssertFalse(layout.guestFrame.intersects(builtIn.frame))
        XCTAssertNotNil(layout.sharedEdge)
    }

    func testStoredOverlappingPlacementIsMadeCollisionFreeOnLoad() {
        let suite = "ContinuityDisplayLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "mirror.continuity.hasGuestDisplayOrigin")
        defaults.set(800.0, forKey: "mirror.continuity.guestDisplayOriginX")
        defaults.set(100.0, forKey: "mirror.continuity.guestDisplayOriginY")

        let layout = ContinuityDisplayLayout(
            hostDisplays: [host], guestSize: CGSize(width: 800, height: 600),
            defaults: defaults, observeScreens: false)

        XCTAssertFalse(layout.guestFrame.intersects(host.frame))
        XCTAssertNotNil(layout.sharedEdge)
    }

    func testGuestEdgeCoordinatesMapAtScaledResolution() throws {
        let layout = makeLayout()
        layout.selectScale(.double)
        let edge = try XCTUnwrap(layout.sharedEdge)

        let guest = ContinuityDisplayGeometry.guestEntryPoint(
            at: CGPoint(x: 1440, y: 600), edge: edge,
            guestFrame: layout.guestFrame, guestPixels: layout.guestSize,
            scale: layout.guestScale)
        let returned = ContinuityDisplayGeometry.hostReturnPoint(
            for: guest, edge: edge, guestFrame: layout.guestFrame,
            scale: layout.guestScale)

        XCTAssertEqual(guest.x, 0)
        XCTAssertEqual(guest.y, 450)
        XCTAssertEqual(returned.x, 1439)
        XCTAssertEqual(returned.y, 600)
    }

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
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 0, y: 300))
        XCTAssertTrue(environment.hidden.isEmpty,
                      "the host cursor stays visible until the guest owns it")

        controller.transportPhaseChanged(.active)
        XCTAssertEqual(controller.state, .active)
        XCTAssertEqual(environment.hidden, [host.id])

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: 12, y: 0),
                               buttonsDown: false))
        XCTAssertEqual(driver.points.last, MirrorKit.Point(x: 12, y: 300))

        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 600),
                               delta: CGPoint(x: -20, y: 0),
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
        XCTAssertEqual(driver.downPoints, [MirrorKit.Point(x: 0, y: 450)])
        XCTAssertEqual(driver.upPoints, [MirrorKit.Point(x: 0, y: 450)])
        XCTAssertTrue(environment.shown.isEmpty)
        XCTAssertEqual(environment.moves.last?.displayID, host.id)
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
                       [MirrorKit.Point(x: 8, y: 455)])
        XCTAssertTrue(environment.shown.isEmpty)
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

    private func makeLayout() -> ContinuityDisplayLayout {
        ContinuityDisplayLayout(hostDisplays: [host],
                                guestSize: CGSize(width: 800, height: 600),
                                defaults: nil, observeScreens: false)
    }
}

private extension ContinuityDisplayLayoutTests {
    final class Driver: ContinuityEdgeDriving {
        var keyboardForwardingEnabled = true
        var escapeShortcut = ContinuityEscapeShortcut.controlOptionEscape
        var points: [MirrorKit.Point] = []
        var leftCount = 0
        var downPoints: [MirrorKit.Point] = []
        var draggedPoints: [MirrorKit.Point] = []
        var upPoints: [MirrorKit.Point] = []
        var keys: [HostKeySample] = []

        func pointerMoved(to point: MirrorKit.Point) { points.append(point) }
        func pointerLeft() { leftCount += 1 }
        func primaryDown(at point: MirrorKit.Point,
                         inMenuBar: Bool) -> Bool {
            _ = inMenuBar
            downPoints.append(point)
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
        func emit(_ sample: HostPointerSample) { handler?(sample) }
    }

    final class KeyboardEnvironment: ContinuityKeyboardEnvironment {
        final class Token: NSObject {}
        var handler: (@MainActor (HostKeySample) -> Bool)?
        var stopCount = 0

        func start(_ handler: @escaping @MainActor (HostKeySample) -> Bool)
            -> AnyObject? {
            self.handler = handler
            return Token()
        }
        func stop(_ token: AnyObject) {
            _ = token
            stopCount += 1
            handler = nil
        }
        func emit(_ sample: HostKeySample) -> Bool {
            handler?(sample) ?? false
        }
    }
}
