import XCTest
@testable import MirrorKit

/// The presentation contract Michelle gave for slice 10.5, one test per rule.
///
/// These drive `ItemDragSession` directly, which is the same type
/// `LiveMirrorView` holds — the view was moved onto it precisely so that this
/// file tests the code that runs rather than a second copy of the rules.
final class ItemDragSessionTests: XCTestCase {

    private static let home = Rect(l: 40, t: 60, r: 72, b: 104)

    private static func subject() -> DragTargeting.Subject {
        .desktopItem(.init(name: "Read Me", kind: "file", type: nil,
                           creator: nil, x: 40, y: 60, placed: true,
                           alias: false, invisible: false,
                           w: 32, h: 32, origin: .drawn))
    }

    private static func session(grabAt p: Point = Point(x: 56, y: 76))
        -> ItemDragSession {
        .init(subject: subject(), home: home, grabbedAt: p)
    }

    private static func aPlan() -> DragTargeting.Plan {
        .init(subject: subject(), home: home,
              destination: .desktop(x: 500, y: 400), intent: .rearrange)
    }

    // MARK: - Rule 1: the item moves immediately

    /// Mutation: gate `move(to:)` on `confirmed`. The item then sits still
    /// under a moving pointer until the guest answers — which is the "feels
    /// dead" failure the contract's first rule exists to forbid.
    func testTheItemMovesBeforeAnyConfirmation() {
        var s = Self.session()
        XCTAssertFalse(s.confirmed)
        s.move(to: Point(x: 200, y: 300))
        XCTAssertTrue(s.frame != Self.home,
                      "rule 1: the ghost does not wait for the guest")
        /* And it keeps the grab offset — the pointer took hold 16 in and 16
           down, so the box stays 16 in and 16 down from the pointer. */
        XCTAssertEqual(s.frame, Rect(l: 184, t: 284, r: 216, b: 328))
        XCTAssertFalse(s.confirmed, "moving is not confirming")
    }

    /// Mutation: make `confirmed` settable, or default it true. Rule 2's
    /// honesty is that nothing but a guest answer opens that door.
    func testConfirmationHasExactlyOneDoor() {
        var s = Self.session()
        s.move(to: Point(x: 200, y: 300))
        XCTAssertFalse(s.confirmed)
        s.confirm()
        XCTAssertTrue(s.confirmed)
    }

    // MARK: - Rule 3: released before confirmation

    /// Mutation: test the destination before `confirmed`. A release before
    /// the guest answered then produces a refusal about the TARGET, which
    /// hides the fact that nothing was ever picked up.
    func testReleasingBeforeConfirmationSnapsHome() {
        let s = Self.session()
        switch s.release(.success(Self.aPlan())) {
        case .drop:
            XCTFail("nothing was picked up — there is nothing to drop")
        case .snapBack(let why):
            XCTAssertTrue(why.contains("before the guest confirmed"), why)
            XCTAssertTrue(why.contains("Read Me"),
                          "the person needs to know WHICH item went back")
        }
    }

    /// Even with a perfectly good destination. Stated separately because the
    /// tempting implementation checks the plan first and only then the
    /// confirmation, and it passes every test where the plan also fails.
    func testAValidTargetDoesNotRescueAnUnconfirmedDrag() {
        let s = Self.session()
        guard case .snapBack = s.release(.success(Self.aPlan())) else {
            return XCTFail("a valid target is not a confirmation")
        }
    }

    /// **Unconfirmed AND badly aimed, which is the case that pins the
    /// ORDER.** The mutation that checks the plan first still passes every
    /// test above: with a valid plan it falls through to the confirmation
    /// check anyway. Only here do the two answers differ, and only one of
    /// them is true — nothing was picked up, so where the pointer ended is
    /// not the reason the item is going back.
    func testAnUnconfirmedDragIsAboutTheGrabAndNotTheTarget() {
        let s = Self.session()
        switch s.release(.failure(.notADropTarget(what: "a scroll bar"))) {
        case .drop:
            XCTFail("nothing was picked up")
        case .snapBack(let why):
            XCTAssertTrue(why.contains("before the guest confirmed"),
                          "the reason must be the grab, not the target: "
                          + why)
            XCTAssertFalse(why.contains("scroll bar"), why)
        }
    }

    // MARK: - Rule 4: the guest refused

    /// Mutation: treat `refused` as a no-op and leave the ghost in flight.
    /// The item then hangs under the pointer after the guest has declined,
    /// which asserts a state the guest is not in.
    func testARefusedPressSnapsHome() {
        var s = Self.session()
        s.move(to: Point(x: 300, y: 300))
        switch s.refused("the plane is not armed") {
        case .drop: XCTFail("a refusal is not a drop")
        case .snapBack(let why):
            XCTAssertTrue(why.contains("would not take Read Me"), why)
            XCTAssertTrue(why.contains("the plane is not armed"),
                          "the guest's own reason survives to the status "
                          + "line: \(why)")
        }
    }

    /// `kNowPeekDragEndSessionLost` arrives through the same door. The
    /// resident releases the button and never reports the gesture as
    /// completed; this side must agree.
    func testALostSessionIsASnapBackAndNotADrop() {
        let s = Self.session()
        guard case .snapBack(let why) = s.refused("session lost") else {
            return XCTFail("a lost session must never read as completed")
        }
        XCTAssertTrue(why.contains("session lost"))
    }

    // MARK: - The happy ending

    func testAConfirmedDragOntoARealTargetDrops() {
        var s = Self.session()
        s.confirm()
        guard case .drop(let plan) = s.release(.success(Self.aPlan())) else {
            return XCTFail("a confirmed drag onto a real target drops")
        }
        XCTAssertEqual(plan.intent, .rearrange)
    }

    /// Confirmed, but the pointer ended on a scroll bar: the gesture was real
    /// and its destination was not, so the same snap-back — in the targeting
    /// layer's own words rather than a second phrasing of them.
    func testAConfirmedDragOntoNothingSnapsHome() {
        var s = Self.session()
        s.confirm()
        let refusal = DragTargeting.Refusal.notADropTarget(what: "a scroll bar")
        switch s.release(.failure(refusal)) {
        case .drop: XCTFail("a scroll bar is not a destination")
        case .snapBack(let why):
            XCTAssertTrue(why.contains(refusal.message),
                          "one phrasing of a refusal, not two: \(why)")
            XCTAssertTrue(why.contains("went back"))
        }
    }

    /// Home is never touched by anything the gesture does. Mutation: update
    /// `home` in `move(to:)` and the snap-back returns the item to wherever
    /// the pointer last was, which is the failure with a file attached.
    func testHomeSurvivesTheWholeGesture() {
        var s = Self.session()
        s.move(to: Point(x: 400, y: 400))
        s.confirm()
        s.move(to: Point(x: 10, y: 10))
        XCTAssertEqual(s.home, Self.home)
    }
}
