import XCTest
@testable import Host

/// The NOW-68K paths that had never run anywhere — on metal or in an
/// emulator — driven against the real PowerBook 180c.
///
///     NOW_METAL=1 swift test --filter Metal68KTests
///
/// `MetalQuitTests` covers `quit`'s outcome table against either guest.
/// This file covers what is specific to the 68K guest and what only a
/// machine can settle: that the wire still works after the frame reader
/// moved out of `wire68.c`, that a bounded catalog search says it was
/// bounded, that the farewell is orderly, and that the redial comes back.
///
/// SAME OPT-IN RULE AS THE OTHER METAL GATES, for the same reason: a
/// gate that reads green having never reached a machine is worse than no
/// gate. `NOW_METAL` unset skips — the human did not ask for a metal run.
/// Everything downstream of that opt-in fails. Two cases need a human to
/// do something at the keyboard as well, and carry their own second
/// opt-in rather than silently proving nothing.
///
/// The guest has no preferences at all: it dials whatever host and port
/// the human types at launch. So the port here must be the one typed on
/// the 180c, not whatever a previous run used.
@MainActor
final class Metal68KTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5250

    /// The 68K guest's fixed hello name (`guest68k/src/hello.h ::
    /// NOW68K_HELLO_NAME`). The PowerPC guest sends the MACHINE's name
    /// here instead, so this is what tells them apart on the wire.
    private let helloName = "now-68k"

    private struct MetalGateFailure: Error, CustomDebugStringConvertible {
        let text: String
        var debugDescription: String { "metal gate not met — see above" }
    }

    private func gateFailed(_ message: String) -> MetalGateFailure {
        XCTFail(message)
        return MetalGateFailure(text: message)
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5250
        // Whether the machine is free, before whether the right guest
        // answers it (MetalMachineGuard). This process's own sockets are
        // excluded, so the self-race `startListening` absorbs below is
        // invisible here and stays absorbed.
        try MetalMachineGuard.preflight(port: port)
        listener = GuestListener(identity: .init(
            version: "0.1-metal", name: "Metal Harness"))
        await startListening()
    }

    /// Binds the harness port, retrying briefly on "address already in
    /// use".
    ///
    /// Not papering over a real conflict: a port genuinely held by
    /// something else (the NOW app itself lives on 5250) still fails, with
    /// the same message as before. What this absorbs is the harness racing
    /// ITSELF — `stop()` sets state to .idle at once while NWListener
    /// cancels asynchronously, so the next test in the same suite can ask
    /// for a port its predecessor has not finished releasing. That failed
    /// two of five tests here on the 180c while the other three passed
    /// against the same live guest, which is the signature of a race
    /// rather than a busy port.
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

    /// Waits for NOW-68K specifically. Anything else that dials in is a
    /// failure, not a skip: this file's assertions are about the 68K
    /// guest, and running them against the PowerPC one would produce a
    /// green result that means something else entirely.
    @discardableResult
    private func waitFor68K(_ seconds: TimeInterval = 120) async throws
        -> GuestListener.SessionHealth {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            switch listener.state {
            case .failed(let why):
                throw gateFailed(
                    "NOW_METAL=1 asked for metal evidence, but this "
                    + "harness could not listen on port \(port): \(why). "
                    + "Nothing could have dialled in — free the port and "
                    + "run again. This is a harness fault, not the Mac's.")
            case .connected:
                try await Task.sleep(nanoseconds: 500_000_000)
                guard let health = listener.health else {
                    throw gateFailed("a guest connected but sent no usable "
                                     + "hello — nothing to test against.")
                }
                guard health.guestName == helloName else {
                    throw gateFailed(
                        "\"\(health.guestName)\" dialled in, not NOW-68K. "
                        + "The PowerPC guest sends its machine's name and "
                        + "the 68K guest sends the fixed \"\(helloName)\", "
                        + "so this is the 1400c (or the emulator) on the "
                        + "port the 180c was meant to use. These "
                        + "assertions are about the 68K guest; running "
                        + "them against another one would go green for "
                        + "the wrong reason.")
                }
                return health
            case .idle, .listening:
                break
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw gateFailed(
            "NOW_METAL=1 asked for metal evidence, but no Mac dialled in "
            + "within \(Int(seconds))s on port \(port). The harness WAS "
            + "listening (state: \(listener.state)), so this is the Mac's "
            + "end: NOW-68K has no preferences and dials only what the "
            + "human types at launch — check the host and port on the "
            + "180c. If MacTCP has wedged, the dial never completes and "
            + "nothing on this side can tell you so; reboot it.")
    }

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

    private func message(_ result: CommandResult) -> String {
        result.output?.values.first?.first?.last
            ?? result.error.map { "[\($0.code)] \($0.message)" }
            ?? "(no message)"
    }

    // MARK: - the reader extraction

    /// The frame reader moved out of `wire68.c` into `n68_reader.c`
    /// behind an ops table, and 837 native checks say the state machine
    /// is correct. None of that is evidence that the guest still talks:
    /// dial, handshake and keepalive all run through the code that
    /// moved, and their only witness is this machine.
    ///
    /// So this asserts the three things the extraction could have broken
    /// and a native test cannot see — the handshake completed, the guest
    /// pings unprompted after its 30s of silence and the host's pong
    /// gets back, and a control frame in each direction still round
    /// trips afterwards.
    func testTheWireStillWorksAfterTheReaderExtraction() async throws {
        let health = try await waitFor68K()
        print("=== \(health.guestName) v\(health.guestVersion ?? "?") "
              + "(OS \(health.guestOS ?? "?")) connected ===")

        XCTAssertEqual(health.guestOS, "7.1",
                       "the 68K guest reports the system it is running on")

        // The keepalive is GUEST-driven: it pings after 30s of wire
        // silence. So say nothing — a command here would reset that
        // silence and the ping would never come.
        let deadline = Date().addingTimeInterval(75)
        var answered = 0
        while Date() < deadline {
            answered = listener.health?.pingsAnswered ?? 0
            if answered > 0 { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertGreaterThan(answered, 0, """
            no ping arrived within 75s of silence. The guest pings after \
            30s of quiet, so either the reader is not delivering the \
            host's frames or the guest's timer never fired — both are \
            regressions the native tests cannot see.
            """)
        print("  keepalive: \(answered) ping(s) answered")

        // Now a round trip, which proves a control frame still crosses in
        // both directions AFTER the reader has been through a ping cycle.
        // "quit" of a name that is not running is the harmless one: it
        // changes nothing on the machine and still exercises the whole
        // request/dispatch/reply path.
        let result = await run("quit", target: "NoSuchApplicationHere")
        XCTAssertTrue(result.ok, """
            the round trip after the keepalive failed: \
            \(message(result)). The frame reader is the shared path for \
            every message, so a break here is a break in everything.
            """)
        print("  round trip: \(message(result))")
        print("=== the reader extraction is metal-verified on this machine")
    }

    // MARK: - process.list

    /// The gap the ledger called "the next gap worth closing" from the day
    /// this guest shipped: `proc_list` existed, was bounded, and was used
    /// internally by `quit` — but nothing on the wire could reach it, so a
    /// human had to read the Application menu on the machine to know what
    /// was running.
    ///
    /// It is not a convenience. Without an independent listing, `quit`'s
    /// confirmation of "gone" is weaker BY CONSTRUCTION: it re-asks
    /// through `quit`, the same subsystem that just answered. Every
    /// measurement built on this machine inherited that. What this asserts
    /// is that the listing arrives, that it is a genuinely different code
    /// path from `quit` (it can see a process `quit` was never asked
    /// about), and that paging terminates.
    func testTheGuestCanFinallySayWhatIsRunning() async throws {
        try await waitFor68K()

        var names: [String] = []
        var cursor: Int? = nil
        var pages = 0
        while pages < 10 {
            pages += 1
            let listing: ProcessListing? = await withCheckedContinuation {
                cont in
                var done = false
                listener.listProcesses(cursor: cursor) { result in
                    guard !done else { return }
                    done = true
                    cont.resume(returning: try? result.get())
                }
            }
            guard let listing else {
                throw gateFailed("process.list page \(pages) failed. If the "
                                 + "guest answered not-implemented, this is "
                                 + "a build older than the one that serves "
                                 + "it — check the version in the banner "
                                 + "above.")
            }
            names.append(contentsOf: listing.processes.map(\.name))
            print("  page \(pages): \(listing.processes.map(\.name))")
            guard listing.more, let next = listing.cursor else { break }
            cursor = next
        }

        XCTAssertLessThan(pages, 10, """
            paging never terminated. A cursor that does not advance past \
            the last row makes the host page forever, which is worse than \
            no listing at all.
            """)
        XCTAssertFalse(names.isEmpty, "something is running on that Mac")
        XCTAssertTrue(names.contains { $0.hasPrefix("NOW-68K") }, """
            the listing does not include NOW-68K itself, and it is \
            demonstrably running — it just answered this request. A \
            listing that cannot see the process asking is not a listing.
            """)

        // The independence check. `quit` of a name that is not running
        // reports not-running; the listing sees processes nobody asked
        // quit about. Those are different code paths, which is the whole
        // point of having this one.
        print("=== \(names.count) process(es): \(names.joined(separator: ", "))")
    }

    // MARK: - the bounded launch search

    /// `launch` of a bare name searches the startup volume, and the
    /// search is double-bounded on purpose: a whole-volume Finder-style
    /// search has hard-wedged this fleet before, badly enough to need a
    /// physical reboot. The bound is ~20s of wall clock
    /// (`kLaunchSearchBudgetTicks`).
    ///
    /// The branch that has never run is what happens when that budget
    /// runs out first. It must say the search was cut short — "not found
    /// so far, may exist deeper in the catalog" — because a bounded
    /// search reporting a clean "not found" is a lie of exactly the kind
    /// this project keeps paying for: it looks like an answer and is
    /// really a shrug.
    func testABoundedLaunchSearchSaysItWasBounded() async throws {
        try await waitFor68K()

        let absent = "ZzNoSuchApplicationOnThisDisk"
        let started = Date()
        // Longer than the guest's own budget, so the harness timeout
        // cannot be mistaken for the guest's bound. Overridable because
        // "~20s" is a tick count on a machine nobody has timed: the 180c
        // reads its catalog off a BlueSCSI-emulated disk, and the first
        // metal run of this blew straight through 60s.
        let budget = ProcessInfo.processInfo.environment[
            "NOW_68K_LAUNCH_TIMEOUT"].flatMap(TimeInterval.init) ?? 60
        // Watch the WIRE while the search runs, not just the reply. The
        // search is supposed to pump between slices (yield_ticks(0)); if
        // instead the guest goes deaf, the host's idle timeout kills the
        // session and the reply is written to a dead socket — which
        // looks identical to "no answer" from the reply's side alone,
        // and is a completely different bug.
        let watcher = Task { @MainActor [listener] in
            var wentAway: TimeInterval?
            let from = Date()
            while !Task.isCancelled {
                if case .connected = listener!.state {} else if wentAway == nil {
                    wentAway = Date().timeIntervalSince(from)
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            return (wentAway, listener!.lastDisconnect)
        }
        let result = await run("launch", target: absent, timeout: budget)
        let elapsed = Date().timeIntervalSince(started)
        watcher.cancel()
        let (wentAway, why) = await watcher.value
        if let wentAway {
            print("  the wire DIED \(String(format: "%.0f", wentAway))s "
                  + "into the search: \(why ?? "(no reason)"). The guest "
                  + "stopped servicing it — so the search does not pump "
                  + "the wire the way its yield_ticks(0) intends, and any "
                  + "reply it later writes goes to a closed socket.")
        } else {
            print("  the wire stayed up for the whole search")
        }
        let text = message(result)
        let timedOut = result.error?.code == "harness-timeout"
        print("  launch \(absent) -> \(text) (\(String(format: "%.1f", elapsed))s)")

        XCTAssertFalse(result.ok,
                       "launching a name that is not on the disk cannot "
                       + "succeed, and it answered: \(text)")

        // The exact sentences proc68.c :: launch_bare_name emits. Matched
        // literally rather than by a guessed keyword: the first version of
        // this looked for "not found" and failed a perfectly good run,
        // because the plain-miss sentence is "nothing named X is on the
        // startup volume" and never contains that phrase.
        let saidBounded = text.contains("truncated at the time budget")
            || text.contains("may exist deeper in the catalog")
        let saidNotFound = text.contains("is on the startup volume")
            || text.contains("ROOT folder only")   // PBCatSearch unusable
            || text.contains("not found")          // the full-path path

        XCTAssertTrue(saidBounded || saidNotFound, """
            neither documented outcome: \(text). launch_bare_name answers \
            either a bounded-search sentence or a plain "not found"; a \
            third shape means the search failed some other way.
            """)

        // The real guard. The budget is ~20s; if the guest spent it and
        // then reported a clean "not found", the truncation branch did
        // not fire and every future "not found" from this command is
        // unreliable.
        if elapsed >= 19, !saidBounded {
            XCTFail("""
                the search ran \(String(format: "%.1f", elapsed))s — at or \
                past its ~20s budget — and still answered "\(text)". A \
                search that was cut short must say so; reporting a clean \
                "not found" turns a shrug into an answer.
                """)
        }
        if saidBounded {
            print("=== the truncation branch has now run on metal")
        } else if timedOut {
            print("  NOTE: no answer at all within "
                  + "\(String(format: "%.0f", budget))s. That is not the "
                  + "truncation branch failing to SAY it was bounded — it "
                  + "is the whole command failing to answer, which is a "
                  + "worse thing and a different bug.")
        } else {
            print("  NOTE: the search completed within its budget "
                  + "(\(String(format: "%.1f", elapsed))s), so the "
                  + "TRUNCATION branch did not fire and remains unrun. "
                  + "This machine's catalog is small enough to finish — "
                  + "it is not evidence that the branch works.")
        }
    }

    // MARK: - the farewell (needs a human)

    /// Every close this project has watched was the abortive path. The
    /// contract asks a guest leaving on purpose to announce it —
    /// `bye {code, reason?}` before the TCP close — because a silent
    /// close is indistinguishable from a crash or a closed lid, and the
    /// difference is the whole reason the keepalive and `bye` are
    /// separate mechanisms.
    ///
    /// Needs a human: NOW-68K refuses to quit itself (`quit-refused`), so
    /// nothing on this side can provoke it. Quit the app on the 180c —
    /// menu, not a force-quit — while this waits.
    func testTheFarewellIsOrderly() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_68K_BYE"] != nil, """
            set NOW_68K_BYE=1 and quit NOW-68K on the 180c by hand while \
            this runs — the guest will not quit itself, so there is no \
            way to prove this without someone at the keyboard.
            """)
        try await waitFor68K()
        print("=== quit NOW-68K on the 180c now (File > Quit, not a "
              + "force-quit) ===")

        let deadline = Date().addingTimeInterval(120)
        var reason: String?
        while Date() < deadline {
            if let seen = listener.lastDisconnect { reason = seen; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }

        guard let reason else {
            throw gateFailed("the guest never disconnected within 120s. "
                             + "Nothing was proved either way.")
        }
        print("  disconnect reason: \(reason)")

        // GuestListener writes "Connection lost" for a wire that simply
        // stopped and the bye's own description for one that said
        // goodbye. That is exactly the distinction under test.
        XCTAssertFalse(reason.hasPrefix("Connection lost"), """
            the guest vanished instead of saying goodbye: "\(reason)". \
            An orderly quit must send bye first — a close the host can \
            only discover by its own timeout is the crash path, and if \
            the two look identical the host can never tell a quit from a \
            dead machine.
            """)
        print("=== the farewell is metal-verified on this machine")
    }

    // MARK: - the redial (needs a human to have armed it)

    /// The 68K guest redials at a fixed interval the human starts and
    /// stops — no capped backoff, which is what the contract's reconnect
    /// clause was amended to admit. It has never been driven to failure
    /// and back.
    ///
    /// This takes the host away mid-session and puts it back, which is
    /// the ordinary case in a dev loop: the harness restarts far more
    /// often than the Mac does.
    func testTheGuestComesBackAfterTheHostGoesAway() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_68K_REDIAL"] != nil, """
            set NOW_68K_REDIAL=1 and tick "Retry every 5s" on the 180c \
            first — the redial is human-armed by design, so without that \
            checkbox this would prove only that it stayed away.
            """)
        try await waitFor68K()
        print("=== dropping the host; the guest should redial ===")

        listener.stop()
        try await Task.sleep(nanoseconds: 3_000_000_000)
        listener.start(port: port)

        // 5s cadence armed by the human, plus MacTCP's own connect
        // latency on a 33 MHz machine over emulated ethernet. 90s is
        // generous on purpose: the claim is "it comes back", not "it
        // comes back fast".
        let health = try await waitFor68K(90)
        print("  \(health.guestName) redialled and re-helloed")
        XCTAssertEqual(health.guestOS, "7.1",
                       "the reconnect re-handshakes; a reconnect that "
                       + "skipped hello would not be the contract's")
        print("=== the redial is metal-verified on this machine")
    }
}
