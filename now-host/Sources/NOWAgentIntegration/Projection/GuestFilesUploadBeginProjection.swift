import Foundation

/// Reserves private host staging for one declared file beneath `guestRoot`.
///
/// It accepts no modern-host path and sends the guest nothing, which is why
/// it requires no guest capability: the whole call is the host bounding what
/// it is willing to hold on its own disk.
public enum GuestFilesUploadBeginProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_upload_begin")

    public static let requires: [String] = []

    public static let availabilityNote =
        "Reserves private host disk and sends the guest no message, so "
        + "staging is available regardless; the commit is where the guest's "
        + "put lane is needed."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Begin a New Old World Guest File Upload",
            "description":
                "Reserves private NOW-owned staging for one declared file beneath guestRoot. It accepts no modern-host path and sends nothing to the guest yet.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "destinationPath": GuestFilesSchema.path,
                    "bytes": [
                        "type": "integer", "minimum": 0,
                        "maximum": Int(Int32.max),
                    ],
                    "sha256": [
                        "type": "string",
                        "pattern": "^[0-9a-f]{64}$",
                    ],
                    "container": [
                        "type": "string",
                        "enum": ["data", "macbinary"],
                    ],
                    "fileType": [
                        "type": "string", "minLength": 4, "maxLength": 4,
                    ],
                    "creator": [
                        "type": "string", "minLength": 4, "maxLength": 4,
                    ],
                    "modified": ["type": "integer", "minimum": 0],
                ],
                "required": [
                    "destinationPath", "bytes", "sha256", "container",
                ],
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
              let upload = declaration(arguments) else {
            return .invalidArguments(
                "now_guest_files_upload_begin requires one canonical destination, declared size, SHA-256, and data or macbinary container")
        }
        return .value(.init(await client.beginGuestFileUpload(upload)))
    }

    private static func declaration(
        _ arguments: [String: Any]
    ) -> AgentIntegrationGuestFileUploadBegin? {
        let allowed = Set([
            "destinationPath", "bytes", "sha256", "container",
            "fileType", "creator", "modified",
        ])
        guard Set(arguments.keys).isSubset(of: allowed),
              let destination = arguments["destinationPath"] as? String,
              !destination.isEmpty,
              AgentIntegrationGuestFilePolicy.isBoundedPath(destination),
              let bytes = arguments["bytes"] as? Int,
              bytes >= 0, bytes <= Int(Int32.max),
              let sha256 = arguments["sha256"] as? String,
              AgentIntegrationGuestFilePolicy.isCanonicalSHA256(sha256),
              let container = arguments["container"] as? String,
              container == "data" || container == "macbinary" else {
            return nil
        }
        func optionalString(_ key: String) -> String? {
            arguments[key] as? String
        }
        if arguments["fileType"] != nil
            && optionalString("fileType") == nil { return nil }
        if arguments["creator"] != nil
            && optionalString("creator") == nil { return nil }
        guard AgentIntegrationGuestFilePolicy.isClassicOSType(
                optionalString("fileType")),
              AgentIntegrationGuestFilePolicy.isClassicOSType(
                optionalString("creator")) else {
            return nil
        }
        let modified: Int?
        if let value = arguments["modified"] {
            guard let integer = value as? Int, integer >= 0 else {
                return nil
            }
            modified = integer
        } else {
            modified = nil
        }
        return .init(
            destinationPath: destination,
            bytes: bytes,
            sha256: sha256,
            container: container,
            fileType: optionalString("fileType"),
            creator: optionalString("creator"),
            modified: modified)
    }
}
