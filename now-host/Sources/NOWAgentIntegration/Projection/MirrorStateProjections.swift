import Foundation

private enum MirrorStateProjectionSchema {
    static let output: [String: Any] = [
        "type": "object",
        "properties": [
            "available": ["type": "boolean"],
            "value": ["type": "object"],
            "unavailable": ["type": "object"],
        ],
        "required": ["available"],
    ]

    static func descriptor(
        title: String, description: String,
        properties: [String: Any], required: [String] = [],
        annotations: [String: Any] =
            HostProjectionSchema.readOnlyAnnotations
    ) -> [String: Any] {
        [
            "title": title,
            "description": description,
            "x-now-stability": "experimental",
            "inputSchema": [
                "type": "object",
                "properties": properties,
                "required": required,
                "additionalProperties": false,
            ],
            "outputSchema": output,
            "annotations": annotations,
        ]
    }
}

private enum MirrorStateProjectionReach {
    static let faces: [HostCapabilityFace: HostFaceReach] = [
        /* **The pane, not the window.** These rows read the state engine
           the Mirror's poll fills, and the app's face on it is now the
           Mirror module's own surface — one view drawn in two containers,
           so naming the container would name the lesser half. The window
           hosts this same view; the view is the face. */
        .appUI: .reached(file: "MirrorPaneView.swift",
                         symbol: "LiveMirrorView(controller: source"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    static let availability = "Reads the current immutable Mirror state "
        + "engine projection and sends the guest no additional request."
}

public enum MirrorStatusProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_status")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Status",
            description: "Experimental. Returns the retained semantic UI snapshot identity, sequence, digest, completeness, and generations without polling the guest again.",
            properties: [:])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .status))))
    }
}

/// **The Mirror page's own measurements, for the client with no page.**
///
/// The Mirror window and MCP are two clients of one state engine; the only
/// differences are meant to be pixels and input method. A number a person
/// can read off the Acts card and an agent cannot is therefore drift, and
/// it is the drift that bites hardest headless: without the queue depth
/// and the four clocks, an agent cannot tell an act that is being served
/// slowly from one queued behind an act that will time out — which is the
/// exact ambiguity that made the 2026-08-04 PowerBook drive unreadable.
public enum MirrorMetricsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_metrics")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Metrics",
            description: "Experimental. Returns semantic action clocks and scene-cycle clocks without polling the guest.",
            properties: [:])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .metrics))))
    }
}

/// **Which resident answered, and what the planes are doing.**
///
/// The lifecycle, the resident's build fingerprint, and the three plane
/// bitmasks — capability, requested, active. The gap between the last two
/// is the difference between "not armed" and "cannot arm", which reads
/// identically in an act's refusal and calls for opposite repairs.
public enum MirrorLifecycleProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_lifecycle")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Lifecycle",
            description: "Experimental. Returns the NOW Extension lifecycle, build fingerprint, plane bits, and host policy that qualify retained semantic UI evidence.",
            properties: [:])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .lifecycle))))
    }
}

/// **Every operation this session, and which face drove it.**
///
/// `now_semantic_ui_metrics` says how long an act took; this says what was
/// asked, of what, by whom, and how it ended. The `source` field is the
/// one that makes a hand-driven act and an MCP-driven one distinguishable
/// after the fact.
public enum MirrorJournalProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_journal")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Journal",
            description: "Experimental. Returns the shared bounded semantic-operation journal with source, target, postcondition, outcome, and reason.",
            properties: [:])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .journal))))
    }
}

