import Foundation

/// The bounds this row renders one census page under, stated where the
/// schema above and the host-side owner read one copy.
///
/// They live here rather than beside the models for the reason
/// `AgentIntegrationRevealPolicy` gives: sibling capabilities are being wired
/// against the shared model files in the same wave, and a tail nobody has to
/// touch is a merge nobody has to resolve.
public enum AgentIntegrationCensusBounds {
    /// The contract's own page size (`CensusReport.rows`, `maxItems: 16`),
    /// restated on this side so a page that exceeds it is REFUSED rather
    /// than trimmed. Trimming would hand a caller sixteen rows out of
    /// seventeen with `hasMore` saying the page was complete, which is the
    /// one failure a paginated answer must not be able to have.
    public static let maximumRowsPerPage = 16

    /// Each row is a `[name, raw, meaning]` triple by contract.
    public static let cellsPerRow = 3

    /// One cell, bounded. A 4 KB frame cannot carry more than this and the
    /// number is declared in the schema, so a caller reading `maxLength`
    /// knows what a long value did.
    public static let maximumCellScalars = 512

    /// The guest's own sentence about why `partial`, why `refused`, what
    /// `absent` means on this machine. Its buffer is smaller than this.
    public static let maximumNoteScalars = 512

    /// A refusal sentence, which may quote the probe name a caller sent.
    public static let maximumRefusalScalars = 320
}

/// The hardware census — `census.request` / `census.report`, projected one
/// page of one probe at a time.
///
/// **The family and not the `census` console verb**, the same choice
/// `ListProcessesProjection` made over `ps`: the verb is the flat read a
/// person types at the machine, the family is the one that paginates and
/// carries a per-probe OUTCOME. That outcome is the thing `x-census` is most
/// emphatic about and the reason this row exists in this shape.
///
/// ## A probe's outcome is not the call's outcome
///
/// Two levels, and conflating them is precisely the failure the census was
/// designed to prevent:
///
/// | Level | Vocabulary | Says |
/// |---|---|---|
/// | the CALL | `completed` / `refused` / `unavailable` (`AgentIntegrationProjectedResult`) | whether a Macintosh was reached and answered at all |
/// | the PROBE | `present` / `absent` / `partial` / `refused` / `failed` / `not-attempted` (`x-census.x-outcomes`) | what that machine found when it looked |
///
/// A probe that answers `refused` — `selectors` on a machine whose partition
/// cannot hold 32 KB of documented selector names, `scsi` where an unattended
/// bus scan is not allowed — is a **completed call**. The machine was asked, it
/// answered, and the answer is "I did not
/// look". Mapping it onto the call's `refused` arm would tell a caller that
/// nothing reached the machine, which is false and unfixable by retrying.
/// The reverse conflation is worse: a probe answering `absent` (no PCI
/// nub, no SCSI bus) is a **finding about the hardware**, rendered as content
/// with zero rows, and must never read as a failure to look.
///
/// The only things that leave the completed arm are calls that produced no
/// census report at all: no paired guest (`unavailable`), a guest that does
/// not implement the family (`refused`, in the guest's own words), a report
/// the host has no vocabulary to render (`refused`), and a probe name this
/// side can see is out of bounds before anything is sent.
///
/// ## Absence is absent, never `false` and never `""`
///
/// Rule 4 of the parity slice lives in this row: both guests answer all
/// fourteen probes and the OUTCOMES differ, which is the whole point of
/// `contract-coverage.md`'s census table rather than a tick. So every fact
/// the guest did not state is an absent key — `total`, `note` and
/// `nextCursor` are nullable and omitted rather than defaulted, and a probe
/// with nothing to report arrives as `absent` with an empty `rows` array and
/// says so in `outcome`. A `0` where the guest said nothing would be this
/// side making a claim about somebody's Macintosh.
///
/// **The smaller guest is a full participant here**, one of the few
/// capabilities where it is. Nothing in this row forks on which guest
/// answered — nothing here can even see which one did — and nothing degrades
/// the MESSAGE for a less capable machine: it degrades the ANSWER, in that
/// guest's own `outcome` and `note`.
///
/// ## Paging is the caller's, deliberately
///
/// `now_capture_screen` hides its paging because the answer is one picture
/// and a half-fetched PNG is nothing. A census page is not that: the page
/// boundary is **semantic**, and the contract pages `scsi` at one target per
/// page exactly so that a wedged SCSI target stalls one frame turnaround
/// rather than a whole probe. A host that looped until `more` went false
/// would collapse that pacing back into one unbounded call and hand a caller
/// an answer with no way to stop.
///
/// So one call is one page, `hasMore` and `nextCursor` are required fields of
/// the answer rather than an implementation detail, and the row count is
/// bounded at the contract's own `maxItems` — a page that exceeds it is
/// refused rather than silently trimmed.
///
/// ## The overlap with `gestalt`, named rather than merged
///
/// The `gestalt` verb — until it landed the largest single unnoticed gap in
/// `docs/mcp-coverage.md` — answers adjacent hardware questions by a different
/// route, and `MachineFactsProjection` is now that row, which endorses this
/// paragraph rather than reopening it. Two capabilities answering adjacent
/// questions is
/// fine; two composing each other is not. Nothing here reads `gestalt` and
/// nothing here should be rewritten in terms of it — the census's `selectors`
/// probe IS the documented Gestalt walk on the machines that can afford it,
/// and it says so in its own outcome when it cannot.
public enum HardwareCensusProjection: HostProjection {
    public static let capability = HostCapabilityID("now_hardware_census")

