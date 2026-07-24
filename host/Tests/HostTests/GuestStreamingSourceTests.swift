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

    private func source(_ path: String) throws -> String {
        try String(contentsOf:
            Self.repoRoot.appendingPathComponent(path), encoding: .utf8)
    }

    func testPreparingAGuestFileDoesNotAllocateOrReadTheWholePayload()
        throws {
        let files = try source("guest/src/fileshare.c")
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
        let wire = try source("guest/src/wire.c")
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
        let wire = try source("guest/src/wire.c")

        XCTAssertTrue(wire.contains(
            "g_xfer.frame_sent += sent;\n"
            + "            /* This is an inactivity deadline"))
        XCTAssertTrue(wire.contains(
            "g_xfer.deadline = TickCount() + kXferDeadlineTicks;"))
    }

    func testAFileThatCannotOpenAfterBeginStillEndsTheTransfer() throws {
        let wire = try source("guest/src/wire.c")
        let calls = wire.components(
            separatedBy: "file_start_failed(").count - 1

        // declaration + guest-initiated send + host-requested pull
        XCTAssertEqual(calls, 3)
    }
}
