import Foundation

/// Host and paired-session state, and nothing about the machine.
///
/// The one projection that is honestly answering out of host state, because
/// what it answers IS a fact about the host: whether it is listening, and
/// whether something is paired. It sends the guest no message.
public enum SessionHealthProjection: HostProjection {
    public static let capability = HostCapabilityID("now_list_machines")

    public static let requires: [String] = []

    /* Nothing: it sends the guest no message, so there is no guest capability
       for a caller to reach through it. Every fact it answers is the host's
       own. */
    public static let exposes: [String] = []

    /* The Connection page's Health block renders the same
       GuestListener.SessionHealth this projection reports — guest name and
       version, when it connected, how long the wire has been quiet, frames
       and pings — and the Start/Stop Listening buttons above it are the
       listener state itself. */
    /* Takes no arguments at all, so the strict answer is the empty set
       rather than an absence of one. */
    public static let acceptedArguments: Set<String> = []

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "ConnectionLinkSection.swift",
                         symbol: "healthBlock(health)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "Reads host-owned listener state and sends the guest no message, "
        + "so it is available whatever the guest implements."

    // `Any` erases Sendable; this is an immutable JSON value graph only.
    private nonisolated(unsafe) static let guestReferenceSchema: [String: Any] = [
        "type": "object",
        "properties": [
            "id": [
                "type": "string",
                "description":
                    "Stable host-assigned machine id used for addressing.",
            ],
            "sessionID": [
                "type": "string",
                "description":
                    "Exact connection id; stale after that connection ends.",
            ],
            "name": [
                "type": "string",
                "description":
                    "Host-owned title shown in NOW's Connections page.",
            ],
            "reportedName": [
                "type": ["string", "null"],
                "description":
                    "Name the guest reported at hello, when present.",
            ],
            "idIsAutoAssigned": ["type": "boolean"],
            "idIsAnchored": [
                "type": "boolean",
                "description":
                    "False when stable identity across reconnect is uncertain.",
            ],
        ],
        "required": [
            "id", "sessionID", "name", "reportedName",
            "idIsAutoAssigned", "idIsAnchored",
        ],
        "additionalProperties": false,
    ]

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Connected Macintosh Machines",
            "description":
                "Lists every Macintosh connected to the running NOW host, identifies the one currently driven, and reports host/session readiness without changing either application. Machine names match the human Connections page; stable ids and exact session ids remain separate.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "health": [
                        "type": "object",
                        "properties": [
                            "state": [
                                "type": "string",
                                "enum": [
                                    "notListening", "listening",
                                    "connected", "failed",
                                ],
                            ],
                            "observedAt": [
                                "type": "string", "format": "date-time",
                            ],
                            "guest": [
                                "oneOf": [
                                    ["type": "null"],
                                    [
                                        "type": "object",
                                        "properties": [
                                            "reference": [
                                                "oneOf": [
                                                    guestReferenceSchema,
                                                    ["type": "null"],
                                                ],
                                            ],
                                            "name": ["type": "string"],
                                        ],
                                        "required": ["reference", "name"],
                                    ],
                                ],
                            ],
                            "roster": [
                                "type": "array",
                                "items": guestReferenceSchema,
                            ],
                            "issues": [
                                "type": "array",
                                "description":
                                    "Host-local failures that can make MCP address a different NOW process than the visible application.",
                                "items": [
                                    "type": "object",
                                    "properties": [
                                        "code": ["type": "string"],
                                        "severity": [
                                            "type": "string",
                                            "enum": ["warning", "error"],
                                        ],
                                        "message": ["type": "string"],
                                        "processIDs": [
                                            "type": "array",
                                            "items": ["type": "integer"],
                                        ],
                                    ],
                                    "required": [
                                        "code", "severity", "message",
                                        "processIDs",
                                    ],
                                    "additionalProperties": false,
                                ],
                            ],
                            "compatibility": [
                                "type": ["object", "null"],
                                "description": "Host/stdio-bridge preflight identity: host build, local protocol, projection catalog and schema revisions.",
                            ],
                        ],
                        "required": [
                            "state", "observedAt", "roster", "issues",
                        ],
                    ],
                    "unavailable":
                        HostProjectionSchema.unavailableFailure,
                ],
                "required": ["available"],
                "additionalProperties": false,
            ],
            "annotations": HostProjectionSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.sessionHealth()))
    }
}
