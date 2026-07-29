import Foundation

/// How a projection reaches the running host.
///
/// It lives beside the projections rather than in the companion executable
/// because a projection is defined by what it may ask the host for, and the
/// same definition has to be readable by every face that renders it.
///
/// Nothing here reads guest identity, and nothing that decides what a call
/// may do is allowed to: availability follows from what the connected guest
/// answers, never from which guest it is
/// (`AgentIntegrationCapabilityTests.testNoCompanionCodeBranchesOnGuestIdentity`).
public protocol AgentIntegrationClient: Sendable {
    /// Which machine the calls that follow are about. One method rather
    /// than a parameter on every other one: the selector is orthogonal to
    /// all of them, and a default implementation lets a client that has
    /// no host to ask ignore it.
    func addressing(_ selector: String?) -> AgentIntegrationClient
    func sessionHealth() async -> AgentIntegrationSessionHealthResult
    func sessionCapabilities(probeCostly: Bool) async
        -> AgentIntegrationSessionCapabilitiesResult
    func listProcesses() async -> AgentIntegrationProcessListResult
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult
    func requestQuit(reference: String) async -> AgentIntegrationQuitResult
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult
    func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult
    func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult
    func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult
}

extension AgentIntegrationClient {
    public func beginGuestFileUpload(
        _ upload: AgentIntegrationGuestFileUploadBegin
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        .hostUnavailable(.host)
    }

    public func appendGuestFileUpload(
        uploadID: UUID, offset: Int, bytes: Data
    ) async -> AgentIntegrationGuestFileUploadStageResult {
        .hostUnavailable(.host)
    }

    public func commitGuestFileUpload(uploadID: UUID) async
        -> AgentIntegrationGuestFileUploadCommitResult {
        .hostUnavailable(.host)
    }

    /// Nothing to address: this client answers "no host" to everything.
    public func addressing(_ selector: String?) -> AgentIntegrationClient {
        self
    }
}
