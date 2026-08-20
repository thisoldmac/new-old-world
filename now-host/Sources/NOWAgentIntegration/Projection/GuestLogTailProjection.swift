import Foundation

/// Read the guest's own log for this launch — the `tail` verb, paged into a
/// real retrieval.
///
/// **This row began as one 40-line page and that was not retrieval.** The
/// guest's ring holds 2000 lines and a night of diagnosis wants hundreds of
/// them; what it got, five separate times on 2026-08-14, was a person
/// saving the Logs page to a file on a PowerBook, FTPing it off, and
/// pasting it to an agent. So the verb learned to page
/// (`contract/asyncapi.yaml`, `x-commands` tail: an `area` filter applied
/// on the guest before the wire, and a `before` sequence cursor), and this
/// row asks for as many pages as the ask is deep. One wire answer is still
/// at most 40 lines — that bound belongs to the 4 KB control frame and did
/// not move; what moved is whose job it is to keep asking.
///
/// *What may a caller name, and where?* **No file, anywhere.** The
/// arguments are a count and an area tag. What it reads is the
/// application's own in-memory ring for the launch it is in
/// (`now-guest-ppc/src/core/nowlog.c`) — the same text the person at the
/// machine reads on the guest's Logs page or by typing the same `tail` at
/// its console. That is a deliberate refusal, not an omission: this row
/// returns bytes, so it may not also take a name — "tail any file on the
/// volume" would be a materially broader authority than anything on this
/// surface has. If a bounded read of a named file is wanted,
/// `now_guest_files_download` already is it, under `guestRoot`, with the
/// authority that belongs there.
///
/// **What it can still disclose, said out loud.** A log line is prose the
/// guest wrote, and some of that prose contains paths: the `get`, `put` and
/// `files` areas log the items they handled, by design (docs/logging.md).
/// So a caller can learn the NAMES of items the machine touched, including
/// items outside `guestRoot`. The bound on that is the guest's own
/// editorial judgement about what belongs in its log, and it is the same
/// text a person sitting at the machine reads — but it is a widening over
/// the Files family and is recorded here rather than discovered later.
///
/// **How much, and who chooses.** Up to the ring's own 2000 — asking for
/// more is refused rather than clamped, because there are no such lines to
/// have. The default stays the guest verb's own 20. The answer's byte
/// budget can still bind before the count does, and when it does the OLDEST
/// lines are dropped and `shown` says so; nothing truncates silently in
/// either direction. `matching` beside it tells a short log from a cut
/// answer.
///
/// **The answer is the host log's shape, on purpose.** Whole lines with
/// declared edges (`shown`, `matching`, `ringCapacity`), because the two
/// logs are the two halves of one wire and an agent diagnosing it reads
/// `now_host_log_tail` and this row side by side. The guest's clock is on
/// its lines and is not this Mac's clock; nothing here re-times them.
///
/// **PowerPC only, and by derivation rather than by declaration.** The
/// requirement is the command `tail`; the ledger resolves a command against
/// the connected guest's own `help` table. The 68K guest's table has no
/// `tail` row (`now-guest-68k/src/commands/commands68.c`), so this row
/// reports `unavailable` there in typed form — a complete answer, never a
/// weaker version of the tool. That asymmetry is recorded in
/// docs/contract-coverage.md with the other per-guest gaps.
public enum GuestLogTailProjection: HostProjection {
    public static let capability = HostCapabilityID("now_guest_log_tail")

    /* One command and nothing else. It reads no files through the file
       family and drives nothing, so there is no second requirement to
       compose from — the paging is repetition of the same command, not a
       second capability. */
    public static let requires = [
        AgentIntegrationCapabilityNames.tailCommand,
    ]

    /* The caller directs the read and receives its answer, so the command
       is exposed. Nothing is consumed internally, which is why this row has
       no required-and-not-exposed entry in docs/mcp-coverage.md. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.tailCommand,
    ]

    /* The host's own Console module: a person types `tail 40 files` and
       reads the lines, and can type the `before` cursor the answer offers.
       The console forwards the typed line whole down the EXEC plane while
       this row sends `command.request`; they meet inside the guest, in the
       one selection both of its faces dispatch through
       (`now-guest-ppc/src/core/logquery.c`) — the guest-side parity rule
       working as intended rather than a coincidence to lean on. */
    public static let acceptedArguments: Set<String> = Argument.all

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ConsoleModel.swift",
                         symbol: "send(command)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest's command table names tail."

