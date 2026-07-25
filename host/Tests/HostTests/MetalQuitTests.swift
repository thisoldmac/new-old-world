import XCTest
@testable import Host

/// Drives `quit` against a REAL CarbonLib guest over the wire — the
/// acceptance test for the composition described in
/// guest/src/proc_actions.h. Opt-in, same as the other metal tests:
///
///     NOW_METAL=1 swift test --filter MetalQuitTests
///
/// It runs against ANY live guest: the mac99 emulator (where the guest's
/// default 10.0.2.2 dials the host through SLIRP) or the PowerBook 1400c.
/// Say which one a result came from — the emulator settles nothing about
/// timing on a 117 MHz 603e.
///
/// The subject under test is not "does the Apple Event send". It is
/// whether the guest tells the truth about the OUTCOME, because
/// `now_proc_ask_quit` returning noErr means only that the event was
/// delivered. So every assertion here is on the `Outcome` row, and the
/// gone case is confirmed a SECOND time from process.list rather than
/// taken on the guest's word — a test that believes the thing it is
/// testing proves nothing.
///
/// NOT covered here, and it needs a human: the DECLINED path. An
/// application holding an unsaved document stops to ask about it and
/// stays running, and there is no way to dirty a document from this side.
/// Open SimpleText on the machine, type a character, then run `quit
/// SimpleText` from a console and watch it come back "STILL RUNNING".
@MainActor
final class MetalQuitTests: XCTestCase {
    private var listener: GuestListener!

    /// The application to quit. Overridable because the emulator image and
    /// the PowerBook do not hold the same software.
    private var victim: String {
        ProcessInfo.processInfo.environment["NOW_QUIT_APP"] ?? "SimpleText"
    }

    /// The guest's own process name, for the self-refusal check. The
    /// emulator build is "now-guest"; the canonical one is "New Old World".
    private var selfName: String {
        ProcessInfo.processInfo.environment["NOW_GUEST_NAME"] ?? "now-guest"
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        let port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"))
        listener.start(port: port)
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
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

    private func run(_ name: String, target: String? = nil) async
        -> CommandResult {
        await withCheckedContinuation { cont in
            listener.runCommand(name,
                                args: target.map { ["target": $0] }) {
                cont.resume(returning: $0)
            }
        }
    }

    /// The machine-readable half of the reply. Nil when the command failed.
    private func outcome(_ result: CommandResult) -> String? {
        result.output?["quit"]?.first { $0.first == "Outcome" }?.last
    }

    private func sentence(_ result: CommandResult) -> String {
        result.output?["quit"]?.first { $0.first == "Quit" }?.last
            ?? result.error.map { "[\($0.code)] \($0.message)" }
            ?? "(no message)"
    }

    /// Every live process name, paged the way the agent projection pages it.
    private func processNames() async throws -> [String] {
        var names: [String] = []
        var cursor: Int? = nil
        for _ in 0..<8 {
            let page: Result<ProcessListing, GuestListener.FileFailure> =
                await withCheckedContinuation { cont in
                    listener.listProcesses(cursor: cursor) {
                        cont.resume(returning: $0)
                    }
                }
            switch page {
            case .failure(let f):
                throw XCTSkip("the guest would not list processes: "
                              + "[\(f.code)] \(f.message)")
            case .success(let listing):
                names.append(contentsOf: listing.processes.map(\.name))
                guard listing.more, let next = listing.cursor else {
                    return names
                }
                cursor = next
            }
        }
        return names
    }

    func testQuitTellsTheTruthAboutWhatHappened() async throws {
        let who = try await waitForGuest()
        print("=== \(who) connected; exercising quit ===")

        // 1. Nothing to quit is not a failure: the asked-for state holds.
        //    Run it FIRST so the rest starts from a known-clean machine.
        var result = await run("quit", target: victim)
        print("quit \(victim) (before launch): \(sentence(result))")
        if result.ok, outcome(result) == "gone" {
            // It was already up from an earlier run; that is fine, and the
            // rest of the test still holds.
            print("  (it was already running and has now been quit)")
        } else {
            XCTAssertTrue(result.ok, "a process that is not running is not an "
                          + "error: \(sentence(result))")
            XCTAssertEqual(outcome(result), "not-running")
        }

        // 2. A name nothing answers to, and a line that does not parse.
        result = await run("quit", target: "NoSuchApplicationHere")
        print("quit NoSuchApplicationHere: \(sentence(result))")
        XCTAssertEqual(outcome(result), "not-running")

        result = await run("quit")
        print("quit (no target): \(sentence(result))")
        XCTAssertFalse(result.ok, "an empty target must not be accepted")
        XCTAssertEqual(result.error?.code, "quit-bad-args")

        result = await run("quit", target: "--frobnicate \(victim)")
        print("quit --frobnicate: \(sentence(result))")
        XCTAssertEqual(result.error?.code, "quit-bad-args",
                       "an unknown flag must refuse, not become a name")

        // 3. The guest will not quit ITSELF through this verb: that would
        //    sever the reply we are waiting on.
        result = await run("quit", target: selfName)
        print("quit \(selfName) (itself): \(sentence(result))")
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.error?.code, "quit-refused")
        // And it is still there to say so.
        var live = try await processNames()
        XCTAssertTrue(live.contains {
            $0.caseInsensitiveCompare(selfName) == .orderedSame
        }, "the guest refused to quit itself and then quit anyway")

        // 4. The real path: launch something, watch it appear, quit it,
        //    watch it go — and confirm the disappearance INDEPENDENTLY.
        result = await run("launch", target: victim)
        print("launch \(victim): "
              + (result.output?["launch"]?.first?.last ?? "failed"))
        try XCTSkipUnless(result.ok,
                          "cannot test quit without launching \(victim)")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        live = try await processNames()
        XCTAssertTrue(live.contains {
            $0.caseInsensitiveCompare(victim) == .orderedSame
        }, "\(victim) was launched but is not in the process list")

        result = await run("quit", target: victim)
        print("quit \(victim): \(sentence(result))")
        XCTAssertTrue(result.ok, "quit failed: \(sentence(result))")
        XCTAssertEqual(outcome(result), "gone",
                       "quit must confirm by re-listing, not assume: "
                       + sentence(result))
        live = try await processNames()
        XCTAssertFalse(live.contains {
            $0.caseInsensitiveCompare(victim) == .orderedSame
        }, "the guest reported \"gone\" while \(victim) is still running — "
           + "this is the failure mode the Outcome row exists to prevent")

        // 5. And now that it is gone, the same command says so plainly.
        result = await run("quit", target: victim)
        print("quit \(victim) (again): \(sentence(result))")
        XCTAssertEqual(outcome(result), "not-running")
    }

