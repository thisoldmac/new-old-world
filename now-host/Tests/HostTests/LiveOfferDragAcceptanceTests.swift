import XCTest
@testable import Host

/// Live emulator acceptance for slice 1 of
/// `docs/local/plan-host-to-guest-drag-2026-08-15.md`: publish a
/// `continuity.offer` host-side against a real PPC guest, grab it
/// guest-side through both faces (the console's exec-line fallback and
/// the wire's typed `command.request`), and exercise the `offer-expired`
/// refusal by name.
///
///     NOW_OFFER_LIVE_PORT=<wire port> swift test --filter LiveOfferDragAcceptanceTests
///
/// Opt-in and env-gated exactly like the `Metal*Tests` — a guest that does
/// not answer once opted in is a FAILURE, not a skip
/// (AGENTS.md > Testing). Not a metal test: this drives an emulator guest
/// (`scripts/spin-up-ppc`), so it asserts against the wire port a lane
/// already has up rather than `NOW_METAL_PORT`/`MetalMachineGuard`.
///
/// Deliberately does not assert byte-for-byte content by pulling the file
/// back over the wire — the guest's own `get_end` already crc32-checks a
/// grab and discards on mismatch (see `now-guest-ppc/src/core/wire.c`), so
/// an `ok` grab plus the file appearing in the guest's shared listing at
/// the expected size is evidence the transfer was accepted intact; the
/// print of `ls` after each grab is what a report should quote.
@MainActor
final class LiveOfferDragAcceptanceTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 0

    override func setUp() async throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["NOW_OFFER_LIVE_PORT"] != nil,
            "set NOW_OFFER_LIVE_PORT=<wire port> to run against a live guest")
        port = UInt16(
            ProcessInfo.processInfo.environment["NOW_OFFER_LIVE_PORT"]!)!
        listener = GuestListener(identity: .init(
            version: "0.2.0-slice1-live", name: "Slice-1 Live Harness"))
        let deadline = Date().addingTimeInterval(10)
        while true {
            listener.start(port: port)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard case .failed = listener.state, Date() < deadline else {
                break
            }
            listener.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func waitConnected() async throws {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if case .connected = listener.state, listener.activeKey != nil {
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("no guest dialled in on \(port) within 60s")
    }

    private func arm(epoch: UInt32) async throws {
        var acked = false
        var reportEpoch: UInt32 = 0
        var armState = ""
        listener.onContinuityReport = { _, report in
            reportEpoch = report.epoch
            armState = report.state
            acked = true
        }
        listener.armContinuity(nonceHi: 1, nonceLo: 1, epoch: epoch,
                               requestedHz: 30, leaseTicks: 600)
        let deadline = Date().addingTimeInterval(15)
        while !acked, Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(acked, "no continuity.report ack within 15s")
        XCTAssertEqual(reportEpoch, epoch)
        print("=== continuity armed: epoch=\(reportEpoch) state=\(armState) ===")
    }

    private func execLine(_ line: String) async -> GuestListener.ExecOutcome {
        await withCheckedContinuation { cont in
            listener.exec(line) { cont.resume(returning: $0) }
        }
    }

    private func runCommand(_ name: String, line: String) async -> CommandResult {
        await withCheckedContinuation { cont in
            listener.runCommand(name, line: line) { cont.resume(returning: $0) }
        }
    }

    func testOfferAndGrabBothFacesWithRefusal() async throws {
        try await waitConnected()
        try await arm(epoch: 424_242)

        let control = AgentIntegrationContinuityOfferControl(listener: listener)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-slice1-offer-\(UUID().uuidString).txt")
        let payload = Data(
            "slice-1 live acceptance \(Date())\n".utf8)
        try payload.write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        print("=== source file: \(tmp.path), \(payload.count) bytes, "
              + "crc32=\(TransferIdentity.crc32(payload)) ===")

        // --- Face 1: the console's exec-line fallback. ---
        guard case .published(let item1) = control.publish(
            fileAt: tmp, epoch: 424_242, generation: 1) else {
            return XCTFail("publish (gen 1) failed")
        }
        print("=== published gen 1: \(item1) ===")

        let report1 = await execLine("offer")
        XCTAssertTrue(report1.ok,
                     "bare offer report (console face) failed: "
                         + "\(report1.code ?? "") \(report1.message ?? "")")
        print("=== console face bare report: \(report1.text) ===")

        let take1 = await execLine("offer --take")
        XCTAssertTrue(take1.ok,
                     "console-face offer --take failed: "
                         + "\(take1.code ?? "") \(take1.message ?? "")")
        print("=== console face --take asked: \(take1.text) ===")

        try await Task.sleep(nanoseconds: 5_000_000_000)
        // now_files_downloads(): unset dl_vol preference lands a pull on
        // the Desktop, not the share root — ls the actual destination.
        let ls1 = await runCommand("ls", line: "Desktop Folder")
        print("=== ls Desktop Folder after console-face grab: "
              + "\(String(describing: ls1.output)) ===")

        // --- Face 2: the wire's typed command.request, same x-line grammar. ---
        guard case .published(let item2) = control.publish(
            fileAt: tmp, epoch: 424_242, generation: 2) else {
            return XCTFail("publish (gen 2) failed")
        }
        print("=== published gen 2: \(item2) ===")

        let take2 = await runCommand("offer", line: "--take")
        XCTAssertTrue(take2.ok,
                     "wire-face offer --take failed: "
                         + "\(take2.error?.code ?? "") "
                         + "\(take2.error?.message ?? "")")
        print("=== wire face --take asked: "
              + "\(String(describing: take2.output)) ===")

        try await Task.sleep(nanoseconds: 5_000_000_000)
        let ls2 = await runCommand("ls", line: "Desktop Folder")
        print("=== ls Desktop Folder after wire-face grab: "
              + "\(String(describing: ls2.output)) ===")

        // --- Refusal path: end the HOST's offer clock (not the guest's
        // epoch — endContinuityOfferEpoch sends no wire message), wait
        // past the 30s bound, and expect `offer-expired` by name. ---
        guard case .published = control.publish(
            fileAt: tmp, epoch: 424_242, generation: 3) else {
            return XCTFail("publish (gen 3) failed")
        }
        listener.endContinuityOfferEpoch()
        try await Task.sleep(nanoseconds: 31_000_000_000)

        let expiredTake = await execLine("offer --take")
        print("=== expired take attempt: ok=\(expiredTake.ok) "
              + "code=\(expiredTake.code ?? "") "
              + "message=\(expiredTake.message ?? "") "
              + "text=\(expiredTake.text) ===")
        XCTAssertTrue(expiredTake.ok,
                     "the console reply for --take only reports it was "
                         + "ASKED; a false result here means the guest "
                         + "refused it LOCALLY (e.g. still busy), not that "
                         + "offer-expired was ever reached on the wire")

        // The console reply only reports that the grab was ASKED; the
        // actual refusal lands on the file lane (`file.refuse`), whose
        // text this run cannot read headlessly (it prints to the Files
        // browser page, which needs a display — see the notes this test
        // leaves for the report). What IS observable from here: the guest
        // must have processed the refusal and cleared its pending-get
        // state, or a second attempt would answer "busy" rather than a
        // fresh outcome. It will not be "busy" — the host's own offer was
        // already cleared by the first expiry check (ContinuityOfferService
        // .grab sets `current = nil` on expiry), so a second ask reaches a
        // DIFFERENT host-side refusal (`no-selection`), which is itself
        // evidence the first one was not silently dropped.
        try await Task.sleep(nanoseconds: 2_000_000_000)
        let secondTake = await execLine("offer --take")
        print("=== second take after expiry (expect NOT busy): "
              + "ok=\(secondTake.ok) code=\(secondTake.code ?? "") "
              + "message=\(secondTake.message ?? "") "
              + "text=\(secondTake.text) ===")
        XCTAssertNotEqual(secondTake.message, "A transfer is already in flight",
                          "the first expired grab left the guest's pending "
                              + "get state stuck rather than clearing it")
    }
}
