import Combine
import XCTest
@testable import Host

/// Drives the REAL classic Mac over the wire: opt-in, because it needs
/// the machine on the other end and the host app not holding the port.
///
///     NOW_METAL=1 swift test --filter MetalPutTests
///
/// The guest dials us, so nothing here reaches out to the hardware; it
/// waits for the PowerBook to connect and then sends files chosen to sit
/// on the boundaries that keep breaking — exactly one chunk, one chunk
/// plus a byte, and sizes past every buffer in the path.
@MainActor
final class MetalPutTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["NOW_METAL"]
                          != nil, "set NOW_METAL=1 to run against the Mac")
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"))
        listener.start(port: 5250)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func waitForGuest(_ seconds: TimeInterval = 90) async throws
        -> String {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .connected(let name) = listener.state {
                // Let the handshake settle before driving it.
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw XCTSkip("no Mac dialled in within \(Int(seconds))s")
    }

    /// Timeline of one transfer, so a stall can be located rather than
    /// guessed at: which step consumed the wall clock.
    private func timeline(_ started: Date) -> String {
        String(format: "%5.1fs", Date().timeIntervalSince(started))
    }

    private func put(_ name: String, _ bytes: Data,
                     container: String = "data",
                     fileType: String? = nil,
                     timeout: TimeInterval = 180) async -> String {
        let started = Date()
        var outcome: String?
        var marks: [String] = []
        var lastSeen = 0
        // A guest that tears the wire down when its buffer fills would
        // show as a session change mid-transfer; that is the difference
        // between "slow" and "wrong".
        let states = listener.$state.sink { st in
            switch st {
            case .connected: marks.append("connected \(self.timeline(started))")
            case .listening: marks.append("DROPPED \(self.timeline(started))")
            case .idle, .failed: marks.append("down \(self.timeline(started))")
            }
        }
        defer { states.cancel() }
        let watch = listener.$captureProgress.sink { progress in
            guard let progress, progress.received != lastSeen else { return }
            if lastSeen == 0 {
                marks.append("first byte \(self.timeline(started))")
            }
            lastSeen = progress.received
            if progress.received == progress.expected {
                marks.append("last byte \(self.timeline(started))")
            }
        }
        defer { watch.cancel() }
        listener.putFile(name: name, into: "", container: container,
                         bytes: bytes, fileType: fileType,
                         creator: fileType != nil ? "ttxt" : nil,
                         overwrite: true) { result in
            switch result {
            case .success:
                let secs = Date().timeIntervalSince(started)
                let rate = Double(bytes.count) / 1024.0 / max(secs, 0.001)
                marks.append("done \(self.timeline(started))")
                outcome = String(format: "ok in %.1fs (%.0f KB/s) [%@]",
                                 secs, rate, marks.joined(separator: ", "))
            case .failure(let f):
                outcome = "FAILED [\(f.code)] \(f.message) "
                    + "[\(marks.joined(separator: ", "))]"
            }
        }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        if outcome == nil {
            let p = listener.captureProgress
            let stalled = p.map { "\($0.received) of \($0.expected)" }
                ?? "nothing sent"
            listener.cancelFile()
            return "HUNG after \(Int(timeout))s — \(stalled)"
        }
        return outcome!
    }

    /// Round-trip latency of a trivial command, which needs only the
    /// guest's event loop — not its disk or its receive path. Slow here
    /// means the loop itself is starved; fast here while a transfer
    /// crawls means the receive path is the problem.
    private func commandLatency() async -> String {
        let started = Date()
        var got: String?
        listener.runCommand("gestalt") { result in
            got = result.ok ? "ok" : "err"
        }
        let deadline = Date().addingTimeInterval(20)
        while got == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return got == nil ? "no answer in 20s"
            : String(format: "%.2fs", Date().timeIntervalSince(started))
    }

    func testEventLoopLatencyIdleVersusDuringATransfer() async throws {
        _ = try await waitForGuest()
        print("\n=== gestalt latency, idle ===")
        for _ in 0..<3 {
            print("  idle: \(await commandLatency())")
            try? await Task.sleep(nanoseconds: 300_000_000)
        }

        // Start a transfer big enough to still be running while we probe.
        var probeBytes = [UInt8]()
        probeBytes.reserveCapacity(256 * 1024)
        for i in 0..<(256 * 1024) {
            probeBytes.append(UInt8((i &* 31 &+ 7) & 0xFF))
        }
        let bytes = Data(probeBytes)
        var finished = false
        listener.putFile(name: "mp probe.bin", into: "", container: "data",
                         bytes: bytes, overwrite: true) { _ in
            finished = true
        }
        print("=== gestalt latency, during a 256 KB put ===")
        for _ in 0..<8 where !finished {
            print("  busy: \(await commandLatency())")
        }
        listener.cancelFile()
        print("=== done ===\n")
    }

    func testSendsFilesOfVariedSizesAndTypes() async throws {
        let guest = try await waitForGuest()
        print("\n=== connected to \(guest) ===")

        // Deterministic bytes, so a corrupted arrival is provable later.
        func pattern(_ n: Int) -> Data {
            Data((0..<n).map { UInt8(($0 &* 31 &+ 7) & 0xFF) })
        }
        let chunk = FrameHeader.maxPayloadLength   // 32768

        let cases: [(String, Data, String, String?)] = [
            ("mp tiny.txt", Data("hello\r".utf8), "data", "TEXT"),
            ("mp 4k.txt", Data(String(repeating: "line\r", count: 800).utf8),
             "data", "TEXT"),
            ("mp under.bin", pattern(chunk - 1), "data", nil),
            ("mp exact.bin", pattern(chunk), "data", nil),
            ("mp over.bin", pattern(chunk + 1), "data", nil),
            ("mp 64k.bin", pattern(64 * 1024), "data", nil),
            ("mp 128k.bin", pattern(128 * 1024), "data", nil),
            ("mp 256k.bin", pattern(256 * 1024), "data", nil),
        ]

        var report: [String] = []
        for (name, bytes, container, type) in cases {
            let result = await put(name, bytes, container: container,
                                   fileType: type)
            let line = String(format: "%-14s %8d bytes  %@",
                              (name as NSString).utf8String!, bytes.count,
                              result)
            print(line)
            report.append(line)
            // A failure of one should not poison the next: give the
            // guest a moment, and make sure nothing is left in flight.
            if result.contains("FAILED") || result.contains("HUNG") {
                listener.cancelFile()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            } else {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        print("=== done ===\n")

        let bad = report.filter {
            $0.contains("FAILED") || $0.contains("HUNG")
        }
        XCTAssertTrue(bad.isEmpty, "\n" + bad.joined(separator: "\n"))
    }
}
