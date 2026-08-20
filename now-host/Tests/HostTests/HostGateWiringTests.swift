import XCTest
@testable import Host

/// **What the host gate runs, and what may quietly stop running it.**
///
/// `scripts/test-host` grew two ways to do less work, and both are correct
/// exactly where they are wired and wrong anywhere else:
///
///   * the `NOW_MIRROR_ASSETS=none` pass is skipped when no pack resolved,
///     because with no pack the first pass already WAS the no-pack run —
///     an identical environment, not a second one;
///   * `--fast` drops that pass and the Release configuration for the inner
///     loop, and says so rather than printing the gate's own passing line.
///
/// A lane that does less is one edit away from becoming the lane everything
/// runs. This reads the wiring so that edit fails here instead of in a
/// release nobody built twice.
final class HostGateWiringTests: XCTestCase {
    func testNothingThatMustBeTheGateAsksForTheFastLane() throws {
        for path in ["scripts/test-all", ".github/workflows/ci.yml"] {
            let text = try GateSource.shellScript(path)
            XCTAssertTrue(text.contains("test-host"),
                          "\(path) no longer runs the host gate at all")
            XCTAssertFalse(text.contains("--fast"), """
                \(path) invokes the host gate with --fast. That lane does \
                not build Release and, on a machine with an asset pack, \
                never watches the degradation path — it is deliberately not \
                the gate, and the two places that ARE the gate must ask for \
                the whole of it.
                """)
        }
    }

    /// The expensive pass must still exist, and its ONLY excuse must be the
    /// one argued for in the script: that there is no second environment to
    /// run. A skip that grew a second condition — a timeout, a "usually
    /// unchanged", an unset variable — would read the same in a green run.
    func testTheNoPackPassIsSkippedOnlyWhereThereIsNoPack() throws {
        let text = try GateSource.shellScript("scripts/test-host")
        XCTAssertTrue(text.contains("NOW_MIRROR_ASSETS=none"),
                      "the degradation pass is gone from the host gate")
        XCTAssertTrue(text.contains("if [ \"$pack_present\" = no ]; then"), """
            The no-pack pass is no longer guarded by pack presence. It costs \
            169 seconds and re-proves the first pass verbatim when no pack \
            resolved; it is the only run that watches degradation when one \
            did. Both halves of that depend on this exact condition.
            """)
    }

    /// `test-all` used to run the whole host gate a second time just to show
    /// the output of a failure it had already produced — eight minutes to
    /// reprint a log, and a second run free to disagree with the first.
    func testTestAllRunsTheHostGateOnce() throws {
        let text = try GateSource.shellScript("scripts/test-all")
        let runs = text.components(separatedBy: "\"$script_dir/test-host\"")
            .count - 1
        XCTAssertEqual(runs, 1, """
            scripts/test-all invokes the host gate \(runs) times. A failure \
            is reported by keeping the first run's log, never by running it \
            again: the rerun costs another eight minutes and can report a \
            state nobody observed (a held port, another session's VM).
            """)
    }
}
