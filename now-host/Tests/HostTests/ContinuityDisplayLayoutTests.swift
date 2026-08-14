import AppKit
import MirrorKit
import MirrorKitUI
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

        XCTAssertEqual(guest.x, 24)
        XCTAssertEqual(guest.y, 450)
        XCTAssertEqual(returned.x, 1439)
        XCTAssertEqual(returned.y, 600)
    }

    private func makeLayout() -> ContinuityDisplayLayout {
        ContinuityDisplayLayout(hostDisplays: [host],
                                guestSize: CGSize(width: 800, height: 600),
                                defaults: nil, observeScreens: false)
    }
}