    public static var operationDescriptor: NOWOperationDescriptor {
        let policy = AgentIntegrationGuestLogPolicy.self
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": [
                    "type": "string",
                    "maxLength": policy.maximumRefusalScalars,
                    "description":
                        "The guest's own refusal sentence when it refused, bounded and control-escaped; otherwise the host's.",
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let completed: [String: Any] = [
            "type": "object",
            "properties": [
                "lines": [
                    "type": "array",
                    "maxItems": policy.maximumLineCount,
                    "items": [
                        "type": "string",
                        "maxLength": policy.maximumLineScalars,
                        "description":
                            "One whole log line: `HH:MM:SS area [!?] message` — that Macintosh's local clock (not this Mac's; the two are not synchronised and are not comparable), a six-character area tag, an optional \"?\" (warn) or \"!\" (error) marker, and the guest's sentence. Text, not fields — read it, do not parse it. Already Unicode: the guest transcodes its MacRoman itself. A line never contains a line terminator, and any other control character arrives written as \\xNN rather than raw.",
                    ],
                    "description":
                        "OLDEST FIRST — the last line is the most recent thing that happened on that machine.",
                ],
                "requested": ["type": "integer"],
                "matching": [
                    "type": "integer",
                    "description":
                        "How many lines the guest's ring holds that match the area filter, as the guest last reported it. Read beside \"shown\" to tell a short log from a truncated answer.",
                ],
                "shown": [
                    "type": "string",
                    "description":
                        "\"N of M\", plus \"(older ones did not fit)\" when a bound — the byte budget, the page cap or the walk deadline — stopped the retrieval before the count did. The oldest lines are always the ones dropped. Read this before concluding anything from the first line you were given.",
                ],
                "area": [
                    "type": ["string", "null"],
                    "maxLength": policy.areaTagScalars,
                    "description":
                        "The filter that was applied, echoed back; null when every area was returned.",
                ],
                "ringCapacity": [
                    "type": "integer",
                    "description":
                        "The guest ring's size. When \"matching\" equals it, the beginning of that launch has already rolled off.",
                ],
                "guestFile": [
                    "type": ["string", "null"],
                    "description":
                        "Where that launch is writing its log file ON THE GUEST'S OWN DISK, as the guest names it — context, not a handle: nothing on this surface takes a guest path. Null when the guest did not say.",
                ],
                "pages": [
                    "type": "integer",
                    "minimum": 1,
                    "description":
                        "How many wire round trips served this answer — the honest cost of asking a 68030-class link for hundreds of lines.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": [
                "lines", "requested", "matching", "shown", "ringCapacity",
                "pages", "observedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read the New Old World Guest's Own Log",
            "description":
                "Returns lines of the connected Macintosh's log for the launch it is in — the application's own 2000-line in-memory ring, the same text a person sitting at that machine reads on its Logs page. It NAMES NO FILE and cannot be pointed at one: the arguments are how many lines (up to the ring's \(policy.maximumLineCount); the guest verb's own \(policy.defaultLineCount) by default) and an optional \"area\" that narrows to one subsystem tag AS THE GUEST'S LOG WROTE IT, at most \(policy.areaTagScalars) characters, filtered on the guest before crossing the wire. The host pages the guest's `tail` verb underneath — 40 lines per 4 KB control frame — so deep asks cost round trips to a slow machine; \"pages\" reports how many. It is the log of NOW's own guest application, not the system's, so it reports what the wire, the transfers and the file operations did — and because the guest logs the items it handled, a line can name a file on that machine. On a classic Mac this is the record that survives a crash which takes the window and every in-memory buffer with it, which is the reason to be able to read it from here at all. PowerPC guests only: the 68K guest's command table has no tail.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.lines: [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": policy.maximumLineCount,
                        "description":
                            "How many lines, newest last. Omit for the guest verb's own default of \(policy.defaultLineCount); a diagnosis usually wants hundreds. More than \(policy.maximumLineCount) is refused rather than clamped — the ring holds no more, and a silently smaller answer to a bigger question is how a reader concludes the machine went quiet.",
                    ],
                    Argument.area: [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": policy.areaTagScalars,
                        "description":
                            "One area tag, matched exactly against the tag the guest wrote — the tag field is \(policy.areaTagScalars) characters, so \"contin\" and not \"continuity\". A longer word is refused rather than answered with an empty tail, which would read as a silent subsystem. Omit for every area.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", completed),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* A read, without qualification: nothing on the machine
                   moves, nothing comes to the front, and the person
                   sitting at it sees nothing happen. */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* Not idempotent in the useful sense — the ring is live, so
                   two identical calls a second apart legitimately differ,
                   and a caller must not be told a repeat is free of
                   surprises. Cheap to retry, which is a different claim. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    /// The two arguments, spelled once. They are the contract's own keys;
    /// the `before` cursor is deliberately NOT here — paging is this side's
    /// job, and a cursor a caller could pass is a page they could skip.
    enum Argument {
        static let lines = "lines"
        static let area = "area"
        static let all: Set<String> = [lines, area]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        /* Absent arguments are an empty object — every member of this row's
           input is optional, so a bare call is a complete request — while
           something that is not an object at all is refused. The same
           distinction the host log row keeps, because a caller uses the two
           rows the same way. */
        guard let object = arguments.object
            ?? (arguments.raw == nil ? [:] : nil) else {
            return .invalidArguments(
                "\(capability.rawValue) takes an object with an optional "
                    + "\(Argument.lines) and \(Argument.area)")
        }
        let unknown = Set(object.keys).subtracting(Argument.all)
        guard unknown.isEmpty else {
            return .invalidArguments(
                "\(capability.rawValue) does not take "
                    + unknown.sorted().joined(separator: ", "))
        }

        var lines: Int?
        if let raw = object[Argument.lines] {
            /* `true` bridges to an NSNumber that casts to 1, so the boolean
               is refused before the integer is read: a caller who sent a
               flag asked something this row does not serve, and answering
               it with one line of log would be a guess. */
            guard !(raw is Bool), let value = raw as? Int,
                  AgentIntegrationGuestLogPolicy.isValidLineCount(value)
            else {
                return .invalidArguments(
                    "\(Argument.lines) is a whole number from 1 to "
                        + "\(AgentIntegrationGuestLogPolicy.maximumLineCount)")
            }
            lines = value
        }

        var area: String?
        if let raw = object[Argument.area] {
            guard let value = raw as? String,
                  AgentIntegrationGuestLogPolicy.isValidArea(value) else {
                return .invalidArguments(
                    "\(Argument.area) is an area tag of 1 to "
                        + "\(AgentIntegrationGuestLogPolicy.areaTagScalars) "
                        + "characters, as the guest's log writes it")
            }
            area = value
        }

        return .value(.init(
            await client.tailGuestLog(lines: lines, area: area)))
    }
}
