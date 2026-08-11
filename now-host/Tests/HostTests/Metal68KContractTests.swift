import XCTest
@testable import Host

/// Three things the contract promises that nothing had ever provoked on a
/// real machine, now that the deploy loop makes provoking them cheap.
///
///     NOW_METAL=1 NOW_METAL_PORT=5252 swift test --filter Metal68KContract
///
/// All three are about NOW-68K being the INCOMPLETE guest. It implements
/// almost none of the contract, and that is legal — the contract is
/// explicitly additive, and "I do not do that" is an answer, not a fault.
/// What had never been checked is that the honest refusals actually
/// arrive, and that the connection survives them. A guest that refuses
/// cleanly and a guest that has stopped listening look identical from the
/// host until you test the difference.
///
/// Same opt-in rule as every metal gate here: `NOW_METAL` unset skips,
/// everything after it fails.
@MainActor
final class Metal68KContractTests: XCTestCase {
    private var listener: GuestListener!
    private var port: UInt16 = 5252

    private struct GateFailure: Error, CustomDebugStringConvertible {
        var debugDescription: String { "metal gate not met — see above" }
    }

    private func gateFailed(_ message: String) -> GateFailure {
        XCTFail(message)
        return GateFailure()
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")
        port = env["NOW_METAL_PORT"].flatMap { UInt16($0) } ?? 5252
        // Whether the machine is free, before whether the right guest
        // answers it (MetalMachineGuard). This process's own sockets are
        // excluded, so the self-race `startListening` absorbs below is
        // invisible here and stays absorbed.
        try MetalMachineGuard.preflight(port: port)
        listener = GuestListener(identity: .init(version: "0.1-metal",
                                                 name: "Metal Harness"))
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

    @discardableResult
    private func waitFor68K(_ seconds: TimeInterval = 120) async throws
        -> GuestListener.SessionHealth {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .failed(let why) = listener.state {
                throw gateFailed("could not listen on port \(port): \(why) "
                                 + "— a harness fault, not the Mac's.")
            }
            if case .connected = listener.state, let health = listener.health {
                try await Task.sleep(nanoseconds: 400_000_000)
                guard health.guestName == "now-68k" else {
                    throw gateFailed("\(health.guestName) dialled in, not "
                                     + "NOW-68K. These assertions are about "
                                     + "the incomplete guest and would go "
                                     + "green for the wrong reason against "
                                     + "the PowerPC one.")
                }
                return health
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw gateFailed("no Mac dialled in within \(Int(seconds))s on port "
                         + "\(port).")
    }

    private func run(_ name: String, target: String,
                     timeout: TimeInterval = 30) async -> CommandResult {
        await withCheckedContinuation { cont in
            var done = false
            let finish: (CommandResult) -> Void = {
                guard !done else { return }
                done = true
                cont.resume(returning: $0)
            }
            listener.runCommand(name, args: ["target": target]) { finish($0) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9))
                finish(CommandResult(
                    id: 0, ok: false, output: nil,
                    error: .init(code: "harness-timeout",
                                 message: "no result in \(Int(timeout))s")))
            }
        }
    }

    private func stillTalking(_ note: String) async throws {
        let alive = await run("quit", target: "NoSuchApplicationHere")
        XCTAssertTrue(alive.ok, """
            the wire did not survive \(note): a plain command afterwards \
            answered \(alive.error?.code ?? "nothing"). Surviving is the \
            whole claim — refusing a message must cost one message, never \
            the connection.
            """)
    }

    // MARK: - 1. the error nobody had ever provoked

    /// `error {code:"not-implemented"}` is NOW-68K's answer to a message
    /// family it does not have, and it had never been emitted anywhere —
    /// on metal or in an emulator. Its fixture in GuestWireFixtureTests is
    /// a claim read off `send_error_reply`, not evidence from a wire.
    ///
    /// `file.move` provokes it: NOW-68K will say what is on its disk and
    /// carry bytes both ways, but does not change the shape of that disk
    /// on request, so the mutations fall through to the generic reply.
    /// What this asserts is that the refusal ARRIVES and the session
    /// survives it — for a partial guest, refusals are ordinary traffic,
    /// and a guest that refuses cleanly must not be confusable with one
    /// that died.
    ///
    /// This canary was `file.list` until 2026-07-26, when that message
    /// was implemented and the test began failing by SUCCEEDING. A test
    /// whose subject is "something not implemented" has to be repointed
    /// every time the gap it names gets closed — which is a good problem,
    /// and worth the two lines of maintenance rather than picking a
    /// message nobody will ever implement.
    func testAnUnimplementedMessageIsRefusedAndSaysSo() async throws {
        try await waitFor68K()

        // Through the real API a caller would use, so the assertion is
        // about what a CALLER experiences, not about a frame going by.
        let started = Date()
        let failure: GuestListener.FileFailure? =
            await withCheckedContinuation { cont in
                var done = false
                listener.moveFile(from: "NOW no such file",
                              to: "NOW no such file 2") { result in
                    guard !done else { return }
                    done = true
                    switch result {
                    case .success: cont.resume(returning: nil)
                    case .failure(let why): cont.resume(returning: why)
                    }
                }
            }
        let waited = Date().timeIntervalSince(started)
        let seen = listener.lastGuestError

        XCTAssertEqual(failure?.code, "not-implemented", """
            file.move came back as \(failure?.code ?? "success") after \
            \(String(format: "%.1f", waited))s. A refusal the guest sent \
            immediately must reach the caller as that refusal — if this \
            says "timeout", the host is still dropping guest errors and \
            every unimplemented request costs 15s and explains nothing.
            """)
        XCTAssertLessThan(waited, 10, """
            the refusal took \(String(format: "%.1f", waited))s, which is \
            watchdog territory, not answer territory.
            """)

        guard let seen else {
            throw gateFailed("""
                file.move drew no error at all. Either the guest \
                answered something else, or it answered nothing — and \
                silence is the one thing the contract does not allow here: \
                "never a protocol error; that is what keeps commands \
                additive" cuts both ways, and a request that is refused \
                must SAY it was refused rather than leave a waiter to time \
                out with no reason.
                """)
        }
        print("=== error provoked: [\(seen.code)] \(seen.message)")
        XCTAssertEqual(seen.code, "not-implemented",
                       "the only code send_error_reply emits")
        XCTAssertNotNil(seen.id, """
            the error carried no id, so nothing could have been \
            unblocked by it — the caller above was rescued by a \
            watchdog rather than answered.
            """)
        try await stillTalking("an unimplemented request")
    }

