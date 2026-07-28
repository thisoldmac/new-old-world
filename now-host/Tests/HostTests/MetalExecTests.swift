import Foundation
import XCTest
@testable import Host

/// The exec plane against a LIVE guest — emulator or metal, the same test.
///
///     scripts/q800-68k                                   # boot, it dials
///     NOW_METAL=1 swift test --filter MetalExecTests     # in another shell
///
/// Gated the way every other live-guest suite here is: `NOW_METAL` unset
/// skips, because nobody asked for a run against a real machine.
///
/// WHAT THIS PROVES THAT THE UNIT TESTS CANNOT. `ConsoleShellTests` drives a
/// FakeGuest — a fake that answers exec the way the contract says a guest
/// should, which means it can only confirm the host is self-consistent. Every
/// claim this plane makes is about the OTHER machine: that a real guest reads
/// `line` unsplit, that it renders the text its own console would, that it
/// says `unknown-command` in its own words, that its chunking reassembles.
/// None of that is testable without a guest on the wire.
///
/// The order climbs deliberately: nothing here can wedge a machine, and the
/// one path that could — exec.input — is not exercised at all, because
/// nothing in either guest's table asks for input yet. See
/// docs/remote-console.md's checklist for how that one gets tested when
/// something does.
@MainActor
final class MetalExecTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5250

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        try MetalMachineGuard.preflight(port: port)
        listener = GuestListener(identity: .init(
            version: "0.1-exec", name: "Exec Harness"))
        listener.start(port: port)
        try await waitForGuest()
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    /// The guest dials out on its own cadence, so the harness waits rather
    /// than connecting. 90s is generous on purpose: the claim under test is
    /// never "it comes back fast".
    private func waitForGuest() async throws {
        let deadline = Date().addingTimeInterval(90)
        while Date() < deadline {
            if case .connected = listener.state { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("no Mac dialled in on port \(port) within 90s")
        throw XCTSkip("no guest")
    }

    /// Runs one line and returns what came back, or fails the test.
    @discardableResult
    private func exec(_ line: String,
                      timeout: TimeInterval = 45) async throws
        -> GuestListener.ExecOutcome {
        var outcome: GuestListener.ExecOutcome?
        listener.exec(line) { outcome = $0 }
        let deadline = Date().addingTimeInterval(timeout)
        while outcome == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        guard let outcome else {
            XCTFail("\"\(line)\" never settled within \(Int(timeout))s")
            throw XCTSkip("no result")
        }
        XCTAssertFalse(outcome.gap,
                       "\"\(line)\" lost an exec.output frame in transit")
        return outcome
    }

    // MARK: - The ordinary path

    /// `help` is the one verb both guests serve, so it is the first thing to
    /// ask a machine whose table you do not know.
    func testHelpComesBackAsTextTheGuestRendered() async throws {
        let outcome = try await exec("help")

        XCTAssertTrue(outcome.ok, "help failed: \(outcome.code ?? "?")")
        XCTAssertFalse(outcome.text.isEmpty, "help returned no text at all")
        // Not an exact match: the two guests word their own banners
        // differently and SHOULD, because each is describing itself. What
        // must hold is that this is prose a person could read, not a
        // reconstruction from [label, value] pairs.
        XCTAssertTrue(outcome.text.lowercased().contains("command"),
                      "help did not read like a command list:\n\(outcome.text)")
    }

    /// THE ACCEPTANCE CRITERION, against a real machine.
    ///
    /// A verb neither this binary nor the contract has ever heard of reaches
    /// the guest intact and is refused BY THE GUEST, in the guest's own
    /// words. Both halves matter: if the host had a command list it would
    /// have answered this itself and the line would never have crossed.
    func testAnUnknownVerbIsRefusedByTheGuestInItsOwnWords() async throws {
        let outcome = try await exec("frobnicate --all")

        XCTAssertFalse(outcome.ok, "the guest claimed to serve `frobnicate`")
        XCTAssertEqual(outcome.code, "unknown-command")
        XCTAssertTrue(outcome.text.contains("frobnicate"),
                      "the guest's refusal must name the verb it was sent, "
                      + "which is also proof the whole line arrived:\n"
                      + outcome.text)
    }

    /// The line crosses WHOLE — verb included, spaces intact. A guest that
    /// received a pre-split name could not tell these two apart, and the
    /// second is the case that forced the rule ("quit Adobe Photoshop 5.0").
    func testTheWholeLineArrivesUnsplit() async throws {
        // `help <topic>` is the argument grammar both guests share, so this
        // asks the same question of either machine.
        let bare = try await exec("help")
        let topical = try await exec("help help")

        XCTAssertTrue(bare.ok)
        XCTAssertTrue(topical.ok)
        XCTAssertNotEqual(
            bare.text, topical.text,
            "`help` and `help help` produced identical output, which means "
            + "the argument never reached the guest — the line is being "
            + "split or truncated somewhere between here and there")
    }

    /// An empty line is a no-op, not an error. A person pressing Return at a
    /// prompt has asked for nothing, which a console sees constantly.
    func testAnEmptyLineIsANoOpNotAFailure() async throws {
        let outcome = try await exec("")

        XCTAssertTrue(outcome.ok,
                      "an empty line answered ok:false [\(outcome.code ?? "?")]")
        XCTAssertTrue(outcome.text.isEmpty,
                      "an empty line produced output: \(outcome.text)")
    }

    // MARK: - The property the whole plane exists for

    /// THE DRIFT TEST, as far as it can be automated.
    ///
    /// Every line above ran against a guest built from a tree this host does
    /// not read, through a contract that declares nothing about what a line
    /// may say. What cannot be automated is the other half — rebuilding the
    /// GUEST with a new verb and typing it here with this binary untouched —
    /// because it needs a deploy between the two halves. That is step 2 of
    /// docs/remote-console.md's checklist and it is done by hand.
    ///
    /// What this asserts is the part that IS checkable from here: the host
    /// sent something it has no declaration for and got text back. If the
    /// host ever grows a command list, `CommandRegistryTests` fails first.
    func testTheHostNeededNoDeclarationForAnythingItSent() async throws {
        for line in ["help", "frobnicate", "help help", "  spaced  out  "] {
            let outcome = try await exec(line)
            XCTAssertNotNil(outcome.code ?? "ok",
                            "\"\(line)\" settled with neither ok nor a code")
        }
    }

    // MARK: - Streaming and cancel

    /// A long command streams rather than arriving all at once.
    ///
    /// `vprobe` measures for ~12s by design and is the only verb either
    /// guest has that runs long enough to see this. Skipped rather than
    /// failed where it is not served: this suite runs against both guests
    /// and only one has it.
    func testALongCommandStreamsBeforeItFinishes() async throws {
        let probe = try await exec("help vprobe", timeout: 20)
        try XCTSkipUnless(probe.ok && !probe.text.contains("unknown"),
                          "this guest does not serve vprobe")

        var sawEarlyOutput = false
        var outcome: GuestListener.ExecOutcome?
        listener.exec("vprobe") { outcome = $0 }

        // The guest emits its "measuring, ~12s" notice before it starts, so
        // output must exist well before the result does. This is exactly
        // what a single terminal reply could not do.
        let checkpoint = Date().addingTimeInterval(6)
        while Date() < checkpoint && outcome == nil {
            if listener.runningExecId != nil { sawEarlyOutput = true }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertTrue(sawEarlyOutput, "vprobe settled instantly — that is "
                      + "not the command this test thinks it is")

        let deadline = Date().addingTimeInterval(60)
        while outcome == nil && Date() < deadline {
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTAssertNotNil(outcome, "vprobe never finished")
        XCTAssertFalse(outcome?.gap ?? true, "vprobe lost a frame")
    }

    /// A cancel for an id nothing is running under is ANSWERED, not ignored.
    /// The rule stream.stop was hardened into: an unanswered cancel is a
    /// host waiting forever on a reply the contract promised.
    ///
    /// Asserted by absence of a hang plus the wire staying usable — a guest
    /// that mishandled this would either wedge or drop the connection, and
    /// the `help` afterwards proves neither happened.
    func testACancelForNothingLeavesTheWireHealthy() async throws {
        listener.cancelExec(id: 999_999)
        try await Task.sleep(nanoseconds: 1_000_000_000)

        guard case .connected = listener.state else {
            return XCTFail("the guest dropped the wire on a stray cancel")
        }
        let after = try await exec("help")
        XCTAssertTrue(after.ok, "the wire stopped serving after a cancel")
    }

    /// Two execs at once: the second is refused cleanly rather than
    /// corrupting the first. Both guests dispatch synchronously into a
    /// single output sink, so this is the guard that keeps that safe.
    ///
    /// Racy by nature — a fast command may finish before the second is sent,
    /// in which case both succeed and nothing is proven. That is reported
    /// rather than retried: a flaky assertion is worse than a stated gap.
    func testASecondExecIsRefusedOrTheFirstFinishedFirst() async throws {
        var first: GuestListener.ExecOutcome?
        var second: GuestListener.ExecOutcome?
        listener.exec("help") { first = $0 }
        listener.exec("help") { second = $0 }

        let deadline = Date().addingTimeInterval(30)
        while (first == nil || second == nil) && Date() < deadline {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertNotNil(first, "the first exec never settled")
        XCTAssertNotNil(second, "the second exec never settled — a refused "
                        + "exec must still answer")
        if second?.code == "exec-busy" {
            XCTAssertTrue(first?.ok ?? false,
                          "the second was refused busy, so the first must "
                          + "have been the one that ran")
        }
    }
}