/// **Driving the Mirror by the same path a hand takes.**
///
/// The one mutation row that goes through `MirrorActionExecutor` and the
/// mutation broker, addressing entities the snapshot published. The act
/// lane's five older rows remain, and remain a different thing: they take
/// an `now_observe_elements` ref straight to the guest's command dispatch
/// and settle for nothing, which is a path no person can take.
///
/// A reply is an OPERATION RECORD, not an effect. `dispatched` means the
/// request reached the Mac; only a `confirmed*` outcome says a later
/// observation saw the postcondition hold. Poll `now_semantic_ui_metrics` for
/// the operation's id to watch it settle — the same record the Mirror
/// page's Acts card is showing.
public enum MirrorDriveProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_act")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = [
        "gesture", "entityID", "menuID", "itemIndex", "keyCode", "keyChar",
        "modifiers", "text", "itemName", "container",
    ]
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote =
        "Runs the gesture through the native Mirror's own action executor "
        + "and mutation broker, exactly as a click in the Mirror window "
        + "does; settlement comes from a later guest observation."
    public static var mcpDescriptor: [String: Any] {
        var descriptor = MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Action",
            description: "Experimental. Acts through the shared semantic executor using entities from now_semantic_ui_snapshot. Choose only a published gesture and follow its per-gesture argument branch. Retained entityIDs belong here; opaque now-element references belong to the direct now_control_act, now_window_act, and now_text_* family. Returns an operation record; dispatch is not proof of effect, so wait or re-read state to verify.",
            properties: [
                "gesture": [
                    "type": "string",
                    "enum": AgentIntegrationMirrorDriveGesture.allCases
                        .map(\.rawValue),
                    "description": "One exact gesture from this enum. The matching oneOf branch below states its required arguments; never guess a synonym.",
                ],
                "entityID": [
                    "type": "string",
                    "description": "A retained process or window entityID exactly as now_semantic_ui_snapshot published it. Never pass an opaque now-element reference here.",
                ],
                "menuID": [
                    "type": "integer",
                    "description": "A menu id from the retained snapshot's menu bar.",
                ],
                "itemIndex": [
                    "type": "integer", "minimum": 1,
                    "description": "A 1-based menu item index, or for dialogItem the dialog item's number from the addressed window in the retained snapshot.",
                ],
                "keyCode": [
                    "type": "integer",
                    "description": "A classic Mac virtual keycode, not a character or key name.",
                ],
                "keyChar": [
                    "type": "integer",
                    "description": "Optional classic Mac character code for a key gesture.",
                ],
                "modifiers": [
                    "type": "integer",
                    "description": "Optional classic Mac modifier bitmask.",
                ],
                "text": [
                    "type": "string", "minLength": 1, "maxLength": 256,
                    "description": "Text for the type gesture only.",
                ],
                "itemName": [
                    "type": "string", "minLength": 1,
                    "description": "An exact Finder or Apple menu item name from the retained snapshot.",
                ],
                "container": [
                    "type": "string",
                    "description": "For Finder gestures only: desktop or a retained Finder window entityID.",
                ],
            ],
            required: ["gesture"],
            /* The one row in this file that changes the machine, so it
               must not inherit the read-only annotations its neighbours
               share. Destructive because `close` is in the gesture set and
               a window can hold unsaved work; not idempotent because
               driving the same gesture twice is two acts on the Mac. */
            annotations: [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false,
            ])
        var input = descriptor["inputSchema"] as? [String: Any] ?? [:]
        input["allOf"] = [[
            "oneOf": AgentIntegrationMirrorDriveGesture.allCases.map {
                gesture -> [String: Any] in
                let contract = gesture.argumentContract
                return [
                    "title": gesture.rawValue,
                    "description": contract.guidance,
                    "properties": [
                        "gesture": ["const": gesture.rawValue],
                    ],
                    "required": ["gesture"] + contract.required,
                ]
            },
        ]]
        descriptor["inputSchema"] = input
        return descriptor
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        switch AgentIntegrationMirrorDriveRequest.decode(
            arguments.object ?? [:], tool: capability) {
        case .failure(let refusal):
            return .invalidArguments(refusal.text)
        case .success(let request):
            return .value(.init(await client.mirrorDrive(request)))
        }
    }
}

