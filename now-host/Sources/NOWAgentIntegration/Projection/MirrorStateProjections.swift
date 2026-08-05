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

    static func descriptor(title: String, description: String,
                           properties: [String: Any],
                           required: [String] = []) -> [String: Any] {
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
            "annotations": HostProjectionSchema.readOnlyAnnotations,
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
            description: "Returns the immutable state projection the native Mirror reads: snapshot and session identity, digest, coverage, freshness, stable process/window entities, and guest-provided menubar rows.",
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
