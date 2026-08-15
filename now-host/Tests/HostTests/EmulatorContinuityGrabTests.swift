import Foundation
import XCTest
@testable import Host

/// A CONTINUITY GRAB SERVED BY A REAL GUEST, over a real wire, through
/// this Mac's real `Session` — the whole lane the product uses, minus the
/// human's hand on the trackpad.
///
///     NOW_SPIN_RUN=/tmp/spin scripts/spin-up-ppc     # boot the clone, then:
///     NOW_EMU=1 NOW_EMU_PORT=19161 \
///       NOW_EMU_BUILD="<the build the guest reported>" \
///       swift test --filter EmulatorContinuityGrab
///
/// Opt-in, and once opted in it FAILS rather than skips: a gate that reads
/// green having never reached a machine is worse than no gate.
///
/// ---- Why it exists ---------------------------------------------------
///
/// The defect it was written for is the one no unit test could see and the
/// guest could not report: the guest granted the drag, staged the file and
/// sent `file.begin`, and this Mac cancelled the transfer because the two
/// asks that redeem a grant never armed the receiver. The guest's log said
/// "grab granted", the host's log said `timeout`, and neither sentence
/// named the door that was shut. `FileWireTests` now holds that boundary
/// against a fake guest; this holds the whole lane against a real one,
/// including the order that made the bug reachable — the epoch is DISARMED
/// before the grab, exactly as a drag that crosses back ends its epoch
/// before macOS ever calls the promise.
///
/// ---- What a green run proves -----------------------------------------
///
/// That a grab redeemed inside the grant window arrives as BYTES: same
/// content this Mac put there, through `file.begin` / bulk / `file.end`
/// and `InboundFileSink`. It proves nothing about the PowerBook 1400c —
/// QEMU's mac99 is not that machine and its network is not a Farallon
/// card. Read a green run as emulator-verified; never write "works".
@MainActor
final class EmulatorContinuityGrabTests: XCTestCase {
    private var listener: GuestListener!
    private var selections: [ContinuitySelection] = []

