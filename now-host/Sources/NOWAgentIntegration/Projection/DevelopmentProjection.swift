import Foundation

/// One compact semantic lane for build, run and optional human handoff. The
/// operation discriminant is the whole vocabulary: there is no generic guest
/// command, path, ToolServer script or launch target.
public enum DevelopmentProjection: HostProjection {
    public static let capability = HostCapabilityID("now_development")
    public static let requires = [
        "development-project", "development-stage", "development-build", "development-run",
        "development-open",
    ]
    public static let exposes = requires
    public static let authorityDomain =
        HostProjectionAuthorityDomain.hostProjectsAndGuest
    public static let acceptedArguments: Set<String> = [
        "operation", "projectID", "workspaceID", "candidateID", "productRef",
    ]
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "Projects/DevelopmentModuleView.swift",
                         symbol: "Toolchains, Builds & Runs"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "The connected guest serves project snapshot, stage, build, run and handoff commands."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Build and Run a New Old World Project",
            "description":
                "Imports one verified active guest project, stages and promotes an inactive candidate, starts or observes a declarative MPW ToolServer build, launches only its unchanged product, or optionally opens one active Project.ckp in CodeKitten. It accepts no path, MPW text, shell text, Git operation or generic launch target. Build and run are separate outcomes.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "operation": [
                        "type": "string",
                    "enum": ["import", "stage", "stage-status", "stage-discard", "promote",
                                 "build-start", "build-status", "build-cancel",
                                 "run", "open-in-codekitten"],
                    ],
                    "projectID": ["type": "string",
                                  "pattern": "^[0-9a-f]{32}$"],
                    "workspaceID": ["type": "string",
                                    "pattern": "^workspace-[0-9a-f]{16}$"],
                    "candidateID": ["type": "string",
                                    "pattern": "^candidate-[0-9a-f]{16}$"],
                    "productRef": ["type": "string",
                                   "pattern": "^product-[0-9a-f]{16}$"],
                ],
                "required": ["operation"],
                "additionalProperties": false,
            ],
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

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let object = arguments.object,
              JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object),
              let request = try? JSONDecoder().decode(
                AgentIntegrationDevelopmentRequest.self, from: data),
              request.isWellFormed else {
            return .invalidArguments(
                "now_development requires exactly one valid semantic operation and only its opaque project or product reference")
        }
        return .value(.init(await client.development(request)))
    }
}
