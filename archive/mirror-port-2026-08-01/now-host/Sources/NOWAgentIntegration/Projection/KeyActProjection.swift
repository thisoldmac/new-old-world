import Foundation

/// Post **one keystroke** into the connected guest's event queue — the
/// mechanism `now_text_set` is not, rather than a better one.
///
/// `now_text_set` writes an addressed element's text directly, through the
/// Dialog Manager's or TextEdit's own setter. That reaches further in one
/// direction (no focus, no frontmost application) and not at all in the
/// other: a dialog that answers only keystrokes never sees it, and there is
/// no text to set for Return, Escape or Tab. This row is for the second
/// case, and it is the MCP face of the guest's own `key` verb
/// (`contract/asyncapi.yaml:key`).
///
/// ## Not one of the five, though it shares their file
///
/// `MirrorActProjections.rows` is the four-dispatch act plane plus the text
/// read beside it, held to properties about a shared vocabulary: one opaque
/// reference as the identity check, one `Dispatch` row as the only claim a
/// completion may make. This row answers neither. It names no reference —
/// there is nothing to observe before pressing a key — and its receipt reads
/// the input plane's own `posted` row, not the act plane's `Dispatch`. So it
/// is registered here, beside the family it belongs to, and left out of that
/// group the same way `now_observe_elements` is: running those properties
/// over it would either fail them or force them to carve out the one row
/// they were never written about.
///
/// ## `mods`, and why this row does not smooth it over
///
/// **A value outside the modifier mask is refused before this row builds a
/// request at all** — `AgentIntegrationKeyModifierPolicy.isValid`, the
/// contract's own bad-request line. A value inside the mask is a different
/// question: `0` never touches the act plane and always succeeds the way it
/// always has; a nonzero value is CARRIED to the guest, which answers
/// through the resident extension's route when one is armed and refuses
/// `unsupported` when it is not. This row does not pre-refuse a nonzero
/// `mods` the way the rendered scene's own click driver does
/// (`MirrorActionDriver`, a choice about that face and not a limit of this
/// one, or of the guest's route) — an agent asking for a modified keystroke
/// gets the machine's own answer, honestly, rather than a blanket no this
/// row invented on its behalf.
///
/// ## `posted`, never `typed`
///
/// The keystroke entered the guest's event queue. Which application dequeues
/// it and what it does with it is the caller's to verify against a fresh
/// observation — the same rule `now_menu_act`'s `dispatched` states for a
/// menu command, and `aesend`'s `sent` states for an Apple Event.
public enum KeyActProjection: HostProjection {
    public static let capability = HostCapabilityID("now_key_act")

    /* One command, resolved against the connected guest's own `help` table
       — the same derivation as the act plane's five. No observation is
       required: a key names no reference, so a caller with no scene still
       has everything this row takes. */
    public static let requires = [
        AgentIntegrationCapabilityNames.keyCommand,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.keyCommand,
    ]

