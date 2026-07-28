import XCTest
@testable import Host

/// Runs `vprobe` on the real machine and prints its table.
///
///     NOW_METAL=1 NOW_METAL_PORT=5253 swift test --filter MetalVProbe
///
/// Not an assertion about the NUMBERS — nobody knows what they should be,
/// which is the entire reason for measuring. What it asserts is that the
/// probe ran, answered in one frame, and did not take the guest away: a
/// measurement command that returns nothing, or returns while the wire is
/// dead, has told us about the harness rather than the machine.
@MainActor
final class MetalVProbeTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5253

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = ProcessInfo.processInfo.environment["NOW_METAL_PORT"]
            .flatMap { UInt16($0) } ?? 5253
        listener = GuestListener(identity: .init(version: "0.1-metal",
                                                 name: "Metal Harness"))
        let deadline = Date().addingTimeInterval(6)
        while true {
            listener.start(port: port)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard case .failed = listener.state, Date() < deadline else { break }
            listener.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    override func tearDown() async throws {
        listener?.stop(); listener = nil
    }

    func testVProbeOnMetal() async throws {
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if case .connected = listener.state, listener.health != nil { break }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        guard case .connected = listener.state, let health = listener.health else {
            return XCTFail("no guest dialled in on \(port) within 120s")
        }
        print("=== \(health.guestName) v\(health.guestVersion ?? "?") "
              + "(OS \(health.guestOS ?? "?")) ===")

        // The probe bounds itself at ~11.7s worst case; 90s is slack for a
        // 33 MHz machine, not an expectation.
        let started = Date()
        let result: CommandResult = await withCheckedContinuation { cont in
            var done = false
            listener.runCommand("vprobe") { r in
                guard !done else { return }; done = true; cont.resume(returning: r)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 90_000_000_000)
                guard !done else { return }; done = true
                cont.resume(returning: CommandResult(
                    id: 0, ok: false, output: nil,
                    error: .init(code: "harness-timeout",
                                 message: "no vprobe result in 90s")))
            }
        }
        let elapsed = Date().timeIntervalSince(started)
        print("=== vprobe answered in \(String(format: "%.1f", elapsed))s ===")

        guard result.ok, let rows = result.output?["vprobe"] else {
            return XCTFail("vprobe did not answer: "
                           + "[\(result.error?.code ?? "?")] "
                           + "\(result.error?.message ?? "")")
        }
        for row in rows {
            let label = row.first ?? ""
            let pad = String(repeating: " ", count: max(0, 18 - label.count))
            print("  \(label)\(pad) \(row.last ?? "")")
        }

        // The wire must survive the probe: it goes deaf between pumps, and
        // "the guest answered then died" is a different result from "the
        // guest answered".
        let after: CommandResult = await withCheckedContinuation { cont in
            var done = false
            listener.runCommand("quit", args: ["target": "NoSuchApplicationHere"]) {
                guard !done else { return }; done = true; cont.resume(returning: $0)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !done else { return }; done = true
                cont.resume(returning: CommandResult(id: 0, ok: false, output: nil,
                    error: .init(code: "harness-timeout", message: "gone")))
            }
        }
        XCTAssertTrue(after.ok, "the wire did not survive the probe")
        print("=== the wire survived the probe ===")
    }
}
