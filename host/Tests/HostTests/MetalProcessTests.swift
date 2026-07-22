import XCTest
@testable import Host

/// Asks the REAL classic Mac for its running processes over the wire —
/// the consume half of the process.* family. Opt-in, same as the other
/// metal tests:
///
///     NOW_METAL=1 swift test --filter MetalProcessTests
///
/// The guest dials us; once it does, this pages through process.list and
/// prints what came back, so a human can read the PowerBook's own process
/// table off the host and confirm the two halves met. Nothing here is a
/// substitute for watching it — it is the thing to watch.
@MainActor
final class MetalProcessTests: XCTestCase {
    private var listener: GuestListener!

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against the Mac")
        let port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"))
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

    /// One page, awaited.
    private func page(cursor: Int?) async -> Result<ProcessListing,
                                                    GuestListener.FileFailure> {
        await withCheckedContinuation { cont in
            listener.listProcesses(cursor: cursor) { cont.resume(returning: $0) }
        }
    }

    func testAskTheGuestForItsProcessList() async throws {
        let who = try await waitForGuest()
        print("=== \(who) connected; asking for its processes ===")

        var all: [ProcessEntry] = []
        var cursor: Int? = nil
        var pages = 0
        while true {
            switch await page(cursor: cursor) {
            case .failure(let f):
                return XCTFail("the Mac would not list its processes: "
                               + "[\(f.code)] \(f.message)")
            case .success(let listing):
                pages += 1
                all.append(contentsOf: listing.processes)
                guard listing.more, let next = listing.cursor else {
                    cursor = nil
                    break
                }
                cursor = next
            }
            if cursor == nil { break }
            // A runaway cursor is a bug worth catching, not looping on.
            if pages > 8 { return XCTFail("the listing never ended") }
        }

        print("=== \(all.count) process(es) in \(pages) page(s) ===")
        for p in all {
            let front = (p.front ?? false) ? " *" : "  "
            let code = p.code.map { " (\($0))" } ?? ""
            print(String(format: "%@ %-10@ %@%@", front,
                         p.kind as NSString, p.name as NSString,
                         code as NSString))
        }

        XCTAssertFalse(all.isEmpty, "a running Mac has at least the Finder")
        XCTAssertTrue(all.contains { $0.kind == "finder" },
                      "the Finder should be in the list")
    }
}
