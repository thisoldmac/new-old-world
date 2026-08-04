import XCTest
@testable import MirrorKit

final class MirrorOperationReducerTests: XCTestCase {
    func testCloseNeedsCompleteAbsenceAndCanConfirmAfterTimeout() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        let window = MirrorWindowIdentity(process: process,
                                          incarnation: "window-disk")
        var operation = MirrorOperation(
            id: "op-1", source: .human, displayedSnapshotID: 4,
            displayedSequence: 4,
            target: .window(window), postcondition: .windowAbsent(window),
            enqueuedAt: Date(timeIntervalSince1970: 1))

        operation = MirrorOperationReducer.reduce(
            operation, event: .dispatched(at: Date(timeIntervalSince1970: 2)))
        operation = MirrorOperationReducer.reduce(
            operation, event: .timedOut(at: Date(timeIntervalSince1970: 3)))
        XCTAssertEqual(operation.outcome, .timedOut)

        let partial = MirrorSettlementEvidence(
            session: session, sequence: 5,
            coverage: .init(scope: "windows", owner: process.incarnation,
                            status: .partial), presentWindows: [])
        operation = MirrorOperationReducer.reduce(operation,
                                                  event: .observation(partial))
        XCTAssertEqual(operation.outcome, .timedOut)

        let complete = MirrorSettlementEvidence(
            session: session, sequence: 6,
            coverage: .init(scope: "windows", owner: process.incarnation,
                            status: .complete), presentWindows: [])
        operation = MirrorOperationReducer.reduce(
            operation, event: .observation(complete))
        XCTAssertEqual(operation.outcome, .confirmedAfterTimeout)
        XCTAssertEqual(operation.settledSequence, 6)
    }

    func testRefusalAndSessionChangeAreTerminal() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        let base = MirrorOperation(
            id: "op-2", source: .human, displayedSnapshotID: 1,
            displayedSequence: 1,
            target: .process(process), postcondition: .processFront(process),
            enqueuedAt: Date())
        let refused = MirrorOperationReducer.reduce(
            base, event: .refused(reason: "capability-expired", at: Date()))
        XCTAssertEqual(refused.outcome, .refused)
        XCTAssertEqual(MirrorOperationReducer.reduce(
            refused, event: .sessionChanged(at: Date())), refused)
    }

    func testQueuedOperationCannotBeConfirmedByObservation() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        let queued = MirrorOperation(
            id: "op-3", source: .human, displayedSnapshotID: 1,
            displayedSequence: 1,
            target: .process(process), postcondition: .processFront(process),
            enqueuedAt: Date())
        let evidence = MirrorSettlementEvidence(
            session: session, sequence: 2,
            coverage: .init(scope: "processes", status: .complete),
            frontProcess: process)

        XCTAssertEqual(MirrorOperationReducer.reduce(
            queued, event: .observation(evidence)), queued)
    }

    func testObservationMustBeLaterThanDisplayedSnapshot() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        var operation = MirrorOperation(
            id: "op-4", source: .human, displayedSnapshotID: 8,
            displayedSequence: 12, target: .process(process),
            postcondition: .processFront(process), enqueuedAt: Date())
        operation = MirrorOperationReducer.reduce(
            operation, event: .dispatched(at: Date()))
        let old = MirrorSettlementEvidence(
            session: session, sequence: 12,
            coverage: .init(scope: "processes", status: .complete),
            frontProcess: process)

        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(old)), operation)
    }
}
