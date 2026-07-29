import Foundation

/// The active host `guestRoot` policy, its bounds, and which guest Files
/// commands are implemented versus deferred. Every fact in it is a fact
/// about the host's own policy, and it changes nothing.
public enum GuestFilesCapabilitiesProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_capabilities")

    public static let requires =
        [AgentIntegrationCapabilityNames.fileList]

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
