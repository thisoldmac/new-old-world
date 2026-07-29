import Foundation

/// The active host `guestRoot` policy, its bounds, and which guest Files
/// commands are implemented versus deferred. Every fact in it is a fact
/// about the host's own policy, and it changes nothing.
public enum GuestFilesCapabilitiesProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_capabilities")

    public static let requires =
        [AgentIntegrationCapabilityNames.fileList]

    public static let faces: [HostFace: HostFaceReach] = [
        .appUI: .notReached(because:
            "What it reports is the agent-facing guestRoot policy — that "
            + "root, its bounds, and which guest Files commands are "
            + "implemented versus deferred. `guestRoot` appears nowhere in "
            + "the app's own sources: the app browses the share the guest "
            + "offers, bounded by the guest, and shows a command it cannot "
            + "run as a disabled control rather than as a policy readout. A "
            + "person is inside the policy; only a caller that cannot see "
            + "the window needs it stated."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.list."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "New Old World Guest Files Capabilities",
            "description":
                "Reports the running NOW host's active guestRoot policy, current guest share label, bounded limits, and implemented versus deferred guest Files commands. It changes nothing.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.capabilities),
            "annotations": GuestFilesSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.guestFilesCapabilities()))
    }
}
