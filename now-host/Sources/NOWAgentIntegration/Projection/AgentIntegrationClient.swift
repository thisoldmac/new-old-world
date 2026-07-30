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
///
/// **A NEW METHOD HERE ARRIVES WITH ITS DEFAULT, IN THE SAME EDIT.** Add the
/// requirement below and a default in the extension underneath, returning
/// "no host" — the truthful answer for a client that has none, and what the
/// upload trio, the capture trio and `bringToFront` all do.
///
/// The nine oldest methods have no default and are implemented by every
/// conformer; that is history, not the pattern to copy. Seven stub clients
/// across the test tree conform to this protocol and implement only the lanes
/// their own tests exercise, so a requirement without a default is seven
/// compile errors in seven files named for other capabilities.
///
/// **No test can catch this, and it is worth knowing why rather than looking
/// for the gate.** The omission breaks the compilation of the test target
/// itself, so it fails before any test in the tree runs; a canary type
/// conforming here would only add an eighth error to the same build failure.
/// The mechanism is this paragraph, sitting where the method gets typed.
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
    /// Measure what a whole-volume application search costs on the connected
    /// machine. No parameters, because the guest's `catsearch` takes none:
    /// the volume is the guest's own startup volume and the sweep's shape is
    /// the guest's. See `CatalogSearchProjection` for the cost and the scope.
    func catalogSearch() async -> AgentIntegrationGuestRowReportResult
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

    /// Defaulted with the trio and `bringToFront`, and arriving in the same
    /// edit as the requirement above — the rule at the top of this file.
    public func catalogSearch() async
        -> AgentIntegrationGuestRowReportResult {
        .hostUnavailable
    }

    /// Nothing to address: this client answers "no host" to everything.
    public func addressing(_ selector: String?) -> AgentIntegrationClient {
        self
    }
}
