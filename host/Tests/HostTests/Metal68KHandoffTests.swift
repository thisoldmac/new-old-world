import XCTest
@testable import Host

/// Replaces the build running on the PowerBook with a newly deployed one,
/// using nothing but the guest's own `launch` and `quit`.
///
///     NOW_METAL=1 NOW_68K_NEW_APP="NOW-68K 0.8" \
///     NOW_68K_OLD_PORT=5252 NOW_68K_NEW_PORT=5253 \
///     swift test --filter Metal68KHandoffTests
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
/// WHY THIS IS NOT SELF-QUITTING. `proc68.h` refuses to quit the instance
/// the request arrived in — `kProcRefusedSelf` — and that refusal is
/// deliberate. But it says in the same breath that "a second copy is a
/// fair target", and here the copies are two different processes, which
/// the new build's Process Manager can tell apart perfectly.
///
/// WHY A PSN AND NOT A NAME. The retire step used to name the outgoing
/// build `"NOW-68K " + <the version it reported in hello>` — a file name
/// derived from a compiled constant. They agree by convention only, and
/// on 2026-07-25 they did not: a build deployed as 0.18 reported 0.16,
/// the guest was asked to quit a process that did not exist, said so
/// honestly, and a 4 MB machine was left running two NOW-68Ks. The
/// identity now comes off the old build's own `process.listing` (the
/// `isSelf` row) and the retire is `process.quit` against that PSN.
/// `Handoff68K` holds that logic; `HandoffIdentityTests` reproduces the
/// disagreement over loopback, so the fix is checkable without a
/// PowerBook.
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
        // Not a skip: asking for a metal run and giving no build to hand
        // off to is a broken invocation, not a decision to sit this out.
        guard let app = env["NOW_68K_NEW_APP"], !app.isEmpty else {
            throw gateFailed("NOW_68K_NEW_APP must name the build to launch "
                             + "on the Mac, e.g. \"NOW-68K 0.8\" — it is the "
                             + "name the file has on the machine, which is "
                             + "the name `launch` searches the catalog for.")
        }
        newApp = app
        oldPort = env["NOW_68K_OLD_PORT"].flatMap { UInt16($0) } ?? 5252
        newPort = env["NOW_68K_NEW_PORT"].flatMap { UInt16($0) } ?? 5253

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
        // WHO IS ON THE OTHER END, asked of the machine that knows. Not
        // "NOW-68K " + the version from its hello: that is a file name
        // guessed from a compiled constant, the two agree only by
        // convention, and on 2026-07-25 they did not — see Handoff68K.
        // The version is still read, but only to REPORT it and to refuse
        // a pointless handoff; nothing is driven by it.
        let retiree: Handoff68K.Retiree
        do {
            retiree = try await Handoff68K.identifySelf(of: oldHost)
        } catch {
            throw gateFailed("could not name the running build: \(error)")
        }
        let oldVersion = old.guestVersion ?? "?"
        print("=== running: \(retiree) reporting v\(oldVersion) "
              + "on port \(oldPort) ===")
        print("=== launching: \(newApp), expected on port \(newPort) ===")

        // A version match is a real "nothing to do"; a NAME match is not
        // necessarily anything, which is the whole lesson here — so the
        // gate reads the version, and the retire step reads the PSN.
        guard "NOW-68K \(oldVersion)" != newApp else {
            throw gateFailed("the running build already reports the version "
                             + "of \(newApp). There is nothing to hand off "
                             + "to — bump NOW68K_APP_VERSION and deploy "
                             + "first.")
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
            throw gateFailed("\(retiree.name) could not launch \(target): "
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
        // By PSN, read off the old build's own listing: the new build is
        // being told WHICH PROCESS, not which name, so a build whose file
        // name disagrees with its version is retired exactly as one whose
        // name agrees. HandoffIdentityTests proves that without hardware.
        do {
            try await Handoff68K.retire(retiree, using: newHost)
        } catch {
            XCTFail("""
                \(newApp) is up, but \(retiree) would not quit: \(error). \
                Both builds are now running on a 4 MB machine — quit one \
                by hand before the next cycle.
                """)
            throw GateFailure()
        }
        print("  quit \(retiree): delivered")

        // Delivered is not gone — the contract says so, and this is where
        // that gets checked. Two independent confirmations, because they
        // fail differently: the session drop is the host's own view (a
        // process that quit cannot still hold a TCP session), and the
        // re-list asks the NEW build about the Process Manager, which is
        // the only thing that can tell a granted quit from a declined one.
        let deadline = Date().addingTimeInterval(30)
        var wentAway = false
        while Date() < deadline {
            if case .connected = oldHost.state {} else { wentAway = true; break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(wentAway, """
            the quit for \(retiree) was delivered, but its session on port \
            \(oldPort) is still up 30s later. Something is still running \
            and answering, so the quit was declined or is sitting on a \
            dialog.
            """)

        let gone = try await Handoff68K.hasGone(retiree, accordingTo: newHost)
        XCTAssertTrue(gone, """
            \(retiree) dropped its session, but \(newApp) still lists that \
            PSN as a running process. A guest that closed its connection \
            without quitting is worse than one that never quit: the \
            machine looks clean from here and is not.
            """)
        print("=== handoff complete: \(newApp) is the running build ===")
    }
}
