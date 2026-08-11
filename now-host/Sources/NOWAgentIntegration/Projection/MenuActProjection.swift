import Foundation

/// Perform **one menu command** in a guest application, by answering that
/// application's own `MenuSelect`.
///
/// **No menu is drawn, no tracking loop runs, and nothing depends on mouse
/// motion or timing.** The application is handed the item its own
/// `MenuSelect` would have returned and does what it would have done. So an
/// item with no keyboard shortcut becomes reachable — which is the whole
/// reason this row exists. An item that HAS a shortcut should go through a
/// key instead: it is simpler and needs no patch at all.
///
/// ## The identity check is a coordinate, and that is not a shortcut
///
/// Every other act on this surface names its target with an opaque reference
/// minted by an observation. **A menu press cannot**, because there is no
/// handle to name: `MenuSelect` takes a point, and the menu bar is one shared
/// surface that the person at the machine is also pressing. So the identity
/// checked is the PRESS ITSELF. `titleLeft` — the x at which this menu's
/// title sits in the menu bar, as an observation reports it — is where this
/// act's press will land, and a press anywhere else belongs to the person and
/// is passed through untouched.
///
/// That is why `titleLeft` is required and is not derived from `menu`. A host
/// that computed it would be guessing where a title sits, and a guess that
/// was wrong would either miss or — far worse — match the user's own press.
/// Read the other way: without it there is no way to tell this act's press
/// from theirs, which is the measured 18/20 hijack in its menu-shaped form.
///
/// **And since 2026-08-07 the machine is asked whether it is right.** A
/// required coordinate is not a checked one: a caller holding a scene a
/// second out of date, or a host path whose scene builder defaulted an
/// unread `left` to 0 — which arms at x=4, the Apple menu — supplies the
/// number in perfect good faith and names one menu while describing a press
/// on another. So the guest reads the target application's own menu bar and
/// refuses a press that is not where that bar puts the named menu's title.
/// Where the bar cannot be read there is no second opinion to have, the
/// press is armed where the caller said, and the receipt's `identity` says
/// which of the two this was. Both remain, and a caller can tell them apart.
///
/// **Success is `dispatched`.** It means the application's `MenuSelect`
/// returned this item. What the command handler then did — opened a window,
/// put up a dialog, did nothing — is the caller's to verify against the
/// machine's own state, and this row will not answer it out of the arguments
/// it was handed. See `AgentIntegrationActDispatch`.
public enum MenuActProjection: HostProjection {
    public static let capability = HostCapabilityID("now_menu_act")

    /* One command, resolved against the connected guest's own `help` table.
       No observation is required for the reason `ControlActProjection`
       gives: `requires` is a conjunction, and a caller with no scene simply
       has no numbers to send. */
    public static let requires = [
        AgentIntegrationCapabilityNames.menuActCommand,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.menuActCommand,
    ]

    /* Five keys: the item, its identity check, and the optional process.
       Three of the five are required, which is unusual on this surface and
       is the point — a menu act that could be spelled with fewer would be a
       menu act that could not be told apart from a person's. */
    public static let acceptedArguments: Set<String> = [
        "menu", "item", "titleLeft", "serialHi", "serialLo",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "No NOW pane shows a guest application's menu bar, so "
                + "there is no menu for a person to pick and no title "
                + "position for them to have read. The affordance lands "
                + "with the scene view that reports both — rule 3 is owed "
                + "here and is not waived."),
        /* Registered 2026-07-31, with the folded requirement name and the
           coverage row in the one edit. */
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the menuact command."

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "menu": ["type": "integer"],
                "item": ["type": "integer"],
                "titleLeft": [
                    "type": "integer",
                    "description":
                        "Echoed back because it is the identity that was checked, not a parameter of the act: it is the basis on which the guest agreed to treat this press as the caller's rather than the person's at the machine.",
                ],
                "identity": [
                    "type": "string",
                    "description":
                        "Whether the identity above was CHECKED against the machine or only trusted. The guest asks the target application's own menu bar where that menu's title sits: where it can read one, a press described anywhere else is refused before anything is armed; where it cannot, the press is armed where you said and this says so. Absent means the guest did not answer the row at all — read that as unchecked, never as checked.",
                ],
                "dispatch": [
                    "type": "string",
                    "enum": AgentIntegrationActDispatch.allCases
                        .map(\.rawValue),
                    "description":
                        "dispatched means the application's own MenuSelect returned this item. It is NOT a claim that the command handler ran, or that whatever it does happened — verify that against the machine's own state.",
                ],
                "dispatchedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": [
                "menu", "item", "titleLeft", "dispatch", "dispatchedAt",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Perform One New Old World Guest Menu Command",
            "description":
                "Performs ONE menu command in a guest application by answering that application's own MenuSelect. No menu is drawn, no tracking loop runs, nothing depends on mouse motion or timing, and no emulator is involved — so an item with no keyboard shortcut becomes reachable. An item that has one should go through a key instead. titleLeft is where this act's press will land and is its identity check: a menu press carries no handle to name, so the press itself is the identity, and a press anywhere else belongs to the person at the machine and is passed through untouched. A completed call means MenuSelect returned this item, never that the command handler's work happened.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "menu": [
                        "type": "integer",
                        "description":
                            "The menu's id, as an observation of the machine reports it.",
                    ],
                    "item": [
                        "type": "integer",
                        "minimum": 1,
                        "description":
                            "Its 1-based position in that menu. Menu items are counted from 1, so 0 names nothing.",
                    ],
                    "titleLeft": [
                        "type": "integer",
                        "minimum":
                            AgentIntegrationActPolicy.minimumCoordinate,
                        "maximum":
                            AgentIntegrationActPolicy.maximumCoordinate,
                        "description":
                            "The x of that menu's title in the menu bar, as an observation reports it — now_semantic_ui_snapshot's menubar rows carry it. Required and not derived: this is the act's identity check. A menu press carries no handle, so the press itself is the identity — without this there is no way to tell this act's press from the user's own, and a host that guessed the position could match theirs. A menubar row that reports NO left cannot be pressed: send nothing rather than a zero, which is four pixels from the Apple menu's title and is refused.",
                    ],
                    "serialHi": [
                        "type": "integer",
                        "description":
                            "High half of the process serial number of the application whose menu bar this is. Omit both halves for the frontmost.",
                    ],
                    "serialLo": [
                        "type": "integer",
                        "description":
                            "Low half of the same process serial number. Sent together with serialHi or not at all — half a serial number names nothing.",
                    ],
                ],
                "required": ["menu", "item", "titleLeft"],
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
                /* True, and it is the honest reading of a row that can
                   reach any item in any menu. Quit, Close, Clear and Revert
                   are menu commands; there is no subset of this row that
                   excludes them, because the caller names a position and
                   this host does not know what sits there. Splitting a
                   "safe" menu act out would mean the host deciding which of
                   a foreign application's commands are safe, which is
                   exactly the guess it must not make. */
                "destructiveHint": true,
                /* A second identical command is not free: Undo undoes
                   itself, Close closes the next window, and a dialog the
                   first put up may swallow the second. */
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
        switch AgentIntegrationMenuActRequest.decode(
            arguments.object ?? [:], tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let request):
            return .value(.init(await client.menuAct(request)))
        }
    }
}
