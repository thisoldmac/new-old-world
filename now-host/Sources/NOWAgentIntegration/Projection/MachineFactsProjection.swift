import Foundation

/// The bounds and the one ordering this capability renders under, stated
/// where the schema, the host-side owner and its tests read one copy.
///
/// They live beside the row rather than in the shared model files for the
/// reason `AgentIntegrationCensusBounds` and `AgentIntegrationRevealPolicy`
/// give: sibling capabilities are being wired against those files in the same
/// wave, and a tail nobody has to touch is a merge nobody has to resolve.
///
/// **Every bound is read off a buffer in the guest's own source, and every
/// one is a backstop rather than a trim.** `now-guest-ppc/src/commands/
/// commands.h` declares `GestaltRow` and `kGestaltMaxRows`; the guest cannot
/// answer past them, so in normal operation none of these can bite. They
/// exist so a guest that grew a group or a longer value is rendered short and
/// says so, rather than rendered unboundedly.
public enum AgentIntegrationMachineFactsPolicy {
    /// The verb, as `help` names it and as the report labels itself.
    public static let verb = "gestalt"

    /// The group order the answer is rendered in, and the reason this type
    /// exists at all.
    ///
    /// **The wire's order is already gone by the time the host sees it.**
    /// `CommandResult.output` is a dictionary (`[String: [[String]]]`), so
    /// the guest's declared order survives only if this side restores it.
    /// `tail` solved the same problem by sorting names alphabetically, which
    /// is fine for two groups whose order carries nothing; here it would put
    /// `cpu, hw, memory, network, os, snapshot` and bury the summary the
    /// guest writes FIRST and a reader wants first.
    ///
    /// So the order is the **contract's** — `x-commands.gestalt.output`
    /// lists snapshot, cpu, memory, os, network, hw — which makes this
    /// rendering rather than deciding: the sequence is the guest's own,
    /// carried, not a judgement made here about which facts matter.
    ///
    /// A group the guest sends that is not on this list is **kept**, ordered
    /// after these and sorted among themselves. A newer guest's group must
    /// not be silently dropped by a host holding a stale copy of a list — the
    /// same reason `HardwareCensusProjection` refuses to enumerate probe
    /// names.
    public static let declaredGroupOrder = [
        "snapshot", "cpu", "memory", "os", "network", "hw",
    ]

    /// Groups rendered, at most. Six declared plus room for a group a newer
    /// guest grows, so the answer is rendered rather than trimmed to what
    /// this side expected.
    public static let maximumGroups = 8

    /// `kGestaltMaxRows` — the guest's whole row buffer for this verb, which
    /// it fills across all groups. Used per group so that a guest which puts
    /// every row in one group is still rendered whole.
    public static let maximumRowsPerGroup = 48

    /// `GestaltRow.label`, which is a 28-BYTE cap on the machine, so a scalar
    /// count can only come in under it.
    public static let maximumLabelScalars = 28
    /// `GestaltRow.value`, likewise 56 bytes on the machine.
    public static let maximumValueScalars = 56
    /// `GestaltRow.group`, 12 bytes. A group name a newer guest sends is
    /// bounded by the same number the guest's own struct is.
    public static let maximumGroupNameScalars = 12

    /// A refusal sentence. `gestalt`'s own is `unknown-group`, which can
    /// quote a word back — but only from a `line`, which this side never
    /// sends, so in practice the sentence is the guest's `unknown-command` or
    /// this host's own.
    public static let maximumFailureCodeScalars = 64
    public static let maximumMessageScalars = 200

    /// What `note` says when the host had to bound the answer.
    ///
    /// Sitting in `AgentIntegrationGuestRowReport.note`, documented as the
    /// GUEST's sentence about the edges of its answer. This is the one host
    /// sentence that field carries for this verb, and it is attributed in the
    /// text for that reason: `gestalt` offers no note of its own, and the
    /// alternative — dropping groups and saying nothing — is the silent
    /// truncation that field exists to refuse.
    public static func truncationNote(answered: Int) -> String {
        "The host bounded this answer to \(maximumGroups) groups; the guest "
            + "answered \(answered). The groups beyond the bound are not here."
    }
}

