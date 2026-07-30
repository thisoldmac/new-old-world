import Foundation

/// End the file transfer in flight, in whichever direction it is going.
///
/// **It takes no argument, and inventing one would be worse than the
/// asymmetry it would tidy.** The lane is one transfer wide across BOTH
/// directions — the contract says so where it declares the `cancel` verb, and
/// both guests are written to it: the 68K guest's handler acts on a cancel
/// even for a transfer whose id it never learned — its own reason being that
/// one transfer wide leaves "the transfer" unambiguous, and that refusing to
/// cancel over a missing field would leave standing the very wedge the
/// handler exists to prevent (`wire68.c :: cancel_in_flight`). The `transfer` integer the wire message
/// carries is this host's own sequence number, minted per transfer in
/// `Session`; it has never been a caller's to hold, and a tool that took one
/// would be asking a caller to name something it can only have guessed.
///
/// **Why it is not part of the download.** P1a refused to merge it, and the
/// reason is the same sentence: a cancel ends a transfer in EITHER direction,
/// so folding it into a download would have left an upload — the transfer the
/// download lane knows nothing about — with nothing that can end it. That is
/// the one transfer most likely to need ending, since the host is its sender
/// and a stalled send is what wedges the lane.
///
/// **Success means `asked`, and this row will not say `cancelled`.**
/// `file.cancel` has no reply in the contract, deliberately. The terminal
/// message each guest sends for a transfer it cancelled is discarded by this
/// host on purpose — waiting for it is the park that wedged the lane — so
/// nothing here can confirm the Macintosh stopped, and the confirming read
/// `BringToFrontProjection` earns from a second `process.list` has no
/// equivalent: neither guest serves a "what is in flight" question, and the
/// one thing that would settle it is the reply the contract does not define.
/// What IS confirmed is this host's own half, re-read rather than assumed and
/// reported as `hostLaneFree`.
///
/// **It may cancel a transfer a PERSON started, and does.** Rule 3 in
/// reverse: the risk here is not an agent capability a person cannot reach —
/// the Files page has had a Cancel button throughout — it is a person's
/// action ended invisibly by an agent. Refusing would be worse than the risk:
/// the host does not record who started the transfer holding the lane, so a
/// row that refused what it could not attribute could never cancel anything,
/// and the case that most needs ending is a stalled transfer on a machine
/// that will otherwise refuse every later one. So it is allowed, and the
/// visibility is paid for instead: beside the dispatch's audit line, the host
/// writes a `files` line at warn naming the direction, how far it had got,
/// and that it does not know who started it.
public enum TransferCancelProjection: HostProjection {
    public static let capability = HostCapabilityID("now_transfer_cancel")

    /* One requirement, and it is the MESSAGE on both guests rather than the
       68K guest's `cancel` verb. The verb is that machine's console face on
       the same body; requiring it would make a capability both guests serve
       read as 68K-only, which rule 4 refuses — degrade the answer, not the
       message. */
    public static let requires = [
        AgentIntegrationCapabilityNames.fileCancel,
    ]

    /* Exposed, not merely consumed: a caller directs the effect, which is
       the whole of what this capability is. */
    public static let exposes = [
        AgentIntegrationCapabilityNames.fileCancel,
    ]

    /* The Files page's Cancel button, on the transfer bar. It predates this
       row: `FilesModel.cancelTransfer()` reaches the same
       `GuestListener.cancelFile()`, which is why rule 3 costs this
       capability nothing on the initiable half. */
    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "FilesModuleView.swift",
                         symbol: "model.cancelTransfer()"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves file.cancel."

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "outcome": [
                    "type": "string",
                    "enum": AgentIntegrationTransferCancelOutcome.allCases
                        .map(\.rawValue),
                    "description":
                        "asked means this host has stopped and the guest has been told, for any transfer it had begun; it is NOT a report that the guest stopped, because the message has no reply. nothing-to-cancel means no transfer was in flight and nothing was sent.",
                ],
                "direction": [
                    "type": "string",
                    "enum": AgentIntegrationTransferCancelReport.Direction
                        .allCases.map(\.rawValue),
                    "description":
                        "Which way the cancelled transfer was going. Absent when there was none.",
                ],
                "confirmedBytes": ["type": "integer"],
                "expectedBytes": ["type": "integer"],
                "hostLaneFree": [
                    "type": "boolean",
                    "description":
                        "The one checked fact: the lane was re-read after the cancel and this host holds no transfer. False is a defect, not an expected outcome.",
                ],
                "note": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationTransferCancelPolicy
                            .maximumNoteScalars,
                ],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["outcome", "hostLaneFree", "observedAt"],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Cancel the New Old World File Transfer in Flight",
            "description":
                "Ends the file transfer running between this Mac and the connected classic Macintosh, in whichever direction it is going — the wire has one transfer lane across both, so it takes no argument. The answer distinguishes a cancel that was ASKED from a transfer that stopped: this message has no reply by contract, so what is confirmed is that this host stopped, never that the guest did. A cancel with nothing in flight is answered, not refused. It can end a transfer the person at this Mac started; when it does, the host writes a line they can read.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", "completed", receipt),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                /* Destructive, and the honest reading of a word the MCP
                   defines loosely. Nothing is deleted here by this host —
                   but an interrupted transfer loses whatever work it had
                   done, the receiving guest discards its partial, and the
                   transfer it ends may be a person's. A caller deciding
                   whether to ask twice should be told that. */
                "destructiveHint": true,
                /* Asking again is safe and answers differently on purpose:
                   the second call finds a quiet lane and says
                   nothing-to-cancel. Same state, different answer, so not
                   idempotent by this protocol's definition. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.cancelTransfer()))
    }
}

/// The bound on this row's own sentence.
///
/// Its `note` is written HERE — it is never a guest's words, because a
/// cancel has no reply to carry any — and it is the longest of them, so the
/// cap is stated where the schema and the writer can both read it rather
/// than guessed at by either.
public enum AgentIntegrationTransferCancelPolicy {
    public static let maximumNoteScalars = 512
}