/// **Opening the Mirror on an already-running host.**
///
/// The row that closes the gap every other Mirror row assumed away: the
/// four reads and the drive all address a window that already exists,
/// and until this landed the only ways to make one exist were a click on
/// this Mac and `--open-mirror` at launch. A headless caller had neither,
/// and the gap was closed in practice by scripting macOS accessibility to
/// press the button on somebody's desktop — a missing affordance that
/// became a documented habit.
///
/// It sends the classic Mac NOTHING. The only row on this surface whose
/// whole effect is on the modern machine; `now_reveal_item` is the
/// closest relative and still crosses the wire.
///
/// Not read-only, and not destructive either: opening a window loses no
/// work. Idempotent because asking twice leaves exactly one Mirror in
/// front of you — the already-open case raises it and says so.
public enum MirrorOpenProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_start")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "MainMenu.swift",
                         symbol: "item(\"Show Mirror\", actions.showMirror"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "Opens the native Mirror window on the host, or raises it if it "
        + "is already open. Sends the guest nothing; refused when no Mac "
        + "is connected, because a Mirror with nothing behind it "
        + "publishes an empty state no call can get out of."
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Start Experimental Semantic UI State",
            description: "Experimental. Starts the host's retained semantic UI state engine. The human Mirror is a sibling view over the same engine; this operation may show that view but sends the classic Mac nothing. Call before other now_semantic_ui_* tools if state is not running.",
            properties: [:],
            annotations: [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": true,
                "openWorldHint": false,
            ])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorOpen()))
    }
}

public enum MirrorSnapshotProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_snapshot")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Experimental Semantic UI Snapshot",
            description: "Experimental. The first UI-context read: returns the immutable retained semantic projection with identity, coverage, freshness, stable process/window entities, menubar rows, geometry, controls, dialogs, Finder items, and bounded content evidence. Call this before now_observe_elements and read its coverage and content before deciding whether to escalate; do not launch direct observation in parallel. Prefer this over pixels for desktop and application context.",
            properties: [:])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .snapshot))))
    }
}

public enum MirrorFindProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_find")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = ["query"]
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Find an Experimental Semantic UI Entity",
            description: "Experimental. Finds stable process or window entities in retained semantic UI state without creating a second observer.",
            properties: ["query": ["type": "string", "minLength": 1,
                                      "maxLength": 128]],
            required: ["query"])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        guard let query = (arguments.object ?? [:])["query"] as? String,
              !query.isEmpty, query.count <= 128 else {
            return .invalidArguments(
                "now_semantic_ui_find requires query with 1 to 128 characters")
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .find, query: query))))
    }
}

public enum MirrorWaitProjection: HostProjection {
    public static let capability = HostCapabilityID("now_semantic_ui_wait")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = [
        "afterSnapshotID", "timeoutMs",
    ]
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Wait for Experimental Semantic UI State",
            description: "Experimental. Waits for retained semantic UI state newer than the supplied snapshot ID. It never creates a second guest poll; timeout is a bounded non-green result.",
            properties: [
                "afterSnapshotID": ["type": "integer", "minimum": 1],
                "timeoutMs": ["type": "integer", "minimum": 1,
                              "maximum": 15_000],
            ], required: ["afterSnapshotID"])
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        let values = arguments.object ?? [:]
        guard let after = values["afterSnapshotID"] as? Int, after > 0,
              values["timeoutMs"] == nil
                || values["timeoutMs"] is Int else {
            return .invalidArguments(
                "now_semantic_ui_wait requires a positive afterSnapshotID and an optional integer timeoutMs")
        }
        let timeout = values["timeoutMs"] as? Int ?? 5_000
        guard (1...15_000).contains(timeout) else {
            return .invalidArguments(
                "now_semantic_ui_wait timeoutMs must be between 1 and 15000")
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .wait, afterSnapshotID: after,
            timeoutMs: timeout))))
    }
}
