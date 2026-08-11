import XCTest
@testable import Host

@MainActor
final class LogsModelTests: XCTestCase {
    private func freshDefaults() -> UserDefaults {
        let suite = "logs-model-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testInvertDefaultsOffAndPersists() {
        let defaults = freshDefaults()
        let model = LogsModel(log: .shared, defaults: defaults)
        XCTAssertFalse(model.invert, "a fresh install is not inverted")

        model.setInvert(true)
        XCTAssertTrue(model.invert)

        // A second model on the same store reads the saved choice back.
        let reloaded = LogsModel(log: .shared, defaults: defaults)
        XCTAssertTrue(reloaded.invert)
    }

    /// The switch shows HostLog's ACTUAL state, never the mere request —
    /// so a failed open reads as off, not as an on it cannot back.
    func testDiskSwitchMirrorsTheLogNotTheRequest() {
        let model = LogsModel(log: .shared, defaults: freshDefaults())

        model.setPersistsToDisk(true)
        XCTAssertEqual(model.persistsToDisk, HostLog.shared.persistsToDisk)

        model.setPersistsToDisk(false)
        XCTAssertFalse(model.persistsToDisk)
        XCTAssertFalse(HostLog.shared.persistsToDisk)
    }

    func testWriteReachesTheInMemoryRing() {
        /* Grows by one only while there is room. The log is a shared ring
           with a cap, so once enough of the suite has run ahead of this
           test the count stops rising and the oldest line is dropped
           instead — which is the ring working, not a write going missing.
           Asserting `before + 1` outright made this test pass for the
           accidental reason that the suite used to be smaller. */
        let before = HostLog.shared.lines.count
        HostLog.shared.write(.info, "test", "a line for the ring")
        XCTAssertEqual(HostLog.shared.lines.count,
                       min(before + 1, HostLog.ringCapacity))
        XCTAssertEqual(HostLog.shared.lines.last?.text.contains(
            "a line for the ring"), true)
    }
}
