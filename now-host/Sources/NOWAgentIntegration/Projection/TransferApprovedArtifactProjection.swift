import Foundation

/// Redemption of one host-minted, one-use transfer approval.
///
/// The authorization is not in this projection: a native Files action mints
/// the receipt, and all this may do is refuse a receipt that is malformed,
/// expired, already redeemed, or bound to another session. It accepts no
/// path and cannot mint an approval of its own.
public enum TransferApprovedArtifactProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_transfer_approved_artifact")

    public static let requires =
        [AgentIntegrationCapabilityNames.filePut]

    /* The put lane, which the caller directs — it names the receipt and the
       guest gains the file. That the destination was fixed when the receipt
       was minted bounds the ask; it does not make the capability internal. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.filePut]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(because:
            "The app UI is the GRANT side of this capability, not the "
            + "redeeming side: Files offers \"Approve One-Time Agent "
            + "Transfer…\", which stages one private copy and hands out a "
            + "receipt. Redeeming that receipt is the agent's half by "
            + "construction — a person with a file to send uses Add File… "
            + "(now_guest_files_upload_commit) and needs no receipt, and a "
            + "button that redeemed the app's own grant would be the app "
            + "approving on the human's behalf, which is the one thing the "
            + "approval exists to prevent."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest accepts a host-driven put."

    public static var mcpDescriptor: [String: Any] {
        let failure: [String: Any] = [
            "type": "object",
            "properties": [
                "code": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy
                            .maximumFailureCodeScalars,
                ],
                "message": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
            ],
            "required": ["code", "message"],
            "additionalProperties": false,
        ]
        let evidence: [String: Any] = [
            "type": "object",
            "properties": [
                "sha256": [
                    "type": "string",
                    "pattern": "^[0-9a-f]{64}$",
                ],
                "bytes": [
                    "type": "integer",
                    "minimum": 0,
                    "maximum":
                        AgentIntegrationArtifactPolicy.maximumSourceBytes,
                ],
            ],
            "required": ["sha256", "bytes"],
            "additionalProperties": false,
        ]
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "transferID": ["type": "string", "format": "uuid"],
                "sessionID": ["type": "string", "format": "uuid"],
                "approvedAt": ["type": "string", "format": "date-time"],
                "redeemedAt": ["type": "string", "format": "date-time"],
                "acknowledgedAt": [
                    "type": "string", "format": "date-time",
                ],
                "name": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumNameScalars,
                ],
                "source": evidence,
                "handedToNOW": evidence,
                "container": [
                    "type": "string",
                    "enum": ["data", "macbinary"],
                ],
                "conversion": [
                    "type": ["string", "null"],
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
                "guestAcknowledgedWrite": ["const": true],
                "destinationBytesVerified": ["const": false],
                "guestMessage": [
                    "type": "string",
                    "maxLength":
                        AgentIntegrationArtifactPolicy.maximumMessageScalars,
                ],
            ],
            "required": [
                "transferID", "sessionID", "approvedAt", "redeemedAt",
                "acknowledgedAt", "name", "source", "handedToNOW",
                "container", "guestAcknowledgedWrite",
                "destinationBytesVerified", "guestMessage",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Transfer an Approved New Old World Artifact",
            "description":
                "Redeems one unexpired, one-use approval minted by a native New Old World host action. The receipt already fixes one private staged file and guest destination. The tool accepts no path, never overwrites, and reports success only after the paired guest acknowledges writing the file.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "approvalReceipt": [
                        "type": "string",
                        "pattern":
                            AgentIntegrationArtifactPolicy.receiptPattern,
                    ],
                ],
                "required": ["approvalReceipt"],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("delivered", "delivered", receipt),
                    variant("unavailable", "unavailable", failure),
                    variant("expired", "expired", failure),
                    variant("refused", "refused", failure),
                    variant("failed", "failed", failure),
                ],
            ],
            "annotations": [
                "readOnlyHint": false,
                "destructiveHint": true,
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        guard let arguments = arguments.object,
              Set(arguments.keys) == ["approvalReceipt"],
              let receipt = arguments["approvalReceipt"] as? String,
              AgentIntegrationArtifactPolicy.isValidReceipt(receipt)
        else {
            return .invalidArguments(
                "now_transfer_approved_artifact requires one host-minted approval receipt")
        }
        return .value(.init(
            await client.transferApprovedArtifact(receipt: receipt)))
    }
}
