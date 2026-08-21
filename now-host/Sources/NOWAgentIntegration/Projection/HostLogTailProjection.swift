import Foundation

/// Read the end of THIS Mac's own log — the host sibling of
/// `now_guest_log_tail`.
///
/// **Why the row exists at all.** The surface could read the classic Mac's
/// log and not this one. On 2026-08-14 a Continuity Accessibility-permission
/// defect was diagnosable only because an agent went looking for
/// `~/Library/Logs/now-logs/*.log` on the filesystem by hand, and only
/// because the disk switch happened to be on. Everything the host knows about
/// its own wire, transfers, continuity and cloud lanes is written to a ring
/// that the Logs page renders and nothing else could reach.
///
/// **It serves the RING, not the file.** `HostLog` keeps a 2000-line
/// in-memory ring that is live from the first line of every launch, plus —
/// when a switch is on — one file per launch. Serving the file would make
/// this row answer nothing whenever somebody had turned logging off, which is
/// the shape of gate this project keeps being bitten by: a surface that reads
/// empty because a switch is off is indistinguishable from a machine with
/// nothing to say. So the file is a DECLARED FIELD beside the lines
/// (`persistsToDisk`, `file`) and never a substitute for them.
///
/// **Availability is stated, not derived, and that is the difference from the
/// guest row.** `GuestLogTailProjection` derives its availability from the
/// connected guest's own `help` table, because `tail` exists on PowerPC and
/// not on the 68K guest. This row's question is simpler and has one answer:
/// the ring belongs to the process serving this call, so it is always there.
/// `requires` is empty because the row sends the guest nothing — not because
/// nobody worked the requirements out.
///
/// **It takes no `guest` selector.** Which Macintosh is connected has no
/// bearing on what this Mac wrote in its own log, and a selector that was
/// accepted and ignored is the fail-open argument-key defect
/// `HostProjectionArguments` was built to end. `acceptsGuestAddressing` is
/// false, so naming one is refused at the face.
///
/// **What it can disclose, said out loud.** The lines are prose this side
/// wrote, and some of that prose names things: transferred file names, guest
/// paths, host paths, machine ids, and the log file's own location under the
/// user's home. That is the same text a person sitting at this Mac reads on
/// the Logs page, and it is recorded here rather than discovered later. It is
/// NOT a way to read arbitrary files: the only argument that selects anything
/// is an area tag, matched against a closed set of tags the host's own
/// `HostLog.write` calls produce.
public enum HostLogTailProjection: HostProjection {
    public static let capability = HostCapabilityID("now_host_log_tail")

    /* Sends the classic Mac nothing at all. Empty here is the positive
       statement the protocol defines it to be: available whatever the guest
       implements, and available with no guest at all. */
    public static let requires: [String] = []
    public static let exposes: [String] = []

    /* This Mac's own application state, and so outside guest consent. A
       guest that answered `disabled` to `hello.agent` has declined to be
       read or driven; it has not been asked about, and has no standing over,
       what this Mac wrote in its own log. Without this the dispatch would
       deny a host-log read because a Macintosh across the room said no,
       which is a refusal nobody could act on. */
    public static let authorityDomain =
        HostProjectionAuthorityDomain.hostApplication
    public static let acceptsGuestAddressing = false

