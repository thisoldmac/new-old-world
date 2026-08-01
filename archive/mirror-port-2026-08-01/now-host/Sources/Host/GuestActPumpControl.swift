import Foundation

/// Asks the connected guest's act pump how it is doing, over the listener's
/// `actstate` command, and reports honestly. This is the seam
/// `MirrorModuleModel` declares (`MirrorPumpControl`) and constructs nothing
/// against on its own — see that type's header for why: "Not a new wire
/// verb."
///
/// **It sends nothing to make the pump start.**
/// `now-guest-ppc/src/act/act_session.c :: now_act_session_service` launches
/// the pump on its own the moment this Mac's wire session opens — a click
/// has to be posted from a CLASSIC process's own context, and nothing this
/// side of the wire can reach into that context to ask for one. The launch
/// is one attempt per session (`g_launch_tried`), made as soon as
/// `conn_is_connected()` goes true, which on this side is exactly the
/// moment a guest is `.connected` — so by the time a person presses Start
/// Mirror, the guest has usually already tried.
///
/// `start()` therefore POLLS `actstate` rather than reading it once: the
/// guest's launch can still take a few event-loop passes, and on real
/// hardware, real wall-clock time for `LaunchApplication` to return — and a
/// single "never attached" read would describe a pump still on its way up
/// as permanently missing (`kNowPeekActPumpGraceTicks` in
/// `contract/peek_table.h` gives it 30 seconds, precisely because a launch
/// is not instant). `stop()` sends nothing at all: the guest quits its own
/// pump when the WIRE session ends (`session_quit_pump`, same file), not
/// when this page's Start/Stop toggle does — this side has no verb to ask
/// for that early, and inventing a local-only "stop" the guest was never
/// asked to honour would be exactly the kind of thing `SceneProjection`'s
/// own header warns against for a different verb.
@MainActor
final class GuestActPumpControl: MirrorPumpControl {
    private let listener: GuestListener
    private let attempts: Int
    private let delayNanoseconds: UInt64

    /// `attempts`/`delayNanoseconds` are a test seam. Production keeps the
    /// defaults (a few seconds of patience, well inside the guest's own
    /// 30-second grace window); a test shortens the wait so it does not sit
    /// through it.
    init(listener: GuestListener, attempts: Int = 8,
         delayNanoseconds: UInt64 = 400_000_000) {
        self.listener = listener
        self.attempts = max(1, attempts)
        self.delayNanoseconds = delayNanoseconds
    }

    func start() async -> MirrorPumpOutcome {
        var lastPumpWord = "never attached"
        for attempt in 0..<attempts {
            switch await query() {
            case .settled(let outcome):
                return outcome
            case .stillLaunching(let word):
                lastPumpWord = word
                if attempt + 1 < attempts {
                    try? await Task.sleep(nanoseconds: delayNanoseconds)
                }
            }
        }
        return .refused(
            "the act pump still reports \"\(lastPumpWord)\" after "
                + "\(attempts) actstate checks — see actstate's Pump row on "
                + "the guest for what it is doing")
    }

    func stop() {
        /* Deliberately nothing. See the type's header: the guest tears its
           own pump down on the wire session's own end, not on this page's
           Stop. Nothing here holds state a second call could see
           differently, so idempotence costs nothing to guarantee. */
    }

    // MARK: - actstate, read and classified

    private enum Poll {
        case settled(MirrorPumpOutcome)
        case stillLaunching(String)
    }

    private func query() async -> Poll {
        await withCheckedContinuation { continuation in
            listener.runCommand("actstate") { result in
                continuation.resume(returning: Self.classify(result))
            }
        }
    }

    /// `actstate`'s rows, read the way `mach_actstate.c` writes them: label,
    /// value pairs under the `"actstate"` group (`x-rowArray`, the same
    /// shape `gestalt` and every other counters verb use). Nothing here
    /// re-decides what the guest's words mean — it matches them literally,
    /// because a second reading of "ready" or "running" is how two answers
    /// to one question start.
    private static func classify(_ result: CommandResult) -> Poll {
        guard result.ok else {
            let message = result.error?.message ?? "actstate refused"
            if result.error?.code == "unknown-command" {
                return .settled(.unsupported(
                    "this guest build has no actstate verb, so its act "
                        + "pump cannot be asked about: " + message))
            }
            return .settled(.refused(message))
        }
        guard let rows = result.rows("actstate") else {
            return .settled(.refused(
                "actstate answered with no rows to read"))
        }
        var fields: [String: String] = [:]
        for row in rows where row.count >= 2 {
            fields[row[0]] = row[1]
        }

        // Any state short of "ready" — no table, stale, wrong format
        // (a V3 resident), or dark (this build ships the plane off) — is
        // exactly the set of states `now_act_pump()` also refuses, so the
        // pump region below would be absent for every one of them anyway.
        // Checked here first for the clearer sentence.
        let plane = fields["Plane"] ?? "no table"
        guard plane == "ready" else {
            let note = fields["Note"].map { " (\($0))" } ?? ""
            return .settled(.unsupported(
                "the act plane is \(plane)\(note)"))
        }
        // Present only when the extension predates the V4 pump handshake
        // (mach_actstate.c returns right after writing this row).
        if let region = fields["Pump region"] {
            return .settled(.unsupported("the act pump region is \(region)"))
        }
        guard let pump = fields["Pump"] else {
            return .settled(.unsupported(
                "actstate reported no Pump row, which a plane reporting "
                    + "ready should always carry"))
        }
        guard pump == "running" else {
            return .stillLaunching(pump)
        }
        return .settled(.started)
    }
}
