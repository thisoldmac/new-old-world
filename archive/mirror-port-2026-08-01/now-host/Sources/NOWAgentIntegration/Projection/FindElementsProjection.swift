import Foundation

/// **Find one element by title and/or kind**, without a caller having to
/// walk `now_observe_elements`'s whole tree themselves first.
///
/// ## Composition, not a second decision about the machine
///
/// This row sends the guest no message of its own. It calls
/// `client.observeElements(process:)` — the exact call
/// `ObserveElementsProjection` makes — and narrows the tree that comes back
/// by `title` (case-insensitive substring) and/or `kind` (`window`,
/// `control` or `text`). `HostProjection`'s own contract permits exactly
/// this: "composition over data the guest just supplied is permitted and is
/// not deciding" (`now_launch_software`'s catalog match is the precedent).
/// Every fact in a match came from the guest in the same observation; this
/// row only decides which of THOSE facts survive the filter.
///
/// **`requires` and `exposes` are therefore identical to
/// `ObserveElementsProjection`'s** — `elements`, and nothing else — because
/// this row asks the guest for nothing beyond what that one does. It is
/// registered as its own capability rather than folded into that row because
/// the ANSWER shape differs (a flat match list keyed by a filter, not a
/// tree keyed by containment) and because a caller who wants "every control
/// titled Cancel across every open window" should not have to reconstruct
/// that walk over `now_observe_elements`'s tree by hand.
///
/// ## No filter, no call
///
/// At least one of `title` or `kind` is required. Omitting both would return
/// the observation's own tree with nothing removed from it — which is
/// `now_observe_elements`, not a second tool wearing its clothes — so this
/// row refuses rather than silently duplicate that answer under a new name.
///
/// ## `title` matches what a caller can see; `kind: text` rarely matches one
///
/// The match is a case-insensitive substring test against the SAME `title`
/// field the tree already carries for a window or a control. A text element
/// has no title of its own — `AgentIntegrationElementTreeText` carries only
/// a reference and a length, the same limit `now_observe_elements` states —
/// so a call combining `title` with `kind: "text"` is well formed and simply
/// never matches anything: this row does not invent a title for a text
/// element to satisfy a caller's filter, the same way `now_observe_elements`
/// does not invent one to satisfy its own schema.
public enum FindElementsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_find_elements")

    /* Identical to ObserveElementsProjection's — this row asks the guest for
       nothing beyond that walk. See the header for why the two rows still
       get separate capability names. */
    public static let requires = [
        AgentIntegrationCapabilityNames.elementsCommand,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.elementsCommand,
    ]

    public static let acceptedArguments: Set<String> = [
        "serialHi", "serialLo", "title", "kind",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "The same gap ObserveElementsProjection states: this "
                + "row's matches are opaque references to windows, controls "
                + "and text elements, which is exactly the thing a person "
                + "cannot read and a pane would have to render as the real "
                + "windows and controls it names — the scene view. The "
                + "affordance lands with that view, the same as the "
                + "observation and every act this row's matches feed."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the elements command."

    private enum Argument {
        static let serialHi = "serialHi"
        static let serialLo = "serialLo"
        static let title = "title"
        static let kind = "kind"
    }

    public static var mcpDescriptor: [String: Any] {
        let bounds: [String: Any] = [
            "type": "object",
            "properties": [
                "left": ["type": "integer"],
                "top": ["type": "integer"],
                "right": ["type": "integer"],
                "bottom": ["type": "integer"],
            ],
            "required": ["left", "top", "right", "bottom"],
            "additionalProperties": false,
        ]
        let process: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "signature": ["type": "string"],
                "serialHi": ["type": "integer"],
                "serialLo": ["type": "integer"],
                "front": ["type": "boolean"],
            ],
            "required": [
                "name", "signature", "serialHi", "serialLo", "front",
            ],
            "additionalProperties": false,
        ]
        let window: [String: Any] = [
            "type": "object",
            "description":
                "The containing window's own identity. Present on a control or text match and absent on a window match, because a window match IS the element rather than something found inside one.",
            "properties": [
                "ref": [
                    "type": "string",
                    "pattern":
                        AgentIntegrationActPolicy.windowReferencePattern,
                ],
                "title": ["type": "string"],
                "occurrence": ["type": "integer"],
            ],
            "required": ["ref", "title", "occurrence"],
            "additionalProperties": false,
        ]
        let match: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": [
                    "type": "string",
                    "enum": ["window", "control", "text"],
                ],
                "ref": [
                    "type": "string",
                    "description":
                        "The opaque reference: now_window_act, now_control_act, now_text_get or now_text_set takes it depending on kind.",
                ],
                "title": ["type": "string"],
                "occurrence": ["type": "integer"],
                "process": process,
                "window": window,
                "bounds": bounds,
                "visible": ["type": "boolean"],
                "enabled": ["type": "boolean"],
                "length": [
                    "type": "integer",
                    "description": "Present only for kind: \"text\".",
                ],
            ],
            "required": ["kind", "ref", "process"],
            "additionalProperties": false,
        ]
        let answer: [String: Any] = [
            "type": "object",
            "properties": [
                "scope": ["type": "string"],
                "truncated": [
                    "type": "boolean",
                    "description":
                        "Copied from the observation this row filtered: the WALK saw more than it could send. A short match list because the filter was narrow reads the same as one clipped upstream unless this is read alongside it.",
                ],
                "live": ["type": "integer"],
                "matches": ["type": "array", "items": match],
            ],
            "required": ["scope", "truncated", "live", "matches"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title":
                "Find New Old World Guest Elements By Title Or Kind",
            "description":
                "Walks one guest application's windows, controls and text fields — the same walk now_observe_elements performs — and returns only the elements whose title contains title (case-insensitive) and/or whose kind matches kind, instead of the whole tree. At least one of title or kind is required; omitting both would return the observation unfiltered, which is now_observe_elements's own job. Every reference in a match is exactly the one now_observe_elements would have minted for the same element, and now_window_act, now_control_act, now_text_get and now_text_set take it the same way. Omitting the process observes the frontmost application. Nothing is clicked or simulated.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.serialHi: [
                        "type": "integer",
                        "description":
                            "High half of the process serial number to search, as an earlier observation or now_list_processes reports it. Omit both halves for the frontmost application.",
                    ],
                    Argument.serialLo: [
                        "type": "integer",
                        "description":
                            "Low half of the same process serial number. Sent together with serialHi or not at all.",
                    ],
                    Argument.title: [
                        "type": "string",
                        "minLength": 1,
                        "description":
                            "Case-insensitive substring to match against an element's own title. A text element has no title and never matches this filter.",
                    ],
                    Argument.kind: [
                        "type": "string",
                        "enum": ["window", "control", "text"],
                        "description":
                            "Restrict the search to one element kind.",
                    ],
                ],
                "required": [],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", answer),
                    variant("refused", "refused",
                            HostProjectionSchema.unavailableFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
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
        let object = arguments.object ?? [:]

        var title: String?
        if let raw = object[Argument.title] {
            guard let value = raw as? String, !value.isEmpty else {
                return .invalidArguments(
                    "\(capability.rawValue) requires title to be a "
                        + "non-empty string when present")
            }
            title = value
        }

        var kind: AgentIntegrationFindElementKind?
        if let raw = object[Argument.kind] {
            guard let value = raw as? String,
                  let parsed = AgentIntegrationFindElementKind(
                    rawValue: value) else {
                return .invalidArguments(
                    "\(capability.rawValue) requires kind to be one of "
                        + "window, control, text")
            }
            kind = parsed
        }

        guard title != nil || kind != nil else {
            return .invalidArguments(
                "\(capability.rawValue) requires at least one of title or "
                    + "kind. Omitting both would return "
                    + "now_observe_elements's own tree unfiltered, which is "
                    + "that row's job, not this one's.")
        }

        switch AgentIntegrationProcessSerial.decode(object, tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let process):
            let observed = await client.observeElements(process: process)
            return .value(.init(
                filter(observed, title: title, kind: kind)))
        }
    }

    // MARK: - The filter

    private static func filter(
        _ result: AgentIntegrationElementObservationResult,
        title: String?, kind: AgentIntegrationFindElementKind?
    ) -> AgentIntegrationFindResult {
        switch result {
        case .completed(let observation):
            return .completed(matches(
                in: observation, title: title, kind: kind))
        case .refused(let failure):
            return .refused(failure)
        case .unavailable(let unavailable):
            return .unavailable(unavailable)
        }
    }

    private static func matches(
        in observation: AgentIntegrationElementObservation,
        title: String?, kind: AgentIntegrationFindElementKind?
    ) -> AgentIntegrationFindAnswer {
        let needle = title?.lowercased()
        var found: [AgentIntegrationFindElementMatch] = []

        for process in observation.processes {
            let processInfo = AgentIntegrationFindElementProcess(
                name: process.name, signature: process.signature,
                serialHi: process.serialHi, serialLo: process.serialLo,
                front: process.front)

            for window in process.windows {
                if kind == nil || kind == .window {
                    if matchesTitle(window.title, needle: needle) {
                        found.append(.init(
                            kind: .window, ref: window.ref,
                            title: window.title,
                            occurrence: window.occurrence,
                            process: processInfo, window: nil,
                            bounds: window.bounds, visible: window.visible,
                            enabled: nil, length: nil))
                    }
                }

                let windowInfo = AgentIntegrationFindElementWindow(
                    ref: window.ref, title: window.title,
                    occurrence: window.occurrence)

                if kind == nil || kind == .control {
                    for control in window.controls {
                        guard matchesTitle(control.title, needle: needle)
                        else { continue }
                        found.append(.init(
                            kind: .control, ref: control.ref,
                            title: control.title,
                            occurrence: control.occurrence,
                            process: processInfo, window: windowInfo,
                            bounds: control.bounds,
                            visible: control.visible,
                            enabled: control.enabled, length: nil))
                    }
                }

                /* A text element carries no title, so it matches a `kind`
                   filter alone and never a `title` one — stated in this
                   row's own header rather than silently dropped here. */
                if let text = window.text, needle == nil,
                   kind == nil || kind == .text {
                    found.append(.init(
                        kind: .text, ref: text.ref, title: nil,
                        occurrence: nil, process: processInfo,
                        window: windowInfo, bounds: nil, visible: nil,
                        enabled: nil, length: text.length))
                }
            }
        }

        return AgentIntegrationFindAnswer(
            scope: observation.scope, truncated: observation.truncated,
            live: observation.live, matches: found)
    }

    private static func matchesTitle(_ title: String, needle: String?)
        -> Bool {
        guard let needle else { return true }
        return title.lowercased().contains(needle)
    }
}
