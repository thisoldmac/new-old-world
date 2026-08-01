import Foundation
import XCTest

/// The guest and host are compiled by different toolchains, so this is a
/// structural regression gate over the exact source boundary that caused
/// whole-file allocation. Functional wire tests cover the bytes; this
/// keeps both guest send entry points on the streaming adapter.
final class GuestStreamingSourceTests: XCTestCase {
    private static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Guest C **with its comments removed** — see `GateSource`.
    ///
    /// The counts below are why. Mutation, 2026-07-31: delete the
    /// `arm_file_transfer(` call in the `file.get` path — so a host asking
    /// the guest for a file gets a staged file and no transfer — and leave
    /// a comment saying the call used to be there. The count stays at 3,
    /// the guest builds, and this file goes on reporting that both entry
    /// points stream. A count over raw text counts the prose too.
    private func source(_ path: String) throws -> String {
        try GateSource.guestC(path)
    }

    /// **A positional window, and its limit is worth stating.** The slice
    /// runs from where `now_files_stage_spec` is defined to where
    /// `now_files_stage_open` is, so it proves those three calls are not in
    /// the TEXT between them — not that staging allocates nothing. Hoist a
    /// whole-file `NewHandle`/`FSRead` into a helper defined ABOVE the
    /// window and call it from inside, and the window contains only the
    /// call: green, with the allocation back. Splitting a function out is
    /// exactly what someone does while refactoring, which is what makes
    /// this one worth naming rather than fixing with a call graph.
    func testPreparingAGuestFileDoesNotAllocateOrReadTheWholePayload()
        throws {
        let files = try source("now-guest-ppc/src/files/fileshare.c")
        let start = try XCTUnwrap(
            files.range(of: "int now_files_stage_spec(")?.lowerBound)
        let end = try XCTUnwrap(
            files.range(of: "int now_files_stage_open(")?.lowerBound)
        let prepare = String(files[start..<end])

        XCTAssertFalse(prepare.contains("TempNewHandle"))
        XCTAssertFalse(prepare.contains("NewHandle"))
        XCTAssertFalse(prepare.contains("FSRead"))
        XCTAssertTrue(prepare.contains("stage->total_bytes = total"))
    }

    func testBothGuestToHostEntryPointsUseTheForkStream() throws {
        let wire = try source("now-guest-ppc/src/core/wire.c")
        let calls = wire.components(separatedBy: "arm_file_transfer(").count - 1

        // declaration + guest-initiated send + host-requested pull
        XCTAssertEqual(calls, 3)
        XCTAssertTrue(wire.contains(
            "now_files_stage_read(\n                &g_xfer.file"))
        XCTAssertTrue(wire.contains(
            "NewPtr(chunk + kNowFrameHeaderBytes)"))
    }

    func testGuestTransferDeadlineTracksProgressRatherThanTotalDuration()
        throws {
        let wire = try source("now-guest-ppc/src/core/wire.c")

        // Both lines, and the deadline reset AFTER the byte count, in the
        // same statement block: the property is that progress is what
        // extends the deadline. This used to pin the two by matching the
        // COMMENT between them — which was load-bearing test text about
        // prose, and stopped working the moment comments were stripped
        // (rightly: the comment was also the only thing making the match
        // adjacent).
        let progress = try XCTUnwrap(
            wire.range(of: "g_xfer.frame_sent += sent;"))
        let deadline = try XCTUnwrap(
            wire.range(of: "g_xfer.deadline = TickCount() "
                           + "+ kXferDeadlineTicks;"))
        // No brace between them: still the same branch. A sibling
        // statement in between is fine — the property is that the reset
        // is REACHED BY progress, not that it is the next line.
        XCTAssertTrue(
            progress.upperBound < deadline.lowerBound
                && !wire[progress.upperBound..<deadline.lowerBound]
                    .contains(where: { $0 == "{" || $0 == "}" }), """
            The transfer deadline is no longer reset immediately after the             bytes that justify it. It is an INACTIVITY deadline, not a size             ceiling: a healthy transfer over ~27 MB takes more than two             minutes on the measured link, and a deadline reset anywhere             but on progress would end it.
            """)
    }

    func testAFileThatCannotOpenAfterBeginStillEndsTheTransfer() throws {
        let wire = try source("now-guest-ppc/src/core/wire.c")
        let calls = wire.components(
            separatedBy: "file_start_failed(").count - 1

        // declaration + guest-initiated send + host-requested pull
        XCTAssertEqual(calls, 3)
    }
}
