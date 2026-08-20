import CryptoKit
import Foundation

/// One file, from the chat workspace's own disk to the guest, in one call.
///
/// The begin/append/commit trio exists for a caller with BYTES and no path
/// the host is willing to read, and it prices every chunk at a model
/// round-trip — measured at 30–160 s per 8 KiB when the caller is an agent,
/// which is slower than the private stage's own expiry. This row is for the
/// one caller that has a PATH: the chat workspace lane, whose companion is
/// spawned by the host with the person's granted folder bound to its server
/// session. It reads the file here, runs
/// the same stage-and-commit lane internally, and returns the commit's own
/// receipt — no byte crosses the model.
///
/// The security property is containment: a path is served only when its
/// canonical form — symlinks resolved on both sides — sits inside the
/// pinned root. A `..` or a symlink pointing out of the granted folder is
/// refused, not followed.
public enum GuestFilesUploadFileProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_upload_file")

    public static let requires =
        [AgentIntegrationCapabilityNames.filePut]

    /* The put lane, same as the commit row: this is the call whose bytes
       reach the machine, entered from a host-readable file rather than a
       chunk protocol. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.filePut]

    public static let acceptedArguments: Set<String> = [
        "localPath", "destinationPath", "container", "fileType", "creator",
    ]

    /// One file the host will read whole. Bounded well under the begin
    /// row's Int32 ceiling because this file crosses the classic wire in
    /// one sitting; anything larger deserves the deliberate chunked lane.
    public static let maximumLocalFileBytes = 32 * 1024 * 1024

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(because:
            "This row exists because an MCP companion holds a PATH inside "
            + "the granted chat workspace and must not push those bytes "
            + "through the model as base64 chunks. A person hands the app a "
            + "real file through Files' Add File… picker, which enters the "
            + "same host transfer lane this row's internal commit uses, so "
            + "there is no affordance to add — the app-reachable capability "
            + "is the commit row's."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest accepts a host-driven put; the file itself "
        + "must sit inside the chat workspace folder this companion was "
        + "launched with."

    public static var mcpDescriptor: [String: Any] {
        [
            "title": "Upload a Workspace File to the New Old World Guest",
            "description":
                "Reads one file from inside the granted chat workspace folder on this Mac, stages it privately, and delivers it to the guest through the host's existing transfer lane in one call. No bytes cross the caller. Refuses paths outside the workspace root and files over 32 MiB.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "localPath": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength": 1024,
                        "description":
                            "Path of the file to read on this Mac, relative to the chat workspace root (or absolute, if it canonicalizes inside it).",
                    ],
                    "destinationPath": GuestFilesSchema.path,
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
                ],
                "required": ["localPath", "destinationPath", "container"],
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
        guard let object = arguments.object,
              Set(object.keys).isSubset(of: acceptedArguments),
              let localPath = object["localPath"] as? String,
              !localPath.isEmpty,
              localPath.unicodeScalars.count <= 1024,
              let destination = object["destinationPath"] as? String,
              !destination.isEmpty,
              AgentIntegrationGuestFilePolicy.isBoundedPath(destination),
              let container = object["container"] as? String,
              container == "data" || container == "macbinary" else {
            return .invalidArguments(
                "now_guest_files_upload_file requires one localPath inside the chat workspace, one canonical destination, and a data or macbinary container")
        }
        if object["fileType"] != nil,
           object["fileType"] as? String == nil {
            return .invalidArguments(
                "now_guest_files_upload_file takes fileType as a four-character string")
        }
        if object["creator"] != nil,
           object["creator"] as? String == nil {
            return .invalidArguments(
                "now_guest_files_upload_file takes creator as a four-character string")
        }
        let fileType = object["fileType"] as? String
        let creator = object["creator"] as? String
        guard AgentIntegrationGuestFilePolicy.isClassicOSType(fileType),
              AgentIntegrationGuestFilePolicy.isClassicOSType(creator) else {
            return .invalidArguments(
                "now_guest_files_upload_file takes fileType and creator as four-character MacRoman types")
        }

        /* Typed unavailability, not an argument refusal: the caller's
           arguments may be perfect, and what is missing is the lane this
           companion was launched from. An invalid-arguments answer here
           reads as "your recipe is wrong" to every conforming client. */
        guard let workspaceRoot = arguments.workspaceGrant?.canonicalRoot else {
            return .value(.init(
                AgentIntegrationGuestFileUploadCommitResult.hostUnavailable(
                    .init(
                        code: "now-files-workspace-unavailable",
                        message: "This companion was launched without a "
                            + "workspace lane, so no local folder is "
                            + "readable. Stage bytes with "
                            + "now_guest_files_upload_begin instead."))))
        }
        /* Canonicalize BOTH sides before comparing: the root the host
           pinned may itself sit behind a symlink (/tmp does on macOS), and
           the candidate may hide an escape in a `..` or a link. What is
           compared is where the names actually land. */
        let canonicalRoot = workspaceRoot
        let candidate = localPath.hasPrefix("/")
            ? URL(fileURLWithPath: localPath)
            : canonicalRoot.appendingPathComponent(localPath)
        let canonical = candidate.standardizedFileURL
            .resolvingSymlinksInPath()
        let rootPath = canonicalRoot.path
        guard canonical.path == rootPath
                || canonical.path.hasPrefix(rootPath + "/") else {
            return .invalidArguments(
                "now_guest_files_upload_file refuses a path that resolves outside the chat workspace root; only files inside the folder the person granted are readable")
        }

        guard let values = try? canonical.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true else {
            return .invalidArguments(
                "now_guest_files_upload_file requires a regular file inside the granted workspace")
        }
        if let size = values.fileSize, size > maximumLocalFileBytes {
            return .invalidArguments(
                "now_guest_files_upload_file refuses a file over the 32 MiB single-call ceiling")
        }
        guard let bytes = try? Data(contentsOf: canonical),
              bytes.count <= maximumLocalFileBytes else {
            return .invalidArguments(
                "now_guest_files_upload_file could not read the requested workspace file")
        }
        let sha256 = SHA256.hash(data: bytes)
            .map { String(format: "%02x", $0) }.joined()

        let begin = await client.beginGuestFileUpload(.init(
            destinationPath: destination,
            bytes: bytes.count,
            sha256: sha256,
            container: container,
            fileType: fileType,
            creator: creator,
            modified: nil))
        guard case .completed(let beginReceipt, let stage?, nil) = begin,
              beginReceipt.outcome == .success else {
            /* Surfaced as-is: a refused reservation carries the reason a
               caller can act on, and inventing a second wording here would
               be a second place for it to be wrong. */
            return .value(.init(begin))
        }

        var offset = 0
        while offset < bytes.count {
            let end = min(
                offset + AgentIntegrationGuestFilePolicy
                    .maximumUploadChunkBytes,
                bytes.count)
            let appended = await client.appendGuestFileUpload(
                uploadID: stage.uploadID,
                offset: offset,
                bytes: bytes.subdata(in: offset..<end))
            guard case .completed(let receipt, _, nil) = appended,
                  receipt.outcome == .success else {
                return .value(.init(appended))
            }
            offset = end
        }

        return .value(.init(
            await client.commitGuestFileUpload(uploadID: stage.uploadID)))
    }
}
