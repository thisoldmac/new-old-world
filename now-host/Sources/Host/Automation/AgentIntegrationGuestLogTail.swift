import Foundation
import NOWAgentIntegration

/// Drives the guest's `tail` verb for an agent face — as many pages of it
/// as the ask is deep.
///
/// One `tail` answer is at most 40 lines, because it must fit a 4 KB
/// control frame; the ring holds 2000. This layer closes that gap the way
/// the contract says to (`x-commands` tail): every answer's `log` group
/// offers a `next` row — the sequence cursor for the next-older page — and
/// this loop follows it until the ask is served, the ring is exhausted, or
/// a bound below stops it out loud. The guest decides what matches and what
/// a page holds; this side only asks again, which is rule 2 of
/// docs/agent-integration.md doing its work on a paged verb.
///
/// **Three things it does not do.**
///
/// It does not ask for a file, and there is nowhere it could: the verb's
/// arguments are a count, an area tag and a cursor.
/// `GuestLogTailProjection` carries the whole of why that stays true.
///
/// It does not fill in the default. An absent count crosses as an absent
/// `lines`, so the number 20 is the guest's own and not a copy of it living
/// on this side.
///
/// It does not summarise, sort or re-time the lines. They are reassembled
/// oldest-first with the guest's own clock on them, which is not this
/// machine's clock and is not comparable to it (docs/logging.md).
///
/// **The bounds, all of which report themselves.** A retrieval stops at the
/// byte budget (`maximumTotalBytes`), the page cap
/// (`maximumPageRequests`), or the walk deadline (`walkDeadline`) — and
/// every early stop drops OLDEST lines only and says so in `shown`, because
/// a tail that silently shortens is a tail that lies about what happened
/// most recently. A cursor that fails to decrease stops the walk too:
/// a loop that trusts a guest's cursor unboundedly is a loop a defective
/// guest drives forever.
@MainActor
final class AgentIntegrationGuestLogTail {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    /// One page is a ring read and a `snprintf` — a wire-and-yield budget
    /// rather than a work budget, generous against a guest that is
    /// mid-transfer and slow to come back round the event loop.
    static let commandTimeout: TimeInterval = 15