    /// The declined path, and the reason the whole verb reports an outcome:
    /// an application holding an unsaved document stops to ask about it and
    /// STAYS RUNNING. Human-in-the-loop by necessity — nothing on this side
    /// can dirty a document — so it is separately opt-in:
    ///
    ///     NOW_METAL=1 NOW_QUIT_DIRTY=1 swift test \
    ///         --filter testADirtyDocumentDeclinesAndSaysSo
    ///
    /// It launches the application, then waits NOW_QUIT_DIRTY_PAUSE seconds
    /// (default 20) for you to type a character into it, then asks it to
    /// quit. Passing means the guest called it still-running rather than
    /// gone. Leave the Save dialog up; the test does not dismiss it.
    func testADirtyDocumentDeclinesAndSaysSo() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_QUIT_DIRTY"] != nil,
                          "set NOW_QUIT_DIRTY=1 and be ready to type")
        _ = try await waitForGuest()

        var result = await run("launch", target: victim)
        try XCTSkipUnless(result.ok, "cannot test without launching \(victim)")

        let pause = env["NOW_QUIT_DIRTY_PAUSE"].flatMap { Double($0) } ?? 20
        print("=== type a character into \(victim) now — \(Int(pause))s ===")
        try await Task.sleep(nanoseconds: UInt64(pause * 1e9))

        result = await run("quit", target: "--wait 4 \(victim)")
        print("quit \(victim) (dirty): \(sentence(result))")
        XCTAssertFalse(result.ok, "a declined quit must not report success")
        XCTAssertEqual(result.error?.code, "quit-declined")
        // Still there, by an independent reading.
        let live = try await processNames()
        XCTAssertTrue(live.contains {
            $0.caseInsensitiveCompare(victim) == .orderedSame
        }, "\(victim) is gone, so nothing declined — was the document dirty?")
    }

    /// --no-wait is the deliberately unconfirmed path: it must SAY it is
    /// unconfirmed rather than borrow the confident answer.
    func testNoWaitReportsItselfUnconfirmed() async throws {
        _ = try await waitForGuest()

        var result = await run("launch", target: victim)
        try XCTSkipUnless(result.ok, "cannot test without launching \(victim)")
        try await Task.sleep(nanoseconds: 2_000_000_000)

        result = await run("quit", target: "--no-wait \(victim)")
        print("quit --no-wait \(victim): \(sentence(result))")
        XCTAssertTrue(result.ok)
        XCTAssertEqual(outcome(result), "sent-unconfirmed",
                       "--no-wait must not claim the process is gone")

        // Tidy up, and leave the machine as we found it.
        try await Task.sleep(nanoseconds: 3_000_000_000)
        result = await run("quit", target: victim)
        print("  cleanup: \(sentence(result))")
    }
}
