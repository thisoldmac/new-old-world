import XCTest
@testable import Host

/// The observation half of the performance picture.
///
/// An act settles from a later scene, so this cycle's period is charged
/// to every act on the machine. Measuring the two together would have
/// made the poll cadence look like guest slowness — the same
/// misattribution the act clocks exist to prevent, one layer out.
@MainActor
final class MirrorCycleClocksTests: XCTestCase {

    func testWalkKindsAreNamedSeparatelyAndNeverAveragedTogether() {
        let structureOnly = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 1.2),
            idleBefore: 3, semantics: false, interaction: false,
            outcome: "ok", windows: 2, elements: 9)
        let full = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 10),
            deliveredAt: Date(timeIntervalSince1970: 18),
            publishedAt: Date(timeIntervalSince1970: 18.4),
            idleBefore: 3, semantics: true, interaction: true,
            outcome: "ok", windows: 2, elements: 61)

        XCTAssertEqual(structureOnly.walk, "structure")
        XCTAssertEqual(full.walk, "full")

        let timeline = MirrorCycleTimeline(log: { _ in })
        timeline.record(structureOnly)
        timeline.record(full)
        /* Like-for-like or nothing: a full walk and a structure poll are
           different amounts of guest work and a mean of the two
           describes a machine that does not exist. */
        XCTAssertEqual(timeline.latest(walk: "structure")?.request, 1)
        XCTAssertEqual(timeline.latest(walk: "full")?.request, 8)
    }

    func testGuestTimeAndOurTimeAreChargedApart() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 6),
            publishedAt: Date(timeIntervalSince1970: 6.5),
            idleBefore: 2, semantics: true, interaction: false,
            outcome: "ok", windows: 3, elements: 40)

        XCTAssertEqual(clocks.request ?? -1, 6, accuracy: 0.001)
        XCTAssertEqual(clocks.decode ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(clocks.total, 6.5, accuracy: 0.001)
        XCTAssertEqual(clocks.baselineLine,
                       "NOWBASE cycle walk=structure+semantics outcome=ok "
                       + "idle_ms=2000 request_ms=6000 decode_ms=500 "
                       + "total_ms=6500 windows=3 elements=40")
    }

    func testACycleThatNeverAnsweredIsStillRecordedAndNotAsZero() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: nil,
            publishedAt: Date(timeIntervalSince1970: 30),
            idleBefore: nil, semantics: true, interaction: true,
            outcome: "declined", windows: nil, elements: nil)

        XCTAssertNil(clocks.request)
        XCTAssertTrue(clocks.baselineLine.contains("request_ms=-"),
                      clocks.baselineLine)
        XCTAssertTrue(clocks.baselineLine.contains("idle_ms=-"),
                      clocks.baselineLine)
        // The guest's thirty seconds were still spent.
        XCTAssertEqual(clocks.total, 30, accuracy: 0.001)
    }

    func testTimelineIsBounded() {
        let timeline = MirrorCycleTimeline(log: { _ in })
        for _ in 0..<(MirrorCycleTimeline.capacity + 3) {
            timeline.record(.init(requestedAt: Date(), deliveredAt: Date(),
                                  publishedAt: Date(), idleBefore: 0,
                                  semantics: false, interaction: false,
                                  outcome: "ok", windows: 0, elements: 0))
        }
        XCTAssertEqual(timeline.records.count, MirrorCycleTimeline.capacity)
    }
}
