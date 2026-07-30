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
    /// Bring one recently observed process forward. The same reference
    /// vocabulary as `requestQuit`, revalidated the same way — a PSN is
    /// meaningful only while the process it names lives.
    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult
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
    /// Ask the paired guest for its screen, and get back the first page of
    /// the result. Three calls rather than one because the answer is an
    /// image: the local request/response cap is 16 KiB, so a screen crosses
    /// in pages, and the paging is the projection's business rather than any
    /// caller's — see `CaptureScreenProjection`.
    func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult
    func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult
    /// Abandon the host's wait for a capture in flight, releasing the
    /// connection's one transfer lane.
    func abandonGuestCapture() async -> AgentIntegrationCaptureResult
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

    /* Defaulted for the same reason the upload trio is: a client that has no
       host to ask answers "no host" without every stub in the tree having to
       learn a new lane. */
    public func requestGuestCapture(depth: Int?) async
        -> AgentIntegrationCaptureResult {
        .hostUnavailable
    }

    public func fetchGuestCapturePage(captureID: UUID, offset: Int) async
        -> AgentIntegrationCaptureResult {
        .hostUnavailable
    }

    public func abandonGuestCapture() async
        -> AgentIntegrationCaptureResult {
        .hostUnavailable
    }

    /// Defaulted for the same reason as the trio above: a stub client with
    /// no host to ask answers "no host" without every conformer in the tree
    /// learning a new lane the day one lands.
    public func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult {
        .hostUnavailable
    }

    /// Nothing to address: this client answers "no host" to everything.
    public func addressing(_ selector: String?) -> AgentIntegrationClient {
        self
    }
}
