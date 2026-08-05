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

    /// **A refusal that did nothing IS the settlement, and the lane must
    /// say so at once.**
    ///
    /// Measured on 2026-08-05: a `winact close` the guest refused before it
    /// armed anything held the FIFO for its whole 15 s timeout, and the
    /// next click on the same window waited 8 025 ms behind it. Nothing
    /// was ever going to arrive — the act never reached the act plane —
    /// so the wait bought nothing and cost a person two gestures.
    func testARefusalThatNeverReachedTheMachineReleasesTheLaneAtOnce()
        async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 30)
        var dispatched: [String] = []
        var outcomes: [MirrorOperationOutcome] = []

        XCTAssertTrue(broker.enqueue(operation(id: "stale", process: process),
          execute: {
            dispatched.append("stale")
            return .init(complaint: "the scene moved on",
                         effectMayHaveLanded: false)
          }, report: { operation, _ in outcomes.append(operation.outcome) }))
        XCTAssertTrue(broker.enqueue(operation(id: "next", process: process),
          execute: {
            dispatched.append("next")
            return .init(complaint: nil, effectMayHaveLanded: true)
          }, report: { operation, _ in outcomes.append(operation.outcome) }))
        /* Far shorter than the lane's 30 s timeout and far longer than the
           handful of hops a release takes, so a failure here means the
           second act is waiting on the timeout rather than on the clock. */
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(dispatched, ["stale", "next"],
                       "the second act must not wait on a timeout for an "
                           + "effect the first could not have had")
        XCTAssertEqual(outcomes.first, .refused)
        XCTAssertEqual(broker.depth, 1,
                       "only the dispatched act still holds the lane")
    }

    /// The other half of the same rule: such an operation is terminal, so a
    /// later scene that satisfies its postcondition — because some OTHER
    /// act produced that state — cannot turn it green. That false green is
    /// what `confirmedAfterRefusal` did to a refused close on 2026-08-05,
    /// three milliseconds after a previous close had closed the window.
    func testARefusalThatNeverReachedTheMachineCannotBeConfirmedLater()
        async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 30)
        XCTAssertTrue(broker.enqueue(operation(id: "stale", process: process),
          execute: { .init(complaint: "the scene moved on",
                           effectMayHaveLanded: false) },
          report: { _, _ in }))
        await Task.yield()

        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(broker.journal.operation(id: "stale")?.outcome,
                       .refused)
    }

    /// **A cancel ends the wait, and the record tells the two histories
    /// apart.** The in-flight act reached a guest whose answer nobody
    /// stayed for, so its reason says the effect may still land; the act
    /// still queued was provably never sent, and says that instead. This
    /// is the difference between a bad act and a lost session: the
    /// 2026-08-05 drive stacked seven timeouts to 87.5 s with no way to
    /// abandon any of them.
    func testCancelAllFreesTheLaneAndRecordsBothHistories() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 30)
        var queuedActDispatched = false

        XCTAssertTrue(broker.enqueue(operation(id: "held", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { _, _ in }))
        XCTAssertTrue(broker.enqueue(operation(id: "behind", process: process),
          execute: {
            queuedActDispatched = true
            return .init(complaint: nil, effectMayHaveLanded: true)
          }, report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(broker.depth, 2)

        XCTAssertEqual(broker.cancelAll(), 2)

        XCTAssertEqual(broker.depth, 0, "the lane is free at once")
        XCTAssertFalse(queuedActDispatched,
                       "a cancelled queued act must never reach the guest")
        let held = broker.journal.operation(id: "held")
        XCTAssertEqual(held?.outcome, .cancelled)
        XCTAssertTrue(held?.reason?.contains("may still land") == true,
                      held?.reason ?? "(no reason)")
        let behind = broker.journal.operation(id: "behind")
        XCTAssertEqual(behind?.outcome, .cancelled)
        XCTAssertTrue(behind?.reason?.contains("nothing was sent") == true,
                      behind?.reason ?? "(no reason)")
    }

    /// A cancel is terminal: a later scene that happens to satisfy the
    /// abandoned postcondition — because some other act produced it —
    /// must not turn the cancelled act green, exactly as a provably
    /// unsent refusal cannot be confirmed.
    func testACancelledActIsNeverRewrittenByLaterEvidence() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 30)
        XCTAssertTrue(broker.enqueue(operation(id: "gone", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 20_000_000)
        broker.cancelAll()

        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(broker.journal.operation(id: "gone")?.outcome,
                       .cancelled)
    }

    /// The point of cancelling: the next act dispatches immediately and
    /// settles normally, instead of waiting out its predecessor.
    func testTheLaneServesTheNextActImmediatelyAfterACancel() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        let broker = MirrorMutationBroker(timeout: 30)
        XCTAssertTrue(broker.enqueue(operation(id: "stuck", process: process),
          execute: { .init(complaint: nil, effectMayHaveLanded: true) },
          report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 20_000_000)
        broker.cancelAll()

        var dispatched = false
        XCTAssertTrue(broker.enqueue(operation(id: "fresh", process: process),
          execute: {
            dispatched = true
            return .init(complaint: nil, effectMayHaveLanded: true)
          }, report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 20_000_000)

        XCTAssertTrue(dispatched, "nothing holds the lane after a cancel")
        broker.observe([processEvidence(process, sequence: 2)])
        XCTAssertEqual(broker.journal.operation(id: "fresh")?.outcome,
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
