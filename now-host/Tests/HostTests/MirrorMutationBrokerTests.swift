import XCTest
import MirrorKit
@testable import Host

@MainActor
final class MirrorMutationBrokerTests: XCTestCase {
    private let session = MirrorGuestSession(guest: "maxbook",
                                             incarnation: "session-a")

    func testFIFOBlocksSecondDispatchUntilFirstAuthoritativelySettles() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let first = operation(id: "first", process: process)
        let second = operation(id: "second", process: process)
        let broker = MirrorMutationBroker(timeout: 1)
        var dispatched: [String] = []
        var outcomes: [MirrorOperationOutcome] = []

        XCTAssertTrue(broker.enqueue(first, execute: {
            dispatched.append("first")
            return .init(complaint: nil, effectMayHaveLanded: true)
        }, report: { operation, _ in outcomes.append(operation.outcome) }))
        XCTAssertTrue(broker.enqueue(second, execute: {
            dispatched.append("second")
            return .init(complaint: nil, effectMayHaveLanded: true)
        }, report: { operation, _ in outcomes.append(operation.outcome) }))
        await Task.yield()
        XCTAssertEqual(dispatched, ["first"])

        broker.observe([processEvidence(process, sequence: 2)])
        await Task.yield()
        XCTAssertEqual(dispatched, ["first", "second"])
        XCTAssertTrue(outcomes.contains(.confirmed))
    }

    func testContradictoryActReplyStaysPendingThenConfirmsFromScene() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 1)
        var reports: [(MirrorOperationOutcome, String?)] = []
        XCTAssertTrue(broker.enqueue(operation(id: "op", process: process),
          execute: {
            .init(complaint: "winact select was refused",
                  effectMayHaveLanded: true)
          }, report: { reports.append(($0.outcome, $1)) }))
        await Task.yield()

        XCTAssertEqual(reports.first?.0, .awaitingEvidenceAfterRefusal)
        XCTAssertEqual(reports.first?.1, "winact select was refused")
        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(reports.last?.0, .confirmedAfterRefusal)
        XCTAssertEqual(broker.journal.operation(id: "op")?.reason,
                       "winact select was refused")
    }

    func testUnconfirmedAttemptTimesOutWithoutBecomingGreen() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 0.01)
        var final: MirrorOperationOutcome?
        XCTAssertTrue(broker.enqueue(operation(id: "timeout", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { operation, _ in final = operation.outcome }))
        try? await Task.sleep(nanoseconds: 30_000_000)

        XCTAssertEqual(final, .timedOut)
        XCTAssertEqual(broker.journal.operation(id: "timeout")?.outcome,
                       .timedOut)
    }

    func testTimedOutAttemptCanConfirmFromLaterExactEvidence() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 0.01)
        var outcomes: [MirrorOperationOutcome] = []
        XCTAssertTrue(broker.enqueue(operation(id: "late", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { operation, _ in outcomes.append(operation.outcome) }))
        try? await Task.sleep(nanoseconds: 30_000_000)

        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(outcomes, [.dispatched, .timedOut,
                                  .confirmedAfterTimeout])
        XCTAssertEqual(broker.journal.operation(id: "late")?.outcome,
                       .confirmedAfterTimeout)
    }

    func testRetryingSamePostconditionDoesNotClaimLateAttempt() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 0.01)
        XCTAssertTrue(broker.enqueue(operation(id: "old", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertTrue(broker.enqueue(operation(id: "retry", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { _, _ in }))
        await Task.yield()

        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(broker.journal.operation(id: "old")?.outcome,
                       .timedOut)
        XCTAssertEqual(broker.journal.operation(id: "retry")?.outcome,
                       .confirmed)
    }

    private func operation(id: String, process: MirrorProcessIdentity)
        -> MirrorOperation {
        .init(id: id, source: .human, displayedSnapshotID: 1,
              displayedSequence: 1, target: .process(process),
              postcondition: .processFront(process), enqueuedAt: Date())
    }

    private func processEvidence(_ process: MirrorProcessIdentity,
                                 sequence: Int)
        -> MirrorSettlementEvidence {
        .init(session: session, sequence: sequence,
              coverage: .init(scope: "processes", status: .complete),
              presentProcesses: [process], frontProcess: process)
    }
}
