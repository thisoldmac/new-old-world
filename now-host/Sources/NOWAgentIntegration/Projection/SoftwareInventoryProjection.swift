import Foundation

/// The bounds one software listing is rendered under, stated where the schema
/// and the host-side owner read one copy.
///
/// Every one of them is a **guest** buffer restated on this side, not a number
/// chosen here. That is the property that matters: a host bound that bites
/// before the guest's would silently shorten an answer the machine sent whole,
/// and this row's whole subject is answers that say where their own edges are.
///
/// They live beside the projection rather than beside the models for the reason
/// `AgentIntegrationCensusBounds` gives: sibling capabilities are being wired
/// against the shared model files in the same wave, and a tail nobody else has
/// to touch is a merge nobody has to resolve.
public enum AgentIntegrationSoftwareInventoryBounds {
    /// The contract's own page size (`SoftwareListing.entries`,
    /// `maxItems: 10`), which is also both guests' page buffer — PPC's
    /// `serve_software_list :: kPage` and the smaller guest's
    /// `NOW68K_SWLIST_MAX_ROWS`. A page over it is **refused rather than
    /// trimmed**: ten entries out of eleven under a `hasMore` that says the
    /// page was complete is the one failure a paginated answer must not be
    /// able to have.
    public static let maximumEntriesPerPage = 10

    /// The cursor's floor. 1-based over the responder's cached inventory by
    /// contract, and 1 (or absent) REBUILDS that cache — so unlike the
    /// census, absent and 0 are not the same request here and there is no
    /// page zero to ask for.
    public static let minimumCursor = 1

    /// The guest's own name buffer (PPC `SoftwareEntry.name[64]`). Larger
    /// than an HFS name needs to be, and restated at the guest's size rather
    /// than at HFS's 31 so that a name this side cannot explain still
    /// arrives whole.
    public static let maximumNameScalars = 63

    /// The LARGER of the two guests' path buffers (PPC
    /// `SoftwareEntry.path[224]`; the other's 80 is smaller, and a bound
    /// sized to the smaller one would clip the bigger guest's own answer).
    /// Deep paths are truncated to `""` ON THE
    /// GUEST rather than clipped, so a path that arrives is a path that
    /// works.
    public static let maximumPathScalars = 223

    /// The `vers` short version string (PPC `version[16]`).
    public static let maximumVersionScalars = 15

    /// A Finder type or creator code.
    public static let fourCCScalars = 4

    /// The listing's `note`. Sized over both guests' note vocabulary — the
    /// larger of the two declared ceilings is 64 (`NOW68K_SWLIST_NOTE_MAX`)
    /// and the longest literal either sends is shorter still — so this cannot
    /// be the thing that shortens the sentence in which a guest declares its
    /// own bound.
    public static let maximumNoteScalars = 128

    /// A refusal sentence, which may quote a domain a caller sent.
    public static let maximumRefusalScalars = 200
}

