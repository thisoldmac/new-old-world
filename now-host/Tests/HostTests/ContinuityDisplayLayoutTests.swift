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

        // 900-tall host against a 600-tall guest across a vertical edge, and
        // the fitted guest is FLUSH with the host edge rather than merely the
        // right size somewhere along it.
        XCTAssertEqual(layout.guestScale, 1.5)
        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 0, width: 1200, height: 900))
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
        XCTAssertEqual(layout.sharedEdge?.overlap, 0 ... 900,
                       "a fitted edge shares the host's whole extent")

        layout.selectScaleMode(.native)

        // Native restores the true pixel size but not the pre-Fit position:
        // placement is free again, and free means left where it is.
        XCTAssertEqual(layout.guestScale, 1)
        XCTAssertEqual(layout.guestFrame,
                       CGRect(x: 1440, y: 0, width: 800, height: 600))
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

    /* Sizing without placing is not fitting: a guest of exactly the right
       length sitting halfway up the edge still leaves a gap at one end. */
    func testFitAlignsTheGuestFlushWithAVerticalHostEdge() throws {
        let edge = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 1440, y: 300, width: 800, height: 600)))

        // 800x600 fitted at 1.5 across the vertical edge is 1200x900.
        let origin = ContinuityDisplayGeometry.fittedOrigin(
            fittedSize: CGSize(width: 1200, height: 900), edge: edge,
            current: CGPoint(x: 1440, y: 300))

        XCTAssertEqual(origin, CGPoint(x: 1440, y: 0))
        // The across-the-edge coordinate is the attachment and is untouched.
        XCTAssertEqual(origin.x, 1440)
    }

    func testFitAlignsTheGuestFlushWithAHorizontalHostEdge() throws {
        let edge = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 400, y: 900, width: 800, height: 600)))

        // 800x600 fitted at 1.8 across the horizontal edge is 1440x1080.
        let origin = ContinuityDisplayGeometry.fittedOrigin(
            fittedSize: CGSize(width: 1440, height: 1080), edge: edge,
            current: CGPoint(x: 400, y: 900))

        XCTAssertEqual(origin, CGPoint(x: 0, y: 900))
        XCTAssertEqual(origin.y, 900)
    }

    /* Which END the alignment is flush to is invisible in the ordinary case,
       because a guest edge of exactly the host's length starts at the host's
       minimum and ends at its maximum either way. A guest edge SHORTER than
       the host's is the only case that can tell "flush to the start" from
       "flush to the end" apart, so the rule is pinned here. Fit itself cannot
       produce it - the scale would have grown the guest - but this is the
       promise `fittedOrigin` makes to any caller, and without this assertion
       a mutation swapping the two ends passes every other test in the file. */
    func testAlignmentIsFlushToTheStartOfTheHostEdgeNotTheEnd() throws {
        let edge = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 1440, y: 300, width: 800, height: 600)))

        let origin = ContinuityDisplayGeometry.fittedOrigin(
            fittedSize: CGSize(width: 800, height: 600), edge: edge,
            current: CGPoint(x: 1440, y: 300))

        // Flush to the host's minY (0), NOT to maxY - height (900 - 600).
        XCTAssertEqual(origin.y, 0)
        XCTAssertNotEqual(origin.y, 300)
    }

    /* Spanning is impossible once the guest edge is longer than the host's,
       so the only question is where the overhang goes. Centred keeps the
       host edge covered at both ends. */
    func testAGuestTooLongToSpanIsCentredOnTheHostEdge() throws {
        let edge = try XCTUnwrap(ContinuityDisplayGeometry.sharedEdge(
            hosts: [host],
            guest: CGRect(x: 1440, y: 0, width: 1600, height: 2000)))

        let origin = ContinuityDisplayGeometry.fittedOrigin(
            fittedSize: CGSize(width: 1600, height: 2000), edge: edge,
            current: CGPoint(x: 1440, y: 0))

        // (900 - 2000) / 2 = -550: the overhang is split between both ends.
        XCTAssertEqual(origin, CGPoint(x: 1440, y: -550))
        XCTAssertEqual(origin.y + 2000 - 900, -origin.y,
                       "the excess above the host equals the excess below")
    }

    func testFitLeavesAnUnattachedGuestWhereItWasPut() {
        let layout = makeLayout()
        layout.selectScaleMode(.fit)

        // Far enough that nothing snaps and no edge is shared.
        layout.setGuestOrigin(CGPoint(x: 3000, y: 1800))
        layout.finishGuestMove()

        XCTAssertNil(layout.sharedEdge)
        XCTAssertEqual(layout.guestOrigin, CGPoint(x: 3000, y: 1800))
        XCTAssertEqual(layout.guestScale, 1, "Fit is Native until reattached")
    }

    /* A drag in Fit mode still chooses WHICH edge; alignment then chooses
       the position along it, and only once the drag has ended. */
    func testDraggingInFitModeChoosesTheEdgeAndAlignmentChoosesThePosition() {
        let below = HostDisplayDescriptor(
            id: 43, name: "Sidecar",
            frame: CGRect(x: 0, y: -700, width: 1000, height: 700),
            pixelSize: CGSize(width: 1000, height: 700), isPrimary: false)
        let layout = ContinuityDisplayLayout(
            hostDisplays: [host, below], guestSize: CGSize(width: 800,
                                                           height: 600),
            defaults: nil, observeScreens: false)
        layout.selectScaleMode(.fit)

        // Mid-drag the guest is wherever the pointer put it: no realignment
        // is allowed to fight the gesture.
        layout.setGuestOrigin(CGPoint(x: 1010, y: -890))
        let midDrag = layout.guestOrigin
        XCTAssertEqual(midDrag.y, -900, "still at the dragged position")

        layout.finishGuestMove()

        XCTAssertEqual(layout.sharedEdge?.host.id, below.id)
        XCTAssertEqual(layout.sharedEdge?.guestSide, .left)
        // Attached to the 700-tall Sidecar now, so the fit is 700/600.
        XCTAssertEqual(layout.guestScale, 700.0 / 600.0, accuracy: 0.0001)
        XCTAssertEqual(layout.guestOrigin.y, -700,
                       "settled flush with the new host's edge")
        XCTAssertNotEqual(layout.guestOrigin, midDrag)
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
        // (900 top of the fitted, aligned frame - 600) / 1.5, not the
        // native 600.
        XCTAssertEqual(guest.y, 200)
        XCTAssertEqual(returned.x, 1439)
        XCTAssertEqual(returned.y, 600)
    }

    private func makeLayout() -> ContinuityDisplayLayout {
        ContinuityDisplayLayout(hostDisplays: [host],
                                guestSize: CGSize(width: 800, height: 600),
                                defaults: nil, observeScreens: false)
    }
}
