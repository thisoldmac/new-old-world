import XCTest
@testable import Host

/// Replaces the build running on the PowerBook with a newly deployed one,
/// using nothing but the guest's own `launch` and `quit`.
///
///     NOW_METAL=1 NOW_68K_NEW_APP="NOW-68K 0.8" \
///     NOW_68K_OLD_PORT=5252 NOW_68K_NEW_PORT=5253 \
///     swift test --filter Metal68KHandoffTests
///
/// It SKIPS unless `NOW_68K_NEW_APP` is set, which only
/// `scripts/deploy-68k --handoff` does — see `setUp`. That is a
/// deliberate exception to "a metal gate fails rather than skips": this
/// is a deploy step and not a coverage gate, and `--filter Metal68K`
/// catches it alongside the suites that are.
///
/// This is what `launch` and `quit` were written for. `proc68.h` puts it
/// first, above the feature framing: "every probe run on this machine is
/// deploy -> quit the FTP server -> measure -> relaunch, and doing that by
/// hand each cycle is what makes people stop running probes." The last
/// manual step in the loop was a human double-clicking each new build,
/// because no Macintosh can be told to open an application over FTP — but
/// a NOW-68K already running on that machine can.
///
/// WHY TWO PORTS. Both builds read the same dev settings file beside them,
/// so the new one has to be pointed somewhere before it starts, or it
/// dials the port its predecessor already holds and is refused as busy
/// (the host serves one guest at a time). The deploy script rewrites the
/// settings file to the alternate port before launching, and the two
/// alternate on every cycle.
///
/// WHY THIS IS NOT SELF-QUITTING. `quit` refuses to quit the instance it
/// is running in — `kProcRefusedSelf` — and that refusal is deliberate.
/// But `proc68.h` says in the same breath that "a second copy is a fair
/// target", and here the copies are different files with different names,
/// so `quit "NOW-68K 0.7"` from inside 0.8 names exactly one process and
/// no guessing is involved.
///
/// THE ORDER IS THE SAFETY. The old build is only asked to quit AFTER the
/// new one has dialled in and completed its handshake. A build that
/// crashes on launch, fails to parse its settings, or cannot reach the
/// host leaves the working one running and the machine still reachable —
/// which matters when the machine is a laptop in another room.
@MainActor
final class Metal68KHandoffTests: XCTestCase {
    private var oldHost: GuestListener!
    private var newHost: GuestListener!
    private var oldPort: UInt16 = 5252
    private var newPort: UInt16 = 5253
    private var newApp = ""

    private struct GateFailure: Error, CustomDebugStringConvertible {
        var debugDescription: String { "handoff gate not met — see above" }
    }

    private func gateFailed(_ message: String) -> GateFailure {
        XCTFail(message)
        return GateFailure()
    }

    override func setUp() async throws {
        let env = ProcessInfo.processInfo.environment
        try XCTSkipUnless(env["NOW_METAL"] != nil,
                          "set NOW_METAL=1 to run against a live guest")

        // A SECOND OPT-IN, and a skip is right here for the same reason
        // NOW_QUIT_DIRTY's is in MetalQuitTests: NOW_METAL=1 says a
        // machine is available, not that this particular thing was asked
        // for. This file is not a coverage gate — it is a DEPLOY STEP
        // that needs a freshly uploaded build, two free ports, and the
        // exact HFS path of a file `scripts/deploy-68k --handoff` has
        // just put on the Mac. It sets these; nothing else does.
        //
        // It used to fail instead, and the argument for that was sound
        // in isolation — "asking for a metal run and giving no build to
        // hand off to is a broken invocation". The trouble is that
        // `--filter Metal68K` catches this class too, so an ordinary
        // metal pass over the 68K suites reported a failure that meant
        // nothing, every time. A red that always fires is a red nobody
        // reads, which costs more than the invocation check saved.
        //
        // The broken-invocation case is still a failure: set but EMPTY
        // is somebody having tried and got it wrong, and is caught below.
        guard let app = env["NOW_68K_NEW_APP"] else {
            throw XCTSkip("""
                a handoff is its own step, not part of a metal pass. \
                `scripts/deploy-68k --handoff` sets NOW_68K_NEW_APP (and \
                NOW_68K_NEW_PATH, NOW_68K_OLD_PORT, NOW_68K_NEW_PORT) \
                after uploading a build; run it rather than this filter.
                """)
        }
        guard !app.isEmpty else {
            throw gateFailed("NOW_68K_NEW_APP is set but empty. It must name "
                             + "the build to launch on the Mac, e.g. "
                             + "\"NOW-68K 0.8\" — the name the file has on "
                             + "the machine, which is the name `launch` "
                             + "searches the catalog for.")
        }
        newApp = app
        oldPort = env["NOW_68K_OLD_PORT"].flatMap { UInt16($0) } ?? 5252
        newPort = env["NOW_68K_NEW_PORT"].flatMap { UInt16($0) } ?? 5253

        // BOTH ports, because a handoff holds both at once and a
        // half-free pair is the state that produces the most confusing
        // failure here: the new build dials a port another session owns,
        // handshakes with somebody else's harness, and this one waits out
        // its 120 s and blames the build.
        try MetalMachineGuard.requireThePortIsFree(oldPort)
        try MetalMachineGuard.requireThePortIsFree(newPort)

        oldHost = GuestListener(identity: .init(version: "0.1-metal",
                                                name: "Metal Harness (old)"))
        newHost = GuestListener(identity: .init(version: "0.1-metal",
                                                name: "Metal Harness (new)"))
        oldHost.start(port: oldPort)
        newHost.start(port: newPort)
    }

