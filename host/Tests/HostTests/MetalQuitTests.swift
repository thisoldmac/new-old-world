import XCTest
@testable import Host

/// Drives `quit` against a REAL guest over the wire — the acceptance test
/// for the composition described in guest/src/proc_actions.h (PowerPC) and
/// guest68k/src/proc68.h (NOW-68K). Opt-in:
///
///     NOW_METAL=1 swift test --filter MetalQuitTests
///
/// It runs against ANY live guest: the mac99 emulator (where the guest's
/// default 10.0.2.2 dials the host through SLIRP), the PowerBook 1400c, or
/// the PowerBook 180c running NOW-68K. Say which one a result came from —
/// the emulator settles nothing about timing on a 117 MHz 603e.
///
/// The subject under test is not "does the Apple Event send". It is
/// whether the guest tells the truth about the OUTCOME, because
/// `now_proc_ask_quit` returning noErr means only that the event was
/// delivered. So every assertion here is on the `Outcome` row, and where
/// the guest can be asked a SECOND time by an independent route it is —
/// a test that believes the thing it is testing proves nothing.
///
/// TWO GUESTS, TWO STRENGTHS OF CONFIRMATION. The PowerPC guest serves
/// `process.list`, so "gone" is checked against a listing produced by a
/// different code path than `quit`. NOW-68K ships only `launch` and `quit`
/// plus the keepalive and answers the contract's additive refusals
/// (`unknown-command` for a command it does not have, a generic
/// `not-implemented` error for a message family it does not have — see
/// guest68k/src/wire68.c :: handle_control_message) for everything else,
/// `process.list` included. Against that guest the independent listing
/// does not exist, so this file falls back to a WEAKER confirmation: the
/// guest's own re-evaluation through `quit`, plus the wire itself for the
/// self-refusal case. That fallback is never silent — `describeStrength()`
/// prints it, and every assertion that runs degraded says so in its own
/// failure text. The strong check still runs wherever it is available.
///
/// WHY THIS FILE FAILS INSTEAD OF SKIPPING. A skipped metal test that
/// reports `passed` is worse than no gate: this file exists to be the
/// evidence that something was watched working on real hardware, and a
/// run where all three cases skipped out of `waitForGuest` (the port was
/// held by another process) once read green. The line is drawn at the
/// human's intent:
///
///   - `NOW_METAL` unset  -> the human did not opt into a metal run. Skip.
///   - `NOW_METAL=1`      -> the human asked for metal evidence. Anything
///                           that stops the evidence being produced —
///                           nothing dialled in, the port already held, a
///                           launch that did not launch, a confirmation
///                           route that did not answer — is a FAILURE,
///                           named specifically enough to tell those
///                           conditions apart.
///
/// NOT covered here, and it needs a human: the DECLINED path. An
/// application holding an unsaved document stops to ask about it and
/// stays running, and there is no way to dirty a document from this side.
/// Open SimpleText on the machine, type a character, then run `quit
/// SimpleText` from a console and watch it come back "STILL RUNNING".
@MainActor
final class MetalQuitTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5250

    /// Which guest dialled in. The hello handshake is what says so:
    /// NOW-68K sends a FIXED `name` ("now-68k", pinned in
    /// guest68k/src/hello.h as NOW68K_HELLO_NAME) with `os` "7.1", while
    /// the PowerPC guest sends the MACHINE's name — `now_machine_name()`
    /// in guest/src/wire.c, e.g. "PowerBook 1400c" — with `os` "9".
    /// So "the hello name is exactly now-68k" identifies NOW-68K and
    /// nothing else identifies it; anything else is treated as the
    /// PowerPC guest, which is the safe default because it means the
    /// STRONGER confirmation is attempted, and a guest that cannot serve
    /// it fails loudly rather than quietly degrading.
    private enum GuestKind {
        case now68k
        case powerPC

        /// Does this guest serve `process.list`? That is the whole of the
        /// difference this file cares about.
        /// NO LONGER DERIVED FROM IDENTITY. NOW-68K gained process.list
        /// on 2026-07-25, and a file that keeps deciding this from the
        /// hello name would go on printing WEAKER against a guest that
        /// can now be corroborated independently — understating its own
        /// evidence, which is the same species of dishonesty as
        /// overstating it. `probeProcessList()` asks the guest.
        var probablyServesProcessList: Bool { self == .powerPC }

        var label: String {
            self == .now68k ? "NOW-68K" : "the PowerPC guest"
        }
    }

    /// A metal gate that did not hold. Thrown to stop the test after the
    /// failure has already been recorded with `XCTFail`, so the message a
    /// human reads is the one written here rather than XCTest's summary
    /// of a thrown error.
    private struct MetalGateFailure: Error, LocalizedError,
                                     CustomDebugStringConvertible {
        let text: String
        var errorDescription: String? { text }
        /// XCTest also prints the thrown error; keep that second line
        /// short so it points at the real message instead of repeating
        /// it in struct-dump form.
        var debugDescription: String {
            "metal gate not met — see the failure above"
        }
    }

    /// Whether THIS guest can corroborate a disappearance independently,
    /// established by asking it rather than by recognising it.
    private var strongConfirmation = false

    /// One `process.list` against the live guest. A guest that does not
    /// implement it answers `not-implemented` (routed now, so this comes
    /// back promptly rather than on a watchdog) and the run degrades to
    /// the weaker re-ask through `quit` — saying so out loud, as before.
    private func probeProcessList() async -> Bool {
        await withCheckedContinuation { cont in
            var done = false
            listener.listProcesses { result in
                guard !done else { return }
                done = true
                switch result {
                case .success(let listing):
                    print("  [probe] process.list ok, "
                          + "\(listing.processes.count) row(s)")
                    cont.resume(returning: true)
                case .failure(let why):
                    print("  [probe] process.list failed: "
                          + "[\(why.code)] \(why.message)")
                    cont.resume(returning: false)
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                guard !done else { return }
                done = true
                cont.resume(returning: false)
            }
        }
    }

    private func gateFailed(_ message: String) -> MetalGateFailure {
        XCTFail(message)
        return MetalGateFailure(text: message)
    }

    /// The application to quit. Overridable because no two of these
    /// machines hold the same software: SimpleText ships with Mac OS 8/9,
    /// where the PowerPC guest runs; the 180c's System 7.1 has TeachText.
    private func victimName(_ kind: GuestKind) -> String {
        if let named = ProcessInfo.processInfo.environment["NOW_QUIT_APP"] {
            return named
        }
        return kind == .now68k ? "TeachText" : "SimpleText"
    }

    /// The guest's own PROCESS name (not its hello name), for the
    /// self-refusal check. The emulator build is "now-guest"; the
    /// canonical PowerPC one is "New Old World"; the 68K target builds as
    /// "now68k-guest" (guest68k/CMakeLists.txt).
    private func guestSelfName(_ kind: GuestKind) -> String {
        if let named = ProcessInfo.processInfo.environment["NOW_GUEST_NAME"] {
            return named
        }
        // A DEPLOYED 68K build runs under its MacBinary name — "NOW-68K
        // 0.14" — not under the CMake target name. Guessing the target
        // name meant the self-refusal case quietly asked to quit a process
        // that does not exist, got "nothing named that is running", and
        // asserted nothing at all. It read green on metal while never
        // testing the thing it is named for.
        //
        // So take it from the hello, the way the handoff test does: the
        // name to use is whatever actually answered.
        if kind == .now68k, let version = listener.health?.guestVersion {
            return "NOW-68K \(version)"
        }
        return kind == .now68k ? "now68k-guest" : "now-guest"
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        // NOT opted in. The only skip in this file that means "the human
        // did not ask for a metal run" — every other stop is a failure.
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"))
        await startListening()
    }

    /// Binds the harness port, retrying briefly on "address already in
    /// use" — the harness racing its own teardown, not a busy port. See
    /// Metal68KTests for the full note; a port genuinely held by something
    /// else still fails with the same message.
    private func startListening() async {
        let deadline = Date().addingTimeInterval(6)
        while true {
            listener.start(port: port)
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard case .failed = listener.state, Date() < deadline else {
                return
            }
            listener.stop()
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    override func tearDown() async throws {
        listener?.stop()
        listener = nil
    }

    /// Waits for a guest and says which one it is.
    ///
    /// Under NOW_METAL=1 neither outcome here is a skip. "The port was
    /// already held" and "no Mac dialled in" are exactly the two
    /// conditions that made a green run meaningless, so they fail, and
    /// they are named apart: the first is the harness's own fault and
    /// fixed by freeing the port, the second is the machine's and fixed
    /// by dialling in.
    private func waitForGuest(_ seconds: TimeInterval = 120) async throws
        -> GuestKind {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            switch listener.state {
            case .failed(let why):
                // NWListener reports "Address already in use" here — the
                // port held by another harness, the app itself, or a
                // previous run that has not let go.
                throw gateFailed(
                    "NOW_METAL=1 asked for metal evidence, but this harness "
                    + "could not listen on port \(port): \(why). Nothing "
                    + "could have dialled in. Free the port (another test "
                    + "run, or the NOW app itself, is holding it) and run "
                    + "again — this is a harness fault, not the Mac's.")
            case .connected:
                // Let the hello settle into `health` before reading it.
                try await Task.sleep(nanoseconds: 500_000_000)
                let kind = try identifyGuest()
                // Ask, then announce. The banner used to be printed inside
                // identifyGuest, which runs BEFORE the probe — so it
                // reported the strength this file assumed rather than the
                // one it had just measured, and said WEAKER about a guest
                // that had answered process.list seconds earlier.
                strongConfirmation = await probeProcessList()
                print("=== \(describeStrength(kind)) ===")
                return kind
            case .idle, .listening:
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw gateFailed(
            "NOW_METAL=1 asked for metal evidence, but no Mac dialled in "
            + "within \(Int(seconds))s on port \(port). The harness was "
            + "listening (state: \(listener.state)), so this is the Mac's "
            + "end: check the guest is running and pointed at this host. "
            + "A metal test that did not reach a machine proves nothing, "
            + "so it fails rather than skipping.")
    }

    /// Reads the guest's identity out of the hello the host already
    /// gated on. `NOW_GUEST_KIND` overrides it for a build that renamed
    /// its hello — the detection is a string match on a constant, and a
    /// human who knows better should not have to edit this file.
    private func identifyGuest() throws -> GuestKind {
        guard let health = listener.health else {
            throw gateFailed(
                "the guest connected but the host recorded no hello "
                + "(GuestListener.health is nil), so this test cannot tell "
                + "which guest it is talking to and cannot honestly claim "
                + "either strength of confirmation.")
        }
        let kind: GuestKind
        switch ProcessInfo.processInfo.environment["NOW_GUEST_KIND"]?
            .lowercased() {
        case "68k", "now-68k", "now68k":
            kind = .now68k
        case "ppc", "powerpc", "carbon":
            kind = .powerPC
        case .some(let other):
            throw gateFailed(
                "NOW_GUEST_KIND=\(other) is not a guest this test knows: "
                + "use 68k or ppc, or unset it and let the hello decide.")
        case nil:
            // guest68k/src/hello.h :: NOW68K_HELLO_NAME.
            kind = health.guestName.caseInsensitiveCompare("now-68k")
                == .orderedSame ? .now68k : .powerPC
        }
        print("=== \(health.guestName) (v\(health.guestVersion ?? "?"), "
              + "OS \(health.guestOS ?? "?")) connected — read as "
              + "\(kind.label) ===")
        return kind
    }

    /// Said out loud on every run, so a result is never read as stronger
    /// than it is.
    private func describeStrength(_ kind: GuestKind) -> String {
        strongConfirmation
            ? "confirmation: STRONG — every disappearance is re-checked "
              + "against process.list, a different code path from quit"
            : "confirmation: WEAKER — \(kind.label) serves no process.list "
              + "(only launch and quit), so disappearance is re-checked by "
              + "asking the guest again through quit, which is the same "
              + "subsystem that just answered. Read every \"gone\" below as "
              + "the guest's own word, checked twice, not as independent "
              + "corroboration."
    }

    /// One command, with a deadline. `runCommand` has no watchdog of its
    /// own, and a guest that dies mid-test would otherwise hang this
    /// process forever — which reads as a stuck CI job rather than as the
    /// failure it is.
    private func run(_ name: String, target: String? = nil,
                     timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { cont in
            var done = false
            let finish: (CommandResult) -> Void = { result in
                guard !done else { return }
                done = true
                cont.resume(returning: result)
            }
            listener.runCommand(name,
                                args: target.map { ["target": $0] }) {
                finish($0)
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                finish(CommandResult(
                    id: 0, ok: false, output: nil,
                    error: .init(code: "harness-timeout",
                                 message: "no command.result for \(name) "
                                          + "within \(Int(timeout))s")))
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

    /// Every live process name, paged the way the agent projection pages
    /// it. PowerPC only — call it behind `strongConfirmation`.
    ///
    /// A failure here used to skip. Under NOW_METAL=1 it is a failure:
    /// this is the independent confirmation the file exists to make, and
    /// a guest that was supposed to serve it and did not is precisely
    /// "the thing we came to prove did not happen". The message names the
    /// one benign cause — a NOW-68K build this test failed to recognise —
    /// because that guest answers a generic `not-implemented` error which
    /// the host does not route, so it surfaces as a 15s `timeout`.
    private func processNames(_ kind: GuestKind) async throws -> [String] {
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
                throw gateFailed(
                    "\(kind.label) would not list processes: "
                    + "[\(f.code)] \(f.message). This test's independent "
                    + "confirmation of \"gone\" runs through process.list, "
                    + "so without it there is no evidence to report. If "
                    + "this is actually a NOW-68K guest under another "
                    + "hello name, set NOW_GUEST_KIND=68k and it will use "
                    + "the weaker quit-based check and say so.")
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

    /// Is `name` running, by the strongest route this guest offers?
    ///
    /// PowerPC: an independent listing. NOW-68K: nothing non-destructive
    /// exists, so this returns nil and the caller must say what it did
    /// instead — the fallback is deliberately not hidden behind this
    /// helper, because a helper that quietly answers "I could not check"
    /// as "it is fine" is the bug this whole file is about.
    private func isRunning(_ name: String, _ kind: GuestKind) async throws
        -> Bool? {
        guard strongConfirmation else { return nil }
        let live = try await processNames(kind)
        return live.contains {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }
    }

    /// Under NOW_METAL=1 a precondition that did not hold is a failure,
    /// not a skip: the run was asked for evidence and produced none.
    private func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw gateFailed(message) }
    }

    func testQuitTellsTheTruthAboutWhatHappened() async throws {
        let kind = try await waitForGuest()
        let victim = victimName(kind)
        let selfName = guestSelfName(kind)
        let weakNote = "(weaker check: \(kind.label) has no process.list — "
            + "this is the guest's own re-reading through quit)"

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
        // And it is still there to say so. On the PowerPC guest that is a
        // listing; on NOW-68K the WIRE answers it instead — if the guest
        // had quit itself the session would be gone and the next command
        // could not come back, so a real reply is the confirmation. That
        // one is independent of the process subsystem, unlike the checks
        // further down.
        if let running = try await isRunning(selfName, kind) {
            XCTAssertTrue(running,
                          "the guest refused to quit itself and then quit "
                          + "anyway")
        } else {
            let alive = await run("quit", target: "NoSuchApplicationHere")
            print("  still answering after the self-refusal: "
                  + "\(sentence(alive))")
            XCTAssertEqual(outcome(alive), "not-running",
                           "after refusing to quit itself, \(kind.label) "
                           + "stopped answering on the wire — which is what "
                           + "quitting itself would look like from here. "
                           + "(no process.list on this guest, so the live "
                           + "session is the confirmation)")
        }

        // 4. The real path: launch something, watch it appear, quit it,
        //    watch it go — and confirm the disappearance by the strongest
        //    route this guest has.
        result = await run("launch", target: victim)
        print("launch \(victim): "
              + (result.output?["launch"]?.first?.last ?? "failed"))
        // A launch that did not launch is not "nothing to test" — it is
        // the run failing to produce the evidence it was asked for.
        try require(result.ok,
                    "NOW_METAL=1 asked for metal evidence, but \(victim) "
                    + "would not launch on \(kind.label): "
                    + "\(sentence(result)). Nothing downstream can be "
                    + "tested; set NOW_QUIT_APP to something this machine "
                    + "actually holds.")
        try await Task.sleep(nanoseconds: 2_000_000_000)
        if let running = try await isRunning(victim, kind) {
            XCTAssertTrue(running,
                          "\(victim) was launched but is not in the process "
                          + "list")
        } else {
            // No listing to check against. The proof that it really did
            // start is the quit below coming back "gone" rather than
            // "not-running" — asserted there, so it is not lost here.
            print("  cannot confirm \(victim) appeared \(weakNote); the quit "
                  + "below must answer \"gone\", which it can only do if "
                  + "the process was there")
        }

        result = await run("quit", target: victim)
        print("quit \(victim): \(sentence(result))")
        XCTAssertTrue(result.ok, "quit failed: \(sentence(result))")
        XCTAssertEqual(outcome(result), "gone",
                       "quit must confirm by re-listing, not assume: "
                       + sentence(result)
                       + (strongConfirmation ? "" :
                          " — and on \(kind.label) this is also the only "
                          + "evidence the launch above took effect, since "
                          + "a process that never started would answer "
                          + "\"not-running\""))
        if let running = try await isRunning(victim, kind) {
            XCTAssertFalse(running,
                           "the guest reported \"gone\" while \(victim) is "
                           + "still running — this is the failure mode the "
                           + "Outcome row exists to prevent")
        } else {
            print("  \"gone\" NOT independently confirmed \(weakNote)")
        }

        // 5. And now that it is gone, the same command says so plainly.
        //    On NOW-68K this doubles as the second reading of step 4: the
        //    guest walks the Process Manager again and finds nothing.
        result = await run("quit", target: victim)
        print("quit \(victim) (again): \(sentence(result))")
        XCTAssertEqual(outcome(result), "not-running",
                       strongConfirmation ? ""
                       : "\(victim) was reported gone and then answered as "
                       + "something other than not-running \(weakNote)")
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
        // A SECOND opt-in, and a skip is right here for the same reason
        // NOW_METAL's is: this case needs a human at the keyboard, and
        // NOW_METAL=1 alone does not say one is there. Nothing below this
        // line skips.
        try XCTSkipUnless(env["NOW_QUIT_DIRTY"] != nil,
                          "set NOW_QUIT_DIRTY=1 and be ready to type")
        let kind = try await waitForGuest()
        let victim = victimName(kind)

        var result: CommandResult

        // Launching the victim ourselves is convenience, not the subject —
        // and on a machine where the human has ALREADY staged one with an
        // unsaved document it is actively wrong: classic Mac OS will hand
        // back a second copy from a different folder, and `quit` then
        // correctly refuses the whole thing as quit-ambiguous rather than
        // guessing which TeachText was meant. Watched on the 180c,
        // 2026-07-25 — the test manufactured the ambiguity it then failed
        // on. So when the scene is already set, use it.
        if env["NOW_QUIT_NO_LAUNCH"] == nil {
            result = await run("launch", target: victim)
            try require(result.ok,
                        "NOW_QUIT_DIRTY=1 asked for the declined path, but "
                        + "\(victim) would not launch on \(kind.label): "
                        + "\(sentence(result)). There is nothing to dirty.")

            let pause = env["NOW_QUIT_DIRTY_PAUSE"]
                .flatMap { Double($0) } ?? 20
            print("=== type a character into \(victim) now — "
                  + "\(Int(pause))s ===")
            try await Task.sleep(nanoseconds: UInt64(pause * 1e9))
        } else {
            print("=== using the \(victim) already running, with the "
                  + "document you dirtied (NOW_QUIT_NO_LAUNCH) ===")
        }

        result = await run("quit", target: "--wait 4 \(victim)")
        print("quit \(victim) (dirty): \(sentence(result))")
        XCTAssertFalse(result.ok, "a declined quit must not report success")
        XCTAssertEqual(result.error?.code, "quit-declined")
        // Still there. Independently on the PowerPC guest; on NOW-68K the
        // re-ask through quit is the best available, and it is the same
        // subsystem — so it is stated, not glossed.
        if let running = try await isRunning(victim, kind) {
            XCTAssertTrue(running,
                          "\(victim) is gone, so nothing declined — was the "
                          + "document dirty?")
        } else {
            let again = await run("quit", target: "--no-wait \(victim)")
            print("  still-running re-check \(sentence(again)) (weaker "
                  + "check: \(kind.label) has no process.list)")
            XCTAssertNotEqual(outcome(again), "not-running",
                              "\(victim) is gone, so nothing declined — was "
                              + "the document dirty? (weaker check: this is "
                              + "the guest re-reading its own process list "
                              + "through quit, not an independent listing)")
        }
    }

    /// --no-wait is the deliberately unconfirmed path: it must SAY it is
    /// unconfirmed rather than borrow the confident answer.
    func testNoWaitReportsItselfUnconfirmed() async throws {
        let kind = try await waitForGuest()
        let victim = victimName(kind)

        var result = await run("launch", target: victim)
        try require(result.ok,
                    "NOW_METAL=1 asked for metal evidence, but \(victim) "
                    + "would not launch on \(kind.label): "
                    + "\(sentence(result)). The --no-wait path cannot be "
                    + "exercised without a running process; set "
                    + "NOW_QUIT_APP to something this machine holds.")
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
