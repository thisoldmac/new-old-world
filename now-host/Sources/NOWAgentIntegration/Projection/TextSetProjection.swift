import Foundation

/// Replace the contents of **one named text element** in a guest
/// application.
///
/// The write half of the pair, and separate from `now_text_get` for a reason
/// the consent tiers make concrete rather than tidy: the read sits in the
/// `readOnly` tier and this sits in `fullAccess`, so a machine whose owner
/// consented to being read and not driven serves one and refuses the other.
/// One row that both read and wrote could sit on only one side of that line.
///
/// **No keystrokes are synthesised and no QMP is involved.** The application
/// is asked to set the element's text through its own path; nothing types.
/// So this row inherits no emulator dependency — worth stating because a
/// "set the text" verb elsewhere usually means a stream of key events, and a
/// reader who assumes that here will gate this on the wrong thing.
///
/// **A replacement, never an append or an edit.** The whole contents are
/// stated by the caller. There is no offset, no insertion point and no
/// selection: an edit expressed as a position into text this side does not
/// hold would be a write against a remembered reading, and the reading is
/// exactly what may have gone stale.
///
/// **Success is `dispatched`.** The event went to the application. Whether
/// the element now holds that text is a question for `now_text_get`, and
/// this row will not answer it out of the argument it was just handed —
/// upstream measured what trusting a service's own `performed: true` is
/// worth, and answered it against the filesystem instead.
public enum TextSetProjection: HostProjection {
    public static let capability = HostCapabilityID("now_text_set")

    /* One command, resolved off the connected guest's `help` table. The read
       command is NOT required: this row never reads, and requiring `textget`
       would switch the write off against a guest that could serve it — the
       same silent-conjunction wall the three diagnostics were split to
       avoid. */
    public static let requires = [
        AgentIntegrationCapabilityNames.textSetCommand,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.textSetCommand,
    ]

    public static let acceptedArguments: Set<String> = ["element", "text"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane addresses a text element inside a guest "
                + "application yet: the host has no element observation to "
                + "select one from, so there is nothing for a person to "
                + "click. Rule 3 is owed here and is not waived — the pane "
                + "lands with the scene view that mints the references this "
                + "row takes."),
        /* Registered 2026-07-31, with the contract's x-commands entry and
           the folded requirement name in the one edit. The row is published
           and reads `unavailable` on every machine — because no guest's
           `help` table has the command, which is a derived fact rather than
           an unresolvable requirement. */
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the textset command."

    public static var operationDescriptor: NOWOperationDescriptor {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "element": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.elementReferencePattern,
                ],
                "requestedScalars": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": AgentIntegrationActPolicy
                        .maximumTextScalars,
                    "description":
                        "How much text this host SENT. Not what the element holds — read it back for that.",
                ],
                "dispatch": [
                    "type": "string",
                    "enum": AgentIntegrationActDispatch.allCases
                        .map(\.rawValue),
                    "description":
                        "dispatched means the event was handed to the element's own application. It is NOT a claim that the text changed.",
                ],
                "dispatchedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": [
                "element", "requestedScalars", "dispatch", "dispatchedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Replace One New Old World Guest Text Element",
            "description":
                "Replaces the whole contents of ONE named element in a guest application, addressed by an opaque reference from a current observation. No keystrokes are synthesised and no emulator is involved. There is no append, offset or selection form, and deliberately no way to say \"the focused field\". A completed call means the event was dispatched, never that the text changed — read the element back to learn that.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "element": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationActPolicy
                                .elementReferencePattern,
                        "description":
                            "Opaque reference to one observed text element. Short-lived, and revalidated by the guest against a live element before anything is dispatched.",
                    ],
                    "text": [
                        "type": "string",
                        "maxLength": AgentIntegrationActPolicy
                            .maximumTextScalars,
                        "description":
                            "The element's whole new contents. Empty is a legal request and clears it.",
                    ],
                ],
                "required": ["element", "text"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", receipt),
                    variant("refused", "refused",
                            HostProjectionSchema.unavailableFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                /* True: the previous contents are gone and nothing here can
                   put them back. The Files family earns a `false` by having
                   a Trash behind it; a text field has no undo this surface
                   can reach. */
                "destructiveHint": true,
                /* A second identical set is not free: the first may not have
                   landed, the application may have moved the insertion
                   point, and a dispatched event is not a state we can
                   compare against. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
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
        /* The target first, and the text second. An act with no valid target
           is the failure this design is shaped against, so a caller that
           sent neither is told about the target. */
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
        guard let text = object["text"] as? String,
              AgentIntegrationActPolicy.isBoundedText(text) else {
            return .invalidArguments(
                "\(capability.rawValue) requires text: the element's whole "
                    + "new contents, at most "
                    + "\(AgentIntegrationActPolicy.maximumTextScalars) "
                    + "characters. It is a replacement, so there is no "
                    + "offset or append form.")
        }
        return .value(.init(
            await client.setElementText(element: element, text: text)))
    }
}
