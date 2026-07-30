import Foundation

/// Read the end of the guest's own log for this launch — the `tail` verb,
/// projected.
///
/// **This is the first row that returns free-form TEXT the machine wrote,
/// rather than facts about it, so the scope question is answered first and
/// deliberately.**
///
/// *What may a caller name, and where?* **Nothing, anywhere.** `tail` takes
/// one argument and it is a COUNT (`contract/asyncapi.yaml`, `x-commands`:
/// `lines`, "Default 20, most 40"). There is no path in the verb, none in
/// the wire operation, and none here. What it reads is
/// `now_log_tail` — the application's own 2000-line in-memory ring for the
/// launch it is in (`now-guest-ppc/src/core/nowlog.c`) — which is the same
/// text the person at the machine already has on the guest's Logs page.
///
/// That is a deliberate refusal, not an omission. "Tail any file on the
/// volume" would be a materially broader authority than anything on this
/// surface has today: the guest-files rows are confined to the host-owned
/// `guestRoot`, and `reveal` escapes that confinement only because it
/// returns no bytes. This row DOES return bytes, so it may not also take a
/// name — and giving it one is not a host decision in any case. The verb
/// would have to grow an argument, which is a guest change, which means it
/// was never a projection (the parity plan's own stop condition). If a
/// bounded read of a named file is wanted, `now_guest_files_download`
/// already is it, under `guestRoot`, with the authority that belongs there.
///
/// **What it can still disclose, said out loud.** A log line is prose the
/// guest wrote, and some of that prose contains paths: the `get`, `put` and
/// `files` areas log the items they handled, by design
/// (docs/logging.md). So a caller of this row can learn the NAMES of items
/// the machine touched, including items outside `guestRoot`. The bound on
/// that is the guest's own editorial judgement about what belongs in its
/// log, and it is the same text a person sitting at the machine reads on the
/// Logs page — but it is a widening over the Files family and is recorded
/// here rather than discovered later.
///
/// **How much, and who chooses.** The caller may raise the count from the
/// verb's default of 20 to its maximum of 40, and no further: 41 is refused
/// HERE, before it costs a round trip to a 68030, and refused again by the
/// local codec on arrival. Above that the guest applies a second bound this
/// side does not get to choose — the answer must fit a 4 KB control frame,
/// so it drops the OLDEST lines first and says so in its own `log` group:
/// `shown` reads `"12 of 20 (older ones did not fit)"`. Nothing truncates
/// silently in either direction, and that row is also the cross-check on
/// this side's own rendering bounds, which are sized from the guest's
/// buffers so that they cannot bite before the guest's do.
///
/// **PowerPC only, and by derivation rather than by declaration.** The
/// requirement is the command `tail`; the ledger resolves a command against
/// the connected guest's own `help` table. The 68K guest's table has no
/// `tail` row (`now-guest-68k/src/commands/commands68.c`), so this row
/// reports `unavailable` there in typed form — a complete answer, never a
/// weaker version of the tool — without one line here asking which guest is
/// on the wire.
public enum GuestLogTailProjection: HostProjection {
    public static let capability = HostCapabilityID("now_guest_log_tail")

    /* One command and nothing else. It reads no files through the file
       family and drives nothing, so there is no second requirement to
       compose from. */
    public static let requires = [
        AgentIntegrationCapabilityNames.tailCommand,
    ]

    /* The caller directs the read and receives its answer, so the command
       is exposed. Nothing is consumed internally, which is why this row has
       no required-and-not-exposed entry in docs/mcp-coverage.md. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.tailCommand,
    ]

    /* The host's own Console module: a person types `tail 40` and reads the
       lines. It predates this row by the whole project — `send(command)` in
       `submit()` is the call site the Return key reaches.

       Worth being precise about what that proves, because the two paths are
       not the same wire message. The console is a dumb shell: it forwards
       the typed line whole down the EXEC plane, and this row sends
       `command.request`. They meet inside the guest, in the one command
       table both of its faces dispatch through
       (`now-guest-ppc/src/commands/commands.c`, and `console_model.c` for
       the machine's own console) — which is the guest-side parity rule
       working as intended rather than a coincidence to lean on. So the
       affordance is real and the implementation is one; what a person gets
       is the guest's rendering of it and what this row gets is its rows. */
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ConsoleModel.swift",
                         symbol: "send(command)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest's command table names tail."

