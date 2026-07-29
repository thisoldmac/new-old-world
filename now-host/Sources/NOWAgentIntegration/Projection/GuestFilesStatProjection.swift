import Foundation

/// Bounded metadata for one exact item beneath `guestRoot`.
///
/// A bounded parent scan returns explicit not-found or scan-limit outcomes
/// rather than guessing — the projection reports what the scan reached, and
/// never fills a gap with a plausible answer.
public enum GuestFilesStatProjection: HostProjection {
    public static let capability = HostCapabilityID("now_guest_files_stat")

    public static let requires =
        [AgentIntegrationCapabilityNames.fileList]

    /* Reached by the same mechanism, not an equivalent one: this projection
       stats one item by a bounded scan of its PARENT, which is exactly what
       the browser does when a person navigates there, and the row renders
       the entry's kind, size and modified date. A person has a window and
       needs no path; a caller has a path and no window. */
    public static let faces: [HostFace: HostFaceReach] = [
        .appUI: .reached(file: "FileBrowserTable.swift",
                         symbol: "item.kind"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.list."

    public static var mcpDescriptor: [String: Any] {
        var path = GuestFilesSchema.path
        path["minLength"] = 1
        return [
            "title": "Inspect a New Old World Guest File",
            "description":
                "Reads bounded metadata for one exact item beneath the running NOW host's configured guestRoot. A bounded parent scan returns explicit not-found or scan-limit outcomes instead of guessing.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": path],
                "required": ["path"],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.entry),
            "annotations": GuestFilesSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == ["path"],
              let path = arguments["path"] as? String,
              !path.isEmpty,
              AgentIntegrationGuestFilePolicy.isBoundedPath(path)
        else {
            return .invalidArguments(
                "now_guest_files_stat requires one bounded root-relative path")
        }
        return .value(.init(await client.statGuestFile(path: path)))
    }
}
