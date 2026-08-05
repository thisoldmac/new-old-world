import XCTest
import MirrorKit
@testable import Host

/// The instrument that has to survive being the first suspect.
///
/// Every assertion here is about ATTRIBUTION rather than about speed:
/// which of the four clocks a delay is charged to, and whether an act
/// that never settled can be told apart from one that settled instantly.
/// Those are the two readings the 2026-08-04 metal drive could not make.
@MainActor
final class MirrorActClocksTests: XCTestCase {
    private let session = MirrorGuestSession(guest: "maxbook",
                                             incarnation: "session-a")

    // MARK: - the record itself

    func testAbsentSettlementIsNotRenderedAsZero() {
        let clocks = MirrorActClocks(
            kind: .released, operationID: "op", label: "close Finder",
            outcome: .timedOut, queueDepthAtEntry: 0,
            enqueuedAt: Date(timeIntervalSince1970: 100),
            dispatchStartedAt: Date(timeIntervalSince1970: 100),
            dispatchReturnedAt: Date(timeIntervalSince1970: 100.5),
            settledAt: nil,
            releasedAt: Date(timeIntervalSince1970: 115))

        XCTAssertNil(clocks.settle)
        XCTAssertTrue(clocks.baselineLine.contains("settle_ms=-"),
                      clocks.baselineLine)
        XCTAssertTrue(clocks.narrative.contains("never settled"),
                      clocks.narrative)
        /* The person waited fifteen seconds and got nothing. Charging
           that to `total` is the point: an act with no settlement still
           cost the whole timeout. */
        XCTAssertEqual(clocks.total, 15, accuracy: 0.001)
    }

    func testEachDelayIsChargedToItsOwnClock() {
        let clocks = MirrorActClocks(
            kind: .released, operationID: "op", label: "open Macintosh HD",
            outcome: .confirmed, queueDepthAtEntry: 2,
            enqueuedAt: Date(timeIntervalSince1970: 0),
            dispatchStartedAt: Date(timeIntervalSince1970: 4),
            dispatchReturnedAt: Date(timeIntervalSince1970: 6),
            settledAt: Date(timeIntervalSince1970: 9),
            releasedAt: Date(timeIntervalSince1970: 9))

        XCTAssertEqual(clocks.waited ?? -1, 4, accuracy: 0.001)
        XCTAssertEqual(clocks.dispatch ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(clocks.settle ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(clocks.total, 9, accuracy: 0.001)
        XCTAssertEqual(clocks.baselineLine,
                       "NOWBASE act kind=released op=op "
                       + "label=open_Macintosh_HD outcome=confirmed depth=2 "
                       + "waited_ms=4000 dispatch_ms=2000 settle_ms=3000 "
                       + "total_ms=9000")
    }

    func testLateSettlementMeasuresFromDispatchNotFromRelease() {
        let clocks = MirrorActClocks(
            kind: .late, operationID: "op", label: "hide Finder",
            outcome: .confirmedAfterTimeout, queueDepthAtEntry: 0,
            enqueuedAt: Date(timeIntervalSince1970: 0),
            dispatchStartedAt: Date(timeIntervalSince1970: 0),
            dispatchReturnedAt: Date(timeIntervalSince1970: 1),
            settledAt: Date(timeIntervalSince1970: 23),
            releasedAt: Date(timeIntervalSince1970: 15))

        // Legitimately larger than the 15s timeout that freed the lane.
        XCTAssertEqual(clocks.settle ?? -1, 22, accuracy: 0.001)
        XCTAssertEqual(clocks.total, 23, accuracy: 0.001)
    }

    // MARK: - the broker feeding it

    func testQueuedActChargesItsWaitToTheLaneAndNotToTheGuest() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        var clock = Date(timeIntervalSince1970: 0)
        var recorded: [MirrorActClocks] = []
        let broker = MirrorMutationBroker(timeout: 60,
                                          now: { clock },
                                          clocks: { recorded.append($0) })

        XCTAssertTrue(broker.enqueue(
            operation(id: "first", process: process, at: clock),
            label: "first",
            execute: {
                clock = Date(timeIntervalSince1970: 2)   // guest took 2s
                return .init(complaint: nil, effectMayHaveLanded: true)
            }, report: { _, _ in }))
        XCTAssertTrue(broker.enqueue(
            operation(id: "second", process: process, at: clock),
            label: "second",
            execute: { .init(complaint: nil, effectMayHaveLanded: true) },
            report: { _, _ in }))
        await Task.yield()

        // The second gesture is behind the first and has not moved.
        XCTAssertEqual(broker.depth, 2)
        clock = Date(timeIntervalSince1970: 5)
        broker.observe([processEvidence(process, sequence: 2)])
        await Task.yield()
        broker.observe([processEvidence(process, sequence: 3)])
        await Task.yield()

        let first = try? XCTUnwrap(recorded.first { $0.operationID == "first" })
        XCTAssertEqual(first?.queueDepthAtEntry, 0)
        XCTAssertEqual(first?.dispatch ?? -1, 2, accuracy: 0.001)
        XCTAssertEqual(first?.waited ?? -1, 0, accuracy: 0.001)

        /* The whole reason this instrument exists: the second act's delay
           belongs to the lane, not to the classic Mac. A single duration
           would have reported it as a slow guest. */
        let second = recorded.first { $0.operationID == "second" }
        XCTAssertEqual(second?.queueDepthAtEntry, 1)
        XCTAssertEqual(second?.waited ?? -1, 5, accuracy: 0.001)
        XCTAssertEqual(second?.dispatch ?? -1, 0, accuracy: 0.001)
    }

    func testTimeoutIsRecordedAndItsLateConfirmationDoesNotRewriteIt() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        var recorded: [MirrorActClocks] = []
        let broker = MirrorMutationBroker(timeout: 0.01,
                                          clocks: { recorded.append($0) })
        XCTAssertTrue(broker.enqueue(
            operation(id: "late", process: process, at: Date()),
            label: "hide Finder",
            execute: { .init(complaint: nil, effectMayHaveLanded: true) },
            report: { _, _ in }))
        try? await Task.sleep(nanoseconds: 30_000_000)
        broker.observe([processEvidence(process, sequence: 2)])

        XCTAssertEqual(recorded.map(\.kind), [.released, .late])
        XCTAssertEqual(recorded.first?.outcome, .timedOut)
        XCTAssertNil(recorded.first?.settledAt)
        XCTAssertEqual(recorded.last?.outcome, .confirmedAfterTimeout)
        XCTAssertNotNil(recorded.last?.settledAt)
    }