    /// The whole walk's budget. Under the local socket's own window (100 s
    /// in `AgentIntegrationLocalClient`), so the app answers with what it
    /// has rather than the socket giving up on an answer that was still
    /// being assembled.
    static let walkDeadline: TimeInterval = 90

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let walkDeadline: TimeInterval
    private let clock: @MainActor () -> Date
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval = AgentIntegrationGuestLogTail
             .commandTimeout,
         walkDeadline: TimeInterval = AgentIntegrationGuestLogTail
             .walkDeadline,
         clock: @escaping @MainActor () -> Date = { Date() },
         audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.walkDeadline = walkDeadline
        self.clock = clock
        /* `app`, not a new area: this is the application's own log being
           read, and docs/logging.md asks for an existing tag before a
           coined one. The `agent` line naming the caller is written by the
           dispatch, which is where "who asked" belongs. */
        self.audit = audit ?? { HostLog.shared.write($0, "app", $1) }
    }

    func tail(lines: Int?, area: String?) async
        -> AgentIntegrationGuestLogRetrievalResult {
        typealias Policy = AgentIntegrationGuestLogPolicy
        if let lines, !Policy.isValidLineCount(lines) {
            /* The projection refuses this first and the local codec refuses
               it again on arrival; this is the third reading, for a caller
               that reached the adapter directly. */
            return refused(
                "now-log-tail-lines-invalid",
                "A log retrieval is 1 to \(Policy.maximumLineCount) lines",
                asked: lines)
        }
        if let area, !Policy.isValidArea(area) {
            return refused(
                "now-log-tail-area-invalid",
                "A log area is a tag of 1 to \(Policy.areaTagScalars) "
                    + "characters, as the guest's log writes it",
                asked: lines)
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }

        let requested = lines ?? Policy.defaultLineCount
        let started = clock()
        /* Pages in FETCH order: each page is oldest-first inside, and each
           page is older than the one before it, so the final answer is the
           pages reversed and concatenated. */
        var pages: [[String]] = []
        var collected = 0
        var collectedBytes = 0
        var matching: Int?
        var guestFile: String?
        var ringCapacity: Int?
        var before: UInt32?
        var exhausted = false

        while collected < requested,
              pages.count < Policy.maximumPageRequests,
              collectedBytes < Policy.maximumTotalBytes,
              clock().timeIntervalSince(started) < walkDeadline {
            let want = min(requested - collected, Policy.pageLineCount)
            /* The FIRST page carries an absent count only when the caller
               chose nothing at all, so the default stays the guest's. */
            let askDefault = lines == nil && pages.isEmpty
            let outcome = await run(lines: askDefault ? nil : want,
                                    area: area, before: before)
            guard currentSessionID() == sessionID else {
                /* Unavailable rather than refused: the machine that was
                   asked is no longer the machine on the other end, so
                   whatever came back is a different Mac's log or nothing
                   at all, and this side cannot tell which. */
                return .unavailable(.init(
                    code: "now-log-tail-outcome-unknown",
                    message: "The paired guest changed while its log was "
                        + "being read"))
            }
            switch outcome {
            case .timedOut:
                return refused(
                    "now-log-tail-outcome-unknown",
                    "The paired guest did not answer the log request in "
                        + "time",
                    asked: lines)
            case .result(let result) where !result.ok:
                /* The guest's own sentence, forwarded rather than replaced
                   — and safe to forward because everything a caller
                   supplied has been bounded above, so there is no
                   caller-chosen text for the guest to quote back at any
                   length. */
                return refused(
                    "now-log-tail-refused",
                    Self.bounded(
                        result.error?.message
                            ?? "The paired guest refused the log request",
                        scalars: Policy.maximumRefusalScalars),
                    asked: lines)
            case .result(let result):
                let page = Page(from: result)
                pages.append(page.lines)
                collected += page.lines.count
                collectedBytes += page.lines.reduce(0) {
                    $0 + $1.utf8.count + Policy.perLineEnvelopeBytes
                }
                if let m = page.matching { matching = m }
                if let f = page.file { guestFile = f }
                if let r = page.ringCapacity { ringCapacity = r }
                /* No next row, or an empty page, is the ring's end. The
                   cursor must also strictly DESCEND, or the walk is being
                   led in a circle by a defective guest; stopping reports
                   what was gathered rather than looping. */
                if let next = page.next, !page.lines.isEmpty,
                   before == nil || next < before! {
                    before = next
                } else {
                    exhausted = true
                }
            }
            if exhausted { break }
        }

        /* Oldest-first, then the byte budget trims from the FRONT — the
           oldest end — so what survives is always the newest of what was
           gathered, and the trim reports itself below. */
        var all = pages.reversed().flatMap { $0 }
        var bytes = all.reduce(0) {
            $0 + $1.utf8.count + Policy.perLineEnvelopeBytes
        }
        var trimmed = false
        while bytes > Policy.maximumTotalBytes, !all.isEmpty {
            bytes -= all[0].utf8.count + Policy.perLineEnvelopeBytes
            all.removeFirst()
            trimmed = true
        }

        /* The suffix appears when a BOUND bit before the count did —
           the byte budget's trim, or a walk stopped by the deadline, the
           page cap or the budget while older matching lines remained. A
           caller served every line they asked for reads no suffix; the
           `matching` beside `shown` already says how much more exists. */
        let reportedMatching = matching ?? all.count
        let cut = trimmed || all.count < min(requested, reportedMatching)
        let shown = "\(all.count) of \(reportedMatching)"
            + (cut ? " (older ones did not fit)" : "")
        let retrieval = AgentIntegrationGuestLogRetrieval(
            lines: all,
            requested: requested,
            matching: reportedMatching,
            shown: shown,
            area: area,
            ringCapacity: ringCapacity
                ?? AgentIntegrationGuestLogPolicy.ringCapacity,
            guestFile: guestFile,
            pages: pages.count,
            observedAt: clock())
        audit(.info, "tail read \(all.count) log lines over "
                  + "\(pages.count) page\(pages.count == 1 ? "" : "s") "
                  + "for a non-user face")
        return .completed(retrieval)
    }

    // MARK: - One page on the wire

    private func run(lines: Int?, area: String?, before: UInt32?) async
        -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            /* Typed args, and typed NUMBERS. The first landing of this
               lane put the count on the LINE because `args` was
               [String: String] then, and a quoted "40" read as 0 by the
               guest's strtol — the silent shortfall its test still pins.
               `CommandArg.number` crosses as a bare JSON integer, which
               `now_json_find_int` and `now_json_find_u32` read exactly;
               the line form stays what it is for: humans. */
            var args: [String: CommandArg] = [:]
            if let lines { args["lines"] = .number(lines) }
            if let area { args["area"] = .text(area) }
            if let before { args["before"] = .number(Int(before)) }
            listener.runScheduledCommand(
                "tail", typed: args.isEmpty ? nil : args,
                purpose: .command("tail"), workClass: .foreground) {
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

    // MARK: - Reading one page

    /// One command result, read as the page the contract declares: the
    /// `tail` group's rows are the lines, the `log` group's rows are the
    /// answer's edges. Unknown rows are ignored rather than refused — a
    /// guest that grew a row is newer, not wrong.
    struct Page {
        var lines: [String] = []
        var matching: Int?
        var file: String?
        var ringCapacity: Int?
        var next: UInt32?

        init(from result: CommandResult) {
            typealias Policy = AgentIntegrationGuestLogPolicy
            for cells in result.rows("tail") ?? [] {
                let stamp = cells.first ?? ""
                let rest = cells.count > 1 ? (cells.last ?? "") : ""
                /* The guest split its own line into [time, rest] for the
                   row shape; rejoining them is rendering, not invention —
                   and both halves are control-escaped, because a raw
                   control byte corrupts whatever renders the answer. */
                let joined = stamp.isEmpty ? rest : stamp + " " + rest
                lines.append(Self.escaped(
                    joined, scalars: Policy.maximumLineScalars))
            }
            for cells in result.rows("log") ?? [] {
                guard let label = cells.first else { continue }
                let value = cells.count > 1 ? (cells.last ?? "") : ""
                switch label {
                case "file":
                    file = Self.escaped(value, scalars: 255)
                case "matching":
                    matching = Int(value)
                case "held":
                    /* "H of 2000" — the ring's size is the second number,
                       and a guest that says a different one is believed
                       over this side's constant. */
                    if let of = value.range(of: " of ") {
                        ringCapacity = Int(value[of.upperBound...])
                    }
                case "next":
                    next = UInt32(value)
                default:
                    break
                }
            }
        }

        /// Bound, then write any control character as `\xNN` — the same
        /// discipline the host log's own lines cross under. The bytes
        /// arrive already transcoded (the guest maps its MacRoman itself,
        /// `now_json_escape`), so what reaches here is Unicode; what can
        /// still arrive is a control character inside a line, made visible
        /// rather than dropped or passed through.
        static func escaped(_ value: String, scalars: Int) -> String {
            var out = ""
            let bounded = AgentIntegrationBoundedText.prefix(
                value, scalars: scalars)
            for scalar in bounded.unicodeScalars {
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
    }

    private func refused(_ code: String, _ message: String, asked: Int?)
        -> AgentIntegrationGuestLogRetrievalResult {
        audit(.warn, "tail of \(asked.map(String.init) ?? "the default")"
                  + " log lines refused: " + Self.sanitized(message))
        return .refused(.init(
            code: code,
            message: Self.bounded(
                message,
                scalars: AgentIntegrationGuestLogPolicy
                    .maximumRefusalScalars)))
    }

    private static func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    /// A log line's own bound and escape, for text this side is writing
    /// into the host's log rather than returning.
    private static func sanitized(_ value: String) -> String {
        Page.escaped(value, scalars: maximumLoggedMessageScalars)
    }

    private static let maximumLoggedMessageScalars = 255
}
