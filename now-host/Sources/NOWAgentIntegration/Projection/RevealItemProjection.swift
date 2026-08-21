import Foundation

/// Bounds this capability's one argument.
///
/// It lives here rather than in `AgentIntegrationRowReportModels.swift`
/// beside the other row-report policies for a scheduling reason, not a
/// design one: four sibling capabilities are being wired against that file
/// in the same wave, and a tail nobody has to touch is a merge nobody has to
/// resolve. Promote it there when the wave is done if a second row wants it.
public enum AgentIntegrationRevealPolicy {
    /// The verb's own bound, restated on this side so a target that could
    /// only be refused is refused HERE. The guest reads the target into a
    /// 256-byte buffer and rejects anything over 255 with "that is longer
    /// than any HFS path"; `maximumSelectorScalars` is the same number, and
    /// the local codec already enforces it on the wire.
    public static var maximumTargetScalars: Int {
        AgentIntegrationProjectionPolicy.maximumSelectorScalars
    }

    /// The `#n` form, which this projection refuses. See the type comment on
    /// `RevealItemProjection` for why a positional pick is not a reference.
    public static func isPositionalPick(_ target: String) -> Bool {
        target.first == "#"
    }

    public static func isValidTarget(_ target: String) -> Bool {
        AgentIntegrationProjectionPolicy.isBoundedSelector(target)
            && !isPositionalPick(target)
    }
}

/// Show one item in the guest's own Finder — the `reveal` verb, projected.
///
/// **What `ok` means here is "the Macintosh was asked", and the row that
/// comes back must not be read as more than that.** The guest's
/// implementation (`now-guest-ppc/src/software/software.c ::
/// now_software_reveal`) finds the Finder by its `'MACS'` signature, sends it
/// one `kAEMakeObjectsVisible` Apple Event **with `kAENoReply`**, and then
/// calls `SetFrontProcess` on it. Every step of that is an ask:
///
/// - `kAENoReply` means the Finder never answers, so nothing on this wire can
///   say whether it made the object visible, or selected the right one.
/// - `kAENeverInteract` means a Finder that would need to ask the person
///   something fails silently instead.
/// - the front switch is cooperative on this platform and lands when the
///   Finder next yields — the same fact `BringToFrontProjection` exists to
///   keep honest.
///
/// So `ok:true` is the Apple Event queued and the front switch accepted. The
/// guest's own row says "revealed X in the Finder", which is its wording and
/// is carried through unchanged because the rows are the guest's words (rule
/// 2, and `AgentIntegrationGuestRowReport`); what this row adds is the
/// sentence in `outputSchema` saying what that word can and cannot mean.
///
/// **Nothing here confirms it, and that is a bounded rather than an open
/// question.** The sibling row earns `fronted` from a second `process.list`,
/// and the equivalent here would be a fresh listing showing the entry the
/// guest classifies `kind: "finder"` with `front: true` — a real fact, from a
/// different subsystem, cheap to get. It is deliberately **not** asked for,
/// because the answer has nowhere to go: this capability's wire result is
/// `AgentIntegrationGuestRowReport`, shared with four sibling verbs, and the
/// only places a host-derived outcome could ride are a new field on that
/// shared type or its `note` — which the type reserves for the guest's own
/// sentence. Spending a round trip on a fact that cannot be reported would
/// be worse than not asking. The follow-up is named in the handoff rather
/// than half-built here.
///
/// **It changes what the person at the machine is looking at**, which is the
/// whole of rule 3 for this row. Two things carry that: the dispatch's audit
/// event (face, capability, machine, outcome), and the host-side line
/// `AgentIntegrationRevealItem` writes under `sw` naming the target — because
/// for this capability the target *is* the event, the same reason the
/// guest-Files family logs its paths.
public enum RevealItemProjection: HostProjection {
    public static let capability = HostCapabilityID("now_reveal_item")

    /* One command, and deliberately nothing else. The Finder-not-running
       case is the obvious candidate for a host precondition — a fresh
       `process.list` can see whether anything is the Finder — and it is
       refused on rule 2: the guest decides that by signature at the moment
       it acts, and a host that refused from a listing taken a moment earlier
       would be answering a question about the machine out of stale state.
       The guest's own refusal is both later and better. */
    public static let requires = [
        AgentIntegrationCapabilityNames.revealCommand,
    ]

