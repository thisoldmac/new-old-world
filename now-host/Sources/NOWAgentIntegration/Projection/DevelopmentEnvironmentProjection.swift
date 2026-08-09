import Foundation

public enum AgentIntegrationDevelopmentEnvironmentPolicy {
    public static let verb = "development"
    public static let group = "development"
    public static let maximumRows = 16
    public static let maximumLabelScalars = 32
    public static let maximumValueScalars = 96
    public static let maximumFailureCodeScalars = 64
    public static let maximumMessageScalars = 200
}

/// The classic Mac's own, human-qualified development environment.
///
/// This deliberately returns prose rows rather than a host path or an MPW
/// invocation surface. The person at the guest chooses both folders; the
/// guest qualifies the toolchain and returns only its opaque identity and
/// measured components. Later build operations consume that registration by
/// project/action ID, so no agent ever acquires ambient path execution.
public enum DevelopmentEnvironmentProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_development_environment")
    public static let requires = [
        AgentIntegrationCapabilityNames.developmentCommand,
    ]
    public static let exposes = [
        AgentIntegrationCapabilityNames.developmentCommand,
    ]
    public static let acceptedArguments: Set<String> = []
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "Projects/DevelopmentModuleView.swift",
                         symbol: "Toolchain"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]
    public static let availabilityNote =
        "The connected guest's command table names development."

    public static var mcpDescriptor: [String: Any] {
        let policy = AgentIntegrationDevelopmentEnvironmentPolicy.self
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": ["type": "string", "maxLength":
                    policy.maximumFailureCodeScalars],
                "message": ["type": "string", "maxLength":
                    policy.maximumMessageScalars],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let report: [String: Any] = [
            "type": "object",
            "properties": [
                "verb": ["const": policy.verb],
                "groups": [
                    "type": "array", "maxItems": 1,
                    "items": [
                        "type": "object",
                        "properties": [
                            "name": ["const": policy.group],
                            "rows": [
                                "type": "array",
                                "maxItems": policy.maximumRows,
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "label": ["type": "string",
                                            "maxLength": policy.maximumLabelScalars],
                                        "value": ["type": "string",
                                            "maxLength": policy.maximumValueScalars],
                                    ],
                                    "required": ["label", "value"],
                                    "additionalProperties": false,
                                ],
                            ],
                        ],
                        "required": ["name", "rows"],
                        "additionalProperties": false,
                    ],
                ],
                "note": ["type": ["string", "null"], "maxLength": 200],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["verb", "groups", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read the Classic Mac Development Environment",
            "description":
                "Reads the connected guest's human-selected Projects and MPW registration as path-free status rows: opaque toolchain identity, measured qualification version, and required component presence. It never returns a guest path and cannot execute an arbitrary command. Availability follows the connected guest's advertised command table.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", report),
                    variant("refused", "refused", failure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                "readOnlyHint": true,
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
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.developmentEnvironment()))
    }
}