    // MARK: - 2. the oversized control frame nobody had ever sent

    /// A control frame larger than the guest's 4 KB receive buffer but
    /// inside the protocol's legal 32 KB must be SKIPPED, not fatal —
    /// "skipping it costs one message; dropping the connection costs
    /// everything in flight and looks like a network fault instead of a
    /// message we could not read" (frame.h). 837 native checks cover the
    /// reader's side of that. Nothing in NOW had ever SENT one, so the
    /// host's half of the bargain was pure assumption.
    ///
    /// A command with a very long argument is the honest way to produce
    /// one: it is a legal frame the host can really build, not a test
    /// harness poking bytes onto the wire that no code path would emit.
    func testAnOversizedControlFrameCostsOneMessageNotTheWire() async throws {
        try await waitFor68K()

        // Comfortably over the guest's 4096-byte control buffer, well
        // under the protocol's 32768 ceiling — the band where "legal but
        // bigger than I can hold" lives.
        let huge = String(repeating: "Z", count: 8000)
        let result = await run("quit", target: huge, timeout: 25)

        // Either answer is contract-legal, and which one arrives says
        // something worth knowing, so both are reported rather than one
        // being quietly accepted.
        if result.error?.code == "harness-timeout" {
            print("=== the oversized frame was SKIPPED (no reply) — the "
                  + "documented behaviour: one message lost, connection "
                  + "kept")
        } else {
            print("=== the oversized frame was ANSWERED: "
                  + "[\(result.error?.code ?? "ok")] — so it fitted after "
                  + "all, and this did not exercise the skip path")
        }

        // The claim under test is the connection, not the reply.
        try await stillTalking("an oversized control frame")
        print("=== frame sync survived: the next command answered normally")
    }

    // MARK: - 3. the confirm wait under a second request

    /// `quit`'s confirm wait yields with an event mask of zero and pumps
    /// the wire each pass, with a re-entrancy guard so a command arriving
    /// mid-wait cannot recurse into it (proc68.h). Neither the pump nor
    /// the guard had ever been observed with a second request actually in
    /// flight — and an automated probe loop is exactly what produces
    /// overlapping requests.
    ///
    /// So: start a `quit` that must wait out its full window on a name
    /// that is not running, and fire a second command into the middle of
    /// it. Both must answer.
    func testASecondRequestArrivesDuringTheConfirmWait() async throws {
        try await waitFor68K()

        let slow = Task { @MainActor in
            await self.run("quit", target: "--wait 6 NoSuchApplicationHere",
                           timeout: 40)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let interloper = Task { @MainActor in
            await self.run("launch", target: "", timeout: 40)
        }

        let (first, second) = await (slow.value, interloper.value)
        print("  during-wait quit:  \(first.error?.code ?? "ok") "
              + "\(first.output?.values.first?.first?.last ?? "")")
        print("  interloping launch: \(second.error?.code ?? "ok") "
              + "\(second.error?.message ?? "")")

        XCTAssertNotEqual(first.error?.code, "harness-timeout", """
            the quit never answered while a second request was in flight. \
            The wait is supposed to pump the wire each pass; if it stopped \
            doing that, every command issued during a wait is lost.
            """)
        XCTAssertNotEqual(second.error?.code, "harness-timeout", """
            the second request never answered. It arrived during a confirm \
            wait, which is precisely the case the re-entrancy guard exists \
            for — a guard that drops the request instead of deferring it \
            is not a guard, it is a hole.
            """)
        // launch with an empty target is a bad-args refusal, which is a
        // real answer and proves the request was PROCESSED, not merely
        // acknowledged.
        XCTAssertEqual(second.error?.code, "launch-bad-args",
                       "the interloping request was answered on its merits")
        try await stillTalking("two overlapping requests")
    }
}
