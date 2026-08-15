import AppKit
import CoreGraphics
import XCTest
@testable import Host

/// One `HostPointerSample` has two producers — the CGEvent tap and the
/// NSEvent monitors — and everything downstream reads `buttonsDown` as the
/// truth about the human's finger. These assert the two agree.
///
/// They exist because they did not. The tap derived `buttonsDown` from the
/// event TYPE, so a cursor warp's synthetic `mouseMoved` read as a release
/// while the button was physically held; the NSEvent adapter had always read
/// `pressedMouseButtons`. Only the NSEvent half ever ran, because the tap
/// needs Accessibility and this Mac had not granted it — so the disagreement
/// shipped invisible and surfaced the morning permission was granted, as
/// three guest→host file drags abandoned mid-gesture (metal, 2026-08-15).
final class ContinuityPointerSampleTests: XCTestCase {

    /// The metal defect, in one assertion.
    func testAWarpedMouseMovedWhileHeldIsNotReadAsARelease() throws {
        let sample = try XCTUnwrap(tapSample(.mouseMoved, held: true))
        XCTAssertTrue(sample.buttonsDown,
                      "a cursor warp synthesizes a mouseMoved with the "
                        + "button still down; calling that a release "
                        + "abandons whatever gesture is in flight")
        XCTAssertEqual(sample.kind, .moved)
    }

    func testAnUnheldMouseMovedIsStillAnUnheldMove() throws {
        let sample = try XCTUnwrap(tapSample(.mouseMoved, held: false))
        XCTAssertFalse(sample.buttonsDown)
    }

    /// The one place the type outranks the button state: a read taken as the
    /// release goes by can still say "held", and honouring it would keep a
    /// press alive past its own end.
    func testAReleaseIsAReleaseEvenIfTheSessionStillReadsHeld() throws {
        let sample = try XCTUnwrap(tapSample(.leftMouseUp, held: true))
        XCTAssertEqual(sample.kind, .primaryUp)
        XCTAssertFalse(sample.buttonsDown)
    }

    func testADraggedEventNeedsNoSecondOpinion() throws {
        let held = try XCTUnwrap(tapSample(.leftMouseDragged, held: false))
        XCTAssertTrue(held.buttonsDown,
                      "leftMouseDragged means the primary button is down by "
                        + "definition")
        let down = try XCTUnwrap(tapSample(.leftMouseDown, held: false))
        XCTAssertTrue(down.buttonsDown)
    }

    /// A right-drag is not a primary drag — but it is also not proof that
    /// the primary button came up.
    func testASecondaryDragReportsThePrimaryButtonHonestly() throws {
        let alone = try XCTUnwrap(tapSample(.rightMouseDragged, held: false))
        XCTAssertFalse(alone.buttonsDown)
        XCTAssertEqual(alone.kind, .moved)
        let both = try XCTUnwrap(tapSample(.rightMouseDragged, held: true))
        XCTAssertTrue(both.buttonsDown)
    }

    // MARK: - The NSEvent monitors, one layer deeper

    /// The monitor half of the same defect. `pressedMouseButtons` reads the
    /// session's event state, which this app's own consuming tap starves —
    /// a swallowed `leftMouseDown` never reaches it — so every monitor
    /// sample of a captured gesture reads button-up, and the window server
    /// keeps synthesizing plain `mouseMoved` rather than `leftMouseDragged`
    /// for the same reason. On metal (2026-08-15 02:48) that abandoned four
    /// bound handoffs on the first post-teardown sample, in the same second
    /// as their crossings.
    func testAMonitorMouseMovedWhileHeldIsNotReadAsARelease() throws {
        let sample = AppKitContinuityPointerEnvironment.sample(
            try monitorEvent(.mouseMoved), primaryHeld: { true })
        XCTAssertTrue(sample.buttonsDown,
                      "the session state cannot see past this app's own "
                        + "tap; only the HID read can")
        XCTAssertEqual(sample.kind, .moved)
    }

    func testAMonitorMouseUpIsAReleaseWhateverTheHardwareReads() throws {
        let sample = AppKitContinuityPointerEnvironment.sample(
            try monitorEvent(.leftMouseUp), primaryHeld: { true })
        XCTAssertEqual(sample.kind, .primaryUp)
        XCTAssertFalse(sample.buttonsDown)
    }

    func testAMonitorDraggedEventNeedsNoSecondOpinionEither() throws {
        let sample = AppKitContinuityPointerEnvironment.sample(
            try monitorEvent(.leftMouseDragged), primaryHeld: { false })
        XCTAssertTrue(sample.buttonsDown)
        let down = AppKitContinuityPointerEnvironment.sample(
            try monitorEvent(.leftMouseDown), primaryHeld: { false })
        XCTAssertTrue(down.buttonsDown)
        XCTAssertEqual(down.kind, .primaryDown)
    }

    private func monitorEvent(_ type: NSEvent.EventType) throws -> NSEvent {
        try XCTUnwrap(NSEvent.mouseEvent(
            with: type, location: CGPoint(x: 10, y: 20), modifierFlags: [],
            timestamp: 12, windowNumber: 0, context: nil, eventNumber: 7,
            clickCount: 1, pressure: 1))
    }

    private func tapSample(_ type: CGEventType, held: Bool)
        -> HostPointerSample? {
        guard let event = CGEvent(
            mouseEventSource: nil, mouseType: type,
            mouseCursorPosition: CGPoint(x: 10, y: 20), mouseButton: .left)
        else { return nil }
        return AppKitContinuityPointerEnvironment.sample(
            event, type: type, flipHeight: 900, primaryHeld: { held })
    }
}
