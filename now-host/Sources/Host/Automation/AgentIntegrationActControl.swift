import Foundation
import NOWAgentIntegration

/// **The act lane** — the five `command.request`s that carry an act to the
/// connected Macintosh, and the only place on this side that turns a guest
/// reply into a dispatch claim.
///
/// It is the sibling of `AgentIntegrationRevealItem` and shaped like it on
/// purpose: address, bound, forward, render, and decide nothing about the
/// machine (rule 2, docs/agent-integration.md). What differs is what is at
/// stake in the rendering, which is the whole reason this file is longer
/// than that one.
///
/// ## An act is NOT on the transfer lane, and that is a decision
///
/// `GuestListener.requestScene` and `requestCapture` both consult
/// `transferLaneHolder` before they ask, because a scene and a screenshot
/// are BULK: they cross in pages, the contract allows one such transfer at
/// a time, and the guest refuses a second. An act is neither. It is a
/// bounded `command.request` with a bounded `command.result` — the same
/// envelope `reveal`, `gestalt` and `tail` ride — served out of the guest's
/// ordinary command dispatch, which the console already drives while a
/// download is running.
///
/// So these go through `GuestListener.runCommand`, which has its own
/// `pendingCommands` map and its own id, and they neither take the transfer
/// lane nor check it. Putting an act behind `transferLaneHolder` would make
/// clicking a button in a rendered scene refuse itself for the duration of
/// the very stream that is DRAWING the scene — the two would deadlock as a
/// matter of design, with a person watching a live mirror of a machine they
/// could not touch. That is the concrete failure the choice avoids; the
/// general one is that a lane exists to serialize a scarce resource, and
/// command dispatch is not scarce.
///
/// ## What the guest's reply is allowed to be turned into
///
/// **`dispatched` is read off the machine's own rows, never assumed.** The
/// guest writes a `Dispatch` row saying `dispatched` after its act plane
/// withdrew; this side finds that row or refuses. A host that filled the
/// field in from its own request would be reporting a call it composed as a
/// thing that happened — the exact defect the one-case
/// `AgentIntegrationActDispatch` exists to make unspellable, and the one a
/// mutation of this file must not survive.
///
/// **The guest's `Re-read` rows are dropped here, and their absence is not
/// a loss.** `winact` and `ctlact` both quote the element read back after
/// the act, which is real evidence and is the machine speaking. It is a
/// SEPARATE claim from the dispatch — the guest keeps it in its own row for
/// that reason — and there is nowhere in `AgentIntegrationWindowActReceipt`
/// or `AgentIntegrationControlActReceipt` to put it that would not merge it
/// into the dispatch. A caller who wants to know where the window went
/// reads it back. Carrying the row would want its own dated reading type,
/// which is a design pass rather than a field.
@MainActor
final class AgentIntegrationActControl {
    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    /// **15 s, and it is the guest's own bound plus room, not a guess.**
    ///
    /// An act does not return from the guest's own code the way `reveal`
    /// does. The act plane ARMS a patch and then waits for the addressed
    /// application to reach its own `FindWindow` / `TrackControl` /
    /// `MenuSelect` — `kNowActDeadlineTicks` is 300 ticks (~5 s), and a
    /// submit can spend that twice (once waiting for the target to pump,
    /// once waiting for the armed call to fire) before it gives up with
    /// `act-timeout`. So the worst legal case is ~10 s of a guest that is
    /// working exactly as intended, and a bound below that would report a
    /// working machine as silent.
    static let commandTimeout: TimeInterval = 15

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private let commandTimeout: TimeInterval
    private let clock: @MainActor () -> Date
    private let audit: (HostLog.LogLevel, String) -> Void

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         commandTimeout: TimeInterval = AgentIntegrationActControl
             .commandTimeout,
         clock: @escaping @MainActor () -> Date = { Date() },
         audit: ((HostLog.LogLevel, String) -> Void)? = nil) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.commandTimeout = commandTimeout
        self.clock = clock
        self.audit = audit ?? { HostLog.shared.write($0, "act", $1) }
    }

    // MARK: - winact

    func windowAct(_ request: AgentIntegrationWindowActRequest) async
        -> AgentIntegrationWindowActResult {
        /* The third reading of the same rule: the projection refuses a
           malformed act before a request is composed, the local codec
           refuses it again on arrival, and this is the reading for a caller
           that reached the adapter directly. The refusal that matters most
           is the target's — an act that cannot name what it acts on is the
           18/20 hijack restated. */
        guard request.isWellFormed else {
            return .refused(Self.failure(
                "now-window-act-invalid",
                "A window act names one now-window-… reference from a "
                    + "current observation, one action, and exactly the "
                    + "geometry that action takes",
                reach: .notSent))
        }
        /* Numbers as NUMBERS. `String(left)` sent `"left": "40"`, and the
           classic guest's strtol stops at the quote - so every window act
           this host ever sent moved a window to (0,0) and was told
           `dispatched`. See CommandArg. */
        var args: [String: CommandArg] = [
            "window": .text(request.window),
            "action": .text(request.action.rawValue),
        ]
        if let left = request.left { args["left"] = .number(left) }
        if let top = request.top { args["top"] = .number(top) }
        if let width = request.width { args["width"] = .number(width) }
        if let height = request.height { args["height"] = .number(height) }

        return await dispatch(
            verb: "winact", args: args,
            describing: "winact \(request.action.rawValue) "
                + "\(Self.sanitized(request.window))",
            invalidCode: "now-window-act-invalid",
            refusedCode: "now-window-act-refused",
            unknownCode: "now-window-act-outcome-unknown"
        ) { claim in
            .init(window: request.window,
                  action: request.action,
                  dispatch: claim.dispatch,
                  dispatchedAt: claim.at, correlation: claim.correlation,
                  settlement: claim.settlement)
        }
    }

    // MARK: - ctlact

    func controlAct(_ request: AgentIntegrationControlActRequest) async
        -> AgentIntegrationControlActResult {
        guard request.isWellFormed else {
            return .refused(Self.failure(
                "now-control-act-invalid",
                "A control act names one now-element-… reference from a "
                    + "current observation and one Control Manager part "
                    + "code",
                reach: .notSent))
        }
        return await dispatch(
            verb: "ctlact",
            /* The part is a NUMBER. As `String(request.part)` it crossed
               as "21", the guest's strtol stopped at the quote, and it
               pressed part 0 - measured, and it answered `dispatched`. */
            args: ["element": .text(request.element),
                   "part": .number(request.part)],
            describing: "ctlact part \(request.part) "
                + "\(Self.sanitized(request.element))",
            invalidCode: "now-control-act-invalid",
            refusedCode: "now-control-act-refused",
            unknownCode: "now-control-act-outcome-unknown"
        ) { claim in
            .init(element: request.element,
                  part: request.part,
                  dispatch: claim.dispatch,
                  dispatchedAt: claim.at, correlation: claim.correlation,
                  settlement: claim.settlement)
        }
    }

    // MARK: - menuact

    func menuAct(_ request: AgentIntegrationMenuActRequest) async
        -> AgentIntegrationMenuActResult {
        guard request.isWellFormed else {
            return .refused(Self.failure(
                "now-menu-act-invalid",
                "A menu act names a menu id, a 1-based item and the "
                    + "titleLeft that is its identity check",
                reach: .notSent))
        }
        var args: [String: CommandArg] = [
            "menu": .number(request.menu),
            "item": .number(request.item),
            "titleLeft": .number(request.titleLeft),
        ]
        if let process = request.process {
            args["serialHi"] = .number(process.high)
            args["serialLo"] = .number(process.low)
        }
        return await dispatch(
            verb: "menuact", args: args,
            describing: "menuact \(request.menu)/\(request.item) at x "
                + "\(request.titleLeft)",
            invalidCode: "now-menu-act-invalid",
            refusedCode: "now-menu-act-refused",
            unknownCode: "now-menu-act-outcome-unknown"
        ) { claim in
            .init(menu: request.menu,
                  item: request.item,
                  titleLeft: request.titleLeft,
                  dispatch: claim.dispatch,
                  dispatchedAt: claim.at, correlation: claim.correlation,
                  settlement: claim.settlement)
        }
    }

    // MARK: - key

    /// Post one keystroke into the guest's event queue, through the input
    /// plane's own verb rather than the act plane's four — `key` answers no
    /// `Dispatch` row (`now-guest-ppc/src/input/input_cmds.c`), so this
    /// does not go through `dispatch()` below; it reads `posted` instead,
    /// the same shape `getElementText` reads `Text`/`Truncated`.
    ///
    /// **Not a claim that the front application acted on it.** `posted`
    /// means the guest's `PostEvent(keyDown, …)` returned `noErr` — the
    /// keystroke is in the queue. What dequeues it and what it does with it
    /// is the caller's to verify against a fresh observation, the same rule
    /// every other act on this lane states for itself.
    ///
    /// **`mods` is forwarded exactly as given, and refused by the GUEST if
    /// it is anything but 0** — never smoothed over here. CarbonLib has no
    /// `PPostEvent`, so the guest cannot say what was held down while a key
    /// was posted, and posting anyway would be the silent-modifier defect
    /// this project's contract was written to refuse
    /// (`contract/asyncapi.yaml:key`, `docs/input-plane-decisions.md`).
    /// `ActionModel.availability(.key)` refuses a non-zero `mods` before a
    /// request is even built; this is the second reading, for a caller that
    /// reached the adapter directly.
    func key(_ request: AgentIntegrationKeyRequest) async
        -> AgentIntegrationKeyResult {
        guard request.isWellFormed else {
            return .refused(Self.failure(
                "now-key-invalid",
                "A key act names a key by `name`, by `code`, by `char`, or "
                    + "any combination — but at least one of the three",
                reach: .notSent))
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        /* `named`, not `name`: the guest scans a request FLAT, so an
           argument called `name` reads the envelope's own "name":"key".
           Measured 2026-08-02 - the verb refused every wire call while
           the console face worked perfectly. */
        var args: [String: CommandArg] = ["mods": .number(request.mods)]
        if let n = request.name, !n.isEmpty { args["named"] = .text(n) }
        if let code = request.code { args["code"] = .number(code) }
        if let char = request.char { args["char"] = .number(char) }

        let outcome = await run(verb: "key", args: args)
        guard currentSessionID() == sessionID else {
            audit(.warn, "key: the paired guest changed while the "
                      + "keystroke was in progress")
            return .unavailable(Self.failure(
                "now-key-outcome-unknown",
                "The paired guest changed while the keystroke was in "
                    + "progress").asUnavailable)
        }
        switch outcome {
        case .timedOut:
            audit(.warn, "key: no answer in time")
            return .refused(Self.failure(
                "now-key-outcome-unknown",
                "The paired guest did not answer the keystroke in time"))
        case .result(let result) where !result.ok:
            /* The guest's own sentence — `unsupported` for a refused
               modifier, `act-not-taken` for a queue that would not take the
               keyDown — forwarded rather than replaced. */
            audit(.warn, "key refused: "
                      + Self.sanitized(result.error?.message ?? ""))
            return .refused(Self.failure(
                "now-key-refused",
                Self.bounded(result.error?.message
                    ?? "The paired guest refused the keystroke")))
        case .result(let result):
            /* The `key` verb's own rows are lower-case (`code`, `char`,
               `posted`, …) — the input plane's convention, distinct from
               the act plane's capitalized `Window`/`Dispatch` rows read
               above. Reading the wrong case is a silent miss, not a type
               error, so this is spelled out rather than shared with
               `rows(from:verb:)`'s callers above. */
            let rows = Self.rows(from: result, verb: "key")
            guard let posted = rows["posted"] else {
                audit(.warn, "key: the guest answered without a posted row")
                return .refused(Self.failure(
                    "now-key-outcome-unknown",
                    "The paired guest answered the keystroke without "
                        + "saying whether it was posted"))
            }
            let code = Int(rows["code"] ?? "") ?? request.code ?? 0
            let char = Int(rows["char"] ?? "") ?? request.char ?? 0
            audit(.info, "key code \(code) char \(char): "
                      + (posted == "true" ? "posted" : "not posted"))
            return .completed(.init(
                code: code, char: char,
                posted: posted == "true", postedAt: clock()))
        }
    }

    // MARK: - textget

    /// The one third of the act plane that changes nothing, and the only
    /// one of the five whose completion is NOT a dispatch: a reading has
    /// no `Dispatch` row to find, and demanding one would refuse every
    /// successful read.
    func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult {
        guard AgentIntegrationActPolicy.isValidElementReference(element)
        else {
            return .refused(Self.failure(
                "now-text-get-invalid",
                "A text read names one now-element-… reference from a "
                    + "current observation",
                reach: .notSent))
        }
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        let outcome = await run(verb: "textget",
                                args: ["element": .text(element)])
        guard currentSessionID() == sessionID else {
            return .unavailable(Self.failure(
                "now-text-get-outcome-unknown",
                "The paired guest changed while the text read was in "
                    + "progress").asUnavailable)
        }
        switch outcome {
        case .timedOut:
            return .refused(Self.failure(
                "now-text-get-outcome-unknown",
                "The paired guest did not answer the text read in time"))
        case .result(let result) where !result.ok:
            return .refused(Self.failure(
                "now-text-get-refused",
                Self.bounded(result.error?.message
                    ?? "The paired guest refused the text read")))
        case .result(let result):
            let rows = Self.rows(from: result, verb: "textget")
            /* `Text` may legitimately be empty — an empty field is a real
               reading — so its ABSENCE is what refuses, not its emptiness.
               `Truncated` is the guest's word and is read as one: anything
               that is not the machine's "no" is treated as clipped, which
               is the safe direction for a flag whose whole job is to stop
               a caller mistaking a clipped field for a short one. */
            guard let text = rows["Text"], let flag = rows["Truncated"]
            else {
                return .refused(Self.failure(
                    "now-text-get-outcome-unknown",
                    "The paired guest answered the text read without a "
                        + "reading"))
            }
            audit(.info, "textget \(Self.sanitized(element)) read "
                      + "\(text.unicodeScalars.count) scalars")
            return .completed(.init(
                element: element,
                text: Self.bounded(text),
                truncated: flag.lowercased() != "no",
                observedAt: clock()))
        }
    }

    // MARK: - textset

    func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult {
        guard AgentIntegrationActPolicy.isValidElementReference(element)
        else {
            return .refused(Self.failure(
                "now-text-set-invalid",
                "A text write names one now-element-… reference from a "
                    + "current observation",
                reach: .notSent))
        }
        guard AgentIntegrationActPolicy.isBoundedText(text) else {
            /* Named rather than truncated. A silent half-write is the one
               outcome a caller cannot detect and cannot undo. */
            return .refused(Self.failure(
                "now-text-set-invalid",
                "This host sends at most "
                    + "\(AgentIntegrationActPolicy.maximumTextScalars) "
                    + "scalars of replacement text, and refuses a longer "
                    + "one rather than writing a truncated half",
                reach: .notSent))
        }
        let requested = text.unicodeScalars.count
        return await dispatch(
            verb: "textset",
            args: ["element": .text(element), "text": .text(text)],
            describing: "textset \(Self.sanitized(element)) "
                + "(\(requested) scalars)",
            invalidCode: "now-text-set-invalid",
            refusedCode: "now-text-set-refused",
            unknownCode: "now-text-set-outcome-unknown"
        ) { claim in
            .init(element: element,
                  requestedScalars: requested,
                  dispatch: claim.dispatch,
                  dispatchedAt: claim.at, correlation: claim.correlation,
                  settlement: claim.settlement)
        }
    }

    // MARK: - The shared dispatch

    /// What a `Dispatch` row was found to say, and when this side read it.
    struct DispatchClaim {
        let dispatch: AgentIntegrationActDispatch
        let at: Date
        let correlation: String?
        let settlement: String
    }

    /// The four dispatching acts, as one path.
    ///
    /// **`make` is not called at all unless the guest's own rows carried a
    /// `Dispatch` row whose value is a case of
    /// `AgentIntegrationActDispatch`.** That is the load-bearing property,
    /// and it is why the receipt is built here rather than by each caller: a
    /// guest that answered `ok` with no such row has said something this
    /// surface has no vocabulary for, and the honest reading of that is a
    /// refusal with an unknown outcome — never a receipt this side filled in
    /// from the arguments it had just sent.
    ///
    /// The claim is passed IN for the same reason. A `make` that could
    /// construct its own `.dispatched` would be a second place the word can
    /// be spelled, and only one of the two would be reading a machine.
    private func dispatch<Receipt: Codable & Equatable & Sendable>(
        verb: String,
        args: [String: CommandArg],
        describing description: String,
        invalidCode: String,
        refusedCode: String,
        unknownCode: String,
        make: (DispatchClaim) -> Receipt
    ) async -> AgentIntegrationProjectedResult<Receipt> {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        let outcome = await run(verb: verb, args: args)
        guard currentSessionID() == sessionID else {
            /* Unavailable rather than refused: the machine that was asked
               is no longer the machine on the other end, so this side
               cannot say what became of the act. */
            audit(.warn, "\(description): the paired guest changed while "
                      + "the act was in progress")
            return .unavailable(Self.failure(
                unknownCode,
                "The paired guest changed while the act was in progress")
                    .asUnavailable)
        }
        switch outcome {
        case .timedOut:
            audit(.warn, "\(description): no answer in time")
            return .refused(Self.failure(
                unknownCode,
                "The paired guest did not answer the act in time"))
        case .result(let result) where !result.ok:
            /* The guest's own sentence, forwarded rather than replaced —
               `act-not-taken`, `act-timeout` and a stale reference all
               arrive as prose, and inventing a typed code by reading it
               would be this side deciding what happened on a machine it
               cannot see. Safe to forward: every one of those sentences
               quotes counters and fixed prose, never a caller's text. */
            audit(.warn, "\(description) refused: "
                      + Self.sanitized(result.error?.message ?? ""))
            return .refused(Self.failure(
                refusedCode,
                Self.bounded(result.error?.message
                    ?? "The paired guest refused the act"),
                correlation: result.error?.correlation,
                settlement: result.error?.settlement,
                reach: Self.reach(ofGuestRefusal: result.error)))
        case .result(let result):
            let rows = Self.rows(from: result, verb: verb)
            let correlation = rows["Correlation"]
            let settlement = rows["Settlement"] ?? "unknown"
            guard let claimed = rows["Dispatch"],
                  let dispatch = AgentIntegrationActDispatch(
                    rawValue: claimed) else {
                /* THE LINE THIS WHOLE FILE IS BUILT AROUND. An `ok` with no
                   dispatch row is not a success: nothing on this side knows
                   that the event was handed to anything, and filling the
                   receipt in from the request would be the host answering
                   for the machine. */
                audit(.warn, "\(description): the guest answered without a "
                          + "dispatch row")
                return .refused(Self.failure(
                    unknownCode,
                    "The paired guest answered the act without saying the "
                        + "event was dispatched"))
            }
            audit(.info, "\(description) settlement=\(settlement)"
                      + (correlation.map { " correlation=\($0)" } ?? "")
                      + " (dispatch is not guest-visible effect)")
            return .completed(make(
                .init(dispatch: dispatch, at: clock(),
                      correlation: correlation, settlement: settlement)))
        }
    }

    // MARK: - The wire

    private func run(verb: String, args: [String: CommandArg]) async
        -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runCommand(verb, typed: args) {
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

    // MARK: - Reading the guest's rows

    /// The act verbs answer the contract's `x-rowArray` under their own verb
    /// name — `{"output": {"winact": [["Window", "now-window-…"], …]}}`. The
    /// rows are label/value pairs, so this side reads them as a lookup and
    /// keeps nothing it was not asked for.
    ///
    /// The verb name is REQUIRED rather than "whatever single group came
    /// back": a reply carrying another verb's group is a reply to a question
    /// this call did not ask, and reading it would make an act's receipt
    /// composable out of some other verb's answer.
    static func rows(from result: CommandResult,
                     verb: String) -> [String: String] {
        var out: [String: String] = [:]
        for cells in result.output?[verb] ?? [] {
            guard let label = cells.first, !label.isEmpty else { continue }
            out[label] = cells.count > 1 ? (cells.last ?? "") : ""
        }
        return out
    }

    private static func failure(
        _ code: String, _ message: String,
        correlation: String? = nil,
        settlement: String? = nil,
        reach: AgentIntegrationProjectionFailure.Reach = .unknown)
        -> AgentIntegrationProjectionFailure {
        .init(code: code, message: bounded(message),
              correlation: correlation, settlement: settlement,
              reach: reach)
    }

    /// **Whether a guest refusal reached the act plane, read off the
    /// guest's own reply rather than out of its prose.**
    ///
    /// The guest draws this line structurally and says so where it draws
    /// it (`now-guest-ppc/src/act/act_cmds.c`): `reply_error` answers a
    /// malformed request or a reference that would not resolve, and
    /// carries no correlation because no act was ever registered —
    /// "validation and resolve errors … can never inherit a previous
    /// action". `reply_registered_error` answers everything after
    /// `now_act_submit`, and carries the correlation that submit
    /// registered. So the absence of a correlation on a refusal is the
    /// machine saying nothing was armed, dispatched or attempted.
    ///
    /// It is deliberately not a list of codes. `element-not-found`,
    /// `element-stale`, `bad-request` and the act-plane status codes all
    /// arrive by the correlation-free path today, and a code added to the
    /// guest tomorrow lands on the right side of this test without anyone
    /// remembering to add it here.
    static func reach(ofGuestRefusal error: CommandResult.CommandError?)
        -> AgentIntegrationProjectionFailure.Reach {
        error?.correlation == nil ? .notSent : .unknown
    }

    private static func bounded(_ value: String) -> String {
        AgentIntegrationBoundedText.prefix(
            value, scalars: AgentIntegrationActPolicy.maximumTextScalars)
    }

    /// A log line's own bound and escape, for the same reason the reveal
    /// lane has one: a control byte is legal inside an element title and a
    /// raw one corrupts the row the Logs page draws.
    private static func sanitized(_ value: String) -> String {
        var escaped = ""
        for scalar in AgentIntegrationBoundedText
            .prefix(value, scalars: 255).unicodeScalars {
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
}

private extension AgentIntegrationProjectionFailure {
    /// The same code and sentence as the unavailable shape. They are two
    /// types because a refusal and an absence are different facts, and the
    /// act lane needs both spellings of one sentence when the machine
    /// changed mid-act.
    var asUnavailable: AgentIntegrationUnavailable {
        /* The reach travels with it. Every OTHER unavailable means nobody
           was asked, but this one is built after a guest went away mid-act
           — the request did leave, and saying otherwise would let a caller
           write off an act that may be running on a Macintosh. */
        AgentIntegrationUnavailable(code: code, message: message,
                                    reach: reach)
    }
}
