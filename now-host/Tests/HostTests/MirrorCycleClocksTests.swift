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

    /// **`decode_ms` is a bracket, not a decode**, and on 2026-08-06 that
    /// cost an evening: it read 12,457 ms, every reading of it began by
    /// looking for a quadratic in the JSON, and the document in question
    /// decodes, reduces and projects in 4 ms. The time was guest
    /// round-trips inside the bracket. So the bracket now says which half
    /// it spent, on the same line, in the same grammar — and only when
    /// there is a split to report, because a `-` is read as a zero.
    func testTheBracketSaysWhichHalfOfItselfItSpent() {
        var clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 13.5),
            idleBefore: 0.8, semantics: true, interaction: true,
            outcome: "ok", windows: 6, elements: 170)
        XCTAssertFalse(clocks.baselineLine.contains("dc_"),
                       "a cycle with no split reports none: "
                       + clocks.baselineLine)

        clocks.ownWork = 0.004
        clocks.contentJoin = 0.120
        XCTAssertTrue(clocks.baselineLine.contains(
            "decode_ms=12500 dc_own_ms=4 dc_content_ms=120 total_ms=13500"),
            "the split rides beside the bracket it explains, in order: "
            + clocks.baselineLine)
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

    /// **A bound that is not reported is a truncation.**
    ///
    /// `command.request` gained a watchdog on 2026-08-06. Before it, a
    /// wedged Macintosh held a completion forever; after it, a cycle can
    /// publish a scene whose content join was abandoned — and if the line
    /// does not say so, the two look identical in the record and the
    /// second is the more dangerous, because it looks like an answer.
    func testACycleThatGaveUpOnAGuestCommandSaysSoOnItsLine() {
        var clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: Date(timeIntervalSince1970: 1),
            publishedAt: Date(timeIntervalSince1970: 22),
            idleBefore: 0, semantics: true, interaction: true,
            outcome: "ok", windows: 3, elements: 12)
        clocks.guestTimeouts = 1
        XCTAssertTrue(clocks.baselineLine.contains("timeouts=1"),
                      clocks.baselineLine)

        /* And absent on the ordinary cycle, for the reason `phfaults` is:
           a field that reads 0 on every line of a 43,000-cycle log stops
           being seen by the time it matters. */
        clocks.guestTimeouts = 0
        XCTAssertFalse(clocks.baselineLine.contains("timeouts="),
                       clocks.baselineLine)
    }

    /// **The bound must sit ABOVE the guest's own script ceiling.**
    ///
    /// The guest answers a script it cannot finish with a typed refusal at
    /// `kNowScriptDefaultMs` — 15 s (`now-guest-ppc/src/input/input_args.h`)
    /// — and the host never overrides it. A host watchdog below that would
    /// fire on scripts the guest is still working on and is about to
    /// explain, replacing the machine's own reason with a bare "timeout":
    /// the host would be manufacturing the silence it exists to detect.
    ///
    /// This is the mutation guard for the tempting change. Plan 014 §B
    /// contemplates "three seconds"; three seconds would break this, and
    /// it should.
    func testTheCommandWatchdogOutlastsTheGuestsOwnScriptCeiling() {
        XCTAssertGreaterThan(
            GuestListener.commandWatchdogSeconds, 15,
            "a bound at or under the guest's kNowScriptDefaultMs turns the "
            + "guest's typed refusal into a host timeout with no reason")
    }

    /// **Every word of the outcome vocabulary must reach the socket
    /// unchanged.**
    ///
    /// `starved`, `wrong-mac`, `declined` and `failed` are four different
    /// bugs on the other Macintosh — one is a machine nobody is
    /// scheduling, one is a scene from the wrong Mac, one is the guest
    /// answering no, one is this side never asking — and an agent that
    /// cannot tell them apart is looking at the wrong half of the system.
    /// The projection is a hand-written conversion, so nothing but a test
    /// stops a word being flattened on the way through it.
    func testEveryNonOkOutcomeSurvivesTheMetricsProjectionVerbatim() {
        for word in ["no-reply", "wrong-mac", "starved", "declined",
                     "failed"] {
            let clocks = MirrorCycleClocks(
                requestedAt: Date(timeIntervalSince1970: 0),
                deliveredAt: nil,
                publishedAt: Date(timeIntervalSince1970: 0),
                idleBefore: nil, semantics: true, interaction: true,
                outcome: word, reason: "because \(word)",
                windows: nil, elements: nil)

            XCTAssertEqual(clocks.projected.outcome, word,
                           "the projection flattened `\(word)`")
            XCTAssertEqual(clocks.projected.reason, "because \(word)",
                           "and the sentence behind it must ride along, "
                           + "because `failed` alone is five bugs")
        }
    }

    /// The reason is prose and `NOWBASE` values are space-free by
    /// construction — `BaselineLine` says in its own comment that
    /// pretending otherwise "would invite somebody to put a message in
    /// one". So the sentence goes to the metric and the line keeps its
    /// grammar.
    func testTheReasonStaysOffTheGreppableMeasurementLine() {
        let clocks = MirrorCycleClocks(
            requestedAt: Date(timeIntervalSince1970: 0),
            deliveredAt: nil,
            publishedAt: Date(timeIntervalSince1970: 0),
            idleBefore: nil, semantics: false, interaction: false,
            outcome: "failed",
            reason: "A scene is already on its way.",
            windows: nil, elements: nil)

        XCTAssertTrue(clocks.baselineLine.contains("outcome=failed"),
                      clocks.baselineLine)
        XCTAssertFalse(clocks.baselineLine.contains("already"),
                       "a sanitised sentence would be an unreadable field "
                       + "in a grammar built to be diffed: "
                       + clocks.baselineLine)
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
