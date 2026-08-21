import Foundation

/// The bounds this capability states once, because three layers read them.
///
/// The three numbers that matter are a chain, and they are only safe in
/// ascending order: the **guest** gives up after 20 s per sweep and runs at
/// most two (`now-guest-ppc/src/files/catsearch.c :: kGiveUpTicks`), the
/// **host** stops waiting at 42 s, and the local socket's window for this
/// operation is 45 s (`AgentIntegrationLocalClient`, which already classifies
/// `catalogSearch` with capture). Get that order wrong in either place and a
/// call that was going to succeed fails as a transport error instead of as
/// this capability's own typed refusal — which teaches its caller nothing.
public enum AgentIntegrationCatalogSearchPolicy {
    /// The verb, as `help` names it and as the report labels itself.
    public static let verb = "catsearch"

    /// The row ceiling, and it is the **guest's own buffer** rather than a
    /// number chosen here: `run_catsearch` fills a `CatSearchRow rows[16]`
    /// and `now_catsearch_run` writes at most ten of them. So this cannot
    /// truncate a `catsearch` answer today, which is the point — the bound
    /// exists to stay ahead of the guest, not to shorten it. If the guest
    /// ever answers past it, the report says so in `note` rather than
    /// quietly dropping the tail.
    public static let maximumRows = 16

    /// The guest's `CatSearchRow` field sizes. They are BYTE caps on the
    /// machine, so a scalar count can only come in under them; restating
    /// them here is what lets the schema publish a bound a caller can rely
    /// on without reading C.
    public static let maximumLabelScalars = 24
    public static let maximumValueScalars = 56

    /// The refusal-sentence bound. The guest's own `catsearch-failed`
    /// message can carry a Toolbox error number and nothing longer.
    public static let maximumFailureCodeScalars = 64
    public static let maximumMessageScalars = 200

    /// How long the host waits. See the chain above; 42 sits between the
    /// guest's 40 and the socket's 45.
    public static let commandTimeout: TimeInterval = 42

    /// What `note` says when the host had to bound the answer.
    ///
    /// Sitting in `AgentIntegrationGuestRowReport.note`, which is documented
    /// as the GUEST's sentence about the edges of its answer. This is the one
    /// host sentence that field carries, and it is attributed in the text for
    /// exactly that reason: a bound reached is an edge of the answer, and the
    /// alternative — dropping rows and saying nothing — is the silent
    /// truncation the 68K software listing's `note` field exists to refuse.
    public static func truncationNote(answered: Int) -> String {
        "The host bounded this answer to \(maximumRows) rows; the guest "
            + "answered \(answered). The rows beyond the bound are not here."
    }
}

