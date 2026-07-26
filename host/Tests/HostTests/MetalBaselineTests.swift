import XCTest
@testable import Host

/// The baseline record's own tests, in the ordinary suite.
///
/// The record is only worth having if a line written on the day of a
/// metal run still parses months later, so what is pinned here is what a
/// later edit would break silently: the marker, the field separator, and
/// the arithmetic behind the number anyone will actually quote.
///
/// Every case calls the builder the suites call. Assembling the same
/// line here and comparing the two would be testing this file's copy of
/// the format against itself.
final class MetalBaselineTests: XCTestCase {

    func testALineIsTheMarkerAKindAndFields() {
        XCTAssertEqual(
            MetalBaseline.line("rung", [("dir", "send"), ("bytes", "4096")]),
            "NOWBASE rung dir=send bytes=4096")
    }

    /// A value with a space would split into two fields and turn one
    /// record into a differently-shaped one, which a reader six months
    /// later has no way to notice.
    func testASpaceInAValueCannotSplitTheRecord() {
        let line = MetalBaseline.meta(guestName: "New Old World",
                                      version: "0.19", os: "7.1",
                                      port: 5252, repeats: 3,
                                      machine: "10.91.5.180")
        XCTAssertTrue(line.contains("guest=New_Old_World"), line)
        XCTAssertEqual(line.split(separator: " ").count, 8,
                       "marker, kind, and six key=value fields: \(line)")
    }

    /// Which build, which machine, which port. A rate without these is a
    /// number with no subject — which is exactly what the contended run
    /// of 2026-07-25 produced.
    func testMetaCarriesTheConditionsTheRatesDependOn() {
        let line = MetalBaseline.meta(guestName: "now-68k", version: "0.19",
                                      os: "7.1", port: 5252, repeats: 3,
                                      machine: "10.91.5.180")
        XCTAssertEqual(line, "NOWBASE meta guest=now-68k version=0.19 "
                           + "os=7.1 port=5252 machine=10.91.5.180 repeats=3")
    }

    /// An unnamed machine is recorded as unnamed rather than omitted. A
    /// missing field reads, to anyone comparing two runs, as a field that
    /// was not collected yet — not as a run whose target was never
    /// stated.
    func testAnUnnamedMachineSaysSo() {
        XCTAssertTrue(
            MetalBaseline.meta(guestName: "now-68k", version: nil, os: nil,
                               port: 5250, repeats: 1, machine: nil)
                .contains("machine=unnamed"))
    }

    /// The rate is derived in one place so the two directions cannot
    /// disagree about it. 4 MB in 11.70 s is 350 KB/s with a 1024-byte
    /// kilobyte and 358 with a 1000-byte one, and the ledger's emulator
    /// numbers are the former — a silent switch would put every
    /// comparison against them out by 2%.
    func testTheRateUsesBinaryKilobytes() {
        XCTAssertTrue(
            MetalBaseline.rung(direction: "receive", label: "4 MB",
                               bytes: 4 * 1024 * 1024, seconds: 11.70,
                               rep: 1, of: 1, result: "ok")
                .contains("rate_kbs=350"))
    }

    /// A zero-length rung is a real case both ladders carry — the
    /// transfer that sends no bulk frame at all — and dividing by its
    /// duration must not produce an infinity no table can hold.
    func testAZeroSecondRungReportsNoRateRatherThanInfinity() {
        let line = MetalBaseline.rung(direction: "send", label: "empty",
                                      bytes: 0, seconds: 0,
                                      rep: 1, of: 1, result: "ok")
        XCTAssertTrue(line.contains("rate_kbs=0"), line)
        XCTAssertFalse(line.lowercased().contains("inf"), line)
        XCTAssertFalse(line.lowercased().contains("nan"), line)
    }

    /// Repeats are how a rate stops being an anecdote, so the record has
    /// to say which sample it is. A line that lost `rep` would read as a
    /// single authoritative measurement.
    func testARungSaysWhichSampleItIs() {
        XCTAssertTrue(
            MetalBaseline.rung(direction: "receive", label: "4 MB",
                               bytes: 4 * 1024 * 1024, seconds: 12,
                               rep: 2, of: 3, result: "ok")
                .contains("rep=2/3"))
    }

    /// A failed rung is still a record, and its failure is a field rather
    /// than an absence — a ladder that simply stopped emitting on failure
    /// would produce a baseline file that looked like a shorter ladder.
    func testAFailedRungIsRecordedRatherThanOmitted() {
        let line = MetalBaseline.rung(direction: "receive", label: "1 MB",
                                      bytes: 1_048_576, seconds: 300,
                                      rep: 1, of: 3, result: "hung at 606208")
        XCTAssertTrue(line.contains("result=hung_at_606208"), line)
    }

    /// The claim nothing off metal can check, so its record has to
    /// survive: how many control questions were asked during a transfer,
    /// how many went unanswered, and the worst wait.
    func testTheControlLaneRecordKeepsAllThreeNumbers() {
        XCTAssertEqual(
            MetalBaseline.controlLane(direction: "send", asked: 28,
                                      unanswered: 0, worst: 0.10,
                                      idle: 0.05),
            "NOWBASE control dir=send asked=28 unanswered=0 "
            + "worst_s=0.10 idle_s=0.05")
    }

    func testAnUnmeasuredIdleLatencyIsADashRatherThanAZero() {
        XCTAssertTrue(
            MetalBaseline.controlLane(direction: "receive", asked: 5,
                                      unanswered: 1, worst: 12,
                                      idle: nil)
                .contains("idle_s=-"),
            "a zero would read as an instantaneous reply")
    }

    func testRepeatsDefaultToOneAndNeverToZero() {
        // The environment is not manipulated here — setting
        // NOW_METAL_REPEATS would change what a metal run in the same
        // process measures. The floor is what matters: a zero would make
        // a ladder measure nothing and still report success.
        XCTAssertGreaterThanOrEqual(MetalBaseline.repeats, 1)
    }
}
