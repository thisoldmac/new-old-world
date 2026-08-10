import Foundation
import NOWAgentIntegration

/// Runs one named diagnostic on the connected machine and renders its rows.
///
/// One object for three capabilities, because they are one lane: three
/// argument-less verbs, one row shape, and one thing that must never happen
/// twice at once. The three ROWS above it are separate — they are served by
/// different guests — which is the whole argument in
/// `GuestDiagnosticsProjection`; nothing about that argument reaches this
/// file, and nothing here asks which guest answered.
///
/// What this object exists to do:
///
/// - **Bound the wait.** `GuestListener.runCommand` arms no watchdog, and
///   unlike `catsearch` these verbs have no guest-side give-up either: a
///   `vprobe` runs a full-screen read to completion and answers when it is
///   done. So this bound is the only one in the chain
///   (`AgentIntegrationDiagnosticsPolicy.commandTimeout`), and it sits under
///   the local socket's window for the operation.
/// - **Refuse a second one, across all three.** Two full-screen reads in
///   flight on a cooperatively-scheduled Mac are not concurrency — they are
///   the first one's numbers made meaningless. The guard is per LANE and not
///   per verb, for the same reason: `vprobe` and `shotdiag` measure the same
///   framebuffer, and the guests already refuse their own re-entry
///   (`vprobe68_run` answers `kVProbe68Busy`).
/// - **Render, and not interpret.** The rows cross back as the guest wrote
///   them: label, value, order. Whether the base was right, whether CopyBits
///   failed, whether a transfer resumed — the guest states each in its own
///   rows, and turning any of them into a typed host field would be this side
///   answering a question about a Macintosh out of its own state. It would
///   also be how `vprobe`'s CopyBits row gets read as a capture failure,
///   which it is not.
@MainActor
final class AgentIntegrationDiagnostics {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private var runInFlight = false

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval =
            AgentIntegrationDiagnosticsPolicy.commandTimeout) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
    }

    func run(_ probe: AgentIntegrationDiagnosticProbe,
             observedAt: Date = Date()) async
        -> AgentIntegrationGuestRowReportResult {
        let verb = probe.rawValue
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        guard !runInFlight else {
            return refused(
                verb, "now-diagnostic-busy",
                "Another diagnostic is already running on this Mac")
        }
        runInFlight = true
        /* A run that timed out is still ON the machine — the guest is inside
           a full-screen read — so the flag is NOT released on that path; the
           late completion clears it, which is the shape
           `AgentIntegrationCatalogSearch` uses for the same reason. */
        var releaseOnReturn = true
        defer {
            if releaseOnReturn { runInFlight = false }
        }

        let outcome = await send(verb: verb)
        guard case .result(let result) = outcome else {
            releaseOnReturn = false
            return refused(
                verb, "now-diagnostic-outcome-unknown",
                "The paired guest did not answer \(verb) in time")
        }
        guard currentSessionID() == sessionID else {
            return .unavailable(.guest)
        }
        guard result.ok else {
            /* The guest's own code and sentence, bounded here rather than
               trusted. A guest without the verb refuses with
               `unknown-command`, and that arrives on this path: it is the
               machine's answer to "do you have this", which is what a caller
               needs, and it is the CALL's refusal because no diagnostic ran. */
            return refused(
                verb,
                bounded(result.error?.code ?? "\(verb)-refused",
                        scalars: AgentIntegrationDiagnosticsPolicy
                            .maximumFailureCodeScalars),
                bounded(result.error?.message
                            ?? "The paired guest refused \(verb)",
                        scalars: AgentIntegrationDiagnosticsPolicy
                            .maximumMessageScalars))
        }
        guard let rows = result.output?[verb] else {
            /* `ok` with no rows under the verb's own key. Refused rather than
               reported as an empty measurement: "the machine measured
               nothing" and "the answer did not arrive in the shape the
               contract declares" are different facts, and only the first
               would be about the machine. It matters most for `putstat`,
               whose zeroes ARE a real answer. */
            return refused(
                verb, "now-diagnostic-invalid",
                "The paired guest answered \(verb) with no rows")
        }
        return .completed(report(verb: verb, rows: rows,
                                 observedAt: observedAt))
    }

    /// One command, with this side's bound on the wait.
    ///
    /// The typed form and not `line`: a line's presence is what tells the
    /// guest a human is typing, and this caller is a projection.
    private func send(verb: String) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runScheduledCommand(
                verb, purpose: .command("diagnostics \(verb)"),
                workClass: .foreground) { [weak self] result in
                if settled {
                    /* The run that timed out has landed. Releasing here is
                       why the timeout path holds the flag: the machine is
                       free again and only this callback knows. */
                    self?.runInFlight = false
                    return
                }
                settled = true
                timeoutTask?.cancel()
                continuation.resume(returning: .result(result))
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(commandTimeout * 1_000_000_000))
                guard !Task.isCancelled, !settled else { return }
                settled = true
                continuation.resume(returning: .timedOut)
            }
        }
    }

    /// The guest's rows, in the guest's order, under the guest's group name.
    ///
    /// The only host judgement here is the ceiling, and it says so when it
    /// bites. A `[label, value]` pair that arrives short is rendered with an
    /// empty value rather than dropped: a row the guest sent and the host
    /// silently removed is exactly what the bound's note exists to avoid.
    private func report(verb: String, rows: [[String]], observedAt: Date)
        -> AgentIntegrationGuestRowReport {
        let policy = AgentIntegrationDiagnosticsPolicy.self
        let kept = rows.prefix(policy.maximumRows).map { pair in
            AgentIntegrationGuestRow(
                label: bounded(pair.first ?? "",
                               scalars: policy.maximumLabelScalars),
                value: bounded(pair.count > 1 ? pair[1] : "",
                               scalars: policy.maximumValueScalars))
        }
        HostLog.shared.write(
            .info, "sw",
            "\(verb) measured: \(kept.count) row"
                + "\(kept.count == 1 ? "" : "s")")
        return .init(
            verb: verb,
            groups: [.init(name: verb, rows: Array(kept))],
            note: rows.count > policy.maximumRows
                ? policy.truncationNote(verb: verb, answered: rows.count)
                : nil,
            observedAt: observedAt)
    }

    private func refused(_ verb: String, _ code: String, _ message: String)
        -> AgentIntegrationGuestRowReportResult {
        HostLog.shared.write(.warn, "sw", "\(verb) refused: \(code)")
        return .refused(.init(code: code, message: message))
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