/// **What the connected Macintosh says it is** — the `gestalt` verb,
/// projected.
///
/// One call, one answer: the machine's model, System, CPU, memory, ROM,
/// CarbonLib and networking, in the guest's own words, grouped as it groups
/// them. This is the largest single capability that no host face could reach
/// — `docs/mcp-coverage.md` records it as such — and nothing decided that; it
/// never came up.
///
/// ## Why there is no group argument, which is the design question here
///
/// The guest answers `gestalt` in five domain groups plus a `snapshot`
/// summary, and a host that asked five times and merged the answers would be
/// **composing** one — which rule 2 of the parity slice forbids, and which is
/// exactly why `now_hardware_census` requires a probe and the software
/// inventory requires a domain. That is not the shape here, and the contract
/// settles it in one sentence: *"A typed call (no `line`) always returns every
/// group"* (`x-commands.gestalt`), with `args: {}`. The guest's own wire path
/// says the same thing from the other side — `run_gestalt` walks every group
/// when no `line` is present, and reads a slice only when one is
/// (`now-guest-ppc/src/commands/commands.c`). **So this row carries one
/// answer that arrived in one call, and takes nothing.**
///
/// A group selector was available and is deliberately not taken. Narrowing is
/// a legitimate host bound, but there is nothing here to bound: the whole
/// answer is roughly two dozen rows inside one 3 KB reply, so a selector
/// would save a caller nothing while costing three real things — the group
/// grammar is the CONSOLE's (`--cpu`, `--full`, the `line` field whose very
/// presence is how the guest knows a human is typing), a host holding a copy
/// of that grammar goes stale the day the guest grows a group, and
/// `unknown-group` becomes a refusal this surface can produce for a question
/// the caller had no way to get right. The one ordering this row does impose
/// is the contract's own, and `AgentIntegrationMachineFactsPolicy
/// .declaredGroupOrder` says why it has to.
///
/// ## PowerPC only — and the 68K machine is not mute about itself
///
/// The requirement is the COMMAND `gestalt`, and the capability ledger
/// resolves a command against the connected guest's own `help` table. The 68K
/// guest's table has no `gestalt` row, so this row reports `unavailable`
/// against it in typed form, by derivation, without one line here asking
/// which guest is on the wire.
///
/// **What that unavailability must not be read as saying is that the machine
/// cannot answer these questions.** It largely can, by another route:
/// `now-guest-68k/src/ui/health.c` samples machine identity, CPU, System
/// version, Virtual Memory, MacTCP, screen geometry and physical RAM at
/// startup and caches them for its own panel, and the hardware census now
/// reports most of the same facts under its `identity` and `overview` probes
/// on BOTH guests. What is absent on the 68K side is this VERB — the one-call
/// grouped rendering — and `contract-coverage.md` calls a `gestalt` there
/// "closer to a rendering job than a measurement one" and "the cheapest large
/// gap left". So the honest sentence, and the one this row's availability
/// note and description say, is that the guest's command table does not name
/// `gestalt` and that `now_hardware_census` answers the overlapping facts on
/// every guest. Building it is deferred, not refused.
///
/// ## The overlap with the census, named rather than merged
///
/// `HardwareCensusProjection` answers adjacent hardware questions by a
/// different route, and its author's read — adjacent, not composable — is
/// endorsed here rather than re-litigated. Three differences an integrator
/// should see:
///
/// | | the census | this row |
/// |---|---|---|
/// | plane | `census.request`, a message family, both guests | the `gestalt` command, PowerPC only |
/// | shape | paged, one probe per call, a per-probe outcome, raw beside decoded | one command result, every group |
/// | what absence means | a typed probe outcome the caller reads (`absent` is a finding, `refused` is "I did not look") | the verb's own refusal, or this row unavailable |
///
/// **Nothing here reads `census`, and nothing here should be rewritten in
/// terms of it.** The census's `selectors` probe IS the documented Gestalt
/// walk where a machine can afford it, so a host that answered `gestalt` out
/// of a census page — or the reverse — would be composing a fact rather than
/// carrying one, and would go wrong the first time either side reworded a
/// row. Two capabilities answering adjacent questions is fine; two composing
/// each other is not.
public enum MachineFactsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_machine_facts")

    /* One command, and it is the whole derivation. It reads nothing through
       a message family, drives nothing, and needs no second requirement to
       compose from — so there is no `familyPolicy` row owed or wanted, which
       was checked against `AgentIntegrationCapabilityLedger.familyPolicy`
       rather than assumed: that list holds message families, a command
       resolves against the guest's `help` table, and
       `MCPCoverageTests.testEveryFamilyRequirementHasALedgerRow` classifies
       this requirement against the contract to make sure it is one of the
       two. */
    public static let requires = [
        AgentIntegrationCapabilityNames.gestaltCommand,
    ]

    /* The rows the guest gathered ARE the answer, so a caller reaches
       `gestalt` here. Nothing about it is consumed internally. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.gestaltCommand,
    ]

    /* The host's own Console module: a person types `gestalt` and reads the
       snapshot, or `gestalt --full` and reads every group. It predates this
       row by the whole project — `send(command)` in `submit()` is the call
       site the Return key reaches — so rule 3's user-initiable half costs
       this capability nothing.

       The same precision `GuestLogTailProjection` insists on applies, because
       the two paths are not the same wire message. The console is a dumb
       shell: it forwards the typed line whole down the EXEC plane, and this
       row sends `command.request` with no line at all. They meet inside the
       guest, in the one command table both of its faces dispatch through
       (`commands.c`, and `console_model.c` for the machine's own console) —
       the guest-side parity rule working as intended rather than a
       coincidence to lean on. The DIFFERENCE is the answer's breadth, and it
       is the contract's: a line means a human asked for a slice, no line
       means every group. A person at the host who wants what this row
       returns types `gestalt --full`.

       Noted for whoever builds the Machine pane the plan names as this
       capability's eventual home: these are the standing facts that belong
       beside the Census page's probe rail, and the two want to be read
       together. Nothing here needs moving when it arrives. */
    /* Takes no arguments at all, so the strict answer is the empty set
       rather than an absence of one. */
    public static let acceptedArguments: Set<String> = []

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ConsoleModel.swift",
                         symbol: "send(command)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest's command table names gestalt."

    public static var mcpDescriptor: [String: Any] {
        let policy = AgentIntegrationMachineFactsPolicy.self
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
                    "description":
                        "The guest's own refusal sentence when it refused, bounded; otherwise the host's.",
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
                    "maxLength": policy.maximumLabelScalars,
                    "description":
                        "The name of the fact, as the guest wrote it: Model, System, CPU, Memory, CarbonLib, Networking, FPU, Addressing, ROM size, ROM version, and so on.",
                ],
                "value": [
                    "type": "string",
                    "maxLength": policy.maximumValueScalars,
                    "description":
                        "The value, as the guest rendered it for a person to read — \"96 MB\", \"Mac OS 9.1\", \"$077D\", \"Open Transport\". Text, not fields: read it, do not parse it. A fact the machine could not answer is an ABSENT ROW rather than an empty value, so nothing here is a placeholder.",
                ],
            ],
            "required": ["label", "value"],
            "additionalProperties": false,
        ]
        let group: [String: Any] = [
            "type": "object",
            "properties": [
                "name": [
                    "type": "string",
                    "maxLength": policy.maximumGroupNameScalars,
                ],
                "rows": [
                    "type": "array",
                    "maxItems": policy.maximumRowsPerGroup,
                    "items": row,
                ],
            ],
            "required": ["name", "rows"],
            "additionalProperties": false,
        ]
        let report: [String: Any] = [
            "type": "object",
            "properties": [
                "verb": ["const": policy.verb],
                "groups": [
                    "type": "array",
                    "maxItems": policy.maximumGroups,
                    "items": group,
                    "description":
                        "Every group the machine answered, in the contract's own order: \"\(policy.declaredGroupOrder.joined(separator: "\", \""))\". `snapshot` is the guest's curated summary and repeats facts the domain groups state at more length — it is a rendering of them, not a seventh set of facts. A group this host has no order for (a newer guest's) is kept and follows these rather than being dropped. Row order inside a group is the guest's.",
                ],
                "note": [
                    "type": ["string", "null"],
                    "maxLength": 200,
                    "description":
                        "Present only when a bound was reached. The guest offers no note for this verb, so the only sentence that appears here is the host saying it had to shorten the answer.",
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["verb", "groups", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read What the New Old World Guest Machine Is",
            "description":
                "Asks the connected Macintosh, through the Gestalt Manager, what it is: model, System version, CPU and FPU, physical and logical RAM, virtual memory and page size, QuickDraw, AppleEvents, Thread Manager, CarbonLib, AppleTalk and Open Transport, keyboard, machine type, ROM size and ROM version. Cheap and passive — a handful of Gestalt selectors, no disk and no bus. Takes no arguments: one call returns EVERY group, which is what the contract declares for a typed call, so there is nothing to page and no slice to choose. The answer is the guest's own label/value rows in six groups — snapshot (its curated summary), cpu, memory, os, network, hw — read as prose rather than parsed as fields, and a fact the machine could not answer is an absent row rather than a blank one. PowerPC guests only: the 68K guest's command table has no gestalt, which is a missing RENDERING and not a mute machine — now_hardware_census answers the overlapping model, CPU, RAM, ROM and OS facts on every guest, by a different route.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", report),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* A read, without qualification: Gestalt selectors, nothing
                   on the machine moves, and the person sitting at it sees
                   nothing happen. */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* NOT idempotent, and the reason is narrow but real. Most of
                   what this returns changes on a timescale of screwdrivers —
                   but `Virtual memory` and the RAM figures follow the
                   machine's live state, and a caller told this call was
                   idempotent would be entitled to cache the whole answer
                   forever. Cheap to retry, which is a different claim. */
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
        return .value(.init(await client.machineFacts()))
    }
}
