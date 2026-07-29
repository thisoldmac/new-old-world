import Foundation

/// One ordered, bounded chunk into an existing private stage. It sends the
/// guest nothing and resolves no modern-host path.
public enum GuestFilesUploadAppendProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_upload_append")

    public static let requires: [String] = []

    public static let availabilityNote =
        "Accepts bytes into a private host stage and sends the guest no "
        + "message."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Append a New Old World Guest File Upload",
            "description":
                "Writes one ordered, bounded base64 chunk into an existing private NOW upload stage. It sends nothing to the guest.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "uploadID": ["type": "string", "format": "uuid"],
                    "offset": ["type": "integer", "minimum": 0],
                    "data": [
                        "type": "string",
                        "contentEncoding": "base64",
                        "maxLength": 11_000,
                    ],
                ],
                "required": ["uploadID", "offset", "data"],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.uploadStage),
            "annotations": GuestFilesSchema.uploadAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == ["uploadID", "offset", "data"],
              let rawID = arguments["uploadID"] as? String,
              let uploadID = UUID(uuidString: rawID),
              let offset = arguments["offset"] as? Int,
              offset >= 0,
              let encoded = arguments["data"] as? String,
              encoded.count
                <= AgentIntegrationGuestFilePolicy
                    .maximumUploadChunkBase64Scalars,
              let bytes = Data(base64Encoded: encoded),
              !bytes.isEmpty,
              bytes.count
                <= AgentIntegrationGuestFilePolicy
                    .maximumUploadChunkBytes else {
            return .invalidArguments(
                "now_guest_files_upload_append requires one opaque upload ID, exact offset, and at most 8192 decoded bytes")
        }
        return .value(.init(await client.appendGuestFileUpload(
            uploadID: uploadID, offset: offset, bytes: bytes)))
    }
}