    override func tearDown() async throws {
        oldHost?.stop(); oldHost = nil
        newHost?.stop(); newHost = nil
    }

    private func waitFor(_ listener: GuestListener, _ port: UInt16,
                         _ what: String, _ seconds: TimeInterval)
        async throws -> GuestListener.SessionHealth {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if case .failed(let why) = listener.state {
                throw gateFailed("could not listen for \(what) on port "
                                 + "\(port): \(why). A handoff needs both "
                                 + "ports free — this is a harness fault.")
            }
            if case .connected = listener.state, let health = listener.health {
                try await Task.sleep(nanoseconds: 300_000_000)
                return health
            }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        throw gateFailed("\(what) never dialled in on port \(port) within "
                         + "\(Int(seconds))s.")
    }

    private func run(_ listener: GuestListener, _ name: String,
                     target: String, timeout: TimeInterval = 45)
        async -> CommandResult {
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
                                 message: "no result for \(name) in "
                                          + "\(Int(timeout))s")))
            }
        }
    }

    private func text(_ result: CommandResult) -> String {
        result.output?.values.first?.first?.last
            ?? result.error.map { "[\($0.code)] \($0.message)" }
            ?? "(no message)"
    }

    func testTheOldBuildLaunchesTheNewOneAndIsRetiredByIt() async throws {
        let old = try await waitFor(oldHost, oldPort, "the running build", 120)
        // The old build's own hello names it, so the name to retire is
        // never a stale argument someone forgot to update — it is whatever
        // actually answered.
        let oldApp = "NOW-68K \(old.guestVersion ?? "?")"
        print("=== running: \(oldApp) on port \(oldPort) ===")
        print("=== launching: \(newApp), expected on port \(newPort) ===")

        guard oldApp != newApp else {
            throw gateFailed("the running build is already \(newApp). There "
                             + "is nothing to hand off to — bump "
                             + "NOW68K_APP_VERSION and deploy first.")
        }

        // Launch the EXACT path when the deploy script knows it. A bare
        // name makes the guest sweep its whole catalog to find a file
        // whose location we already know, which is slower, and hostage to
        // the search budget: a lab settings file that had shortened that
        // budget to one second failed a handoff outright. A colon-bearing
        // target skips the search (proc68.h).
        let target = ProcessInfo.processInfo
            .environment["NOW_68K_NEW_PATH"] ?? newApp
        let launched = await run(oldHost, "launch", target: target)
        print("  launch: \(text(launched))")
        guard launched.ok else {
            throw gateFailed("\(oldApp) could not launch \(target): "
                             + "\(text(launched)). Nothing was changed on "
                             + "the machine and the old build is still up.")
        }

        // The real gate. Until the new build has completed a handshake it
        // has proved nothing, and the old one must not be touched.
        let new = try await waitFor(newHost, newPort, newApp, 120)
        print("  \(newApp) handshook as v\(new.guestVersion ?? "?") "
              + "(OS \(new.guestOS ?? "?"))")
        XCTAssertEqual("NOW-68K \(new.guestVersion ?? "?")", newApp, """
            the build that dialled port \(newPort) reports version \
            \(new.guestVersion ?? "?"), which is not \(newApp). Either the \
            version was not bumped before deploying, or `launch` found an \
            older copy of that name somewhere else on the disk — both make \
            every result after this unattributable.
            """)

        // Now, and only now, retire the old one — from inside the new one,
        // which is allowed precisely because it is a different process.
        let retired = await run(newHost, "quit", target: oldApp)
        print("  quit \(oldApp): \(text(retired))")
        XCTAssertTrue(retired.ok, """
            \(newApp) is up, but \(oldApp) would not quit: \
            \(text(retired)). Both builds are now running on a 4 MB \
            machine — quit one by hand before the next cycle.
            """)

        // The host's own view is the independent half here: NOW-68K serves
        // no process.list, but the old build held a TCP session, and a
        // process that has quit cannot still be holding one.
        let deadline = Date().addingTimeInterval(30)
        var wentAway = false
        while Date() < deadline {
            if case .connected = oldHost.state {} else { wentAway = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(wentAway, """
            \(oldApp) reported that it quit, but its session on port \
            \(oldPort) is still up 30s later. Something is still running \
            and answering, so the quit did not do what it said.
            """)
        print("=== handoff complete: \(newApp) is the running build ===")
    }
}
