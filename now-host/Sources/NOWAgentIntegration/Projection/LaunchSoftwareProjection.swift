import Foundation

/// The reference example of permitted host composition.
///
/// It is worth reading as the answer to "how much may a projection do
/// without deciding": list the catalog, match exactly one full name in it,
/// hand back an opaque session-bound reference, revalidate that reference
/// against a fresh catalog, and only then send the guest's own `launch`.
/// Five steps, every fact in them supplied by the guest in the same breath,
/// and nothing remembered between calls. Zero matches do not launch;
/// several matches do not launch and return at most eight bounded
/// candidates instead. A version that answered from a cached catalog would
/// be the same code with the safety story removed.
///
/// Both requirements matter: the `launch` command alone is not enough,
/// because "launch exactly one exact match from the current catalog" is the
/// entire safety story and there is no catalog without software.list.
public enum LaunchSoftwareProjection: HostProjection {
    public static let capability = HostCapabilityID("now_launch_software")

    public static let requires = [
        AgentIntegrationCapabilityNames.softwareList,
        AgentIntegrationCapabilityNames.launchCommand,
    ]

    /* The Software page's Launch button, acting by the selected entry's
       launch key the same way this projection does. */
    public static let faces: [HostFace: HostFaceReach] = [
        .appUI: .reached(file: "SoftwareModuleView.swift",
                         symbol: "model.launch(entry)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves software.list and launch."

    private static var failure: [String: Any] {
        [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
    }

    private static var candidate: [String: Any] {
        [
            "type": "object",
            "properties": [
                "reference": ["type": "string", "maxLength": 49],
                "name": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumNameScalars,
                ],
                "version": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumVersionScalars,
                ],
                "type": ["type": "string", "maxLength": 4],
                "creator": ["type": "string", "maxLength": 4],
                "running": [
                    "type": "boolean",
                    "description":
                        "State observed in the catalog before any launch",
                ],
            ],
            "required": ["reference", "name", "running"],
            "additionalProperties": false,
        ]
    }

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "sessionID": [
                    "type": "string",
                    "format": "uuid",
                ],
                "catalogObservedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
                "acknowledgedAt": [
                    "type": "string",
                    "format": "date-time",
                ],
                "software": candidate,
                "guestMessage": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
            ],
            "required": [
                "sessionID", "catalogObservedAt", "acknowledgedAt",
                "software", "guestMessage",
            ],
            "additionalProperties": false,
        ]
        let ambiguity: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationLaunchPolicy.maximumMessageScalars,
                ],
                "matchCount": [
                    "type": "integer",
                    "minimum": 2,
                    "maximum":
                        AgentIntegrationLaunchPolicy.maximumCatalogEntries,
                ],
                "candidates": [
                    "type": "array",
                    "maxItems":
                        AgentIntegrationLaunchPolicy.maximumCandidates,
                    "items": candidate,
                ],
            ],
            "required": [
                "code", "message", "matchCount", "candidates",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Launch New Old World Guest Application",
            "description":
                "Launches only an exact, current application selected from the running NOW host's paired guest catalog. A name with zero or multiple exact matches does not launch; an opaque candidate reference is revalidated before use. Guest paths are never accepted or returned.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength":
                            AgentIntegrationLaunchPolicy.maximumNameScalars,
                    ],
                    "reference": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationLaunchPolicy.referencePattern,
                    ],
                ],
                "oneOf": [
                    ["required": ["name"], "not": ["required": ["reference"]]],
                    ["required": ["reference"], "not": ["required": ["name"]]],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("launched", "launched", receipt),
                    variant("unavailable", "unavailable", failure),
                    variant("ambiguous", "ambiguous", ambiguity),
                    variant("notFound", "notFound", failure),
                    variant("refused", "refused", failure),
                ],
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
        guard let arguments = arguments.object,
              let selection = selection(arguments) else {
            return .invalidArguments(
                "now_launch_software requires exactly one bounded name or opaque reference")
        }
        return .value(.init(await client.launchSoftware(selection)))
    }

    /// Exactly one of the two, never both: a name the host resolves against
    /// the current catalog, or a reference the host revalidates against it.
    private static func selection(_ arguments: [String: Any])
        -> AgentIntegrationLaunchSelection? {
        switch Set(arguments.keys) {
        case ["name"]:
            guard let name = arguments["name"] as? String,
                  !name.isEmpty,
                  name.unicodeScalars.count <=
                    AgentIntegrationLaunchPolicy.maximumNameScalars else {
                return nil
            }
            return .name(name)
        case ["reference"]:
            guard let reference = arguments["reference"] as? String,
                  AgentIntegrationLaunchPolicy
                    .isValidReference(reference) else {
                return nil
            }
            return .reference(reference)
        default:
            return nil
        }
    }
}
