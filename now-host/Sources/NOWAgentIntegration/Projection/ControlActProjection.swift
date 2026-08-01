import Foundation

/// Act on **one named control** in a guest application, by answering that
/// application's own `TrackControl` with the part code the caller named.
///
/// The sibling of `WindowActProjection` one reach further in: that row
/// addresses a window a person would have dragged, this one addresses a
/// button they would have clicked. **The application then runs its real
/// mouse-down handler**, so a control that policed its own behaviour — a
/// disabled item, a dialog that validates before it dismisses — goes on
/// policing it. That is the property that makes this row safe to publish and
/// it is not one the host provides; it is one the host declines to bypass.
///
/// **No mouse is simulated and no QMP is involved.** Nothing is moved, no
/// click is synthesised, and no tracking loop runs. This row inherits no
/// emulator dependency, and a reader who assumes otherwise will gate it on
/// the wrong thing.
///
/// **The target is a reference and there is no target-free form.** Not "the
/// default button", not "the OK button", not a title. That refusal is a
/// MEASUREMENT rather than taste: upstream's variant that merely disarmed
/// after one use rode a real user's press 18 times in 20, and the variant
/// that had to name its exact target rode it 0 in 20. A "default button"
/// spelling would be the first of those with a friendlier name.
///
/// **The part code is bounded, not enumerated.** A control definition
/// procedure may define its own parts, so a host that listed the standard
/// ones would refuse a legal act against a custom CDEF while sounding
/// strict — see `AgentIntegrationControlPartPolicy`. The guest refuses what
/// it will not do.
///
/// **Success is `dispatched` and can be nothing else here.** The event was
/// handed to the application; whether the control moved, or what its handler
/// then did, is a question for another observation. See
/// `AgentIntegrationActDispatch`.
public enum ControlActProjection: HostProjection {
    public static let capability = HostCapabilityID("now_control_act")

    /* One command, resolved against the connected guest's own `help` table.
       `elements` is NOT required, and the omission is the argument the three
       diagnostics made: a row's `requires` is a CONJUNCTION, so requiring
       the observation would switch this row off against any guest that could
       serve the act. A caller with no reference simply has nothing to send. */
    public static let requires = [
        AgentIntegrationCapabilityNames.controlActCommand,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.controlActCommand,
    ]

    public static let acceptedArguments: Set<String> = ["element", "part"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane addresses a control inside a guest "
                + "application yet. The host can now ASK for the elements "
                + "that would populate one — now_observe_elements landed the "
                + "same day — but nothing renders them, so there is still "
                + "nothing for a person to click. Rule 3 is owed and not "
                + "waived: the affordance lands with the scene view."),
        /* Registered 2026-07-31, with the folded requirement name and the
           coverage row in the one edit. */
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the ctlact command."

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "element": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.elementReferencePattern,
                ],
                "part": ["type": "integer"],
                "dispatch": [
                    "type": "string",
                    "enum": AgentIntegrationActDispatch.allCases
                        .map(\.rawValue),
                    "description":
                        "dispatched means the event was handed to the control's own application, which then ran its real mouse-down handler. It is NOT a claim that the control moved, or that whatever the handler does happened — observe the element again to learn that.",
                ],
                "dispatchedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": ["element", "part", "dispatch", "dispatchedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Act on One New Old World Guest Control",
            "description":
                "Drives ONE named control in a guest application by answering that application's own TrackControl with the part code given, so the application runs its real mouse-down handler and a control that policed its own behaviour goes on policing it. No mouse is simulated, no tracking loop runs and no emulator is involved. The control is addressed by an opaque reference from a current observation (now_observe_elements); there is deliberately no way to say \"the default button\" or to name one by title, because a request that cannot name its target rides whatever the person at the machine does next. A completed call means the event was dispatched, never that anything happened.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "element": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationActPolicy
                                .elementReferencePattern,
                        "description":
                            "Opaque reference to one observed control. Short-lived, and revalidated by the guest against a live control before anything is dispatched. A reference that names a TEXT element is refused here — read or write it with now_text_get and now_text_set.",
                    ],
                    "part": [
                        "type": "integer",
                        "minimum":
                            AgentIntegrationControlPartPolicy.minimumPart,
                        "maximum":
                            AgentIntegrationControlPartPolicy.maximumPart,
                        "description":
                            "A Control Manager part code. The button parts are 10 and 11; a scroll bar's are 20 up, 21 down, 22 page-up, 23 page-down, and 129 is the indicator. Bounded rather than enumerated: a control definition procedure may define its own parts, and refusing those would be this host guessing at a control it has never seen.",
                    ],
                ],
                "required": ["element", "part"],
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
                /* False, and the difference from `now_window_act` is real
                   rather than a softer label for the same thing. That row
                   can `close` a window, which loses unsaved work with no
                   undo this surface can reach. This one hands an
                   application a press; what the press then costs is the
                   application's own business, and the honest thing for a
                   host to say is that IT is not the one destroying
                   anything. A caller reading this annotation still gets
                   `readOnlyHint: false`, which is what puts the row in the
                   fullAccess consent tier. */
                "destructiveHint": false,
                /* Two presses are not one press. A checkbox toggles back, a
                   scroll arrow moves twice, and a button pressed again may
                   meet the dialog the first one opened. */
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
        switch AgentIntegrationControlActRequest.decode(
            arguments.object ?? [:], tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let request):
            return .value(.init(await client.controlAct(request)))
        }
    }
}