/// **What is installed on the connected Macintosh** — `software.list` /
/// `software.listing`, projected one page of one domain at a time.
///
/// This is the gap the `exposes` distinction found, and it is the sharpest one
/// in the inventory (`docs/plans/2026-07-30-005`, P1 #3). `now_launch_software`
/// **requires** `software.list` and sweeps the catalog to match one name, so a
/// `requires`-derived coverage check read the listing as covered while **an
/// agent could launch an application it could already name and could not ask
/// what was installed.** Nothing here changes that row; what changes is that
/// the catalog now has a caller of its own.
///
/// ## The domain is required, and there is no all-domains form
///
/// `software.list` has no such form — the contract's `domain` is required and
/// its enum has five members — and inventing one by asking five times and
/// concatenating the answers would be this host composing a fact rather than
/// carrying one (rule 2). The `sw` console verb DOES have a domainless
/// overview, and that is a different capability with a different shape: it
/// answers per-domain counts rather than items. Whether it belongs on this
/// surface is that verb's decision to have made, not this row's to pre-empt.
///
/// **The enum is enumerated here, and the census's probe registry deliberately
/// is not.** The difference is which side owns the list: a `software.list`
/// naming a sixth domain is a malformed request by the message schema, where a
/// census probe name is the GUEST's registry and a host holding a stale copy
/// would refuse a probe a newer guest serves.
///
/// ## Who pays the four seconds
///
/// The `apps` domain's first page is a whole-volume `PBCatSearch` sweep —
/// ~4 s on a PowerBook, and `now_catalog_search` exists to measure exactly
/// that. The capability ledger probes this family only when a caller passes
/// `probeCostly`, on the stated grounds that four seconds of somebody's
/// machine is spent on purpose. **An ordinary call to this tool needs no such
/// flag, and `CatalogSearchProjection`'s reason for reaching the same
/// conclusion is not available here.**
///
/// That row's argument turns on `catsearch` being a **command**: a command's
/// availability comes off `help`, free, so no report can ever spend the
/// machine's time incidentally and the only way to pay is to call the one tool
/// whose purpose is to measure it. **This is the family**, and it is precisely
/// the family whose cost `probeCostly` was invented to gate — so the
/// structural half of that argument inverts rather than transfers.
///
/// What survives is the half that was doing the work anyway, and it is enough:
/// `probeCostly` guards **incidental** spending. It exists because the
/// capability report faced a genuine choice between paying four seconds to
/// answer a question nobody asked and reporting `unproven`. A call to this
/// tool is not that: the sweep is not a side effect of the answer, it **is**
/// the answer, and a caller asking what is installed has asked for it on
/// purpose in the same sense as a caller asking what the sweep costs. A
/// required `acknowledgeCost` on top would guard a door with nothing behind
/// it while making the honest answer harder to get.
///
/// Two things the cost does earn, and one consequence worth knowing:
///
/// - **Disclosure, priced per domain and per page rather than per call**,
///   which is sharper than `catsearch` could be about itself. Only `apps` at
///   cursor 1 pays the sweep; later cursors page the same cached inventory,
///   and the four folder domains enumerate live and are dozens of catalog
///   reads. The description says so before a caller spends anything, and
///   `idempotentHint` is false because a second call is a second sweep.
/// - **The bound is the host's wait, not the guest's silence.** The listing
///   family has a 30 s watchdog on this side, which outlives the ~4 s sweep
///   with room for a slow disk, so a caller gets a typed answer rather than a
///   hung tool.
/// - **An ordinary call settles the family as a side effect.** The listener
///   records every `software.list` outcome (`GuestListener.listSoftware`,
///   wrapped in `observing`), so one real call moves this row in the
///   capability report from `unproven` to the guest's own answer — and makes
///   a later `probeCostly` report free. That is another reason the gate
///   belongs on the ledger and not here: the ledger's probe asks a question
///   nobody asked, and this tool's caller asked it.
///
/// ## Rule 4 lives in this row, concretely
///
/// `SoftwareEntry` has eight fields. **One guest fills all eight; the other
/// fills six**, omitting `version` and `running` deliberately
/// ([contract-coverage.md](../../../../docs/contract-coverage.md),
/// "`software.list` — one message, two amounts of answer"): a `vers` read is
/// one resource-fork open per served entry, and `running` is a Process
/// Manager walk per page, on a machine where `ps` is already the slowest
/// thing a person types.
///
/// So both are **nullable** in the schema and **absent** rather than defaulted
/// in the answer. `"version": ""` would claim the file has an empty version
/// string, and `"running": false` would claim the machine looked and found the
/// application idle — neither of which the smaller guest said, and the second
/// of which would be indistinguishable from the truth on a guest that does
/// look. The
/// schema states what absence means on each of them, because a caller that
/// cannot read absence as absence will read it as a claim.
///
/// **The message does not degrade; the answer does.** Nothing here forks on
/// which guest answered, and nothing here can even see which one did.
///
/// ## Two 68K bounds that must reach the caller
///
/// Both are the guest's, both arrive in the listing's `note`, and this row's
/// job is to carry that sentence **verbatim and unshortened** rather than to
/// restate it:
///
/// | Bound | The guest's own words |
/// |---|---|
/// | the `apps` inventory stops at 48 applications | `"the inventory stopped at this Mac's bound of 48 items"` (`n68_swlist_note_truncated`) |
/// | `PBCatSearch` unusable, so the fallback walked the volume ROOT only | `"PBCatSearch was unusable; only the volume root"` (`n68_swlist_note_root_only`) |
///
/// The second matters more than its length suggests: that answer is
/// **narrower, not merely shorter** — a root-only walk cannot find an
/// application in a folder, and an inventory that hides its own bound is worse
/// than a short one. The host does not parse either sentence into a typed
/// field of its own. Doing so would go stale the first time a guest reworded a
/// note, and deciding out of the guest's prose that a listing was "partial" is
/// how a projection starts answering questions about the machine out of its
/// own head. The bound this side does apply is the note's LENGTH, and it is
/// sized over both guests' note buffers so that it cannot bite first.
///
/// ## Paging is the caller's
///
/// One call is one page, `hasMore` and `nextCursor` are required fields, and
/// the row does not loop. `now_capture_screen` hides its paging because a
/// half-fetched PNG is nothing; a listing is not that — every page is a
/// complete, quotable answer about ten installed items, and looping would
/// hand a caller an unbounded call it had no way to stop over a machine whose
/// first page already cost four seconds. The cursor is the guest's own, echoed
/// as it was sent: a `hasMore` with no cursor is reported rather than repaired,
/// because inventing one would send the caller back to a page the guest never
/// offered.
///
/// The Software page makes the opposite choice — `SoftwareModel.refresh()`
/// chains every page in, because a person wants the inventory rather than a
/// scroll that fetches. That divergence is deliberate and is what rule 3's two
/// faces are for: the same guest capability, rendered for who is asking.
public enum SoftwareInventoryProjection: HostProjection {
    public static let capability = HostCapabilityID("now_software_inventory")

