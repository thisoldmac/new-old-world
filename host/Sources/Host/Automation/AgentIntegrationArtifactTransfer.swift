import Foundation
import NOWAgentIntegration

/// Redeems one host-minted approval into the existing file put lane.
@MainActor
final class AgentIntegrationArtifactTransfer {
    private let listener: GuestListener
    private let approvals: AgentIntegrationArtifactApprovalStore?
    private let currentSessionID: @MainActor () -> UUID?
    private var transferInFlight = false

    init(
        listener: GuestListener,
        approvals: AgentIntegrationArtifactApprovalStore?,
        currentSessionID: @escaping @MainActor () -> UUID?
    ) {
        self.listener = listener
        self.approvals = approvals
        self.currentSessionID = currentSessionID
    }

    func transfer(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        guard !transferInFlight else {
            return refused(
                "now-artifact-transfer-busy",
                "Another approved artifact transfer is in progress")
        }
        guard let approvals else {
            return .failed(.init(
                code: "now-artifact-approval-unavailable",
                message: "Artifact approval staging is unavailable"))
        }
        transferInFlight = true
        defer { transferInFlight = false }

        let artifact: AgentIntegrationRedeemedArtifact
        switch approvals.redeem(receipt: receipt, sessionID: sessionID) {
        case .artifact(let value):
            artifact = value
        case .expired(let failure):
            return .expired(failure)
        case .refused(let failure):
            return .refused(failure)
        case .failed(let failure):
            return .failed(failure)
        }
        guard currentSessionID() == sessionID else {
            return .expired(.init(
                code: "now-artifact-session-expired",
                message:
                    "The guest session changed before transfer could begin"))
        }

        let put = await put(artifact)
        guard currentSessionID() == sessionID else {
            return .failed(.init(
                code: "now-artifact-outcome-unknown",
                message:
                    "The guest session changed while transfer was in progress"))
        }
        switch put {
        case .success(let wireReceipt):
            return .delivered(.init(
                transferID: UUID(),
                sessionID: sessionID,
                approvedAt: artifact.approvedAt,
                redeemedAt: artifact.redeemedAt,
                acknowledgedAt: wireReceipt.acknowledgedAt,
                name: AgentIntegrationBoundedText.prefix(
                    artifact.plan.name,
                    scalars:
                        AgentIntegrationArtifactPolicy.maximumNameScalars),
                source: artifact.source,
                handedToNOW: artifact.handedToNOW,
                container: artifact.plan.container,
                conversion: artifact.plan.note.map {
                    AgentIntegrationBoundedText.prefix(
                        $0,
                        scalars:
                            AgentIntegrationArtifactPolicy
                                .maximumMessageScalars)
                },
                guestAcknowledgedWrite: true,
                destinationBytesVerified: false,
                guestMessage:
                    "The paired guest acknowledged writing the approved artifact"))
        case .failure(let failure) where failure.code == "disconnected":
            return .unavailable(.guest)
        case .failure(let failure) where failure.code == "exists":
            return refused(
                "now-artifact-destination-exists",
                "A guest artifact with that approved name already exists")
        case .failure(let failure) where failure.code == "busy":
            return refused(
                "now-artifact-transfer-busy",
                "The existing New Old World transfer lane is busy")
        case .failure(let failure) where failure.code == "cancelled":
            return refused(
                "now-artifact-transfer-cancelled",
                "The approved artifact transfer was cancelled")
        case .failure(let failure) where failure.code == "timeout":
            return .failed(.init(
                code: "now-artifact-outcome-unknown",
                message:
                    "The paired guest did not acknowledge the artifact write"))
        case .failure:
            return .failed(.init(
                code: "now-artifact-write-failed",
                message: "The paired guest did not write the approved artifact"))
        }
    }

    private func put(_ artifact: AgentIntegrationRedeemedArtifact) async
        -> Result<GuestListener.PutReceipt, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.putFileWithReceipt(
                name: artifact.plan.name,
                into: artifact.destination,
                container: artifact.plan.container,
                bytes: artifact.plan.bytes,
                fileType: artifact.plan.fileType,
                creator: artifact.plan.creator,
                modified: artifact.modified,
                overwrite: false
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationArtifactTransferResult {
        .refused(.init(code: code, message: message))
    }
}
