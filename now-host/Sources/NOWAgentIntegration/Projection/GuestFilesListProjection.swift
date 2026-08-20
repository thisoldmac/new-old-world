import Foundation

/// One bounded page beneath the host-owned `guestRoot`.
///
/// The path is canonical and root-relative: the caller cannot choose or
/// escape `guestRoot`, which is the whole of this projection's authorizing
/// job. It composes nothing the guest did not just enumerate.
public enum GuestFilesListProjection: HostProjection {
    public static let capability = HostCapabilityID("now_guest_files_list")

    public static let requires =
        [AgentIntegrationCapabilityNames.fileList]

    /* The page of entries the guest enumerated is the answer, so this is
       where a caller reaches file.list. Bounded to guestRoot — exposure is
       "can a caller obtain this capability's answer", not "without limits". */
    public static let exposes =
        [AgentIntegrationCapabilityNames.fileList]

    /* The Files page's browser table, walking the same file.list the
       projection pages through. */
    public static let acceptedArguments: Set<String> = ["path", "cursor"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "FilesWorkspaceShell.swift",
                         symbol: "GuestBrowserContent("),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.list."

    public static var operationDescriptor: NOWOperationDescriptor {
        [
            "title": "List New Old World Guest Files",
            "description":
                "Lists one bounded page beneath the running NOW host's configured guestRoot. Paths are canonical root-relative HFS paths; the agent cannot choose or escape guestRoot.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": GuestFilesSchema.path,
                    "cursor": [
                        "type": "integer",
                        "minimum": 1,
                    ],
                ],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.listing),
            "annotations": GuestFilesSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let selection = selection(arguments.objectOrEmpty) else {
            return .invalidArguments(
                "now_guest_files_list accepts one bounded root-relative path and optional positive cursor")
        }
        return .value(.init(await client.listGuestFiles(
            path: selection.path, cursor: selection.cursor)))
    }

    private static func selection(
        _ arguments: [String: Any]
    ) -> (path: String, cursor: Int?)? {
        guard Set(arguments.keys).isSubset(of: acceptedArguments)
        else { return nil }
        let path: String
        if let value = arguments["path"] {
            guard let bounded = value as? String else { return nil }
            path = bounded
        } else {
            path = ""
        }
        guard AgentIntegrationGuestFilePolicy.isBoundedPath(path)
        else { return nil }
        let cursor: Int?
        if let value = arguments["cursor"] {
            guard let positive = value as? Int, positive >= 1
            else { return nil }
            cursor = positive
        } else {
            cursor = nil
        }
        return (path, cursor)
    }
}