    /* The caller chooses what is revealed, so the command is exposed. The
       row consumes nothing internally, which is why it has no
       required-and-not-exposed entry in docs/mcp-coverage.md. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.revealCommand,
    ]

    /* The Software page's "Show in Finder" button, on the selected row. It
       predates this row entirely — the same guest verb, the same `target`
       argument, one click away for the person at the machine — so rule 3's
       user-initiable half costs this capability nothing. Note the app UI
       sends the entry's full PATH and never a bare name, which is also the
       form this row recommends. */
    public static let acceptedArguments: Set<String> = ["target"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "SoftwareModuleView.swift",
                         symbol: "model.reveal(entry)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest's command table names reveal."

    public static var operationDescriptor: NOWOperationDescriptor {
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength": 64],
                "message": [
                    "type": "string",
                    "maxLength": AgentIntegrationRevealItemBounds
                        .maximumRefusalScalars,
                    "description":
                        "The guest's own refusal sentence when it refused, bounded and control-escaped; otherwise the host's. \"the Finder is not running\" arrives here verbatim — the guest answers every reveal refusal with one code, so the distinction is in the words and this side does not invent a typed one by reading them.",
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
                    "maxLength": AgentIntegrationRevealItemBounds
                        .maximumLabelScalars,
                ],
                "value": [
                    "type": "string",
                    "maxLength": AgentIntegrationRevealItemBounds
                        .maximumValueScalars,
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
                    "maxItems": AgentIntegrationRevealItemBounds
                        .maximumRowsPerGroup,
                    "items": row,
                ],
            ],
            "required": ["name", "rows"],
            "additionalProperties": false,
        ]
        let report: [String: Any] = [
            "type": "object",
            "properties": [
                "verb": ["const": "reveal"],
                "groups": [
                    "type": "array",
                    "maxItems": AgentIntegrationRevealItemBounds
                        .maximumGroups,
                    "items": group,
                    "description":
                        "The guest's own rows, in its own words and order. Its sentence reads \"revealed <item> in the Finder\"; that means the Apple Event was sent with no reply requested and the Finder was asked forward. It does NOT mean the Finder complied, that the item is selected, or that the Finder is frontmost yet — the switch is cooperative and lands when the Finder next yields.",
                ],
                "note": ["type": ["string", "null"], "maxLength": 256],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["verb", "groups", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Show an Item in the New Old World Guest's Finder",
            "description":
                "Asks the connected Macintosh to show one installed item in its OWN Finder, selected in its enclosing window. It opens nothing and runs nothing: the guest sends its Finder a single make-objects-visible Apple Event and brings the Finder forward. A completed answer means the machine was ASKED — the Apple Event requests no reply, so nothing can confirm the Finder obeyed or that the item is selected. This CHANGES WHAT THE PERSON AT THE MACHINE IS LOOKING AT, and every call is written to that machine's log where they can read it. Target: a full HFS path (a software listing's path is the reveal key) or a bare item name, which the guest resolves by exact-name catalog search and reveals the first copy it finds. Any item reveals, not only applications. The \"#n\" pick form the console accepts is refused here.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "target": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": AgentIntegrationRevealPolicy
                            .maximumTargetScalars,
                        "description":
                            "A full HFS path (\"Macintosh HD:Apps:SimpleText\") or a bare item name. Not \"#n\": that indexes a match list shared with whoever last searched from the machine's own console, so the same string means different items at different moments.",
                    ],
                ],
                "required": ["target"],
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
                /* Read-only in the filesystem and not in the room. It reads
                   no bytes and returns no content — and it puts a Finder
                   window in front of whoever is sitting there, which is a
                   change to their environment and the reason rule 3 wants
                   this call visible. */
                "readOnlyHint": false,
                /* Nothing is opened, moved or lost; the person undoes it by
                   clicking a window. */
                "destructiveHint": false,
                /* The end state a second identical call asks for is the same
                   one, but the second call still takes over somebody's
                   screen again — so retrying is not free, and an agent must
                   not be told it is. */
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
              Set(arguments.keys) == acceptedArguments,
              let target = arguments["target"] as? String,
              AgentIntegrationRevealPolicy.isValidTarget(target)
        else {
            return .invalidArguments(
                "now_reveal_item requires one bounded target: a full HFS "
                    + "path or an item name, never a #n pick")
        }
        return .value(.init(await client.revealItem(target: target)))
    }
}

/// The bounds this row renders a guest row report under, stated where both
/// the schema above and the host-side owner can read one copy.
public enum AgentIntegrationRevealItemBounds {
    /// `reveal` answers one group (`reveal`) by contract. The allowance is
    /// larger than one so a guest that grows a second group is rendered
    /// rather than silently trimmed to what this side expected.
    public static let maximumGroups = 4
    public static let maximumRowsPerGroup = 16
    public static let maximumLabelScalars = 64
    public static let maximumValueScalars = 256
    /// The guest composes its refusal into a 240-byte buffer; this is that
    /// plus room for the target it may quote back.
    public static let maximumRefusalScalars = 320
}
