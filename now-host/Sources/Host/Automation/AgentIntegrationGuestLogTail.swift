import Foundation
import NOWAgentIntegration

/// Drives the guest's `tail` verb for an agent face.
///
/// Thin, like `AgentIntegrationRevealItem` and for the same reason: `tail`
/// needs no composition. The guest reads its own ring, applies its own
/// bounds and answers in one command result, so this layer bounds, forwards
/// and renders — and decides nothing about the machine (rule 2,
/// docs/agent-integration.md).
///
/// **Three things it does not do.**
///
/// It does not ask for a file, and there is nowhere it could: the verb has
/// one argument and it is a count. `GuestLogTailProjection` carries the
/// whole of why that stays true.
///
/// It does not fill in the default. An absent count is sent as an absent
/// `lines`, so the number 20 is the guest's own and not a copy of it living
/// on this side — the failure mode being avoided is the one the AGENTS.md
/// preamble names, a limit stated in three places until a message grows past
/// the smallest.
///
/// It does not summarise, sort or re-time the lines. They arrive oldest
/// first with the guest's own clock on them, which is not this machine's
/// clock and is not comparable to it (docs/logging.md, *Reading both at
/// once*); rewriting them into host time would be this side answering a
/// question about when something happened on a Mac whose clock it cannot
/// see.
@MainActor
final class AgentIntegrationGuestLogTail {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    /// A ring read and a `snprintf`. Nothing here touches the disk, so this
    /// is a wire-and-yield budget rather than a work budget — generous
    /// against a guest that is mid-transfer and slow to come back round the
    /// event loop, and far under the launch settle it does not share.
    static let commandTimeout: TimeInterval = 15

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let clock: @MainActor () -> Date
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval = AgentIntegrationGuestLogTail
             .commandTimeout,
         clock: @escaping @MainActor () -> Date = { Date() },
         audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.clock = clock
        /* `app`, not a new area: this is the application's own log being
           read, and docs/logging.md asks for an existing tag before a coined
           one. The `agent` line naming the caller is written by the
           dispatch, which is where "who asked" belongs. */
        self.audit = audit ?? { HostLog.shared.write($0, "app", $1) }
    }

    func tail(lines: Int?) async -> AgentIntegrationGuestRowReportResult {
        if let lines,
           !AgentIntegrationGuestLogPolicy.isValidLineCount(lines) {
            /* The projection refuses this first and the local codec refuses
               it again on arrival; this is the third reading, for a caller
               that reached the adapter directly. */
            return refused(
                "now-log-tail-lines-invalid",
                "A log tail is 1 to "
                    + "\(AgentIntegrationGuestLogPolicy.maximumLineCount) "
                    + "lines",
                asked: lines)
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let outcome = await run(lines: lines)
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked is
               no longer the machine on the other end, so whatever came back
               is a different Mac's log or nothing at all, and this side
               cannot tell which. */
            return .unavailable(.init(
                code: "now-log-tail-outcome-unknown",
                message: "The paired guest changed while its log was being "
                    + "read"))
        }
        switch outcome {
        case .timedOut:
            return refused(
                "now-log-tail-outcome-unknown",
                "The paired guest did not answer the log request in time",
                asked: lines)
        case .result(let result) where !result.ok:
            /* The guest's own sentence, forwarded rather than replaced —
               and safe to forward because the only thing a caller supplied
               is a small integer this side has already bounded, so there is
               no caller-chosen text for the guest to quote back. */
            return refused(
                "now-log-tail-refused",
                result.error?.message
                    ?? "The paired guest refused the log request",
                asked: lines)
        case .result(let result):
            let report = Self.report(from: result, observedAt: clock())
            audit(.info, "tail read \(Self.lineCount(of: report)) log lines "
                      + "for a non-user face")
            return .completed(report)
        }
    }

    // MARK: - The wire

    private func run(lines: Int?) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            /* The count goes on the LINE, not in `args`, and that is a
               correctness matter rather than a style one.

               `CommandRequest.args` is `[String: String]` on this side, so
               every typed argument reaches the wire quoted. The guest reads
               this one with `now_json_find_int`, which is `strtol` on the
               byte after the colon — and `strtol("\"40\"")` is 0, which
               `run_tail` clamps to 1. Sending the caller's 40 as a typed arg
               would therefore answer with ONE line and no error anywhere:
               the exact silent shortfall this row's schema promises does not
               happen. `tail` is the first verb whose typed argument is an
               integer, so nothing had met that edge before; widening the
               args map is a shared-file, both-guests change and is reported
               rather than made from inside one capability.

               The line form is not a workaround: the contract declares it
               for this verb (`x-commands.tail.x-line`, "the first integer on
               the line is the count"), the guest's own console uses it, and
               `run_tail` reaches it precisely when no typed `lines` is
               present. Absent when the caller did not choose, so the default
               of 20 stays the guest's number and not a copy of it here. */
            listener.runCommand("tail", line: lines.map(String.init)) {
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
    /// **The shared type is the honest shape here rather than a squeeze into
    /// somebody else's.** `tail`'s declared output is `x-rowArray` like its
    /// four siblings, and the guest itself splits every line into a
    /// timestamp and a remainder before it reaches the wire
    /// (`run_tail` — `stamp` and `rest`), so a label/value pair is the
    /// guest's own decision about its answer, not this side flattening text
    /// into a table. Nothing was needed from `AgentIntegrationGuestRowReport`
    /// that it does not already have.
    ///
    /// The mapping duplicates `AgentIntegrationRevealItem.report` because
    /// that one is `verb: "reveal"` with reveal's bounds; consolidating the
    /// five siblings is named in the handoff, not done from inside one of
    /// them while four other agents are in the same wave.
    ///
    /// Groups are sorted by name for determinism — `CommandResult.output` is
    /// a dictionary, so the wire's order is already gone — which puts `log`
    /// before `tail`. Row order INSIDE a group is the guest's and is
    /// preserved: for this verb it is chronological, and reversing it would
    /// be the one transformation that changes what the answer says.
    static func report(from result: CommandResult,
                       observedAt: Date) -> AgentIntegrationGuestRowReport {
        let bounds = AgentIntegrationGuestLogTailBounds.self
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
                                label: escaped(
                                    cells.first ?? "",
                                    scalars: bounds.maximumLabelScalars),
                                /* `last`, not `[1]`: the contract's row is a
                                   label/value pair, and a guest that sent
                                   one cell has said the same thing twice
                                   rather than crashed this side. */
                                value: escaped(
                                    cells.count > 1 ? (cells.last ?? "") : "",
                                    scalars: bounds.maximumValueScalars))
                        })
            }
        /* `note` stays absent, and that is a decision rather than an
           omission. The type reserves it for a sentence the guest offered
           about the edges of its answer, and `tail` offers exactly such a
           sentence — as a ROW, `shown: "12 of 20 (older ones did not fit)"`.
           Lifting one row out of the guest's own group into a different
           field would be this side deciding which of its rows was the
           important one, and would then say it twice. */
        return .init(verb: "tail", groups: Array(groups),
                     observedAt: observedAt)
    }

    private func refused(_ code: String, _ message: String, asked: Int?)
        -> AgentIntegrationGuestRowReportResult {
        audit(.warn, "tail of \(asked.map(String.init) ?? "the default")"
                  + " log lines refused: " + Self.sanitized(message))
        return .refused(.init(
            code: code,
            message: Self.bounded(
                message,
                scalars: AgentIntegrationGuestLogTailBounds
                    .maximumRefusalScalars)))
    }

    /// How many lines came back, for the log line — which is a count and
    /// never the lines themselves. A log that quoted the log it had just
    /// read would double every line on the next read, and the point of the
    /// entry is that a person can see their machine's log was read at all.
    private static func lineCount(
        of report: AgentIntegrationGuestRowReport
    ) -> Int {
        report.groups.first { $0.name == "tail" }?.rows.count ?? 0
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    /// Bound, then write any control character as `\xNN`.
    ///
    /// **Encoding, said once.** The bytes arrive already transcoded: the
    /// guest maps its MacRoman high range through its own table and emits
    /// `\uXXXX` (`now-guest-ppc/src/core/json.c :: now_json_escape`), so
    /// what reaches here is Unicode and no byte is ever undecodable. A
    /// line's CR endings are gone before that — the ring stores lines
    /// without terminators and `now_log_tail` joins them with `\n`, which
    /// `run_tail` splits back out — so a terminator inside a value would
    /// mean the guest's own line discipline had broken.
    ///
    /// What can still arrive is a control character *inside* a line, because
    /// the guest escapes those into the JSON faithfully rather than dropping
    /// them. They are made visible rather than passed through: a raw one
    /// corrupts whatever renders the row, and dropping it would be the
    /// silent mangling this whole paragraph exists to avoid. Escaped, the
    /// byte is still there and still readable, and the schema says so.
    private static func escaped(_ value: String, scalars: Int) -> String {
        var out = ""
        for scalar in bounded(value, scalars: scalars).unicodeScalars {
            let isControl = scalar.value < 0x20 || scalar.value == 0x7F
                || (0x80...0x9F).contains(scalar.value)
            if isControl {
                out += String(format: "\\x%02X", scalar.value)
            } else {
                out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// A log line's own bound and escape, for text this side is writing into
    /// the host's log rather than returning.
    private static func sanitized(_ value: String) -> String {
        escaped(value, scalars: maximumLoggedMessageScalars)
    }

    private static let maximumLoggedMessageScalars = 255
}
