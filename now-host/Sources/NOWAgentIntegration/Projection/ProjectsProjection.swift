import Foundation

/// The semantic project surface. One discriminated row keeps ordinary machine
/// turns from paying for nine separate project tools while every operation
/// still passes through the registry, strict arguments, dispatch and audit.
public enum ProjectsProjection: HostProjection {
    public static let capability = HostCapabilityID("now_projects")
    public static let requires: [String] = []
    public static let exposes: [String] = []
    public static let authorityDomain = HostProjectionAuthorityDomain.hostProjects
    public static let acceptsGuestAddressing = false
    public static let acceptedArguments: Set<String> = [
        "operation", "projectID", "workspaceID", "name",
        "expectedRevision", "expectedCommit", "path", "maximumBytes",
        "message", "changes",
    ]
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "Projects/DevelopmentModuleView.swift",
                         symbol: "New Project…"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "The running host owns a bounded Application Support Projects root."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "New Old World Projects",
            "description":
                "Lists, creates, reads, atomically revises and recovers only projects beneath New Old World's application-owned Projects root. A project reports host or guest home; guest-home agent edits target a recoverable host workspace, never the active guest tree. No host path or Git command is accepted.",
            "inputSchema": inputSchema,
            "outputSchema": [
                "type": "object",
                "description": "The operation's typed project, revision, workspace, history, bounded contents, or failure result.",
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
                AgentIntegrationProjectRequest.self, from: data),
              request.isWellFormed else {
            return .invalidArguments(
                "now_projects requires one valid operation and only its bounded opaque IDs, relative paths, revision guards and changes")
        }
        return .value(.init(await client.projects(request)))
    }

    private static let relativePath: [String: Any] = [
        "type": "string", "maxLength": 1024,
        "description": "Canonical /-separated project-relative path; never a host path.",
    ]

    private static let inputSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "operation": [
                "type": "string",
                "enum": AgentIntegrationProjectOperation.allWireValues,
            ],
            "projectID": ["type": "string", "pattern": "^[0-9a-f]{32}$"],
            "workspaceID": ["type": "string", "pattern": "^workspace-[0-9a-f]{16}$"],
            "name": ["type": "string", "minLength": 1, "maxLength": 64],
            "expectedRevision": ["type": "integer", "minimum": 0],
            "expectedCommit": ["type": "string", "pattern": "^[0-9a-f]{40}$"],
            "path": relativePath,
            "maximumBytes": ["type": "integer", "minimum": 1,
                             "maximum": 262_144],
            "message": ["type": "string", "minLength": 1,
                        "maxLength": 256],
            "changes": [
                "type": "array", "minItems": 1, "maxItems": 128,
                "items": [
                    "type": "object",
                    "properties": [
                        "path": relativePath,
                        "action": ["type": "string", "enum": ["write", "delete"]],
                        "expectedDigest": ["type": "string",
                                           "pattern": "^[0-9a-f]{64}$"],
                        "contentsBase64": ["type": "string",
                                           "maxLength": 349_528],
                    ],
                    "required": ["path", "action"],
                    "additionalProperties": false,
                ],
            ],
        ],
        "required": ["operation"],
        "additionalProperties": false,
    ]
}

private extension AgentIntegrationProjectOperation {
    static var allWireValues: [String] {
        [list, create, status, read, apply, history, workspaceOpen,
         workspaceResume, workspaceDiscard].map(\.rawValue)
    }
}