/// **What a whole-volume application search costs on the connected machine.**
///
/// Not a query. `catsearch` takes no arguments and returns no file listing:
/// it runs `PBCatSearch` over the guest's startup volume for type `APPL` in
/// short time slices, cold and then warm, and answers rows — the volume and
/// its file/folder counts, whether the volume supports CatSearch at all, what
/// the sweep took, the longest slice against its 15-tick budget, the hit
/// count, and up to three of the names it found. It is the measurement the
/// Software module's inventory design rests on, and it is `catsearch` in the
/// guest's own `help` table on both of the guest's faces.
///
/// ## The cost, and why there is no opt-in flag
///
/// This is the most expensive read on the surface — up to ~40 s of a
/// PowerBook that is doing nothing else while it runs. `software.list` is the
/// nearest comparison and it IS gated: the capability ledger probes it only
/// when a caller passes `probeCostly`, on the stated grounds that four
/// seconds of someone's machine is something a caller asks for on purpose.
/// **That gate does not transfer here, and the reason is a real asymmetry
/// rather than a judgement about which cost is bigger.**
///
/// `probeCostly` exists because `software.list` is a message FAMILY, and a
/// family's availability cannot be established except by sending the request.
/// So the capability report faced a genuine choice — pay four seconds to
/// answer a question nobody asked, or report `unproven` — and the flag is how
/// a caller opts into paying it. `catsearch` is a COMMAND. Its availability
/// comes off `help`, which is sent once per connection anyway and costs
/// nothing, so **no report and no other capability can ever spend this
/// machine's forty seconds incidentally.** The only way to pay the cost is to
/// call the one tool whose entire purpose is to measure it, which is already
/// "a caller asks for it on purpose" — and a required `acknowledgeCost: true`
/// on top of that would be a flag guarding a door with nothing behind it,
/// while making the honest answer harder to obtain.
///
/// What the cost does earn is **disclosure**: the description states the
/// seconds and the two passes before a caller spends them, the annotations
/// say it is not idempotent (the warm pass is measurably not the cold one),
/// and the host's own wait is bounded so a caller gets a typed answer rather
/// than a hung tool. Cost is priced, not hidden; it is simply not gated
/// twice.
///
/// ## Scope, which is deliberately wider than `guestRoot`
///
/// The guest-files projections are confined to a host-owned `guestRoot` and
/// this one is not. That is an authority decision, so here it is:
///
/// - **The caller chooses nothing.** There is no path, no filter, no volume
///   and no cursor to send — `now_catsearch_run` picks its own volume with
///   `FindFolder(kOnSystemDisk, kSystemFolderType, …)`. `guestRoot` bounds
///   what a caller may NAME, and a call that names nothing has nothing to
///   confine. Inheriting the root here would not narrow the sweep; it would
///   only mean refusing a call whose target the caller never chose.
/// - **What crosses back is aggregate, not enumerable.** Counts, tick
///   timings, a slice maximum, a hit count. It cannot be paged, re-aimed or
///   walked, so it is not a directory listing wearing a different name.
/// - **The residual reach is real and is stated rather than waved past:**
///   the volume's name, its total file and folder counts, and up to three
///   application names — the first three `PBCatSearch` happened to return,
///   capped by the guest at 52 bytes together. Those escape `guestRoot`.
///   They are what the guest already prints for the person standing at the
///   machine, on both of its faces, and rule 1 makes that the guest's call
///   to have made. A host that served the measurement while withholding the
///   guest's own three names would be answering a narrower question than the
///   one asked and calling it the same capability.
///
/// ## PowerPC only, and typed
///
/// The 68K guest does not serve `catsearch` — it is absent from
/// `now-guest-68k/src/commands/commands68.c` — so against that guest this row
/// is `unavailable`, derived from the guest's own `help` table by the
/// capability ledger and never from which guest it is. **There is no reduced
/// form.** A "catalog search with the sweep skipped" would answer a volume
/// name and a file count, which is not this capability at less resolution —
/// it is a different answer wearing this one's name, and rule 4's "degrade the
/// answer, not the message" does not license inventing one.
///
/// ## Narrower, not shorter
///
/// `PBCatSearch` is not available on every volume, and the guest handles that
/// rather than failing into it: `GetVolParms` without `bHasCatSearch` makes it
/// return **three rows and no sweep at all**. That answer is narrower than a
/// complete one, not a shorter version of it, and the same is true of a sweep
/// that gave up at 20 s or restarted past its `catChangedErr` limit — the hit
/// count is then explicitly `(incomplete)`.
///
/// **Which path produced the answer is in the rows, in the guest's words, and
/// this row's job is to guarantee those rows are never the ones a bound drops.**
/// The `CatSearch` row says supported or not; an `Outcome` row appears only
/// when the sweep did not run to `eofErr`. The host does not restate either in
/// a typed field of its own: parsing the guest's wording into
/// `searchSupported: false` is how a projection starts answering questions
/// about the machine out of its own head, and it would go stale the first time
/// the guest reworded a row. So the ceiling is the guest's own buffer
/// (`AgentIntegrationCatalogSearchPolicy.maximumRows`), which cannot cut them.
public enum CatalogSearchProjection: HostProjection {
    public static let capability = HostCapabilityID("now_catalog_search")

    /* One command, and it is the whole derivation. No `familyPolicy` row is
       owed or wanted: this is not a message family, so the ledger resolves it
       against the command table `help` fills — which is also why the cost
       argument above holds. */
    public static let requires =
        [AgentIntegrationCapabilityNames.catsearchCommand]