    func testDepthReadInsideTheRecordAlreadyExcludesTheActBeingReleased() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        var depthsSeen: [Int] = []
        var broker: MirrorMutationBroker?
        broker = MirrorMutationBroker(timeout: 60,
                                      clocks: { _ in
            depthsSeen.append(broker?.depth ?? -1)
        })
        XCTAssertTrue(broker!.enqueue(
            operation(id: "only", process: process, at: Date()),
            label: "close",
            execute: { .init(complaint: nil, effectMayHaveLanded: true) },
            report: { _, _ in }))
        await Task.yield()
        broker!.observe([processEvidence(process, sequence: 2)])
        await Task.yield()

        /* The queue display reads depth from inside this notification. A
           lane that has just emptied must not still read as busy. */
        XCTAssertEqual(depthsSeen, [0])
        XCTAssertEqual(broker!.depth, 0)
    }

    func testSessionChangeStillRecordsTheTimeTheActCost() async {
        let process = MirrorProcessIdentity(session: session,
                                            incarnation: "finder")
        var recorded: [MirrorActClocks] = []
        let broker = MirrorMutationBroker(timeout: 60,
                                          clocks: { recorded.append($0) })
        XCTAssertTrue(broker.enqueue(
            operation(id: "dropped", process: process, at: Date()),
            label: "move window",
            execute: { .init(complaint: nil, effectMayHaveLanded: true) },
            report: { _, _ in }))
        await Task.yield()
        broker.sessionChanged()

        XCTAssertEqual(recorded.count, 1)
        XCTAssertEqual(recorded.first?.outcome, .sessionChanged)
        XCTAssertEqual(recorded.first?.operationID, "dropped")
    }

    // MARK: - the store

    func testTimelineIsBoundedAndStillLogsWhatItEvicts() {
        var logged = 0
        let timeline = MirrorActTimeline(log: { _ in logged += 1 })
        for index in 0..<(MirrorActTimeline.capacity + 5) {
            timeline.record(.init(
                kind: .released, operationID: "op\(index)", label: "act",
                outcome: .confirmed, queueDepthAtEntry: 0,
                enqueuedAt: Date(), dispatchStartedAt: Date(),
                dispatchReturnedAt: Date(), settledAt: Date(),
                releasedAt: Date()))
        }

        XCTAssertEqual(timeline.records.count, MirrorActTimeline.capacity)
        XCTAssertEqual(logged, MirrorActTimeline.capacity + 5)
        XCTAssertNil(timeline.latest(operationID: "op0"))
        XCTAssertNotNil(timeline.latest(operationID: "op36"))
    }

    private func operation(id: String, process: MirrorProcessIdentity,
                           at date: Date) -> MirrorOperation {
        .init(id: id, source: .human, displayedSnapshotID: 1,
              displayedSequence: 1, target: .process(process),
              postcondition: .processFront(process), enqueuedAt: date)
    }

    private func processEvidence(_ process: MirrorProcessIdentity,
                                 sequence: Int)
        -> MirrorSettlementEvidence {
        .init(session: session, sequence: sequence,
              coverage: .init(scope: "processes", status: .complete),
              presentProcesses: [process], frontProcess: process)
    }
}
