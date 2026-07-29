import Foundation

/// Consumes one sealed private stage through the host's existing guest
/// transfer lane. It never creates parents and never overwrites, and the
/// receipt reports what the guest confirmed rather than what was sent.
public enum GuestFilesUploadCommitProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_upload_commit")

    public static let requires =
        [AgentIntegrationCapabilityNames.filePut]

    public static let availabilityNote =
        "The connected guest accepts a host-driven put."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Commit a New Old World Guest File Upload",
            "description":
                "Verifies and consumes one private stage, then asks the running NOW host to create the exact destination through its existing guest transfer lane. It never overwrites.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "uploadID": ["type": "string", "format": "uuid"],
                ],
                "required": ["uploadID"],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.uploadReceipt),
            "annotations": GuestFilesSchema.uploadAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == ["uploadID"],
              let rawID = arguments["uploadID"] as? String,
              let uploadID = UUID(uuidString: rawID) else {
            return .invalidArguments(
                "now_guest_files_upload_commit requires one opaque upload ID")
        }
        return .value(.init(
            await client.commitGuestFileUpload(uploadID: uploadID)))
    }
}