    /* The rows the guest measured ARE the answer, so a caller reaches
       `catsearch` here. Nothing about it is consumed internally. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.catsearchCommand]

    /* The Software page's "Measure Sweep Cost" button, in the footer beside
       Refresh. It did NOT already exist — every other affordance on that page
       spends the inventory, and this one measures what producing it costs —
       so it landed with this row, which is what rule 3 asks for when a
       capability's user-facing home is real and merely unbuilt.

       **Why Software and not Files, since the sweep is volume-wide.** The
       page a capability belongs on is the page whose question it answers, not
       the one whose nouns it touches. This answers "why is the Applications
       list slow" — the Applications domain's own first page IS a whole-volume
       catalog sweep (`AgentIntegrationLocalClient`, the softwareInventory
       window), and `catsearch` exists because that sweep's cost is what the
       Software module's design rests on (`catsearch.h`). On the Files page it
       would sit beside a browser that pages one directory at a time and
       answers a question that page never asks. The precedent is already
       there: `reveal` reaches the Finder from this same page, because what it
       serves is "act on the application I selected".

       Noted for whoever lands the software-inventory capability: it will want
       this pane too, and the two belong together — the listing and what
       producing it costs. The footer is where both go; nothing here needs
       moving when it arrives. */
    /* Takes no arguments at all, so the strict answer is the empty set
       rather than an absence of one. */
    public static let acceptedArguments: Set<String> = []

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "SoftwareModuleView.swift",
                         symbol: "model.measureCatalogSearch()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the catsearch command."

    public static var operationDescriptor: NOWOperationDescriptor {
        let policy = AgentIntegrationCatalogSearchPolicy.self
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength": policy.maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength": policy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Measure a New Old World Guest Catalog Search",
            "description":
                "Measures what finding every application on the connected Mac's startup volume costs, by running the guest's own catsearch probe: PBCatSearch for file type APPL in short time slices, cold and then warm to expose caching. EXPENSIVE — seconds normally, and the guest gives up after 20 s per pass, so a slow disk can spend most of a minute answering. Takes no arguments: the volume is the guest's startup volume, which the guest chooses, and there is no query, filter or cursor. Answers rows in the guest's own words, not a file listing — the volume and its file and folder counts, whether the volume supports CatSearch at all, sweep timings, the longest slice against its budget, the APPL hit count, and up to three of the names found. A volume without CatSearch answers three rows and no sweep, and a sweep that gave up marks its hit count incomplete: those rows say which path produced the answer, so read them rather than assuming a complete sweep.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", report),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                /* NOT idempotent, and this is the row where that word earns
                   its keep. Nothing changes on the machine — the sweep reads
                   the catalog and never opens a file — but a second call is
                   a second forty seconds and answers different numbers,
                   because the warm pass rides a cache the cold one filled.
                   A caller told this is idempotent would retry it for free. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.catalogSearch()))
    }

    /// The row-report shape, rendered for this row.
    ///
    /// **Deliberately private, and deliberately not in `HostProjectionSchema`
    /// yet.** Four more capabilities answer `x-rowArray` — `tail`, `gestalt`,
    /// `reveal` and the diagnostics trio — and when the second of them lands
    /// this fragment should be hoisted, exactly as the guest-Files family's
    /// was. Hoisting it from one row would be a shared-file edit made on
    /// behalf of rows that do not exist, which is how a fragment ends up
    /// shaped for the only caller it ever had.
    private static var report: [String: Any] {
        let policy = AgentIntegrationCatalogSearchPolicy.self
        let row: [String: Any] = [
            "type": "object",
            "properties": [
                "label": [
                    "type": "string",
                    "maxLength": policy.maximumLabelScalars,
                ],
                "value": [
                    "type": "string",
                    "maxLength": policy.maximumValueScalars,
                ],
            ],
            "required": ["label", "value"],
            "additionalProperties": false,
        ]
        let group: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["const": policy.verb],
                "rows": [
                    "type": "array",
                    "maxItems": policy.maximumRows,
                    "items": row,
                    "description":
                        "The guest's own rows, in its own order and wording. Ten at most today, against a bound of \(policy.maximumRows) — the guest's own row buffer — so a complete answer is never truncated; `note` says so if one ever is.",
                ],
            ],
            "required": ["name", "rows"],
            "additionalProperties": false,
        ]
        return [
            "type": "object",
            "properties": [
                "verb": ["const": policy.verb],
                "groups": [
                    "type": "array",
                    "maxItems": 1,
                    "items": group,
                ],
                "note": [
                    "type": ["string", "null"],
                    "maxLength": 200,
                    "description":
                        "Present only when a bound was reached. The guest offers none for this verb, so the only sentence that appears here is the host saying it had to shorten the answer.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["verb", "groups", "observedAt"],
            "additionalProperties": false,
        ]
    }
}
