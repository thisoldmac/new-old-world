import Foundation
import NOWAgentIntegration

/// Runs the guest's `catsearch` probe once and renders its rows.
///
/// The most expensive read the agent surface has, so the three things this
/// object exists to do are all about the cost:
///
/// - **Bound the wait.** `GuestListener.runCommand` arms no watchdog — a
///   command's caller owns its own bound, which is why the launch control
///   carries one too. Ours is
///   `AgentIntegrationCatalogSearchPolicy.commandTimeout`, and the chain it
///   sits in is documented there.
/// - **Refuse a second one.** Two sweeps in flight would have the machine
///   thrashing its catalog for both and answering neither in its budget, and
///   the guest is cooperatively scheduled, so the second is not concurrency —
///   it is the first one's numbers made meaningless.
/// - **Render, and not interpret.** The rows cross back as the guest wrote
///   them: label, value, order. Whether the volume supported CatSearch and
///   whether the sweep completed are things the guest states in its own rows,
///   and turning either into a typed host field would be this side answering
///   a question about a Macintosh out of its own state.
@MainActor
final class AgentIntegrationCatalogSearch {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private var sweepInFlight = false

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval =
            AgentIntegrationCatalogSearchPolicy.commandTimeout) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
    }

    func measure(observedAt: Date = Date()) async
        -> AgentIntegrationGuestRowReportResult {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        guard !sweepInFlight else {
            return refused(
                "now-catsearch-busy",
                "Another catalog search measurement is already running")
        }
        sweepInFlight = true
        /* A sweep that timed out is still ON the machine, so the flag is NOT
           released on that path: the guest is inside PBCatSearch and a second
           request would queue behind it and answer the same way. The late
           completion clears it — see `run` — which is the same shape the
           launch control uses for the same reason. */
        var releaseOnReturn = true
        defer {
            if releaseOnReturn { sweepInFlight = false }
        }

        let outcome = await run()
        guard case .result(let result) = outcome else {
            releaseOnReturn = false
            return refused(
                "now-catsearch-outcome-unknown",
                "The paired guest did not answer the catalog search in time")
        }
        guard currentSessionID() == sessionID else {
            return .unavailable(.guest)
        }
        guard result.ok else {
            /* The guest's own code, bounded — `catsearch-failed` carries a
               Toolbox error number and no path, but the bound is the wire's
               to keep rather than the guest's to be trusted with. */
            return refused(
                bounded(result.error?.code ?? "catsearch-failed",
                        scalars: AgentIntegrationCatalogSearchPolicy
                            .maximumFailureCodeScalars),
                bounded(result.error?.message
                            ?? "The paired guest refused the catalog search",
                        scalars: AgentIntegrationCatalogSearchPolicy
                            .maximumMessageScalars))
        }
        guard let rows = result.output?[
            AgentIntegrationCatalogSearchPolicy.verb] else {
            /* `ok` with no rows under the verb's own key. Refused rather than
               reported as an empty measurement: "the sweep found nothing" and
               "the answer did not arrive in the shape the contract declares"
               are different facts, and only the first is about the disk. */
            return refused(
                "now-catsearch-invalid",
                "The paired guest answered the catalog search with no rows")
        }
        return .completed(report(rows: rows, observedAt: observedAt))
    }

    /// One `catsearch`, with this side's bound on the wait.
    ///
    /// The typed form (`args`) and not `line`: a line's presence is what tells
    /// the guest a human is typing, and this caller is a projection.
    private func run() async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runScheduledCommand(
                AgentIntegrationCatalogSearchPolicy.verb,
                purpose: .command("catalog search"), workClass: .foreground
            ) { [weak self] result in
                if settled {
                    /* The sweep that timed out has landed. Releasing here is
                       the whole reason the timeout path holds the flag: the
                       machine is free again and only this callback knows. */
                    self?.sweepInFlight = false
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
    /// The only host judgement in here is the ceiling, and it says so when it
    /// bites. A `[label, value]` pair that arrives short is rendered with an
    /// empty value rather than dropped: a row the guest sent and the host
    /// silently removed is the failure the bound's own note exists to avoid,
    /// one row down.
    private func report(rows: [[String]], observedAt: Date)
        -> AgentIntegrationGuestRowReport {
        let policy = AgentIntegrationCatalogSearchPolicy.self
        let kept = rows.prefix(policy.maximumRows).map { pair in
            AgentIntegrationGuestRow(
                label: bounded(pair.first ?? "",
                               scalars: policy.maximumLabelScalars),
                value: bounded(pair.count > 1 ? pair[1] : "",
                               scalars: policy.maximumValueScalars))
        }
        HostLog.shared.write(
            .info, "sw",
            "catsearch measured: \(kept.count) row"
                + "\(kept.count == 1 ? "" : "s")")
        return .init(
            verb: policy.verb,
            groups: [.init(name: policy.verb, rows: Array(kept))],
            note: rows.count > policy.maximumRows
                ? policy.truncationNote(answered: rows.count) : nil,
            observedAt: observedAt)
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationGuestRowReportResult {
        HostLog.shared.write(.warn, "sw", "catsearch refused: \(code)")
        return .refused(.init(code: code, message: message))
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
