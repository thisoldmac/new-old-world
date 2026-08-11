import Foundation

/// Read the text of **one named text element** in a guest application.
///
/// The read half of the act plane, and the only row of the three that changes
/// nothing — which is why it is worth having as its own row rather than as a
/// mode of the write. Its `readOnlyHint` puts it in the `readOnly` consent
/// tier, so a machine whose owner consented to being READ and not driven can
/// serve it while `now_text_set` and `now_window_act` are refused above it.
/// One row per side of that line is what makes the line expressible at all.
///
/// **It is still an act-plane row, not an observation.** A scene walk
/// describes the interface; this reaches into one element and asks the
/// application what it holds, through the same identity-addressed path the
/// writes use. It is grouped, required and made available with them.
///
/// **No mouse, no QMP.** Nothing is clicked or selected to read a field.
///
/// The reply is a READING and says so: `observedAt` dates it, and
/// `truncated` says whether the element held more than the guest was allowed
/// to send. A caller that gets a short string back can tell a short field
/// from a clipped one, which is the whole reason that flag is required
/// rather than optional.
public enum TextGetProjection: HostProjection {
    public static let capability = HostCapabilityID("now_text_get")

    /* A command, resolved against the connected guest's own `help` table —
       the same derivation that makes `reveal` and `gestalt` PowerPC-only
       without anything here naming a guest. */
    public static let requires = [
        AgentIntegrationCapabilityNames.textGetCommand,
    ]

    /* The caller names the element and receives that element's own answer,
       which is what exposure means. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.textGetCommand,
    ]

    public static let acceptedArguments: Set<String> = ["element"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane addresses a text element inside a guest "
                + "application yet: the host has no element observation to "
                + "select one from, so there is nothing for a person to "
                + "click. The pane lands with the scene view that mints the "
                + "references this row takes."),
        /* Registered 2026-07-31, with the contract's x-commands entry and
           the folded requirement name in the one edit. The row is published
           and reads `unavailable` on every machine — because no guest's
           `help` table has the command, which is a derived fact rather than
           an unresolvable requirement. */
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the textget command."

    public static var mcpDescriptor: [String: Any] {
        let reading: [String: Any] = [
            "type": "object",
            "properties": [
                "element": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.elementReferencePattern,
                ],
                "text": [
                    "type": "string",
                    "maxLength": AgentIntegrationActPolicy
                        .maximumTextScalars,
                ],
                "truncated": [
                    "type": "boolean",
                    "description":
                        "The element held more text than this reading could carry. False means the whole contents are here; there is no way to tell those apart without it.",
                ],
                "observedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": ["element", "text", "truncated", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read One New Old World Guest Text Element",
            "description":
                "Reads the text of ONE named element in a guest application, addressed by an opaque reference from a current observation. Nothing is clicked, selected or simulated. The answer is a dated reading and says whether it was truncated; it is not a claim about what the element holds now.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "element": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationActPolicy
                                .elementReferencePattern,
                        "description":
                            "Opaque reference to one observed text element. Short-lived, and revalidated by the guest against a live element before it is read.",
                    ],
                ],
                "required": ["element"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", reading),
                    variant("refused", "refused",
                            HostProjectionSchema.unavailableFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            /* The shared read-only fragment, which is also what puts this
               row in the readOnly consent tier. Stated through the fragment
               rather than as a literal so that a change to what "read only"
               annotates reaches this row too. */
            "annotations": HostProjectionSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        guard let object = arguments.object,
              let element = object["element"] as? String,
              AgentIntegrationActPolicy.isValidElementReference(element)
        else {
            return .invalidArguments(
                "\(capability.rawValue) requires element: one opaque "
                    + "\(AgentIntegrationActPolicy.elementReferencePrefix)… "
                    + "reference from a current observation. This surface "
                    + "cannot address an element any other way, and "
                    + "deliberately has no \"focused field\" form.")
        }
        return .value(.init(
            await client.getElementText(element: element)))
    }
}
