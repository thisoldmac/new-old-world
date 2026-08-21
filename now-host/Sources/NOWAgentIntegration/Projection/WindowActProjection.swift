import Foundation

/// Move, resize, zoom or close **one named window**, by answering the
/// owning application's own `FindWindow` call.
///
/// The sibling of `BringToFrontProjection` in shape and the opposite of it in
/// reach: that row drives the Process Manager and can say only which
/// application is in front, this one reaches inside an application to the
/// window a person would have dragged. It is the first row on this surface
/// whose target is a piece of an application's interface rather than a
/// process or a path.
///
/// **No mouse is simulated and no QMP is involved.** The application is
/// handed the answer it would have got from its own `FindWindow`, so it does
/// what it would have done. That is what keeps this row inside the
/// no-host-side-cheating rule instead of arguing with it, and it is why the
/// capability carries no emulator dependency — the mechanism is not
/// emu-only, and a reader who assumes otherwise will gate this row on the
/// wrong thing.
///
/// **Four actions, one row, one target grammar.** The four differ only in
/// what they ask of a window they all address the same way, which is the same
/// argument `GuestFilesMutateProjection` makes for its four mutations. They
/// are also served together or not at all: `winact` is one command in the
/// guest's `help` table, so a guest either answers it or does not, and
/// splitting the row would produce four capabilities with one availability.
///
/// **The target is a reference and there is no "frontmost" form.** That is
/// the design's load-bearing refusal, and it is a MEASUREMENT rather than
/// taste: upstream's request that merely disarmed after one use rode the
/// user's own press 18/20, and the variant that required the request to name
/// its exact target hijacked 0/20. A row that let a caller say "act on
/// whatever is frontmost" would be the first of those, and no amount of
/// bounding its lifetime would change that.
///
/// **Success is `dispatched` and can be nothing else here.** The event is
/// handed to the application; whether the window moved is a question for an
/// observation, and this row will not answer it out of the arguments it was
/// handed. See `AgentIntegrationActDispatch`.
public enum WindowActProjection: HostProjection {
    public static let capability = HostCapabilityID("now_window_act")

    /* One command, and a command rather than a message family on purpose:
       the ledger resolves a command against the connected guest's own `help`
       table, which is what makes this row's availability a fact the machine
       states. Mirror's act plane is PowerPC-only upstream; nothing here asks
       which guest answered, and nothing here should. */
    public static let requires = [
        AgentIntegrationCapabilityNames.windowActCommand,
    ]

    /* The caller directs the act and gets back its own receipt, so the one
       requirement is also exposed. Nothing is consumed internally: this row
       composes no listing, because the reference it takes was minted by an
       observation the caller already made. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.windowActCommand,
    ]

    /* Six keys: the target, the action, and the geometry the action takes.
       Every one of them is published in `inputSchema`, which
       `HostProjectionArgumentStrictnessTests` asserts — and the per-action
       rule (a `close` carrying a `width` is refused, not trimmed) lives in
       `AgentIntegrationWindowActRequest.decode`, because a key this row
       accepts for one action and refuses for another is still a key it
       accepts. */
    public static let acceptedArguments: Set<String> = [
        "window", "action", "left", "top", "width", "height",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane addresses a window inside a guest "
                + "application yet: the host has no window observation to "
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
        "The connected guest serves the winact command."

    public static var operationDescriptor: NOWOperationDescriptor {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "window": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.windowReferencePattern,
                ],
                "action": [
                    "type": "string",
                    "enum": AgentIntegrationWindowAction.allCases
                        .map(\.rawValue),
                ],
                "dispatch": [
                    "type": "string",
                    "enum": AgentIntegrationActDispatch.allCases
                        .map(\.rawValue),
                    "description":
                        "dispatched means the event was handed to the window's own application. It is NOT a claim that the window moved, resized, zoomed or closed — read the window back to learn that.",
                ],
                "dispatchedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": [
                "window", "action", "dispatch", "dispatchedAt",
            ],
            "additionalProperties": false,
        ]
        let coordinate: [String: Any] = [
            "type": "integer",
            "minimum": AgentIntegrationActPolicy.minimumCoordinate,
            "maximum": AgentIntegrationActPolicy.maximumCoordinate,
        ]
        let extent: [String: Any] = [
            "type": "integer",
            "minimum": AgentIntegrationActPolicy.minimumExtent,
            "maximum": AgentIntegrationActPolicy.maximumCoordinate,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Act on One New Old World Guest Window",
            "description":
                "Moves, resizes, zooms or closes ONE named window in a guest application, by answering that application's own FindWindow call — no mouse is simulated and no emulator is involved. The window is addressed by an opaque reference from a current observation; there is deliberately no way to say \"the frontmost window\", because a request that cannot name its target rides whatever the person at the machine does next. A completed call means the event was dispatched to the application, never that the window moved.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "window": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationActPolicy
                                .windowReferencePattern,
                        "description":
                            "Opaque reference to one observed window. Short-lived, and revalidated by the guest against a live window before anything is dispatched.",
                    ],
                    "action": [
                        "type": "string",
                        "enum": AgentIntegrationWindowAction.allCases
                            .map(\.rawValue),
                        "description":
                            "move and resize take their own geometry; zoom and close take none, and a call that sends geometry with them is refused rather than trimmed.",
                    ],
                    "left": coordinate,
                    "top": coordinate,
                    "width": extent,
                    "height": extent,
                ],
                "required": ["window", "action"],
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
                /* True because `close` is in the set, and the tier
                   derivation reads `readOnlyHint` rather than this — so the
                   honest reading of one row that can close a window is that
                   the row can lose a person's unsaved work. Splitting the
                   destructive action out to soften this label would be four
                   capabilities with one availability, which is a worse
                   surface for a truer annotation. */
                "destructiveHint": true,
                /* Two calls are not one call. A second zoom undoes the
                   first, a second close may meet a save dialog the first
                   put up, and a move repeated after the app has yielded is
                   a different act from the same move sent twice in a
                   frame. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let object = arguments.object else {
            return .invalidArguments(
                "\(capability.rawValue) requires window and action")
        }
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        switch AgentIntegrationWindowActRequest.decode(
            object, tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let request):
            return .value(.init(await client.windowAct(request)))
        }
    }
}