    public static var mcpDescriptor: [String: Any] {
        let bounds = AgentIntegrationGuestLogTailBounds.self
        let policy = AgentIntegrationGuestLogPolicy.self
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": [
                    "type": "string",
                    "maxLength": bounds.maximumRefusalScalars,
                    "description":
                        "The guest's own refusal sentence when it refused, bounded and control-escaped; otherwise the host's.",
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let row: [String: Any] = [
            "type": "object",
            "properties": [
                "label": [
                    "type": "string",
                    "maxLength": bounds.maximumLabelScalars,
                    "description":
                        "In the \"tail\" group, the line's own timestamp as the guest's clock wrote it (HH:MM:SS, that machine's local time — the two machines' clocks are not synchronised and are not comparable). In the \"log\" group, the name of the fact.",
                ],
                "value": [
                    "type": "string",
                    "maxLength": bounds.maximumValueScalars,
                    "description":
                        "One whole log line, after its timestamp: an area tag, an optional \"?\" (warn) or \"!\" (error) marker, and the guest's sentence. Text, not fields — read it, do not parse it. Already Unicode: the guest transcodes its MacRoman bytes itself before they reach the wire, so nothing here needs an encoding guess. A line never contains a line terminator, and any other control character arrives written as \\xNN rather than raw, so nothing is dropped and nothing is passed through to corrupt a row.",
                ],
            ],
            "required": ["label", "value"],
            "additionalProperties": false,
        ]
        let group: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string", "maxLength": 64],
                "rows": [
                    "type": "array",
                    "maxItems": bounds.maximumRowsPerGroup,
                    "items": row,
                ],
            ],
            "required": ["name", "rows"],
            "additionalProperties": false,
        ]
        let report: [String: Any] = [
            "type": "object",
            "properties": [
                "verb": ["const": "tail"],
                "groups": [
                    "type": "array",
                    "maxItems": bounds.maximumGroups,
                    "items": group,
                    "description":
                        "Two groups, in the guest's own words. \"tail\" is the lines, OLDEST FIRST — the last one is the most recent thing that happened. \"log\" is the guest's account of the answer's own edges: \"file\" is where this launch is writing on that machine, and \"shown\" reads \"N of M\" — plus \"(older ones did not fit)\" when the reply hit the guest's 4 KB control-frame budget and dropped the oldest lines to make room. Read \"shown\" before concluding anything from the first line you were given.",
                ],
                "note": [
                    "type": ["string", "null"], "maxLength": 256,
                    "description":
                        "Reserved for a sentence the guest offered about the edges of its answer. `tail` states its own bound as the \"shown\" row instead, so this is null for this verb; it is not a place the host writes.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["verb", "groups", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read the New Old World Guest's Own Log",
            "description":
                "Returns the last lines of the connected Macintosh's log for the launch it is in — the application's own in-memory ring, the same text a person sitting at that machine reads on its Logs page. It NAMES NO FILE and cannot be pointed at one: the only argument is how many lines, at most \(policy.maximumLineCount) (\(policy.defaultLineCount) by default). It is the log of NOW's own guest application, not the system's, so it reports what the wire, the transfers and the file operations did — and because the guest logs the items it handled, a line can name a file on that machine. On a classic Mac this is the record that survives a crash which takes the window and every in-memory buffer with it, which is the reason to be able to read it from here at all. PowerPC guests only: the 68K guest's command table has no tail.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.lines: [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": policy.maximumLineCount,
                        "description":
                            "How many lines, newest last. Omit for the verb's own default of \(policy.defaultLineCount). More than \(policy.maximumLineCount) is refused rather than clamped — the guest cannot fit them in one control frame, and a silently smaller answer to a bigger question is how a reader concludes the machine went quiet.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", report),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* A read, and the only row here that is one without
                   qualification: nothing on the machine moves, nothing comes
                   to the front, and the person sitting at it sees nothing
                   happen. */
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

    /// The one argument, spelled once. It is the contract's own key.
    enum Argument {
        static let lines = "lines"
        static let all: Set<String> = [lines]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        /* Absent arguments are an empty object — every member of this row's
           input is optional, so a bare call is a complete request — while
           something that is not an object at all is refused. The same
           distinction the capture row keeps. */
        guard let object = arguments.object
            ?? (arguments.raw == nil ? [:] : nil) else {
            return .invalidArguments(
                "\(capability.rawValue) takes an object with an optional "
                    + "\(Argument.lines)")
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
        return .value(.init(await client.tailGuestLog(lines: lines)))
    }
}

/// The bounds this row renders a guest row report under, stated where both
/// the schema above and the host-side owner read one copy.
///
/// **Every one is derived from a buffer in the guest's own source, and is a
/// backstop rather than a trim.** In normal operation the guest's bound
/// binds first and reports itself in its `shown` row; these exist so that a
/// guest which grew a group or a longer line is rendered short rather than
/// rendering unboundedly, and a caller can always detect that by comparing
/// the row count against `shown`.
public enum AgentIntegrationGuestLogTailBounds {
    /// `tail` answers two groups — `tail` and `log`
    /// (`now-guest-ppc/src/commands/commands.c :: run_tail`). Four, so a
    /// guest that grows a third is rendered rather than silently trimmed to
    /// what this side expected.
    public static let maximumGroups = 4
    /// `kLogTailMax`, the guest's own tail index size (48), which is above
    /// the 40 lines the verb will ever return. The larger group is 40 rows
    /// plus the `log` group's two, so this cannot bite before the guest's
    /// own frame budget does.
    public static let maximumRowsPerGroup = 48
    /// A timestamp is `HH:MM:SS` in a 16-byte guest buffer; a `log` row's
    /// label is a word. 64 is the shared row-report label bound.
    public static let maximumLabelScalars = 64
    /// `kLogLineMax` is 120 bytes per stored line, and the guest escapes
    /// into a 320-byte buffer; the `log` group's `file` row carries an HFS
    /// path, which is 255. 320 covers the widest of them.
    public static let maximumValueScalars = 320
    /// The guest composes a command refusal into a 240-byte buffer; this is
    /// that with room for what it may quote back.
    public static let maximumRefusalScalars = 320
}
