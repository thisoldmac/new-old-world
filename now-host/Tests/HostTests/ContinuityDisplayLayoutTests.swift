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

    func testGuestStartsNativeAndFitGrowsFromTheAttachedEdge() {
        let layout = makeLayout()

        XCTAssertEqual(layout.scaleMode, .native)
        XCTAssertEqual(layout.guestScale, 1)

        layout.selectScaleMode(.fit)

        // 900-tall host against a 600-tall guest across a vertical edge.
        XCTAssertEqual(layout.guestScale, 1.5)
        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 300, width: 1200, height: 900))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)

        layout.selectScaleMode(.native)

        XCTAssertEqual(layout.guestScale, 1)
        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 300, width: 800, height: 600))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
    }

    /* The axis is the whole of this derivation: a vertical shared edge is
       matched on height and a horizontal one on width, and picking the wrong
       one still produces a plausible number on any host that is not square. */
    func testFitScaleMatchesTheAxisOfTheSharedEdge() throws {
        let vertical = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 1440, y: 300, width: 800, height: 600)))
        let horizontal = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 0, y: 900, width: 800, height: 600)))

        XCTAssertEqual(vertical.guestSide, .left)
        XCTAssertEqual(horizontal.guestSide, .bottom)
        XCTAssertEqual(
            ContinuityDisplayGeometry.fitScale(
                guestSize: CGSize(width: 800, height: 600), edge: vertical),
            1.5, "a vertical edge matches the host's 900 height / 600")
        XCTAssertEqual(
            ContinuityDisplayGeometry.fitScale(
                guestSize: CGSize(width: 800, height: 600), edge: horizontal),
            1.8, "a horizontal edge matches the host's 1440 width / 800")
    }

    func testFitNeverScalesTheGuestBelowNative() throws {
        let vertical = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 1440, y: 0, width: 1600, height: 2000)))

        // 900 / 2000 is 0.45; a guest taller than the host edge stays native.
        XCTAssertEqual(
            ContinuityDisplayGeometry.fitScale(
                guestSize: CGSize(width: 1600, height: 2000), edge: vertical), 1)
        // And with nothing attached there is no edge to match at all.
        XCTAssertEqual(
            ContinuityDisplayGeometry.fitScale(
                guestSize: CGSize(width: 800, height: 600), edge: nil), 1)
    }

    func testStoredNumericScaleIsMigratedToNative() {
        let suite = "ContinuityDisplayLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(4.0, forKey: "mirror.continuity.guestDisplayScale")

        let layout = ContinuityDisplayLayout(
            hostDisplays: [host], guestSize: CGSize(width: 800, height: 600),
            defaults: defaults, observeScreens: false)

        XCTAssertEqual(layout.scaleMode, .native)
        XCTAssertEqual(layout.guestScale, 1)
        XCTAssertNil(defaults.object(forKey: "mirror.continuity.guestDisplayScale"))
    }

    func testScaleModeIsRestoredPerMachine() {
        let suite = "ContinuityDisplayLayoutTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        ContinuityDisplayLayout(
            hostDisplays: [host], guestSize: CGSize(width: 800, height: 600),
            defaults: defaults, observeScreens: false).selectScaleMode(.fit)

        let restored = ContinuityDisplayLayout(
            hostDisplays: [host], guestSize: CGSize(width: 800, height: 600),
            defaults: defaults, observeScreens: false)

        XCTAssertEqual(restored.scaleMode, .fit)
        XCTAssertEqual(restored.guestScale, 1.5)
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

    /* Fit is a coordinate scale, not a drawing size: the pointer mapping has
       to divide by the same factor the arrangement grew by. */
    func testGuestEdgeCoordinatesMapAtTheFittedResolution() throws {
        let layout = makeLayout()
        layout.selectScaleMode(.fit)
        let edge = try XCTUnwrap(layout.sharedEdge)

        let guest = ContinuityDisplayGeometry.guestEntryPoint(
            at: CGPoint(x: 1440, y: 600), edge: edge,
            guestFrame: layout.guestFrame, guestPixels: layout.guestSize,
            scale: layout.guestScale)
        let returned = ContinuityDisplayGeometry.hostReturnPoint(
            for: guest, edge: edge, guestFrame: layout.guestFrame,
            scale: layout.guestScale)

        XCTAssertEqual(guest.x, 24)
        // (1200 top of the fitted frame - 600) / 1.5, not the native 600.
        XCTAssertEqual(guest.y, 400)
        XCTAssertEqual(returned.x, 1439)
        XCTAssertEqual(returned.y, 600)
    }

    private func makeLayout() -> ContinuityDisplayLayout {
        ContinuityDisplayLayout(hostDisplays: [host],
                                guestSize: CGSize(width: 800, height: 600),
                                defaults: nil, observeScreens: false)
    }
}
