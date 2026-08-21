import Foundation

/// One compact semantic lane for project sync, build and run. The optional
/// CodeKitten handoff stays in the app UI until it has its own approval and
/// acceptance semantics; an agent does not need an IDE to do this work. The
/// operation discriminant is the whole vocabulary: there is no generic guest
/// command, path, ToolServer script or launch target.
public enum DevelopmentProjection: HostProjection {
    public static let capability = HostCapabilityID("now_development")
    public static let requires = [
        AgentIntegrationCapabilityNames.developmentProjectCommand,
        AgentIntegrationCapabilityNames.developmentStageCommand,
        AgentIntegrationCapabilityNames.developmentBuildCommand,
        AgentIntegrationCapabilityNames.developmentRunCommand,
        AgentIntegrationCapabilityNames.developmentTestCommand,
    ]
    public static let exposes = requires
    public static let authorityDomain =
        HostProjectionAuthorityDomain.hostProjectsAndGuest
    public static let acceptedArguments: Set<String> = [
        "operation", "projectID", "workspaceID", "candidateID", "productRef",
        "attemptID",
    ]
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "Projects/DevelopmentModuleView.swift",
                         symbol: "Toolchains, Builds & Runs"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "The connected guest serves project snapshot, stage, build and run commands."

    public static var operationDescriptor: NOWOperationDescriptor {
        [
            "title": "Build and Run a New Old World Project",
            "description":
                "Imports one verified active guest project, stages and promotes an inactive candidate, starts or observes a declarative MPW ToolServer build, or launches only its unchanged product. It accepts no path, MPW text, shell text, Git operation, generic launch target or IDE-control operation. Build and run are separate outcomes.",
            "inputSchema": inputSchema,
            "outputSchema": [
                "type": "object",
                "description": "Bounded guest-owned build, run or handoff rows, or a typed refusal.",
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    // `Any` erases Sendable; these are immutable JSON value graphs only.
    private nonisolated(unsafe) static let projectID: [String: Any] = [
        "type": "string", "pattern": "^[0-9a-f]{32}$",
    ]
    private nonisolated(unsafe) static let workspaceID: [String: Any] = [
        "type": "string", "pattern": "^workspace-[0-9a-f]{16}$",
    ]
    private nonisolated(unsafe) static let candidateID: [String: Any] = [
        "type": "string", "pattern": "^candidate-[0-9a-f]{16}$",
    ]
    private nonisolated(unsafe) static let productRef: [String: Any] = [
        "type": "string", "pattern": "^product-[0-9a-f]{16}$",
    ]
    private nonisolated(unsafe) static let attemptID: [String: Any] = [
        "type": "string", "format": "uuid",
        "description": "Caller-retained idempotency identity for this mutation.",
    ]

    private nonisolated(unsafe) static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "operation": [
                "type": "string",
                "enum": AgentIntegrationDevelopmentOperation.allCases
                    .filter { $0 != .openInCodeKitten }
                    .map(\.rawValue),
            ],
            "projectID": projectID,
            "workspaceID": workspaceID,
            "candidateID": candidateID,
            "productRef": productRef,
            "attemptID": attemptID,
        ],
        "required": ["operation"],
        "additionalProperties": false,
        "oneOf": [
            branch(.catalog),
            branch(.loopStatus),
            branch(.importGuest, ["projectID": projectID,
                                  "attemptID": attemptID],
                   ["projectID", "attemptID"]),
            branch(.stage, ["projectID": projectID,
                            "workspaceID": workspaceID,
                            "attemptID": attemptID], ["projectID", "attemptID"]),
            branch(.stageStatus, ["candidateID": candidateID],
                   ["candidateID"]),
            branch(.stageDiscard, ["candidateID": candidateID,
                                   "attemptID": attemptID],
                   ["candidateID", "attemptID"]),
            branch(.promote, ["candidateID": candidateID,
                              "attemptID": attemptID], ["candidateID", "attemptID"]),
            branch(.buildStart, ["projectID": projectID,
                                 "attemptID": attemptID], ["projectID", "attemptID"]),
            branch(.buildStart, ["candidateID": candidateID,
                                 "attemptID": attemptID],
                   ["candidateID", "attemptID"], title: "Build candidate"),
            branch(.buildStatus),
            branch(.buildCancel, ["attemptID": attemptID], ["attemptID"]),
            branch(.run, ["productRef": productRef, "attemptID": attemptID],
                   ["productRef", "attemptID"]),
            branch(.test, ["productRef": productRef, "attemptID": attemptID],
                   ["productRef", "attemptID"]),
        ],
    ]

    private static func branch(
        _ operation: AgentIntegrationDevelopmentOperation,
        _ properties: [String: Any] = [:],
        _ required: [String] = [],
        title: String? = nil
    ) -> [String: Any] {
        var all = properties
        all["operation"] = ["const": operation.rawValue]
        var result: [String: Any] = [
            "type": "object", "properties": all,
            "required": ["operation"] + required,
            "additionalProperties": false,
        ]
        if let title { result["title"] = title }
        return result
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let object = arguments.object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let request = try? JSONDecoder().decode(
                AgentIntegrationDevelopmentRequest.self, from: data),
              request.isWellFormed,
              request.operation != .openInCodeKitten else {
            return .invalidArguments(
                "now_development requires exactly one valid semantic operation and only its opaque project or product reference")
        }
        return .value(.init(await client.development(request)))
    }
}
