import Foundation
import NOWAgentIntegration

/// Drives the guest's `gestalt` verb for an agent face.
///
/// Thin, like `AgentIntegrationGuestLogTail` and `AgentIntegrationRevealItem`,
/// and for the same reason: `gestalt` needs no composition. The guest reads
/// its own Gestalt selectors, groups them itself, and answers in one command
/// result — so this layer bounds, forwards and renders, and decides nothing
/// about the machine (rule 2, docs/agent-integration.md).
///
/// **Three things it does not do**, each of which would be this side answering
/// a question about somebody's Macintosh:
///
/// It does not send a `line`. A line is what tells the guest a human is
/// typing, and its presence changes the ANSWER — empty means the snapshot
/// group alone, `--cpu` means one group. A typed call with no line returns
/// every group, which is what a projection wants and what the contract
/// declares (`x-commands.gestalt`). `MachineFactsProjection` carries the whole
/// of why there is no selector to pass through either.
///
/// It does not parse a row. `Model`, `CPU` and `Memory` arrive as label/value
/// text the guest rendered for a person, and lifting them into typed host
/// fields would go stale the first time the guest reworded one — the failure
/// `AgentIntegrationRowReportModels` names in its header.
///
/// It does not fill a gap. A selector the machine did not answer is a row the
/// guest never sent (`now_gestalt_gather` adds a row only on `noErr`), so an
/// absent fact is an absent row here. Inventing `"unknown"` for it would be a
/// claim this side has no grounds for.
@MainActor
final class AgentIntegrationMachineFacts {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    /// A handful of `Gestalt` calls and a `snprintf`. No disk, no bus, no
    /// catalog — so this is a wire-and-yield budget rather than a work
    /// budget, and it is `tail`'s number for `tail`'s reason: generous
    /// against a guest that is mid-transfer and slow to come back round its
    /// event loop, and far under the launch settle it does not share.
    static let commandTimeout: TimeInterval = 15

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let clock: @MainActor () -> Date
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval = AgentIntegrationMachineFacts
             .commandTimeout,
         clock: @escaping @MainActor () -> Date = { Date() },
         audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.clock = clock
        /* `app`, not a coined area: this is the guest application answering
           for its own machine, and docs/logging.md asks for an existing tag
           first. The line naming WHO asked is written by the dispatch. */
        self.audit = audit ?? { HostLog.shared.write($0, "app", $1) }
    }

    func read() async -> AgentIntegrationGuestRowReportResult {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let outcome = await run()
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked is
               no longer the machine on the other end, so whatever came back
               describes a different Mac or nothing at all, and this side
               cannot tell which. Reporting it as facts would be the one
               failure this whole surface's addressing exists to prevent. */
            return .unavailable(.init(
                code: "now-machine-facts-outcome-unknown",
                message: "The paired guest changed while it was being asked "
                    + "what it is"))
        }
        switch outcome {
        case .timedOut:
            return refused(
                "now-machine-facts-outcome-unknown",
                "The paired guest did not answer the machine facts in time")
        case .result(let result) where !result.ok:
            /* The guest's own code and sentence, forwarded rather than
               replaced — and safe to forward because this side sent no text
               for the guest to quote back. A 68K guest reaches here with
               `unknown-command`, which is also what makes the capability
               ledger report this row unavailable there. */
            return refused(
                Self.bounded(
                    result.error?.code ?? "gestalt-failed",
                    scalars: AgentIntegrationMachineFactsPolicy
                        .maximumFailureCodeScalars),
                result.error?.message
                    ?? "The paired guest refused the machine facts")
        case .result(let result):
            guard let output = result.output, !output.isEmpty else {
                /* `ok` with no groups. Refused rather than reported as an
                   empty machine: "this Mac has nothing to say about itself"
                   and "the answer did not arrive in the shape the contract
                   declares" are different facts, and only the first would be
                   about the machine — and the first cannot happen, because
                   the snapshot group's Model row is unconditional. */
                return refused(
                    "now-machine-facts-invalid",
                    "The paired guest answered the machine facts with no "
                        + "groups")
            }
            let report = Self.report(from: output, observedAt: clock())
            audit(.info, "gestalt read \(Self.rowCount(of: report)) machine "
                      + "facts for a non-user face")
            return .completed(report)
        }
    }

    // MARK: - The wire

    /// One `gestalt`, with this side's bound on the wait.
    ///
    /// No `line` and no `args`: the verb takes none (`args: {}`), and a line's
    /// presence would narrow the answer. Absent means every group.
    private func run() async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runCommand(
                AgentIntegrationMachineFactsPolicy.verb
            ) { result in
                guard !settled else { return }
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

    // MARK: - Rendering

    /// The guest's groups, in the CONTRACT's order, with the guest's rows in
    /// the guest's order inside each.
    ///
    /// **Restoring an order the transport lost is the one transformation here,
    /// and it is rendering rather than deciding.** `CommandResult.output` is a
    /// dictionary, so the guest's declared sequence is already gone by the
    /// time this runs; the sequence put back is the contract's own
    /// (`x-commands.gestalt.output`), which is also the guest's — see
    /// `AgentIntegrationMachineFactsPolicy.declaredGroupOrder` for why
    /// alphabetical, which is what `tail` does with its two groups, is the
    /// wrong answer for six.
    ///
    /// A group this side has no order for is kept and follows the known ones,
    /// sorted among themselves: a newer guest's group silently dropped by a
    /// host holding a stale list is the drift this whole document family
    /// exists to catch.
    static func report(from output: [String: [[String]]],
                       observedAt: Date) -> AgentIntegrationGuestRowReport {
        let policy = AgentIntegrationMachineFactsPolicy.self
        let known = policy.declaredGroupOrder
        let ordered = output.keys.sorted { left, right in
            switch (known.firstIndex(of: left), known.firstIndex(of: right)) {
            case (let l?, let r?): return l < r
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return left < right
            }
        }
        let groups = ordered.prefix(policy.maximumGroups).map { name in
            AgentIntegrationGuestRowGroup(
                name: bounded(name, scalars: policy.maximumGroupNameScalars),
                rows: (output[name] ?? [])
                    .prefix(policy.maximumRowsPerGroup)
                    .map { cells in
                        AgentIntegrationGuestRow(
                            label: bounded(
                                cells.first ?? "",
                                scalars: policy.maximumLabelScalars),
                            /* `last`, not `[1]`: the contract's row is a
                               label/value pair, and a guest that sent one
                               cell has said the same thing twice rather than
                               crashed this side. */
                            value: bounded(
                                cells.count > 1 ? (cells.last ?? "") : "",
                                scalars: policy.maximumValueScalars))
                    })
        }
        return .init(
            verb: policy.verb,
            groups: Array(groups),
            note: ordered.count > policy.maximumGroups
                ? policy.truncationNote(answered: ordered.count) : nil,
            observedAt: observedAt)
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationGuestRowReportResult {
        audit(.warn, "gestalt refused: \(code)")
        return .refused(.init(
            code: code,
            message: Self.bounded(
                message,
                scalars: AgentIntegrationMachineFactsPolicy
                    .maximumMessageScalars)))
    }

    /// How many facts came back, for the log line — a count, never the facts.
    /// The point of the entry is that a person can see their machine was
    /// asked what it is at all.
    private static func rowCount(
        of report: AgentIntegrationGuestRowReport
    ) -> Int {
        report.groups.reduce(0) { $0 + $1.rows.count }
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }
}
