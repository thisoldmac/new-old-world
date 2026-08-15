import CoreGraphics
import XCTest

@testable import Host

/// The sentence the next metal round reads, tested where it can be tested:
/// as a value, with no tap, no mouse and no live drag session — none of
/// which a test process has.
@MainActor
final class ContinuityDragWitnessTests: XCTestCase {
    private static let ourPID: Int64 = 4242

    private static func event(
        type: UInt32, at uptime: TimeInterval, pid: Int64 = 0,
        sourceStateID: Int64 = 1, hidHeld: Bool = true,
        sessionHeld: Bool = true
    ) -> ContinuityWitnessedEvent {
        ContinuityWitnessedEvent(
            type: type, location: CGPoint(x: 1520, y: 379), sourcePID: pid,
            sourceStateID: sourceStateID, uptime: uptime,
            hidPrimaryHeld: hidHeld, sessionPrimaryHeld: sessionHeld)
    }

    private static func report(
        _ witness: ContinuityDragWitness, seededAt: TimeInterval = 100,
        endedAt: TimeInterval = 102, hidHeldAtEnd: Bool = true,
        sessionHeldAtEnd: Bool = false
    ) -> ContinuityDragWitnessReport {
        ContinuityDragWitnessReport(
            witness: witness, seededAt: seededAt, endedAt: endedAt,
            hidHeldAtEnd: hidHeldAtEnd, sessionHeldAtEnd: sessionHeldAtEnd,
            catchSurface: ContinuityCatchHitTest(serverTopWindowNumber: 3089,
                                                 panelWindowNumber: 3089),
            ownPID: ourPID)
    }

    /// The whole point of the instrument. Every field the log carried before
    /// it was identical for a release the hardware produced and one this app
    /// posted itself; these two are not.
    func testAReleaseThisAppPostedIsNamedAsThisAppsOwn() {
        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.event(type: 6, at: 101))
        witness.record(Self.event(type: 2, at: 101.9, pid: Self.ourPID,
                                  sourceStateID: 0, sessionHeld: false))
        let verdict = Self.report(witness).verdict
        XCTAssertTrue(verdict.contains("ended by a session leftMouseUp"),
                      verdict)
        XCTAssertTrue(verdict.contains("(this app)"), verdict)
        XCTAssertTrue(verdict.contains("(posted)"), verdict)
    }

    func testAReleaseFromTheHardwareIsNotBlamedOnThisApp() {
        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.event(type: 2, at: 101.9, pid: 0,
                                  sourceStateID: 1, hidHeld: false,
                                  sessionHeld: false))
        let verdict = Self.report(witness, hidHeldAtEnd: false).verdict
        XCTAssertTrue(verdict.contains("(not this app)"), verdict)
        XCTAssertTrue(verdict.contains("(hardware)"), verdict)
    }

    /// The discriminating case, and the reason this file exists. A session
    /// that ended with the button still held either saw a release or it did
    /// not, and only one of those two is a manufactured mouse-up.
    func testASessionThatSawNoReleaseSaysSoRatherThanBlamingOne() {
        var witness = ContinuityDragWitness(installed: true)
        for tick in 0..<40 {
            witness.record(Self.event(type: 6,
                                      at: 100 + Double(tick) * 0.05))
        }
        let verdict = Self.report(witness).verdict
        XCTAssertTrue(
            verdict.contains("NO session-level leftMouseUp was seen at all"),
            verdict)
        XCTAssertTrue(verdict.contains("a release is not what ended this "
                                       + "session"), verdict)
    }

    /// A release from an earlier gesture is history, not the ender. Without
    /// this the report would confidently name the wrong event whenever the
    /// human had clicked anything in the seconds before the cross.
    func testAReleaseTooOldToBeTheEnderIsNotNamedAsTheEnder() {
        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.event(type: 2, at: 100.2))
        witness.record(Self.event(type: 6, at: 101.5))
        let verdict = Self.report(witness).verdict
        XCTAssertTrue(verdict.contains("too far back to be the ender"),
                      verdict)
        XCTAssertFalse(verdict.contains("ended by a session leftMouseUp"),
                       verdict)
    }

    /// The armed-plane rule, one layer down: an instrument that never armed
    /// and a stream that carried nothing produce the same empty tally, and
    /// they must not produce the same sentence.
    func testAWitnessThatNeverArmedIsNotReportedAsAQuietStream() {
        let report = Self.report(ContinuityDragWitness(installed: false),
                                 hidHeldAtEnd: false)
        XCTAssertTrue(report.verdict.contains("no witness was installed"),
                      report.verdict)
        XCTAssertFalse(
            report.verdict.contains("NO session-level leftMouseUp"),
            "an uninstalled witness must not be read as evidence of absence")
        XCTAssertTrue(report.isSuspect,
                      "a session nobody watched cannot be reported as fine")
    }

    func testTheTallyCountsEachEventTypeUnderItsOwnName() {
        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.event(type: 1, at: 100))
        witness.record(Self.event(type: 6, at: 100.1))
        witness.record(Self.event(type: 6, at: 100.2))
        witness.record(Self.event(type: 5, at: 100.3))
        witness.record(Self.event(type: 2, at: 100.4))
        XCTAssertEqual(witness.counts,
                       "downs=1, ups=1, drags=2, moves=1")
        XCTAssertEqual(witness.lastUp?.uptime, 100.4)
    }

    /// The line carries elapsed time and the catch surface beside the
    /// verdict, because "the source window moved out from under it" is the
    /// other way a session ends with nobody releasing anything.
    func testTheSummaryCarriesElapsedAndTheCatchSurfaceBesideTheVerdict() {
        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.event(type: 6, at: 101))
        let summary = Self.report(witness).summary
        XCTAssertTrue(summary.contains("elapsed=2000ms"), summary)
        XCTAssertTrue(summary.contains("catchSurfaceAtSeed=serverTopWindow"
                                       + "=3089"), summary)
        XCTAssertTrue(summary.contains("hidHeldAtEnd=1"), summary)
        XCTAssertTrue(summary.contains("sessionHeldAtEnd=0"), summary)
    }
}
