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

    func testUnconfirmedIsTerminalOnlyWithoutAPostcondition() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        let at = Date(timeIntervalSince1970: 2)
        let direct = MirrorOperation(
            id: "op-direct", source: .mcp, displayedSnapshotID: 1,
            displayedSequence: 1, target: .process(process),
            postcondition: nil, enqueuedAt: Date(timeIntervalSince1970: 1))
        let settled = MirrorOperationReducer.reduce(
            direct, event: .unconfirmed(at: at))

        XCTAssertEqual(settled.outcome, .unconfirmed)
        XCTAssertEqual(settled.dispatchedAt, at)
        XCTAssertEqual(settled.settledAt, at)
        XCTAssertTrue(settled.outcome.isTerminal)

        let observable = MirrorOperation(
            id: "op-observable", source: .mcp, displayedSnapshotID: 1,
            displayedSequence: 1, target: .process(process),
            postcondition: .processFront(process), enqueuedAt: Date())
        XCTAssertEqual(MirrorOperationReducer.reduce(
            observable, event: .unconfirmed(at: at)), observable,
            "an observable effect must not bypass later evidence")
    }

    func testPostDispatchRefusalCanBeCorrectedByLaterAuthoritativeEvidence() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        var operation = MirrorOperation(
            id: "op-refused-late", source: .human, displayedSnapshotID: 3,
            displayedSequence: 3, target: .process(process),
            postcondition: .processFront(process), enqueuedAt: Date())
        operation = MirrorOperationReducer.reduce(
            operation, event: .dispatched(at: Date(timeIntervalSince1970: 2)))
        operation = MirrorOperationReducer.reduce(
            operation, event: .refused(
                reason: "a later composite stage was refused",
                at: Date(timeIntervalSince1970: 3),
                effectMayHaveLanded: true))

        XCTAssertEqual(operation.outcome, .awaitingEvidenceAfterRefusal)
        XCTAssertNil(operation.settledAt)
        XCTAssertEqual(operation.reason,
                       "a later composite stage was refused")

        let complete = MirrorSettlementEvidence(
            session: session, sequence: 4,
            coverage: .init(scope: "processes", status: .complete),
            receivedAt: Date(timeIntervalSince1970: 4),
            frontProcess: process)
        operation = MirrorOperationReducer.reduce(
            operation, event: .observation(complete))

        XCTAssertEqual(operation.outcome, .confirmedAfterRefusal)
        XCTAssertEqual(operation.settledSequence, 4)
        XCTAssertEqual(operation.reason,
                       "a later composite stage was refused",
                       "contradictory dispatch evidence remains inspectable")
    }

    func testPreDispatchRefusalCannotBeOverriddenByMatchingScene() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-finder")
        var operation = MirrorOperation(
            id: "op-safety-refused", source: .human, displayedSnapshotID: 1,
            displayedSequence: 1, target: .process(process),
            postcondition: .processFront(process), enqueuedAt: Date())
        operation = MirrorOperationReducer.reduce(
            operation, event: .refused(reason: "stale capability", at: Date()))
        let matching = MirrorSettlementEvidence(
            session: session, sequence: 2,
            coverage: .init(scope: "processes", status: .complete),
            frontProcess: process)

        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(matching)), operation)
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

    func testExactWindowFrontAndNamedCreationNeedOwnerCompleteCoverage() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "process-now")
        let old = MirrorWindowIdentity(process: process,
                                       incarnation: "window-old")
        let workshop = MirrorWindowIdentity(process: process,
                                            incarnation: "window-workshop")
        let coverage = Scene.CoverageClaim(
            scope: "windows", owner: process.incarnation, status: .complete)
        let evidence = MirrorSettlementEvidence(
            session: session, sequence: 2, coverage: coverage,
            presentWindows: [old, workshop], frontWindow: workshop,
            windowTitles: [old: "Other", workshop: "New Old World"])

        for (id, target, postcondition) in [
            ("front", MirrorEntityIdentity.window(workshop),
             MirrorOperationPostcondition.windowFront(workshop)),
            ("create", MirrorEntityIdentity.process(process),
             MirrorOperationPostcondition.windowNamedPresent(
                owner: process, title: "New Old World")),
        ] {
            var operation = MirrorOperation(
                id: id, source: .human, displayedSnapshotID: 1,
                displayedSequence: 1, target: target,
                postcondition: postcondition, enqueuedAt: Date())
            operation = MirrorOperationReducer.reduce(
                operation, event: .dispatched(at: Date()))
            operation = MirrorOperationReducer.reduce(
                operation, event: .observation(evidence))
            XCTAssertEqual(operation.outcome, .confirmed, id)
        }

        var wrongOwner = evidence
        wrongOwner.coverage.owner = "some-other-process"
        var pending = MirrorOperation(
            id: "wrong-owner", source: .human, displayedSnapshotID: 1,
            displayedSequence: 1, target: .window(workshop),
            postcondition: .windowFront(workshop), enqueuedAt: Date())
        pending = MirrorOperationReducer.reduce(
            pending, event: .dispatched(at: Date()))
        XCTAssertEqual(MirrorOperationReducer.reduce(
            pending, event: .observation(wrongOwner)), pending)
    }

    func testVisibilityNeedsLaterCompleteExactGuestEvidence() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let finder = MirrorProcessIdentity(session: session,
                                           incarnation: "finder")
        let now = MirrorProcessIdentity(session: session,
                                        incarnation: "now")
        var operation = MirrorOperation(
            id: "hide-others", source: .human, displayedSnapshotID: 3,
            displayedSequence: 4, target: .process(now),
            postcondition: .processVisibility([finder: false, now: true]),
            enqueuedAt: Date())
        operation = MirrorOperationReducer.reduce(
            operation, event: .dispatched(at: Date()))

        let stale = MirrorSettlementEvidence(
            session: session, sequence: 5,
            coverage: .init(scope: "process-visibility", status: .stale),
            processVisibility: [finder: false, now: true])
        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(stale)), operation)

        let wrong = MirrorSettlementEvidence(
            session: session, sequence: 5,
            coverage: .init(scope: "process-visibility", status: .complete),
            processVisibility: [finder: true, now: true])
        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(wrong)), operation)

        let exact = MirrorSettlementEvidence(
            session: session, sequence: 5,
            coverage: .init(scope: "process-visibility", status: .complete),
            receivedAt: Date(),
            processVisibility: [finder: false, now: true])
        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(exact)).outcome, .confirmed)
    }

    func testNamedProcessLaunchNeedsLaterCompleteProcessCensus() {
        let session = MirrorGuestSession(guest: "maxbook",
                                         incarnation: "session-a")
        let now = MirrorProcessIdentity(session: session,
                                        incarnation: "now")
        let keyCaps = MirrorProcessIdentity(session: session,
                                            incarnation: "key-caps")
        var operation = MirrorOperation(
            id: "key-caps", source: .human, displayedSnapshotID: 1,
            displayedSequence: 1, target: .process(now),
            postcondition: .processNamedPresent("Key Caps"),
            enqueuedAt: Date())
        operation = MirrorOperationReducer.reduce(
            operation, event: .dispatched(at: Date()))
        let evidence = MirrorSettlementEvidence(
            session: session, sequence: 2,
            coverage: .init(scope: "processes", status: .complete),
            processNames: [now: "New Old World", keyCaps: "Key Caps"])

        XCTAssertEqual(MirrorOperationReducer.reduce(
            operation, event: .observation(evidence)).outcome, .confirmed)
    }
}
