import Foundation

/// A bounded point-in-time process snapshot from the paired guest.
///
/// Opaque references identify observations; the PSNs and paths behind them
/// never leave the host adapter, and a reference is offered only to
/// cooperative quit, which revalidates it before use.
public enum ListProcessesProjection: HostProjection {
    public static let capability = HostCapabilityID("now_list_processes")

    public static let requires =
        [AgentIntegrationCapabilityNames.processList]

    /* The listing itself is the answer handed back, so a caller reaches
       process.list through this row — the one place it is exposed rather than
       consumed. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.processList]

    /* The Processes page IS this listing: its Refresh button asks for
       process.list and the table renders the rows. */
    /* Takes no arguments at all, so the strict answer is the empty set
       rather than an absence of one. */
    public static let acceptedArguments: Set<String> = []

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ProcessesModuleView.swift",
                         symbol: "model.refresh()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves process.list."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "List New Old World Guest Processes",
            "description":
                "Reads a bounded point-in-time snapshot of processes already observed through the running NOW host's paired guest session. Opaque references identify observations only and grant no control authority.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "snapshot": [
                        "type": "object",
                        "properties": [
                            "sessionID": [
                                "type": "string",
                                "format": "uuid",
                            ],
                            "observedAt": [
                                "type": "string",
                                "format": "date-time",
                            ],
                            "freshness": [
                                "type": "string",
                                "enum": ["pointInTime"],
                            ],
                            "referenceAuthority": [
                                "type": "string",
                                "enum": ["cooperativeQuit"],
                            ],
                            "processes": [
                                "type": "array",
                                "maxItems": 48,
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "reference": [
                                            "type": "string",
                                        ],
                                        "name": [
                                            "type": "string",
                                            "maxLength": 32,
                                        ],
                                        "kind": [
                                            "type": "string",
                                            "description":
                                                "background means the process DECLARED it has no user interface (modeOnlyBackground in its SIZE resource) - a faceless background application, which is expected to own no windows. It does not mean \"not frontmost\"; front is a separate field.",
                                            "enum": [
                                                "application",
                                                "background",
                                                "finder",
                                                "unknown",
                                            ],
                                        ],
                                        "code": [
                                            "type": "string",
                                            "maxLength": 4,
                                        ],
                                        "creator": [
                                            "type": "string",
                                            "maxLength": 4,
                                        ],
                                        "sizeKB": [
                                            "type": "integer",
                                            "minimum": 0,
                                        ],
                                        "front": ["type": "boolean"],
                                    ],
                                    "required": [
                                        "name", "kind", "front",
                                    ],
                                    "additionalProperties": false,
                                ],
                            ],
                        ],
                        "required": [
                            "sessionID", "observedAt", "freshness",
                            "referenceAuthority", "processes",
                        ],
                        "additionalProperties": false,
                    ],
                    "unavailable": [
                        "type": "object",
                        "properties": [
                            "code": ["type": "string"],
                            "message": ["type": "string"],
                        ],
                        "required": ["code", "message"],
                        "additionalProperties": false,
                    ],
                ],
                "required": ["available"],
                "additionalProperties": false,
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
        return .value(.init(await client.listProcesses()))
    }
}