    /* The message FAMILY, and never a probe name. A probe is an argument of
       this row, not a capability of its own: the capability ledger resolves a
       requirement against the family table first and falls through to the
       guest's `help` COMMAND table, which can contain neither a family nor a
       probe — so requiring "overview" would switch this tool off against
       every guest for the life of every connection, in a sentence that reads
       as a fact about the Macintosh. Requiring the `census` verb instead
       would be the same mistake rule 4 refuses in the other direction: the
       verb is the console's spelling and the message is what both guests
       dispatch. */
    public static let requires = [
        AgentIntegrationCapabilityNames.censusRequest,
    ]

    /* The caller chooses the probe and the page and gets the report back, so
       the family is exposed rather than consumed. That has a documented
       consequence in docs/mcp-coverage.md: exposing `census.request` expands
       the coverage universe to all fourteen probes, which now owe a row
       each. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.censusRequest,
    ]

    /* The Census page: a rail of the fourteen probes with a Run on each and a
       Run All that sweeps them in the guest's own order. It predates this row
       by the whole census arc, so rule 3's user-initiable half costs this
       capability nothing — the difference is that the page pages to the end
       for a person watching, and this row hands the cursor to its caller. */
    public static let acceptedArguments: Set<String> = ["probe", "cursor"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "CensusModuleView.swift",
                         symbol: "model.run(probeID: state.id)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves census.request."

    public static var operationDescriptor: NOWOperationDescriptor {
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": [
                    "type": "string",
                    "maxLength": AgentIntegrationCensusBounds
                        .maximumRefusalScalars,
                    "description":
                        "The guest's own words when it refused the family, bounded and control-escaped; otherwise the host's. A probe that itself answers \"refused\" does NOT arrive here — that is a completed call whose report says the machine declined to look.",
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let row: [String: Any] = [
            "type": "array",
            "minItems": AgentIntegrationCensusBounds.cellsPerRow,
            "maxItems": AgentIntegrationCensusBounds.cellsPerRow,
            "items": [
                "type": "string",
                "maxLength": AgentIntegrationCensusBounds
                    .maximumCellScalars,
            ],
            "description":
                "[name, raw, meaning]. The raw value always survives beside the decoded meaning: a value the guest could not decode keeps its raw form and says so in the meaning column rather than being dropped.",
        ]
        let page: [String: Any] = [
            "type": "object",
            "properties": [
                "probe": [
                    "type": "string",
                    "maxLength": AgentIntegrationProjectionPolicy
                        .maximumSelectorScalars,
                ],
                "outcome": [
                    "type": "string",
                    "enum": AgentIntegrationCensusOutcome.allCases.map(
                        \.rawValue),
                    "description":
                        "THE PROBE's outcome, inside a completed call. present: it ran and returned data. absent: it ran cleanly and the MACHINE said no (no expansion slots, no SCSI bus) — a finding about the hardware, rendered as content and never an error. partial: it reached a smaller surface than its full form; the note says what was out of reach. refused: the RESPONDER declined to look — not served on this build, a safety gate, or an unknown probe name. failed: it started and could not finish, possibly transient. not-attempted: the cursor never reached it. \"We did not look\" and \"it is not there\" are never conflated.",
                ],
                "columns": [
                    "type": "array",
                    "maxItems": AgentIntegrationCensusBounds.cellsPerRow,
                    "items": ["type": "string", "maxLength": 32],
                    "description":
                        "The probe's column headings, which vary by probe ([Fact, Raw, Meaning] for overview, [Volume, Raw, Meaning] for volumes). Empty means this host's probe registry has no headings for a probe name the guest accepted — a newer guest's probe — which is stated rather than guessed at; the rows are unaffected.",
                ],
                "rows": [
                    "type": "array",
                    "maxItems": AgentIntegrationCensusBounds
                        .maximumRowsPerPage,
                    "items": row,
                    "description":
                        "One page. Empty is a complete answer for an absent or refused probe rather than a missing one — read outcome, not the count.",
                ],
                "hasMore": [
                    "type": "boolean",
                    "description":
                        "True when this probe has further pages. One call is one page: the page boundary is the guest's pacing (scsi walks ONE target per page so a wedged target stalls one frame turnaround), so it is handed to the caller rather than looped over here.",
                ],
                "nextCursor": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                    "description":
                        "Pass back as `cursor` to continue. Meaningful only when hasMore; null when the guest sent none, which this host reports rather than invents.",
                ],
                "total": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                    "description":
                        "Rows this probe will yield in total, WHEN THE GUEST KNOWS. Absent means it did not say — never zero, which would be a claim about the machine.",
                ],
                "note": [
                    "type": ["string", "null"],
                    "maxLength": AgentIntegrationCensusBounds
                        .maximumNoteScalars,
                    "description":
                        "The guest's own sentence: why partial, why refused, what absent means on this machine. Absent when it said nothing.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": [
                "probe", "outcome", "columns", "rows", "hasMore",
                "observedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read One Page of the New Old World Guest's Hardware Census",
            "description":
                "Asks the connected Macintosh to look at its own hardware and report one page of one probe. The probe is REQUIRED and there is no all-probes form: fourteen calls summed by this host would be an answer this host composed rather than one the machine gave. The closed probe registry is overview (the synthesis, in plain words), identity, selectors (the documented Gestalt walk), video, volumes, drives, drivers, adb, ata, pccard, power, pci, pram and scsi; an unknown name is answered by the guest as a refused probe with a note, never as an error, which is what keeps the registry additive across guest versions. TWO LEVELS OF OUTCOME, and they mean different things: the call says whether a machine answered, and the report inside a completed call says what that machine found — including \"absent\" (it looked and there is nothing there) and \"refused\" (it declined to look). Both guests answer all fourteen probes and their outcomes differ; that difference is the answer, not a gap. Passive except for scsi, which is a live INQUIRY bus scan and the one declared exception.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "probe": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": AgentIntegrationProjectionPolicy
                            .maximumSelectorScalars,
                        "description":
                            "Which probe to run. Required — asking fourteen times and adding up the answers would be composing a census rather than carrying one. Not enumerated on this side on purpose: the registry is the GUEST's, and a host holding a stale copy would refuse a probe a newer guest serves.",
                    ],
                    "cursor": [
                        "type": "integer",
                        "minimum": 0,
                        "description":
                            "Continue a paginated report from a previous page's nextCursor. 0 or absent starts the probe over — for this family, unlike the software inventory, they mean the same thing.",
                    ],
                ],
                "required": ["probe"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", page),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* Reads the machine and changes nothing on it — including
                   `scsi`, whose INQUIRY is a non-destructive command. What
                   `scsi` does spend is the guest's SCSI bus, which is why the
                   contract paces it and the description names it. */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* Not idempotent, and the honest reason is that a census is a
                   MEASUREMENT: battery charge, free space and mounted volumes
                   are different a minute later, and a caller told this call
                   was idempotent would be entitled to cache it. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys).isSubset(of: acceptedArguments),
              let probe = arguments["probe"] as? String,
              AgentIntegrationCensusPolicy.isValidProbe(probe)
        else {
            return .invalidArguments(Self.argumentRefusal)
        }
        /* Absent and 0 are the same request by contract ("0 or absent starts
           the probe over"), so an omitted cursor is nil rather than 0 and a
           negative one is refused here — the local codec refuses it again on
           arrival, and the guest would have to decide what a negative index
           means. `is Bool` first: a JSON `true` bridges to `Int` on this
           platform, and a caller that sent one did not send a page. */
        var cursor: Int?
        if let raw = arguments["cursor"] {
            guard !(raw is Bool), let value = raw as? Int, value >= 0 else {
                return .invalidArguments(Self.argumentRefusal)
            }
            cursor = value
        }
        return .value(.init(
            await client.census(probe: probe, cursor: cursor)))
    }

    /// The one wording for every way the arguments can be wrong. Public so a
    /// test asserts against the constant rather than against a second copy of
    /// the sentence.
    public static let argumentRefusal =
        "now_hardware_census requires one bounded probe name and an "
            + "optional cursor of 0 or more"
}
