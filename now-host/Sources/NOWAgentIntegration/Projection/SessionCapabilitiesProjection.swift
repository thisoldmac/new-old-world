import Foundation

/// What the CONNECTED guest can do, and therefore which of the other
/// projections are available against it.
///
/// The projection that makes the rest honest against a guest implementing
/// part of the contract. It derives availability from the guest's own `help`
/// table and from observed message-family traffic — never from which guest
/// it is.
public enum SessionCapabilitiesProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_session_capabilities")

    public static let requires: [String] = []

    public static let faces: [HostFace: HostFaceReach] = [
        .appUI: .notReached(because:
            "No pane reports what the connected guest can do. The app UI "
            + "spends those same facts as ENABLEMENT instead — Software "
            + "greys out an entry a guest cannot launch, a process row that "
            + "sent no PSN is not drivable, Files disables itself when the "
            + "guest serves no listing — so a person reads availability off "
            + "the control they were already reaching for, at the moment it "
            + "matters. An agent has no greyed-out button to read, which is "
            + "why the report exists at all. If a capabilities pane is ever "
            + "built, this row flips and the ledger entry goes."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote = "This report."

    private static let state: [String: Any] = [
        "type": "string",
        "enum": ["available", "unavailable", "unproven"],
    ]

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "New Old World Session Capabilities",
            "description":
                "Reports what the currently paired NOW guest can actually do, and therefore which of these tools are available against it. NOW has guests of different completeness; a tool listed as unavailable here cannot be made to work by calling it anyway. Command availability comes from the guest's own help table and message-family availability from observed traffic plus bounded read-only probes; nothing is inferred from the guest's identity. State 'unproven' means nobody has asked this guest yet and is not a synonym for 'unavailable'.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "probeCostly": [
                        "type": "boolean",
                        "description":
                            "Settle software.list by asking. Its first page is a whole-volume sweep costing about four seconds on a guest that implements it; a guest that does not refuses instantly. Defaults to false, which leaves software.list unproven.",
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "capabilities": [
                        "type": "object",
                        "properties": [
                            "sessionID": [
                                "type": "string", "format": "uuid",
                            ],
                            "observedAt": [
                                "type": "string", "format": "date-time",
                            ],
                            "commandTable": [
                                "type": "array",
                                "items": ["type": "string"],
                            ],
                            "commandTableEvidence": ["type": "string"],
                            "probedCostly": ["type": "boolean"],
                            "families": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "family": ["type": "string"],
                                        "state": state,
                                        "evidence": ["type": "string"],
                                        "refusalCode": ["type": "string"],
                                        "refusalMessage": [
                                            "type": "string",
                                        ],
                                    ],
                                    "required": [
                                        "family", "state", "evidence",
                                    ],
                                ],
                            ],
                            "tools": [
                                "type": "array",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "tool": ["type": "string"],
                                        "state": state,
                                        "requires": [
                                            "type": "array",
                                            "items": ["type": "string"],
                                        ],
                                        "missing": [
                                            "type": "array",
                                            "items": ["type": "string"],
                                        ],
                                        "reason": ["type": "string"],
                                    ],
                                    "required": [
                                        "tool", "state", "requires",
                                        "missing", "reason",
                                    ],
                                ],
                            ],
                        ],
                    ],
                    "unavailable": ["type": "object"],
                ],
                "required": ["available"],
            ],
            // Not idempotent: a probe settles a family, so a second call
            // can legitimately report more than the first. Saying
            // otherwise would invite a client to cache the weaker answer.
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
        let arguments = arguments.objectOrEmpty
        let refusal =
            "now_session_capabilities accepts only an optional boolean probeCostly"
        let probeCostly: Bool
        switch arguments["probeCostly"] {
        case nil:
            probeCostly = false
        case let flag as Bool:
            probeCostly = flag
        default:
            return .invalidArguments(refusal)
        }
        guard Set(arguments.keys).isSubset(of: ["probeCostly"]) else {
            return .invalidArguments(refusal)
        }
        return .value(.init(
            await client.sessionCapabilities(probeCostly: probeCostly)))
    }
}
