import Foundation

/// Host and paired-session state, and nothing about the machine.
///
/// The one projection that is honestly answering out of host state, because
/// what it answers IS a fact about the host: whether it is listening, and
/// whether something is paired. It sends the guest no message.
public enum SessionHealthProjection: HostProjection {
    public static let capability = HostCapabilityID("now_session_health")

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
        .appUI: .reached(file: "SettingsModuleView.swift",
                         symbol: "healthBlock(health)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "Reads host-owned listener state and sends the guest no message, "
        + "so it is available whatever the guest implements."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "New Old World Session Health",
            "description":
                "Reports the running NOW host and paired guest session state without changing either application.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "type": "object",
                "properties": [
                    "available": ["type": "boolean"],
                    "health": ["type": "object"],
                    "unavailable": ["type": "object"],
                ],
                "required": ["available"],
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