    /* The message FAMILY, and never a domain name. A domain is an ARGUMENT of
       this row: the ledger resolves a requirement against the family table and
       falls through to the guest's `help` COMMAND table, which can hold
       neither a family nor a domain — so requiring "apps" would switch this
       tool off against every guest for the life of every connection, in a
       sentence that reads as a fact about the Macintosh. Requiring the `sw`
       verb instead would be rule 4's mistake in the other direction: the verb
       is the console's spelling, and the message is what both guests
       dispatch. */
    public static let requires = [
        AgentIntegrationCapabilityNames.softwareList,
    ]

    /* The listing IS the answer, so the family is exposed rather than
       consumed — the distinction `LaunchSoftwareProjection` is on the other
       side of. This is the row that closes W1 #3. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.softwareList,
    ]

    /* The Software page's domain picker and Refresh, which page the same
       family in. It predates this row by the whole software arc — rule 3's
       user-initiable half costs this capability nothing, and the page needed
       no edit to carry it, which is the honest reading of "already reached"
       rather than an affordance added to satisfy a gate. The footer already
       shows the guest's `note` verbatim, so the 48-item and root-only bounds
       reach the person at the machine by the same route they reach an agent. */
    public static let acceptedArguments: Set<String> = ["domain", "cursor"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "SoftwareModuleView.swift",
                         symbol: "model.refresh()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves software.list."

    public static var mcpDescriptor: [String: Any] {
        let bounds = AgentIntegrationSoftwareInventoryBounds.self
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": [
                    "type": "string",
                    "maxLength": bounds.maximumRefusalScalars,
                    "description":
                        "The guest's own words when it refused the family, bounded and control-escaped; otherwise the host's. A domain the guest does not have is NOT here — that is a completed call whose note says so.",
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let entry: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "maxLength": bounds.maximumNameScalars,
                ],
                "path": [
                    "type": "string",
                    "maxLength": bounds.maximumPathScalars,
                    "description":
                        "Full HFS path, and the launch key — pass it to the launch surface rather than a name, so the guest's name-ambiguity refusal can never fire. EMPTY IS A REAL ANSWER: the guest could not name the parent chain honestly (too deep, or the walk failed), so the item is listed and is not launchable or revealable from here. Empty is never a missing field to fill in with a guess.",
                ],
                "fileType": [
                    "type": ["string", "null"],
                    "maxLength": bounds.fourCCScalars,
                    "description": "Finder type 4CC, when the guest sent one.",
                ],
                "creator": [
                    "type": ["string", "null"],
                    "maxLength": bounds.fourCCScalars,
                    "description":
                        "Finder creator 4CC, when the guest sent one.",
                ],
                "sizeK": [
                    "type": ["integer", "null"],
                    "description":
                        "Data plus resource forks, in KB. -1 IS CARRIED THROUGH rather than mapped to absent: \"we looked and could not read it\" is a different fact from \"we did not look\", and absence here is the second.",
                ],
                "disabled": [
                    "type": ["boolean", "null"],
                    "description":
                        "In an Extensions Manager disabled folder. The guest's field is called `off`; renamed here because a boolean named `off` reads backwards at every use site. Absent means the guest did not say.",
                ],
                "running": [
                    "type": ["boolean", "null"],
                    "description":
                        "Joined against the guest's own process list. ABSENT MEANS ABSENT — a guest omits this deliberately where the join is a Process Manager walk per page on a machine whose process listing is already its slowest read. Absent is never false: false would claim the machine looked and found it idle.",
                ],
                "version": [
                    "type": ["string", "null"],
                    "maxLength": bounds.maximumVersionScalars,
                    "description":
                        "The 'vers' short version string. ABSENT MEANS ABSENT — either the file has no readable 'vers', or this guest omits the field, which a guest does deliberately where reading it is one resource-fork open per served entry in a heap with no slack. Absent is never the empty string.",
                ],
            ],
            "required": ["name", "path"],
            "additionalProperties": false,
        ]
        let page: [String: Any] = [
            "type": "object",
            "properties": [
                "domain": [
                    "type": "string",
                    "enum": AgentIntegrationSoftwareDomain.allCases.map(
                        \.rawValue),
                    "description":
                        "The domain this page is of, echoed. Never a domain other than the one asked for.",
                ],
                "entries": [
                    "type": "array",
                    "maxItems": bounds.maximumEntriesPerPage,
                    "items": entry,
                    "description":
                        "One page, in the guest's own inventory order. Empty with hasMore false is a complete answer — a domain with nothing in it, or a bound already reached — so read `note` rather than inferring from the count.",
                ],
                "hasMore": [
                    "type": "boolean",
                    "description":
                        "True when this domain has further pages. One call is one page: every page is a complete answer about ten items, and looping here would make one call unbounded over a machine whose first page can cost four seconds.",
                ],
                "nextCursor": [
                    "type": ["integer", "null"],
                    "minimum": bounds.minimumCursor,
                    "description":
                        "Pass back as `cursor` to continue, WITHOUT re-paying the sweep. Meaningful only when hasMore; null when the guest sent none, which this host reports rather than invents.",
                ],
                "note": [
                    "type": ["string", "null"],
                    "maxLength": bounds.maximumNoteScalars,
                    "description":
                        "THE GUEST'S OWN SENTENCE about the edges of its answer, carried verbatim, and the field to read before trusting a listing as complete. A guest says here that an apps inventory stopped at its own bound of 48 items, or that PBCatSearch was unusable and only the volume root was walked — the second makes the answer NARROWER rather than shorter, because a root-only walk cannot see an application in a folder. A domain this guest does not have is also a completed call that says so here. Absent when the guest said nothing.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": [
                "domain", "entries", "hasMore", "observedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "List What Is Installed on the New Old World Guest",
            "description":
                "Asks the connected Macintosh what software is installed on it and returns one page of one domain. The domain is REQUIRED and there is no all-domains form: five calls summed by this host would be an answer this host composed rather than one the machine gave. The five are apps (the startup volume's catalog swept for applications) and the four System Folder domains — extensions, cdevs (control panels), startup (startup items) and apple (Apple Menu items) — which enumerate live, disabled siblings included. COST IS PER DOMAIN AND PER PAGE, not per call: apps at cursor 1 rebuilds the inventory with a whole-volume PBCatSearch sweep, about four seconds on a PowerBook doing nothing else, where a later cursor pages the same cached inventory and the four folder domains are dozens of catalog reads. now_catalog_search measures that sweep if what you want is its cost rather than its result. Each entry's path is the launch key. TWO FIELDS ARE OPTIONAL AND THEIR ABSENCE IS AN ANSWER: the smaller guest omits `version` (a resource-fork open per entry) and `running` (a Process Manager walk per page) deliberately, so absent means the machine did not look, never that the version is empty or the application is idle. Read `note` before treating a listing as complete: it is where a guest declares its own bound in its own words — an inventory stopped at 48 items, or a catalog search that was unusable so only the volume root was walked, which is narrower than a complete answer rather than merely shorter.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "domain": [
                        "type": "string",
                        "enum": AgentIntegrationSoftwareDomain.allCases.map(
                            \.rawValue),
                        "description":
                            "Which domain to list. Required — asking five times and adding up the answers would be composing an inventory rather than carrying one. Enumerated here because the contract's own enum is closed: a sixth name is a malformed request, not a domain a newer guest might grow.",
                    ],
                    "cursor": [
                        "type": "integer",
                        "minimum": AgentIntegrationSoftwareInventoryBounds
                            .minimumCursor,
                        "description":
                            "Continue from a previous page's nextCursor. 1-based over the guest's cached inventory, and 1 or absent REBUILDS that cache — which for apps is the whole sweep. There is no page zero: unlike the hardware census, absent and 0 are not the same request here, and 0 is refused rather than read as 1.",
                    ],
                ],
                "required": ["domain"],
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
                /* Reads the catalog and never opens a file — the guest's own
                   `vers` read is the one fork open in the family, and it
                   opens to read rather than to write. */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* NOT idempotent, on two counts that are worth keeping apart.
                   An inventory is a snapshot of a disk somebody uses, so the
                   answer changes; and a repeated cursor-1 apps call is a
                   second four-second sweep, so a caller told this was
                   idempotent would be entitled to retry it for free. */
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
              let raw = arguments["domain"] as? String,
              let domain = AgentIntegrationSoftwareDomain(rawValue: raw)
        else {
            return .invalidArguments(argumentRefusal)
        }
        /* The floor is 1 and not 0, by contract: the cursor indexes the
           guest's cached inventory 1-based, and 1 rebuilds it. A 0 is refused
           rather than read as 1 — a caller that sent 0 meant something this
           side cannot know, and answering the first page would silently pay
           for a sweep it may not have asked for. `is Bool` first: a JSON
           `true` bridges to `Int` on this platform, and a caller that sent
           one did not send a page. */
        var cursor: Int?
        if let value = arguments["cursor"] {
            guard !(value is Bool), let page = value as? Int,
                  page >= AgentIntegrationSoftwareInventoryBounds
                      .minimumCursor else {
                return .invalidArguments(argumentRefusal)
            }
            cursor = page
        }
        return .value(.init(
            await client.softwareInventory(domain: domain, cursor: cursor)))
    }

    /// The one wording for every way the arguments can be wrong. Public so a
    /// test asserts against the constant rather than a second copy of the
    /// sentence.
    public static let argumentRefusal =
        "now_software_inventory requires one of the domains "
            + AgentIntegrationSoftwareDomain.allCases
                .map(\.rawValue).joined(separator: ", ")
            + " and an optional cursor of "
            + "\(AgentIntegrationSoftwareInventoryBounds.minimumCursor) "
            + "or more"
}
