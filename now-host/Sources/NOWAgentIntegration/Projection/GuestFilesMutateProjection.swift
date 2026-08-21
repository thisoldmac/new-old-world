import Foundation

/// The first MUTATING guest-Files capability on this surface, and the whole
/// row is about what earns that.
///
/// Everything the companion did to guest files until now was read-only or
/// create-only-with-a-receipt. Moving, trashing and restoring are neither, so
/// the authority is stated rather than inherited:
///
/// 1. **`guestRoot` is the grant.** Every path is canonical, root-relative
///    and composed beneath the host-owned, persisted, versioned root by the
///    command layer. The caller cannot name an absolute guest path, a modern
///    host path, or anything outside the root — the same bound the read-only
///    rows and the upload lane stand on, and the only thing on this surface
///    a person actually approved.
/// 2. **Overwrite is never asked for.** `file.move` carries an `overwrite`
///    flag; this row never sets it and refuses an argument that mentions it.
///    The upload lane is create-only for the same reason, and here it is
///    load-bearing twice over: an overwrite is the one deletion with no
///    Trash entry, so refusing it is what makes "everything an agent removes
///    from a path is recoverable" true rather than aspirational.
/// 3. **There is no unlink.** The vocabulary is the contract's — trash and
///    restore, not delete — and the `delete` command kind stays deferred.
///    A caller cannot express irreversible removal through this tool at all.
/// 4. **One item, one intention, one attempt.** No array form, no recursion,
///    no retry, no created parents. A mistake costs one item.
/// 5. **Rule 3 is satisfied at both ends.** The person at the machine has had
///    all four since the Files page learned to change the share — with a
///    worded confirmation sheet and a fifty-deep Undo — and every call here
///    writes the Files log line the browse commands write, carrying the
///    affected path, beside the dispatch's own agent audit event. A
///    destructive action an agent performs is neither exclusive to it nor
///    invisible.
///
/// **What is deliberately NOT here, with its reason.** The command layer mints
/// short-lived observation references on every listing, and requiring one
/// would let this row say "you may only mutate what you just observed", the
/// shape `now_request_quit` uses for processes. It is not required, because
/// the reference cannot be made to mean anything the guest checks: `file.move`
/// and `file.trash` carry no identity precondition in the contract, so the
/// guest cannot recompute one before acting, and a host-side match would be a
/// stale observation wearing the clothes of a live one. Path-addressed with
/// the guest deciding atomically is the honest version of this operation
/// today; closing the residual window is a contract change plus a local-wire
/// field, and belongs on the ledger rather than in a comment that implies it
/// was done.
///
/// **Where the four are not served, this row is unavailable rather than
/// smaller.** All four families are required together, so a guest that
/// answers `not-implemented` to them reports the row unavailable in typed
/// form and nothing partial is offered. The togetherness is not tidiness: a
/// guest serving `trash` without `restore` would be offering a deletion this
/// projection could not undo, and the pairing IS the safety property, so it
/// is a requirement. Availability is derived from what the connected guest
/// answers and never from which guest answered — the coverage table records
/// which ISA serves the four today, and this file must not.
public enum GuestFilesMutateProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_guest_files_mutate")

    /* All four, and no `file.list`. This row observes nothing: it addresses,
       bounds, and asks — the guest answers whether the item was there, and
       whether the destination was free, at the moment it acted. A required
       listing would be a listing consumed to guess at both. */
    public static let requires = [
        AgentIntegrationCapabilityNames.fileMove,
        AgentIntegrationCapabilityNames.fileTrash,
        AgentIntegrationCapabilityNames.fileRestore,
        AgentIntegrationCapabilityNames.fileMkdir,
    ]

    /* All four are exposed: the caller chooses the intention and directs the
       effect, which is exactly what exposure means. */
    public static let exposes = requires

    /* The one key list this row has, read by both the shared gate and the
       decoding below. It matters most here of anywhere on this surface: the
       optional members are `toPath` and `trashedAs`, so a caller who writes
       `destinationPath` for the first has described a MOVE and, on a fail-open
       surface, would have got a trash — a different destructive action, with a
       success reply. */
    public static let acceptedArguments: Set<String> = [
        "mutation", "path", "toPath", "trashedAs",
    ]

    /* The Files page's confirmation sheet — the call site a person's click
       reaches for a move, a rename and a trash. The other two intentions are
       in the same file and one click away each (`model.createFolder(named:)`
       behind New Folder, `model.undoLastChange()` behind the Undo split
       button, which is where a restore comes from), so rule 3 costs this
       capability nothing: the human affordance predates the tool by the whole
       Files-mutation arc (docs/files.md, "Changing the share from the host").
       One symbol is named because the check reads one; the destructive
       intention is the one worth pinning. */
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "FilesModuleView.swift",
                         symbol: "model.commitPendingChange()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.move, file.trash, file.restore "
        + "and file.mkdir."

    public static var operationDescriptor: NOWOperationDescriptor {
        [
            "title": "Change the New Old World Guest's Files",
            "description":
                "Moves or renames one item, moves one item to the guest's Trash, restores one item the Trash still holds, or creates one folder — all beneath the running NOW host's configured guestRoot. Paths are canonical root-relative HFS paths and the agent can neither choose nor escape guestRoot. There is no delete: removal means the Trash, and the answer carries the name the item landed under, which is the only key a restore takes and is not remembered anywhere. Nothing is ever overwritten and no parent folder is created, so a collision or a missing folder refuses rather than replacing or inventing anything. One item per call, one attempt, no recursion.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "mutation": [
                        "type": "string",
                        "enum": AgentIntegrationGuestFileMutation.allCases
                            .map(\.rawValue),
                        "description":
                            "move renames or relocates (toPath carries the new name); trash moves to the Trash; restore takes trashedAs plus the path it came back to; mkdir makes one folder.",
                    ],
                    "path": mutationPath,
                    "toPath": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength":
                            AgentIntegrationGuestFilePolicy
                                .maximumPathScalars,
                        "description":
                            "move only: where the item is going, including its new name. Must not be the source or inside it.",
                    ],
                    "trashedAs": [
                        "type": "string",
                        "minLength": 1,
                        "maxLength":
                            AgentIntegrationGuestFilePolicy
                                .maximumSegmentScalars,
                        "description":
                            "restore only: the item's name inside the Trash, exactly as the trash answer reported it. It is not always the name the item had.",
                    ],
                ],
                "required": ["mutation", "path"],
                "additionalProperties": false,
            ],
            "outputSchema": GuestFilesSchema.result(
                value: GuestFilesSchema.mutationOutcome),
            "annotations": [
                "readOnlyHint": false,
                /* True, and it is the first row on this surface for which it
                   is. A trash is reversible while the Trash holds it and a
                   move is reversible by name, but "reversible by someone who
                   kept the receipt" is not non-destructive, and a caller
                   deciding whether to ask a human first is entitled to the
                   blunt answer. */
                "destructiveHint": true,
                /* No intention is: a second mkdir or move collides, a second
                   trash of the same path finds nothing, and a second restore
                   has nothing left in the Trash to move. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    /// The item, or where a restore lands. Never `guestRoot` itself — the
    /// empty path means the root everywhere else in this family, and the
    /// root is not something an agent may move, trash or recreate.
    private static var mutationPath: [String: Any] {
        var path = GuestFilesSchema.path
        path["minLength"] = 1
        path["description"] =
            "The item, root-relative and never empty. For a restore, where "
            + "it is going back to."
        return path
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              let request = mutation(arguments) else {
            return .invalidArguments(
                "now_guest_files_mutate requires one bounded root-relative path and one of move (with toPath), trash, restore (with trashedAs) or mkdir")
        }
        return .value(.init(await client.mutateGuestFile(request)))
    }

    /// One intention, its own key set, and nothing else — the shape the
    /// local wire's own branch established, restated here so a refusal
    /// reaches the caller as a sentence rather than as a transport error.
    ///
    /// A crossed form is refused rather than ignored: `trashedAs` on a move
    /// is a caller that believes it is doing something else, and the one
    /// thing worse than refusing it is performing the move.
    private static func mutation(
        _ arguments: [String: Any]
    ) -> AgentIntegrationGuestFileMutationRequest? {
        guard Set(arguments.keys).isSubset(of: acceptedArguments),
              let intention = arguments["mutation"] as? String,
              let mutation = AgentIntegrationGuestFileMutation(
                rawValue: intention),
              let path = arguments["path"] as? String
        else { return nil }
        let destination = arguments["toPath"]
        let trashed = arguments["trashedAs"]
        switch mutation {
        case .move:
            guard let toPath = destination as? String, trashed == nil
            else { return nil }
            return .move(path: path, toPath: toPath)
        case .restore:
            guard let trashedAs = trashed as? String, destination == nil
            else { return nil }
            return .restore(trashedAs: trashedAs, toPath: path)
        case .trash:
            guard destination == nil, trashed == nil else { return nil }
            return .trash(path: path)
        case .mkdir:
            guard destination == nil, trashed == nil else { return nil }
            return .makeFolder(path: path)
        }
    }
}