    /// Non-zero, and ours: the guest checks the epoch it was armed with
    /// against the one a grab names, so a fixed number here is a fixed
    /// part of the story rather than a magic constant.
    private let epoch: UInt32 = 4_711

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_EMU"] != nil,
                          "set NOW_EMU=1 to run against a booted clone")
        let port = env["NOW_EMU_PORT"].flatMap { UInt16($0) } ?? 19_161
        listener = GuestListener(
            identity: .init(version: "0.1-emu", name: "Emulator Harness"),
            pacing: .classicMac)
        listener.onContinuitySelection = { [weak self] _, selection in
            self?.selections.append(selection)
        }
        listener.start(port: port)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
        selections = []
    }

    private func waitForGuest(_ seconds: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected = listener.state {
                try await Task.sleep(nanoseconds: 500_000_000)
                return
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        print("listener state: \(listener.state); log: "
              + listener.log.suffix(10).map(\.text).joined(separator: " | "))
        XCTFail("""
            No guest dialled in within \(Int(seconds))s. NOW_EMU is set, so \
            this is a failure and not a skip — boot one with \
            scripts/spin-up-ppc and pass its wire port as NOW_EMU_PORT.
            """)
        throw XCTSkip("no guest")
    }

    /// Refuses a guest that is not the build under test.
    ///
    /// Every QEMU guest on this Mac sees the host as 10.0.2.2, so any
    /// session's VM can answer this listener. The discriminator here is the
    /// build identity `hello` carries, because the change under test adds
    /// no verb to distinguish itself by — it is a lane through the file
    /// family, and an older build would serve this whole test and fail it
    /// for the very reason it was written, which is indistinguishable from
    /// a regression.
    private func requireTheBuildUnderTest() throws {
        let env = ProcessInfo.processInfo.environment
        guard let expected = env["NOW_EMU_BUILD"], !expected.isEmpty else {
            XCTFail("""
                Set NOW_EMU_BUILD to the build the guest reports — \
                $NOW_SPIN_RUN/provenance.md records it under "what the \
                guest said it was running". Without it this test cannot \
                tell the build under test from another lane's VM.
                """)
            throw XCTSkip("no expected build")
        }
        let seen = listener.guests.first?.build
        XCTAssertEqual(seen, expected, """
            The guest on this wire reports build \(seen ?? "none"), not \
            \(expected): it is NOT the build under test. Most likely \
            another session's VM found this listener. Re-run spin-up-ppc \
            and use its lane's wire port.
            """)
        if seen != expected { throw XCTSkip("wrong build on the wire") }
    }

    private func push(_ name: String, _ bytes: Data) async throws {
        var done: Result<GuestListener.PutReceipt,
                         GuestListener.FileFailure>?
        listener.putFileWithReceipt(
            name: name, into: "", container: "data", bytes: bytes,
            fileType: "TEXT", creator: "ttxt", overwrite: true
        ) { done = $0 }
        let deadline = Date().addingTimeInterval(120)
        while done == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        switch done {
        case .success: return
        case .failure(let f):
            XCTFail("could not put \(name): [\(f.code)] \(f.message)")
            throw XCTSkip("push failed")
        case nil:
            XCTFail("the put of \(name) hung for 120s")
            throw XCTSkip("push hung")
        }
    }

    /// Where the share actually is, ASKED OF THE GUEST rather than
    /// assumed. `reveal` resolves a bare name through the application
    /// sweep, which no document is in, so it needs the full HFS path — and
    /// a path this test invented would be testing this file's guess about
    /// preferences instead of the machine's share.
    private func shareRoot() async throws -> String {
        var answer: CommandResult?
        listener.runCommand("ls", line: "") { answer = $0 }
        let deadline = Date().addingTimeInterval(60)
        while answer == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let result = try XCTUnwrap(answer, "the guest never answered ls")
        let rows = (result.output ?? [:])["ls"] ?? []
        let root = rows.first { $0.first == "Share" }?.last
        return try XCTUnwrap(root, """
            `ls` named no Share row, so this test cannot say where the \
            file it pushed actually is.
            """)
    }

    /// Makes the Finder select the file, which is what a person's hand
    /// does in the product. `reveal` is the guest's own read-only verb and
    /// sends the Finder the same `kAEMakeObjectsVisible` a human click
    /// ends at, so the selection the guest then publishes is a real one.
    private func revealInFinder(_ path: String) async throws {
        var answer: CommandResult?
        listener.runCommand("reveal", line: path) { answer = $0 }
        let deadline = Date().addingTimeInterval(60)
        while answer == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        let result = try XCTUnwrap(answer, "the guest never answered reveal")
        XCTAssertTrue(result.ok, """
            reveal \(path) was refused: \
            \(result.error?.message ?? "no reason given"). Nothing is \
            selected in the Finder, so there is no selection to grab.
            """)
    }

    private func waitForSelection(named name: String)
        async throws -> ContinuitySelection {
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline {
            if let hit = selections.last(where: { $0.item?.name == name }) {
                return hit
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("""
            The guest published no continuity.selection naming \(name) \
            within 60s. Selections seen: \
            \(selections.compactMap(\.item?.name).joined(separator: ", ")). Either \
            the epoch never went live (the resident refused the arm) or \
            the Finder is not selecting what reveal named.
            """)
        throw XCTSkip("no selection")
    }

    // MARK: - the test

    func testAGrabAfterTheEpochEndsArrivesAsBytes() async throws {
        try await waitForGuest()
        try requireTheBuildUnderTest()

        let name = "Grab Probe"
        // Classic text, CR line endings, and a length no other file on that
        // disk shares — a delivery of the wrong file fails on the bytes.
        let payload = Data("int main(void) { return 0; }\rgrab probe\r".utf8)
        try await push(name, payload)
        let root = try await shareRoot()
        try await revealInFinder(root + name)

        XCTAssertNotNil(listener.armContinuity(
            nonceHi: 0xC0FFEE, nonceLo: 0x0BADF00D, epoch: epoch,
            requestedHz: 30, leaseTicks: 3_600),
            "no session to arm — the guest went away between checks")
        let selection = try await waitForSelection(named: name)
        XCTAssertEqual(selection.epoch, epoch,
                       "the guest published under another epoch")

        /* THE ORDER IS THE POINT. The drag crossing back ends the epoch,
           and only then does macOS ask the promise for bytes — so the
           grab below is served with no epoch live at all, out of the
           30-second grant the guest holds. */
        XCTAssertNotNil(listener.disarmContinuity(
            epoch: epoch, reason: "test"), "no session to disarm")
        try await Task.sleep(nanoseconds: 1_000_000_000)

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        var delivery: Result<GuestListener.FileDelivery,
                             GuestListener.FileFailure>?
        listener.grabContinuityFile(
            epoch: epoch, generation: selection.generation,
            container: "data", stagingDirectory: staging) { delivery = $0 }
        let deadline = Date().addingTimeInterval(90)
        while delivery == nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        switch try XCTUnwrap(delivery, "the grab never settled in 90s") {
        case .failure(let failure):
            XCTFail("""
                The grab was refused: [\(failure.code)] \(failure.message). \
                A `timeout` here with the guest's log saying "grab granted" \
                is the original defect: the guest served the file and this \
                Mac cancelled the transfer.
                """)
        case .success(let file):
            XCTAssertEqual(file.name, name)
            XCTAssertEqual(try Data(contentsOf: file.staged.url), payload,
                           "the bytes that landed are not the file the "
                           + "selection named")
        }

        /* The guest's own account of what it SENT, not of what it
           decided. The line it used to write said "granted" before
           anything was queued, so a run where the bytes landed and a run
           where they were dropped read identically in the ring — which is
           how this survived to metal. */
        let ring = await guestLog(area: "mirror")
        XCTAssertTrue(ring.contains { $0.contains("file.begin sent") }, """
            The guest's mirror ring has no line saying the grab's \
            file.begin was sent. Lines seen: \
            \(ring.joined(separator: " | "))
            """)
    }

    /// The guest's ring, over its own `tail` verb.
    private func guestLog(area: String) async -> [String] {
        var answer: CommandResult?
        listener.runCommand("tail", typed: ["area": .text(area),
                                            "lines": .number(20)]) { answer = $0 }
        let deadline = Date().addingTimeInterval(30)
        while answer == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return ((answer?.output ?? [:])["tail"] ?? []).map {
            $0.joined(separator: " ")
        }
    }
}
