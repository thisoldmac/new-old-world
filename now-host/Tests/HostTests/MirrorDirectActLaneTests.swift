import XCTest
@testable import Host

/// The claim under test is exactly the one the guest's refusal names: **two
/// direct acts must not be on the wire at once.** Michelle's nine `act-busy`
/// refusals in ninety seconds were control clicks, and control clicks took
/// the path that had no lane.
///
/// Each test below is written against a specific mutation, named in its own
/// comment, so that reintroducing the defect makes exactly that test fail.
@MainActor
final class MirrorDirectActLaneTests: XCTestCase {

    /// **Mutation this catches:** deleting `_ = await ahead?.value` from
    /// `MirrorDirectActLane.submit` — that is, restoring the pre-fix
    /// behaviour where every direct act got its own unchained `Task`.
    ///
    /// Without the chain both acts start before either finishes, `running`
    /// reaches 2, and the guest would have refused the second.
    func testSecondActDoesNotStartWhileTheFirstIsStillOnTheWire() async {
        let lane = MirrorDirectActLane()
        var running = 0
        var maxConcurrent = 0
        var order: [String] = []

        // A gate the first act blocks on, so "still on the wire" is a state
        // the test controls rather than a race it hopes to win.
        let firstMayFinish = AsyncGate()

        XCTAssertTrue(lane.submit {
            running += 1
            maxConcurrent = max(maxConcurrent, running)
            order.append("first")
            await firstMayFinish.wait()
            running -= 1
        })
        XCTAssertTrue(lane.submit {
            running += 1
            maxConcurrent = max(maxConcurrent, running)
            order.append("second")
            running -= 1
        })

        // Give both tasks every chance to start. The second must not have.
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(order, ["first"],
                       "the second act reached the guest while the first was "
                       + "still in flight — that is the act-busy refusal")

        firstMayFinish.open()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(order, ["first", "second"])
        XCTAssertEqual(maxConcurrent, 1,
                       "two direct acts were on the wire at once")
    }

    /// **Mutation this catches:** dropping the `depth < capacity` guard, so
    /// the lane queues without bound. A person mashing a scroll arrow would
    /// build a backlog that dispatches minutes later at whatever is under
    /// the cursor by then.
    func testLaneRefusesPastCapacityAndNeverRunsTheRefusedWork() async {
        let lane = MirrorDirectActLane(capacity: 2)
        let gate = AsyncGate()
        var ran: [String] = []

        XCTAssertTrue(lane.submit { ran.append("a"); await gate.wait() })
        XCTAssertTrue(lane.submit { ran.append("b") })
        XCTAssertFalse(lane.submit { ran.append("c") },
                       "a full lane must refuse rather than queue")

        gate.open()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(ran, ["a", "b"],
                       "refused work must never run — the caller was told it "
                       + "would not")
    }

    /// **Mutation this catches:** failing to decrement `depth` when an act
    /// completes. The lane would refuse for ever after `capacity`
    /// submissions, which reads to a person as the mirror going dead.
    func testCapacityIsReclaimedAsActsFinish() async {
        let lane = MirrorDirectActLane(capacity: 1)
        var ran = 0

        XCTAssertTrue(lane.submit { ran += 1 })
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(lane.depth, 0, "a drained lane still reads as full")

        XCTAssertTrue(lane.submit { ran += 1 })
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(ran, 2)
    }
}

/// A one-shot gate. `Task.yield` alone cannot express "still in flight", and
/// a sleep would make the test a race.
private final class AsyncGate: @unchecked Sendable {
    private var open_ = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open_ { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        open_ = true
        let pending = waiters
        waiters.removeAll()
        for continuation in pending { continuation.resume() }
    }
}
