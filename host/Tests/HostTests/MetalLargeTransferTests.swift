import Combine
import XCTest
@testable import Host

/// Diagnostic harness for the large-transfer failure: a put that runs at
/// a healthy rate for the first megabyte or two and then stops.
///
///     NOW_METAL=1 NOW_METAL_PORT=5251 swift test --filter MetalLargeTransfer
///
/// Where MetalPutTests reports an outcome, these report a PROFILE — the
/// received count sampled over time — because the question here is not
/// "did it arrive" but "where did it change speed, and what did the guest
/// look like afterwards". A transfer that dies is followed by a liveness
/// probe and a folder listing, so "the guest went mute" and "the guest is
/// fine but the transfer is gone" stop being the same observation.
@MainActor
final class MetalLargeTransferTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against the Mac")
        let port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5251
        let pacing: GuestListener.Pacing
        switch env["NOW_PACE"] {
        case "off": pacing = .none
        case .some(let spec) where spec.contains(":"):
            let parts = spec.split(separator: ":")
            pacing = .init(bytes: Int(parts[0]) ?? 1448,
                           gap: (Double(parts[1]) ?? 3) / 1000.0)
        default: pacing = .classicMac
        }
        print("=== harness on port \(port), pacing \(pacing.bytes) B / "
              + "\(pacing.gap * 1000) ms ===")
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"), pacing: pacing)
        listener.start(port: port)
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
                try await Task.sleep(nanoseconds: 500_000_000)
                return name
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw XCTSkip("no Mac dialled in within \(Int(seconds))s")
    }

    private func pattern(_ n: Int) -> Data {
        var bytes = [UInt8]()
        bytes.reserveCapacity(n)
        for i in 0..<n { bytes.append(UInt8((i &* 31 &+ 7) & 0xFF)) }
        return Data(bytes)
    }

    /// One sample of the received counter.
    private struct Sample { let t: TimeInterval; let received: Int }

    /// Sends a file and returns (outcome, profile). The profile is the
    /// received count every half second, which is what turns "it failed"
    /// into "it decayed from 300 KB/s to nothing over 4 seconds".
    private func profiledPut(_ name: String, _ bytes: Data,
                             timeout: TimeInterval) async
        -> (String, [Sample]) {
        let started = Date()
        var outcome: String?
        var samples: [Sample] = []
        var dropped = false

        let states = listener.$state.sink { st in
            if case .listening = st { dropped = true }
        }
        defer { states.cancel() }

        listener.putFile(name: name, into: "", container: "data",
                         bytes: bytes, overwrite: true) { result in
            switch result {
            case .success:
                let secs = Date().timeIntervalSince(started)
                outcome = String(format: "ok in %.1fs (%.0f KB/s)", secs,
                                 Double(bytes.count) / 1024 / max(secs, 0.001))
            case .failure(let f):
                outcome = "FAILED [\(f.code)] \(f.message)"
            }
        }

        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            samples.append(Sample(t: Date().timeIntervalSince(started),
                                  received: listener.captureProgress?.received
                                      ?? 0))
        }
        if outcome == nil {
            listener.cancelFile()
            outcome = "HUNG after \(Int(timeout))s"
        }
        if dropped { outcome! += " (WIRE DROPPED mid-transfer)" }
        return (outcome!, samples)
    }

    /// Prints the profile as rate-per-interval, which is where a decay
    /// shows up; a cumulative column alone hides it.
    private func report(_ label: String, _ samples: [Sample], _ total: Int) {
        print("--- profile: \(label) (\(total) bytes) ---")
        var prev = Sample(t: 0, received: 0)
        var lastPrinted = -1.0
        for s in samples {
            let dt = s.t - prev.t
            let rate = dt > 0 ? Double(s.received - prev.received) / 1024 / dt
                              : 0
            // Collapse the long flat tail: once nothing is moving, one
            // line per 5 s is enough to see that it stayed stopped.
            let moving = s.received != prev.received
            if moving || s.t - lastPrinted >= 5 {
                print(String(format: "  %6.1fs  %9d  %+8d  %7.1f KB/s",
                             s.t, s.received, s.received - prev.received,
                             rate))
                lastPrinted = s.t
            }
            prev = s
        }
    }

    private func command(_ name: String, _ seconds: TimeInterval = 20) async
        -> String {
        var got: String?
        listener.runCommand(name) { result in
            var rows: [String] = []
            for (_, group) in result.output ?? [:] {
                for row in group where row.count >= 2 {
                    rows.append("\(row[0])=\(row[1])")
                }
            }
            got = rows.isEmpty ? (result.ok ? "ok" : "err")
                : rows.sorted().joined(separator: " ")
        }
        let deadline = Date().addingTimeInterval(seconds)
        while got == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return got ?? "NO ANSWER in \(Int(seconds))s"
    }

    /// Everything in the share root, so a `NOW incoming <ticks>` temp left
    /// by a dead transfer can be seen and measured.
    private func listRoot() async -> String {
        var got: String?
        listener.listFiles(path: "") { result in
            switch result {
            case .success(let listing):
                got = listing.entries
                    .map { "\($0.name)(\($0.dataBytes))" }
                    .joined(separator: ", ")
            case .failure(let f): got = "listing failed: \(f.message)"
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while got == nil, Date() < deadline {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return got ?? "NO LISTING"
    }

    /// Read-only: does a guest dial in, which build is it, and does it
    /// answer? Moves no bytes, so it is safe to run against a machine
    /// whose state is in doubt — including one just recovered from a
    /// wedge, where the first question is whether it came back at all.
    /// NOW_METAL_WAIT sets how long to hold the port open, because the
    /// human has to launch the guest INTO a live listener — a probe that
    /// gives up after 60 s measures the gap between two people, not the
    /// machine. Reading silence from a listener that outlived the guest,
    /// or vice versa, cost this investigation several hours.
    func testJustTellMeTheGuestIsAliveAndWhichBuild() async throws {
        let wait = ProcessInfo.processInfo.environment["NOW_METAL_WAIT"]
            .flatMap { TimeInterval($0) } ?? 60
        print("=== holding 5251 open for \(Int(wait))s — launch the guest now")
        let guest = try await waitForGuest(wait)
        print("\n=== connected to \(guest) ===")
        print("=== about:   \(await command("about"))")
        print("=== putstat: \(await command("putstat"))")
        print("=== root:    \(await listRoot())")
        print("=== alive ===\n")
    }

    /// Watches the guest's own counters WHILE a transfer collapses,
    /// which is the only way to tell the two candidate mechanisms apart.
    ///
    /// `Rcv backlog` is bytes readable at the guest's endpoint, sampled
    /// before it drains. `Loop passes` counts event-loop passes that
    /// reached the wire.
    ///
    ///   backlog ~0, passes climbing  -> the guest is STARVED; the bytes
    ///                                   are not arriving, look upwind
    ///   backlog large, passes climbing -> the guest cannot keep up
    ///   passes NOT climbing            -> the guest's event loop is
    ///                                   blocked (a nested loop, or
    ///                                   another app hogging the CPU)
    ///
    /// Requires a guest carrying the counters (build stamp
    /// 2026-07-20 19:19 or later); an older one answers `Rcv window`.
    func testWhatTheGuestSeesWhileItCollapses() async throws {
        let guest = try await waitForGuest()
        print("\n=== connected to \(guest) ===")
        print("=== baseline putstat: \(await command("putstat")) ===")

        let size = 2 * 1024 * 1024
        var finished = false
        listener.putFile(name: "lt watch.bin", into: "", container: "data",
                         bytes: pattern(size), overwrite: true) { result in
            if case .failure(let f) = result {
                print("=== put ended: FAILED [\(f.code)] \(f.message)")
            } else {
                print("=== put ended: ok")
            }
            finished = true
        }
        let started = Date()
        // Sample across the healthy phase and well into the collapse.
        for _ in 0..<20 where !finished {
            let stat = await command("putstat", 25)
            let received = listener.captureProgress?.received ?? 0
            print(String(format: "  %6.1fs recv=%9d  %@",
                         Date().timeIntervalSince(started), received, stat))
            try? await Task.sleep(nanoseconds: 4_000_000_000)
        }
        listener.cancelFile()
        print("=== watch done ===\n")
    }

    /// The ladder. Each rung reports its profile, then whether the guest
    /// is still answering, then what is left on its disk.
    func testTheSizeLadderToFindWhereItBreaks() async throws {
        let guest = try await waitForGuest()
        print("\n=== connected to \(guest) ===")
        print("=== build: \(await command("about")) ===")

        let rungs = [512 * 1024, 1024 * 1024, 2 * 1024 * 1024,
                     4 * 1024 * 1024]
        for size in rungs {
            let name = "lt \(size / 1024)k.bin"
            print("\n########## \(name) ##########")
            let (outcome, samples) = await profiledPut(name, pattern(size),
                                                       timeout: 180)
            print("=== outcome: \(outcome)")
            report(name, samples, size)
            // Reconnect if the guest dropped: the next rung needs a wire.
            if case .connected = listener.state {} else {
                print("=== wire is down; waiting for the guest to redial")
                _ = try? await waitForGuest(60)
            }
            print("=== liveness after: gestalt -> \(await command("gestalt"))")
            print("=== putstat after:  \(await command("putstat"))")
            print("=== share root:     \(await listRoot())")
            try? await Task.sleep(nanoseconds: 3_000_000_000)
        }
        print("\n=== ladder done ===\n")
    }
}