    public static let acceptedArguments: Set<String> = Argument.all

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        /* The Logs page a person opens in the sidebar: the scrollback IS the
           ring, drawn line by line. `ForEach(log.lines)` is that loop and
           appears once in the file — the distinctiveness rule in
           `HostFaceReach.reached`, which a symbol like `model.refresh()`
           fails. */
        .appUI: .reached(file: "LogsModuleView.swift",
                         symbol: "ForEach(log.lines)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The host's own in-memory ring is live from the first line of every "
        + "launch, so this row is available whether or not a Macintosh is "
        + "connected and whether or not disk logging is on."

    public static var operationDescriptor: NOWOperationDescriptor {
        let policy = AgentIntegrationHostLogPolicy.self
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
                            "One whole log line: `HH:MM:SS area [!?] message` — this Mac's local clock, a six-character area tag, an optional \"?\" (warn) or \"!\" (error) marker, and the host's own sentence. Text, not fields — read it, do not parse it. A line never contains a line terminator, and any other control character arrives written as \\xNN rather than raw.",
                    ],
                    "description":
                        "OLDEST FIRST — the last line is the most recent thing that happened.",
                ],
                "requested": ["type": "integer"],
                "matching": [
                    "type": "integer",
                    "description":
                        "How many lines the ring currently holds that match the area filter. Read beside \"shown\" to tell a short log from a truncated answer.",
                ],
                "shown": [
                    "type": "string",
                    "description":
                        "\"N of M\", plus \"(older ones did not fit)\" when the answer hit its size budget and the oldest lines were dropped to make room. Read this before concluding anything from the first line you were given.",
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
                        "The ring's size. When \"matching\" equals it, the beginning of this launch has already rolled off.",
                ],
                "persistsToDisk": [
                    "type": "boolean",
                    "description":
                        "Whether this launch is ALSO writing its lines to a file. It does not affect the lines above: the ring is served either way.",
                ],
                "file": [
                    "type": ["string", "null"],
                    "description":
                        "Where that per-launch file is on this Mac, when there is one. Null is the ordinary answer and is not a failure.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": [
                "lines", "requested", "matching", "shown", "ringCapacity",
                "persistsToDisk", "observedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read This Mac's Own New Old World Log",
            "description":
                "Returns the last lines of the NEW OLD WORLD HOST's own log for the launch it is in — this Mac's side of the pairing, not the classic Mac's (that is now_guest_log_tail). It reads the application's live in-memory ring, the same text a person sees on the Logs page, so it answers whether or not disk logging is switched on and whether or not a Macintosh is connected; \"persistsToDisk\" and \"file\" report the optional per-launch file beside the lines rather than in place of them. Optional \"area\" narrows to one subsystem tag AS THE LOG WROTE IT, which is at most six characters: \(areaExamples.map { "\"\($0)\"" }.joined(separator: ", ")). Note the truncation: continuity is \"contin\" and network is \"networ\". At most \(policy.maximumLineCount) lines (\(policy.defaultLineCount) by default), newest last; a long answer is cut to a size budget from the OLDEST end and says so in \"shown\".",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.lines: [
                        "type": "integer",
                        "minimum": 1,
                        "maximum": policy.maximumLineCount,
                        "description":
                            "How many lines, newest last. Omit for \(policy.defaultLineCount). The maximum is the ring's own size — more than that is refused rather than clamped, because there are no such lines to have.",
                    ],
                    Argument.area: [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": policy.areaTagScalars,
                        "description":
                            "One area tag, matched exactly against the tag the host wrote. The log's tags are at most \(policy.areaTagScalars) characters, so \"contin\" and not \"continuity\" — a longer word is refused rather than answered with an empty tail, which would read as a silent subsystem. Omit for every area.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                /* Two variants and not three. The shared result type can
                   carry `refused`, and nothing on this lane produces one:
                   the arguments are refused before dispatch, and the only
                   other outcome is that the host process could not be
                   reached — which is `unavailable`. A variant that cannot
                   occur is a claim, so it is not published. */
                "oneOf": [
                    variant("completed", "completed", completed),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* A read of this process's own memory. Nothing on either
                   machine moves. */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* The ring is live and this host writes to it constantly —
                   including a line for this very call, through the audit
                   seam — so two identical calls a second apart legitimately
                   differ. Cheap to retry is a different claim and is true. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    /// **The area tags the description offers, spelled once.**
    ///
    /// The description is prose about a set the app's `HostLog.write` calls
    /// own, and prose restating a set is the second place to be wrong: an
    /// agent that filters on a tag this host never writes gets an empty tail
    /// and reads it as a silent subsystem. So the sentence is BUILT from this
    /// array, and `AgentIntegrationHostLogTailTests` checks every member
    /// against the app's own source. Already truncated to the tag field's
    /// width, which is why continuity appears as `contin`.
    /// Continuity first, because it is the lane that made this row
    /// necessary; the rest alphabetically. Derived from the app's own
    /// `HostLog.write` calls rather than remembered — the first version of
    /// this list was written from memory and offered `config`, which nothing
    /// writes, and omitted `mirror`, which does.
    public static let areaExamples = [
        "contin", "act", "agent", "app", "chat", "dev", "files", "mcp",
        "mirror", "networ", "sw",
    ]

    /// The two arguments, spelled once.
    enum Argument {
        static let lines = "lines"
        static let area = "area"
        static let all: Set<String> = [lines, area]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        /* Absent arguments are an empty object — every member is optional,
           so a bare call is a complete request — while something that is not
           an object at all is refused. The guest log row's distinction, kept
           because a caller uses the two rows the same way. */
        guard let object = arguments.object
            ?? (arguments.raw == nil ? [:] : nil) else {
            return .invalidArguments(
                "\(capability.rawValue) takes an object with an optional "
                    + "\(Argument.lines) and \(Argument.area)")
        }
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: Argument.all) {
            return .invalidArguments(refusal)
        }

        var lines: Int?
        if let raw = object[Argument.lines] {
            /* `true` bridges to an NSNumber that casts to 1, so the boolean
               is refused before the integer is read: a caller who sent a
               flag asked something this row does not serve, and answering it
               with one line of log would be a guess. */
            guard !(raw is Bool), let value = raw as? Int,
                  AgentIntegrationHostLogPolicy.isValidLineCount(value) else {
                return .invalidArguments(
                    "\(Argument.lines) is a whole number from 1 to "
                        + "\(AgentIntegrationHostLogPolicy.maximumLineCount)")
            }
            lines = value
        }

        var area: String?
        if let raw = object[Argument.area] {
            guard let value = raw as? String,
                  AgentIntegrationHostLogPolicy.isValidArea(value) else {
                return .invalidArguments(
                    "\(Argument.area) is an area tag of 1 to "
                        + "\(AgentIntegrationHostLogPolicy.areaTagScalars) "
                        + "characters, as the log writes it")
            }
            area = value
        }

        return .value(.init(
            await client.hostLogTail(lines: lines, area: area)))
    }
}
