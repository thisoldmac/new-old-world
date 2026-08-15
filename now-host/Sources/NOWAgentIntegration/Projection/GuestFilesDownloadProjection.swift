import Foundation

/// Pull one bounded file off the classic Mac (W1 #4, the direction the Files
/// tools were missing).
///
/// The app has had this from the beginning — the Files page's **Download**
/// row action — and no agent face could ask for it, which is the shape of gap
/// this whole slice exists to close (docs/mcp-coverage.md).
///
/// ## The policy, and what it refuses
///
/// docs/agent-integration.md is emphatic that this companion is not a file
/// transport and gets no modern-host filesystem access, and it deferred
/// arbitrary download pending "a typed NOW command, root/size policy,
/// receipts, audit, and explicit tool projection". This is that projection,
/// so the answer is deliberate and is a **bounded** download rather than a
/// general one:
///
/// - **One canonical path beneath the host-owned `guestRoot`**, the same
///   vocabulary `now_guest_files_list` and `now_guest_files_stat` accept. No
///   absolute guest path, no traversal, no folder.
/// - **A size ceiling, refused before any byte moves** — the guest's own
///   listing supplies the fork sizes, so the refusal is composition over
///   what the guest just said rather than a host guess. The number is
///   `AgentDownloadStore.maximumBytes`, which sits where the evidence ends:
///   the artifact lane's existing 4 MiB human-selected source cap, and the
///   4 MiB top of the reverse path's metal ladder on the 1400c.
/// - **The caller does not say where it lands, and cannot.** The host owns
///   the destination, and the receipt reports it. This is the exact mirror of
///   the upload lane, which accepts bytes and never a host path — a tool
///   holding both ends is the transport this boundary refuses to be.
/// - **One attempt.** Reverse resume does not exist
///   (docs/reverse-file-streaming.md): the deployed sequence has no
///   guest-issued source identity before the host asks for an offset, so a
///   retained partial could stitch two different sources together. A
///   `resumeToken` is reported if a guest ever offers one; nothing uses it.
/// - **The container is reported, not chosen.** Whether a classic file
///   crosses as data bytes or as MacBinary is a fact about its forks.
///
/// ## Why there is no paging here, unlike capture
///
/// `CaptureScreenProjection` pages a PNG out over the 16 KiB local surface
/// because a screen is bounded and the picture *is* the answer. A file is
/// neither: it is unbounded, and 4 MiB of base64 through a 16 KiB window is
/// 512 round trips carrying a payload the MCP face would then render twice.
/// So **the bytes never cross this surface at all** — the reverse-streaming
/// path writes them straight into host-owned private storage and the answer
/// is a receipt naming the file. The cost is stated rather than hidden: a
/// caller with no filesystem access cannot use this tool, which is
/// acceptable only because the local surface is same-uid by construction
/// (docs/agent-integration.md, "Local trust boundary").
///
/// ## One capability, two mechanisms on the wire, and why this row uses one
///
/// Guest→host transfer exists in the contract twice: as the `file.get`
/// message family, host-initiated, and as the `put` command, guest-initiated
/// from a leaf name inside the share root. **This row requires the family and
/// does not route through the command**, and the reason is not which machine
/// is on the other end — nothing here may read that, and nothing does. It is
/// that `requires` can express only a CONJUNCTION. Requiring both leaves the
/// row unavailable wherever either is absent; requiring neither overstates;
/// and requiring the family while quietly falling back to the command would
/// make the tool work exactly where the capability report says it cannot,
/// which is worse than either. So the command stays a declared gap with that
/// reason (docs/mcp-coverage.md), and closing it wants a disjunctive
/// requirement in the registry's own contract — shared machinery, not
/// something one capability adds on its way past.
public enum GuestFilesDownloadProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_download")

    /* Both, and both are load-bearing. `file.get` moves the bytes;
       `file.list` is what the ceiling is applied to, because the size has to
       come from the guest before the transfer rather than from watching it
       arrive. A guest serving the pull and no listing could transfer a file
       nobody had bounded, and the model is not relaxed to make a tool
       available. */
    public static let requires = [
        AgentIntegrationCapabilityNames.fileList,
        AgentIntegrationCapabilityNames.fileGet,
    ]

    /* `file.get` only. The listing is consumed to observe one item's size
       and never crosses back — `now_guest_files_list` is where a caller asks
       for a listing. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.fileGet]

    /* The Files page's Download row action, which predates this row by the
       whole project: the same `GuestListener.getFile` has always been one
       click away for the person at the machine, which is why rule 3 costs
       this capability nothing. */
    public static let acceptedArguments: Set<String> = ["path"]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "GuestFileBrowserAdapter.swift",
                         symbol: "model.download(row)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.list and file.get."

    public static var mcpDescriptor: [String: Any] {
        var path = GuestFilesSchema.path
        path["minLength"] = 1
        return [
            "title": "Download a New Old World Guest File",
            "description":
                "Pulls one file off the classic Mac paired with the running NOW host and reports where it landed on this Mac. Bounded on purpose: the source is one canonical path beneath the host's configured guestRoot, folders are refused, and anything larger than \(AgentDownloadPolicy.maximumBytes) bytes is refused from the guest's own reported fork sizes before a byte moves. The destination is not the caller's to choose — the host writes into private per-launch storage and names the file in the receipt; those bytes live only as long as this host launch, so copy what you mean to keep. One attempt, no resume. The container reports whether a data fork or a MacBinary arrived, and crc32 is the checksum the guest computed: absent means the bytes are unchecked, never that they are correct.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": path],
                "required": ["path"],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(value: landingSchema),
            /* Read-only about the MACHINE — nothing on the guest changes —
               and not idempotent, because two calls land two files: the
               second gets its own name rather than overwriting the first,
               which is the create-only discipline the upload lane keeps in
               the other direction. */
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    private static var landingSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "guestPath": GuestFilesSchema.path,
                "hostPath": [
                    "type": ["string", "null"],
                    "description":
                        "Where the file landed on this Mac, inside host-owned private storage. Absent when the transfer did not complete: there is no whole file to name.",
                ],
                "bytes": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum": AgentDownloadPolicy.maximumBytes,
                ],
                "container": [
                    "type": "string", "enum": ["data", "macbinary"],
                ],
                "crc32": [
                    "type": ["integer", "null"],
                    "minimum": 0,
                    "maximum": Int(UInt32.max),
                    "description":
                        "CRC-32 of the whole stream as the guest computed it, already verified against the bytes that arrived. Null means the guest computed none and the file is UNCHECKED.",
                ],
                "resumeToken": [
                    "type": ["string", "null"],
                    "description":
                        "Reported when a guest offers one. Reverse resume is not implemented, so nothing consumes it.",
                ],
                "elapsedMs": ["type": "integer", "minimum": 0],
            ],
            "required": [
                "guestPath", "bytes", "container", "elapsedMs",
            ],
            "additionalProperties": false,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == acceptedArguments,
              let path = arguments["path"] as? String,
              !path.isEmpty,
              AgentIntegrationGuestFilePolicy.isBoundedPath(path)
        else {
            return .invalidArguments(
                "now_guest_files_download requires one bounded "
                    + "root-relative path to a file")
        }
        return .value(.init(await client.downloadGuestFile(path: path)))
    }
}
