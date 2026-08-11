import Foundation
import NOWAgentIntegration

/// Drives the guest's `reveal` verb for an agent face, and writes the line
/// that lets the person whose screen just changed find out why.
///
/// It is deliberately thin. `reveal` needs no composition: the guest resolves
/// the target, finds its own Finder by signature, and answers in one command
/// result — so this layer addresses, bounds, forwards, and renders, and
/// decides nothing about the machine (rule 2, docs/agent-integration.md).
///
/// **Two things it does not do, both on purpose.**
///
/// It does not pre-check that a Finder is running, though `process.list`
/// would tell it: the guest matches by `'MACS'` signature at the moment it
/// acts, so its refusal is later and better, and refusing here from a listing
/// taken a moment earlier would be this side answering a question about the
/// machine out of stale state.
///
/// It does not re-list to confirm anything afterwards. The confirmable half
/// of a reveal is the Finder coming forward — a fresh `process.list` entry
/// with `kind: "finder"` and `front: true` — and there is nowhere in
/// `AgentIntegrationGuestRowReport` to put that answer, since it is shared
/// with four sibling verbs and its `note` is reserved for the guest's own
/// sentence. A round trip whose result cannot be reported is worse than not
/// asking.
@MainActor
final class AgentIntegrationRevealItem {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    /// Bounded because the resolution cost is a catalog sweep, and generous
    /// for the same reason: a bare name sends the guest to `find_by_name`,
    /// the same exact-name walk `launch` pays (~4 s cold on the 1400c, and
    /// the host already allows 15 s for the `software.list` sweep that walks
    /// the same volume). Nothing is executed, so there is no launch settle to
    /// outlive — this is a resolution budget, not launch's 32 s.
    static let commandTimeout: TimeInterval = 15

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let clock: @MainActor () -> Date
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval = AgentIntegrationRevealItem
             .commandTimeout,
         clock: @escaping @MainActor () -> Date = { Date() },
         audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.clock = clock
        self.audit = audit ?? { HostLog.shared.write($0, "sw", $1) }
    }

    func reveal(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        guard AgentIntegrationRevealPolicy.isValidTarget(target) else {
            /* The projection refuses this before a request is composed, and
               the local codec refuses it again on arrival; this is the third
               reading, for a caller that reached the adapter directly. */
            let cap = AgentIntegrationRevealPolicy.maximumTargetScalars
            return refused(
                "now-reveal-target-invalid",
                "A reveal target is a full HFS path or an item name, "
                    + "1 to \(cap) characters, and not a #n pick",
                target: target)
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let outcome = await run(target: target)
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked is
               no longer the machine on the other end, so this side cannot
               say what became of the ask. */
            return .unavailable(.init(
                code: "now-reveal-outcome-unknown",
                message: "The paired guest changed while the reveal was in "
                    + "progress"))
        }
        switch outcome {
        case .timedOut:
            return refused(
                "now-reveal-outcome-unknown",
                "The paired guest did not answer the reveal request in time",
                target: target)
        case .result(let result) where !result.ok:
            /* The guest's own sentence, forwarded rather than replaced.
               `reveal` answers every refusal with one code — "the Finder is
               not running", "nothing named X to reveal" and "no such file:
               X" all arrive as `reveal-refused` — so the words ARE the
               distinction, and inventing a typed code by reading them would
               be this side deciding. It is safe to forward because every one
               of those sentences quotes only the target the caller supplied
               plus fixed prose; the one form that could have named an item
               the caller never sent is `#n`, which is refused above. */
            return refused(
                "now-reveal-refused",
                result.error?.message
                    ?? "The paired guest refused the reveal",
                target: target)
        case .result(let result):
            let report = Self.report(from: result, observedAt: clock())
            audit(.info,
                  "reveal \(Self.sanitized(target)) asked (the guest sent "
                      + "the Apple Event; nothing confirms the Finder "
                      + "obeyed)")
            return .completed(report)
        }
    }

    // MARK: - The wire

    private func run(target: String) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            /* "target", the arg key the contract names for this verb — the
               whole remainder of the line, spaces and all. */
            listener.runScheduledCommand(
                "reveal", args: ["target": target],
                purpose: .command("reveal item"), workClass: .foreground) {
                guard !settled else { return }
                settled = true
                timeoutTask?.cancel()
                continuation.resume(returning: .result($0))
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

    /// One command result as the shared row report, bounded.
    ///
    /// **Four sibling verbs (`tail`, `catsearch`, `gestalt`, the diagnostics
    /// trio) answer the same shape and will each want this mapping.** It is
    /// private here rather than shared because promoting it means a new file
    /// five agents in one wave would edit; consolidating it is named in the
    /// handoff as the next batch's first job.
    ///
    /// The rows are carried, never interpreted: `CommandResult.output` is a
    /// dictionary, so the group ORDER the wire had is already gone, and the
    /// groups are sorted by name to make one answer encode identically twice
    /// rather than to impose a reading. Row order inside a group is the
    /// guest's and is preserved, because `overview`-style captions depend on
    /// it.
    static func report(from result: CommandResult,
                       observedAt: Date) -> AgentIntegrationGuestRowReport {
        let bounds = AgentIntegrationRevealItemBounds.self
        let groups = (result.output ?? [:])
            .sorted { $0.key < $1.key }
            .prefix(bounds.maximumGroups)
            .map { group in
                AgentIntegrationGuestRowGroup(
                    name: bounded(group.key,
                                  scalars: bounds.maximumLabelScalars),
                    rows: group.value
                        .prefix(bounds.maximumRowsPerGroup)
                        .map { cells in
                            AgentIntegrationGuestRow(
                                label: bounded(
                                    cells.first ?? "",
                                    scalars: bounds.maximumLabelScalars),
                                /* `last`, not `[1]`: the contract's row is a
                                   label/value pair and a guest that sent one
                                   cell has said the same thing twice rather
                                   than crashed this side. */
                                value: bounded(
                                    cells.count > 1 ? (cells.last ?? "") : "",
                                    scalars: bounds.maximumValueScalars))
                        })
            }
        return .init(verb: "reveal", groups: Array(groups),
                     observedAt: observedAt)
    }

    private func refused(_ code: String, _ message: String, target: String)
        -> AgentIntegrationGuestRowReportResult {
        audit(.warn, "reveal \(Self.sanitized(target)) refused: "
                  + Self.sanitized(message))
        return .refused(.init(
            code: code,
            message: Self.bounded(
                message,
                scalars: AgentIntegrationRevealItemBounds
                    .maximumRefusalScalars)))
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    /// A log line's own bound and escape. Control bytes are legal in an HFS
    /// name and reach this side inside a target, and a raw one corrupts the
    /// row the Logs page draws — the same choice the guest-Files audit text
    /// makes.
    private static func sanitized(_ value: String) -> String {
        var escaped = ""
        for scalar in bounded(value, scalars: maximumLoggedTargetScalars)
            .unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
            if isControl {
                escaped += String(format: "\\x%02X", scalar.value)
            } else {
                escaped.unicodeScalars.append(scalar)
            }
        }
        return escaped
    }

    /// A whole HFS path fits; the point of the line is that a person can
    /// recognise what appeared on their screen.
    private static let maximumLoggedTargetScalars = 255
}
