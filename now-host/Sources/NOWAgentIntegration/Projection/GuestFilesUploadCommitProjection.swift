import Foundation

/// Consumes one sealed private stage through the host's existing guest
/// transfer lane. It never creates parents and never overwrites, and the
/// receipt reports what the guest confirmed rather than what was sent.
public enum GuestFilesUploadCommitProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_upload_commit")

    public static let requires =
        [AgentIntegrationCapabilityNames.filePut]

    /* The put lane. This is the step where the caller's bytes reach the
       machine, so it is where the capability is exposed — the begin/append
       pair before it exposes nothing because it reaches no guest. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.filePut]

    /* Files' Add File… — the picker's primary action — sends through the
       same host transfer lane this commit consumes; what differs is only
       where the bytes came from (a file a person chose, versus a sealed
       private stage). This is the row that makes the begin/append pair's
       app-UI divergence honest: the CAPABILITY, creating a file on the
       guest, is reachable from the app. */
    public static let acceptedArguments: Set<String> = ["uploadID"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "FilesModuleView.swift",
                         symbol: "model.send(url)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

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
              Set(arguments.keys) == acceptedArguments,
              let rawID = arguments["uploadID"] as? String,
              let uploadID = UUID(uuidString: rawID) else {
            return .invalidArguments(
                "now_guest_files_upload_commit requires one opaque upload ID")
        }
        return .value(.init(
            await client.commitGuestFileUpload(uploadID: uploadID)))
    }
}
