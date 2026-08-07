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
        .appUI: .reached(file: "NOWMirrorWindow.swift",
                         symbol: "LiveMirrorView(controller: source)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    static let availability = "Reads the current immutable Mirror state "
        + "engine projection and sends the guest no additional request."
}

public enum MirrorStatusProjection: HostProjection {
    public static let capability = HostCapabilityID("now_mirror_status")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Status",
            description: "Returns the current Mirror snapshot identity, sequence, digest, completeness, and generations without polling the guest again.",
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
    public static let capability = HostCapabilityID("now_mirror_metrics")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Metrics",
            description: "Returns the Mirror's act clocks (queue wait, dispatch, settle, total, and the lane depth each act entered behind) and its scene cycle clocks (idle, request, decode, per walk kind), without polling the guest.",
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
    public static let capability = HostCapabilityID("now_mirror_lifecycle")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Lifecycle",
            description: "Returns the NOW Extension's lifecycle and build fingerprint, its capability/requested/active plane bits, and the host's plane policy — the provenance any Mirror measurement has to be read against.",
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
/// `now_mirror_metrics` says how long an act took; this says what was
/// asked, of what, by whom, and how it ended. The `source` field is the
/// one that makes a hand-driven act and an MCP-driven one distinguishable
/// after the fact.
public enum MirrorJournalProjection: HostProjection {
    public static let capability = HostCapabilityID("now_mirror_journal")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Journal",
            description: "Returns the Mirror's bounded operation journal: every act this session with its source (human or mcp), target, postcondition, outcome and reason.",
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
/// observation saw the postcondition hold. Poll `now_mirror_metrics` for
/// the operation's id to watch it settle — the same record the Mirror
/// page's Acts card is showing.
public enum MirrorDriveProjection: HostProjection {
    public static let capability = HostCapabilityID("now_mirror_drive")
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
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Drive",
            description: "Drives the connected classic Mac through the native Mirror's own executor: window select/close/zoom by published entity id, process activate, a menu item by menu and index, Hide/Hide Others/Show All, a keystroke, typed text, or a Finder item opened or selected by name. Returns the operation record; a dispatch is not an effect.",
            properties: [
                "gesture": ["type": "string"],
                "entityID": ["type": "string"],
                "menuID": ["type": "integer"],
                "itemIndex": ["type": "integer"],
                "keyCode": ["type": "integer"],
                "keyChar": ["type": "integer"],
                "modifiers": ["type": "integer"],
                "text": ["type": "string"],
                "itemName": ["type": "string"],
                "container": ["type": "string"],
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
    }
    public static func invoke(_ arguments: HostProjectionArguments,
                              through client: AgentIntegrationClient) async
        -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        let fields = arguments.object ?? [:]
        func text(_ key: String) -> String? { fields[key] as? String }
        func number(_ key: String) -> Int? {
            if let value = fields[key] as? Int { return value }
            if let value = fields[key] as? Double { return Int(value) }
            return nil
        }
        guard let raw = text("gesture"),
              let gesture = AgentIntegrationMirrorDriveGesture(
                rawValue: raw) else {
            return .invalidArguments(
                "now_mirror_drive requires a known gesture")
        }
        return .value(.init(await client.mirrorDrive(.init(
            gesture: gesture,
            entityID: text("entityID"),
            menuID: number("menuID"),
            itemIndex: number("itemIndex"),
            keyCode: number("keyCode"),
            keyChar: number("keyChar"),
            modifiers: number("modifiers"),
            text: text("text"),
            itemName: text("itemName"),
            container: text("container")))))
    }
}

public enum MirrorSnapshotProjection: HostProjection {
    public static let capability = HostCapabilityID("now_mirror_snapshot")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = []
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "New Old World Mirror Snapshot",
            description: "Returns the immutable state projection the native Mirror reads: snapshot and session identity, digest, coverage, freshness, stable process/window entities (each process carrying `presence`: `headless` for a process that declares it has no user interface, `windowed`, `empty` when we looked and it has no windows open right now, and `unknown` — with `presenceReason` — when we did not or could not establish it), guest-provided menubar rows, and per-window surfaces — geometry, controls, dialog items, Finder items, and the content plane's QuickDraw draw ops for replay. Bounded lists always report their true total (itemTotal, displayTotal, contentTotal) beside what was returned.",
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
    public static let capability = HostCapabilityID("now_mirror_find")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = ["query"]
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Find an Entity in the New Old World Mirror",
            description: "Finds stable process or window entities in the current Mirror snapshot. It searches only the already-published immutable projection and creates no second observer.",
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
                "now_mirror_find requires query with 1 to 128 characters")
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .find, query: query))))
    }
}

public enum MirrorWaitProjection: HostProjection {
    public static let capability = HostCapabilityID("now_mirror_wait")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let acceptedArguments: Set<String> = [
        "afterSnapshotID", "timeoutMs",
    ]
    public static let faces = MirrorStateProjectionReach.faces
    public static let availabilityNote = MirrorStateProjectionReach.availability
    public static var mcpDescriptor: [String: Any] {
        MirrorStateProjectionSchema.descriptor(
            title: "Wait for New Old World Mirror State",
            description: "Waits for the existing Mirror engine to publish a snapshot newer than the supplied ID. It never creates a guest poll; timeout is a bounded non-green result.",
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
                "now_mirror_wait requires a positive afterSnapshotID and an optional integer timeoutMs")
        }
        let timeout = values["timeoutMs"] as? Int ?? 5_000
        guard (1...15_000).contains(timeout) else {
            return .invalidArguments(
                "now_mirror_wait timeoutMs must be between 1 and 15000")
        }
        return .value(.init(await client.mirrorRead(.init(
            intention: .wait, afterSnapshotID: after,
            timeoutMs: timeout))))
    }
}
