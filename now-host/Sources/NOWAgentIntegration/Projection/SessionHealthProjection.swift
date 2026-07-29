import Foundation

/// Host and paired-session state, and nothing about the machine.
///
/// The one projection that is honestly answering out of host state, because
/// what it answers IS a fact about the host: whether it is listening, and
/// whether something is paired. It sends the guest no message.
public enum SessionHealthProjection: HostProjection {
    public static let capability = HostCapabilityID("now_session_health")

    public static let requires: [String] = []

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
