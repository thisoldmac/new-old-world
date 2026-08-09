import XCTest
@testable import Host

@MainActor
final class GuestWorkSchedulerTests: XCTestCase {
    func testWaitingHumanRunsBeforeEarlierAmbientWork() async {
        let gate = Gate()
        var order: [String] = []
        let scheduler = GuestWorkScheduler(sessionID: "mac")

        scheduler.submit(.finder("front"), as: .ambient) { _ in
            order.append("active")
            await gate.wait()
        }
        scheduler.submit(.finder("desktop"), as: .ambient) { _ in
            order.append("ambient")
        }
        scheduler.submit(.interaction("close"), as: .humanInteractive) { _ in
            order.append("human")
        }

        await eventually { order == ["active"] }
        gate.open()
        await eventually { order.count == 3 }
        XCTAssertEqual(order, ["active", "human", "ambient"])
    }

    func testHumanOrderIsStable() async {
        let gate = Gate()
        var order: [String] = []
        let scheduler = GuestWorkScheduler(sessionID: "mac")
        scheduler.submit(.scene, as: .ambient) { _ in await gate.wait() }
        scheduler.submit(.interaction("A"), as: .humanInteractive) { _ in
            order.append("A")
        }
        scheduler.submit(.interaction("B"), as: .humanInteractive) { _ in
            order.append("B")
        }
        gate.open()
        await eventually { order.count == 2 }
        XCTAssertEqual(order, ["A", "B"])
    }

    func testAmbientCoalescingKeepsNewestGeneration() async {
        let gate = Gate()
        var order: [String] = []
        let scheduler = GuestWorkScheduler(sessionID: "mac")
        scheduler.submit(.scene, as: .ambient) { _ in await gate.wait() }
        scheduler.submit(.finder("generation 1"), as: .ambient,
                         coalescingKey: "finder:front") { _ in
            order.append("old")
        }
        scheduler.submit(.finder("generation 2"), as: .ambient,
                         coalescingKey: "finder:front") { _ in
            order.append("new")
        }
        gate.open()
        await eventually { order.count == 1 }
        XCTAssertEqual(order, ["new"])
    }

    func testSessionResetDropsQueuedAndIgnoresLateActiveCompletion() async {
        let gate = Gate()
        var order: [String] = []
        let scheduler = GuestWorkScheduler(sessionID: "old")
        scheduler.submit(.scene, as: .ambient) { _ in await gate.wait() }
        scheduler.submit(.interaction("stale"), as: .humanInteractive) { _ in
            order.append("stale")
        }
        scheduler.reset(sessionID: "new")
        scheduler.submit(.interaction("fresh"), as: .humanInteractive) { token in
            XCTAssertEqual(token.sessionID, "new")
            order.append("fresh")
        }
        gate.open()
        await eventually { order == ["fresh"] }
        XCTAssertEqual(scheduler.depth, 0)
    }

    func testClocksNameAdmissionWaitAndActiveBlocker() async {
        var instant = Date(timeIntervalSince1970: 100)
        var clocks: [MirrorWorkClocks] = []
        let gate = Gate()
        let scheduler = GuestWorkScheduler(
            sessionID: "mac", now: { instant }, clocks: { clocks.append($0) })
        scheduler.submit(.finder("desktop"), as: .ambient) { _ in
            await gate.wait()
        }
        instant.addTimeInterval(3)
        scheduler.submit(.interaction("open"), as: .humanInteractive) { _ in }
        let waiting = scheduler.snapshot()
        XCTAssertEqual(waiting.activePurpose, .finder("desktop"))
        XCTAssertEqual(waiting.queuedHumanCount, 1)
        XCTAssertEqual(waiting.oldestHumanWait, 0)
        instant.addTimeInterval(9)
        gate.open()
        await eventually { scheduler.depth == 0 }
        let admitted = clocks.last { $0.purpose == .interaction("open")
            && $0.admittedAt != nil }
        XCTAssertEqual(admitted?.admissionWait, 9)
    }

    private func eventually(_ condition: @escaping @MainActor () -> Bool) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition())
    }
}

@MainActor
private final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var opened = false

    func wait() async {
        if opened { return }
        await withCheckedContinuation { continuation = $0 }
    }

    func open() {
        opened = true
        continuation?.resume()
        continuation = nil
    }
}