    public static let acceptedArguments: Set<String> = [
        "name", "code", "char", "mods",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "The app's own Mirror pane sends a plain keystroke "
                + "through MirrorKeyCaptureView and ActionModel.paneKeystroke "
                + "today, which is a person typing at their own machine — "
                + "not a row this capability's caller reaches. There is no "
                + "affordance that lets a PERSON compose an arbitrary key "
                + "name, code or char the way this row's caller can; a "
                + "keyboard already does that for them at the machine."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the key command."

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "integer",
                    "description":
                        "The virtual key code the guest posted, as it resolved it — echoed even when the caller sent only a name or a char, because the Menu Manager and Finder shortcut matching read this half and not the character.",
                ],
                "char": [
                    "type": "integer",
                    "description":
                        "The character code the guest posted, as it resolved it.",
                ],
                "posted": [
                    "type": "boolean",
                    "description":
                        "The keystroke entered the guest's event queue. NOT a claim that the front application acted on it — verify that against a fresh observation.",
                ],
                "postedAt": [
                    "type": "string", "format": "date-time",
                ],
            ],
            "required": ["code", "char", "posted", "postedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Post One Keystroke To The New Old World Guest",
            "description":
                "Posts ONE keystroke into the connected guest's event queue — the ground now_text_set cannot cover: a dialog that answers only keystrokes, and keys with no character (Return, Escape, Tab, the arrows). name is exact-match against a closed set of keys with no character of their own; code and char are the guest's own two-byte encoding and may be sent together, singly, or derived from each other where the US key table has a row. mods carries the standard modifier bits; 0 (or omitted) always succeeds, and a nonzero value inside the mask is forwarded to the machine rather than pre-refused — the guest answers or refuses unsupported depending on whether its resident extension can stamp the modifier right now. A value outside the modifier mask is refused before anything is sent. A completed call means the keystroke was POSTED to the queue, never that any application acted on it.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "enum": [
                            "return", "enter", "tab", "space", "delete",
                            "escape", "help", "home", "fwddelete", "end",
                            "pageup", "pagedown", "left", "right", "down",
                            "up",
                        ],
                        "description":
                            "A key with no character to type. enter is the keypad's key and is not return. Exact match; anything else is a character, so send code or char instead.",
                    ],
                    "code": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 127,
                        "description":
                            "The virtual key code, 0..127. Sent alone, the character is derived where the guest's table has a row.",
                    ],
                    "char": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum": 255,
                        "description":
                            "The character code, 0..255. Sent alone, the virtual code is derived from it where the table has a row; an upper-case character keeps its case and takes the unshifted key's code, because the shift is a modifier this call sends through mods, not through case.",
                    ],
                    "mods": [
                        "type": "integer",
                        "minimum": 0,
                        "maximum":
                            AgentIntegrationKeyModifierPolicy.mask,
                        "description":
                            "A combination of the standard modifier bits — cmd 256, shift 512, alphaLock 1024, option 2048, control 4096 — or 0 for none. Omitted means 0. A value outside this mask is refused before anything is sent; a nonzero value inside it is carried to the guest and may itself be refused unsupported when the machine has no route armed for it right now.",
                    ],
                ],
                "required": [],
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
                /* True, and the honest reading of a row that can post ANY
                   key: Return in a "delete forever" dialog, Delete itself,
                   or (once a route is armed) a modified shortcut. There is
                   no subset of this row that excludes them, because the
                   caller names a key and this host does not know what a
                   foreign application's front window will do with it. */
                "destructiveHint": true,
                /* A second identical key is not free: Return submits
                   whatever is now in front, Delete removes the next
                   character, and a dialog the first keystroke raised may
                   swallow the second. */
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
        let object = arguments.object ?? [:]
        var name: String?
        if let raw = object["name"] {
            guard let value = raw as? String else {
                return .invalidArguments(
                    "\(capability.rawValue) requires name to be a string "
                        + "naming one of the keys with no character of "
                        + "their own")
            }
            name = value
        }
        var code: Int?
        if let raw = object["code"] {
            guard let value = raw as? Int, value >= 0, value <= 127 else {
                return .invalidArguments(
                    "\(capability.rawValue) requires code to be an integer "
                        + "0..127 — the virtual key code")
            }
            code = value
        }
        var char: Int?
        if let raw = object["char"] {
            guard let value = raw as? Int, value >= 0, value <= 255 else {
                return .invalidArguments(
                    "\(capability.rawValue) requires char to be an integer "
                        + "0..255 — the character code")
            }
            char = value
        }
        var mods = 0
        if let raw = object["mods"] {
            guard let value = raw as? Int,
                  AgentIntegrationKeyModifierPolicy.isValid(value) else {
                return .invalidArguments(
                    "\(capability.rawValue) requires mods to be a "
                        + "combination of the standard modifier bits — "
                        + "cmd 256, shift 512, alphaLock 1024, option 2048, "
                        + "control 4096 — or 0. A nonzero value outside "
                        + "that mask names bits no modifier owns.")
            }
            mods = value
        }
        let request = AgentIntegrationKeyRequest(
            name: name, code: code, char: char, mods: mods)
        guard request.isWellFormed else {
            return .invalidArguments(
                "\(capability.rawValue) requires at least one of name, "
                    + "code or char — a key request naming none of the "
                    + "three names no key")
        }
        return .value(.init(await client.key(request)))
    }
}
