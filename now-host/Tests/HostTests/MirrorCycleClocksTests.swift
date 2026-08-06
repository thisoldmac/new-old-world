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

    /// A cycle from a guest that reports phases carries them into the
    /// measurement line, sorted, with the breakdown's own cost beside
    /// them. Sorted because two runs of a measurement grammar whose field
    /// order changes cannot be diffed, and diffing runs is the point.
    func testPhasesRideTheMeasurementLineInAStableOrder() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 1),
            idleBefore: 0, semantics: true, interaction: true,
            outcome: "ok", windows: 1, elements: 7,
            phases: .init(us: ["controls": 916_000, "menubar": 2_100,
                               "bind": 40],
                          clockReads: 52, clockUs: 104, faults: 0))

        let line = clocks.baselineLine
        XCTAssertTrue(line.hasSuffix(
            "ph_bind_us=40 ph_controls_us=916000 ph_menubar_us=2100 "
            + "phcost_us=104 phreads=52"), line)
        /* Absent rather than `phfaults=0`: a field that is always zero
           teaches a reader to stop seeing it, and this one only means
           anything when it is not. */
        XCTAssertFalse(line.contains("phfaults"), line)
    }

    /// The absence rule, on this side of the wire. A guest too old to
    /// report phases must leave the line exactly as it was — not eight
    /// zeroes, which would read as "the walk did nothing".
    func testAGuestThatReportsNoPhasesAddsNothingToTheLine() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 1),
            idleBefore: 0, semantics: true, interaction: true,
            outcome: "ok", windows: 1, elements: 7, phases: nil)

        XCTAssertFalse(clocks.baselineLine.contains("ph_"),
                       clocks.baselineLine)
        XCTAssertTrue(clocks.baselineLine.hasSuffix("elements=7"),
                      clocks.baselineLine)
    }

    /// A seam fault means one of the numbers above it is wrong, so it is
    /// stated loudly when it happens.
    func testASeamFaultIsCarriedRatherThanSwallowed() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 1),
            idleBefore: 0, semantics: true, interaction: true,
            outcome: "ok", windows: 1, elements: 7,
            phases: .init(us: ["windows": 10], clockReads: 4, clockUs: 8,
                          faults: 2))

        XCTAssertTrue(clocks.baselineLine.contains("phfaults=2"),
                      clocks.baselineLine)
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
