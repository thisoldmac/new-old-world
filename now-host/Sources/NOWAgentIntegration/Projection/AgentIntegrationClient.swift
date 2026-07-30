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
    /// One page of one hardware-census probe. The probe is required and
    /// there is no all-probes form: fourteen calls summed here would be an
    /// answer this side composed. The page's own outcome is a fact about the
    /// machine and is never flattened into this call's — see
    /// `HardwareCensusProjection`.
    func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult
    /// One page of one software domain. The domain is required and there is
    /// no all-domains form: five calls summed here would be an inventory this
    /// side composed. The cursor is 1-based and 1 rebuilds the guest's cache
    /// — for `apps` that is a whole-volume sweep, so absent and 0 are NOT the
    /// same request. See `SoftwareInventoryProjection`.
    func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult
    func listProcesses() async -> AgentIntegrationProcessListResult
    func launchSoftware(_ selection: AgentIntegrationLaunchSelection) async
        -> AgentIntegrationLaunchSoftwareResult
    func requestQuit(reference: String) async -> AgentIntegrationQuitResult
    /// Bring one recently observed process forward. The same reference
    /// vocabulary as `requestQuit`, revalidated the same way — a PSN is
    /// meaningful only while the process it names lives.
    func bringToFront(reference: String) async
        -> AgentIntegrationFrontResult
    /// Show one item in the guest's own Finder. The target is a full HFS
    /// path or an item name; the answer is the guest's own rows, and a
    /// completed one means the machine was asked rather than that the
    /// Finder obeyed — `RevealItemProjection` says why in full.
    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult
    /// The connected machine's own account of itself — the `gestalt` verb.
    ///
    /// **No parameter, and none to invent.** The contract is explicit that a
    /// typed call with no `line` "always returns every group", so one call
    /// carries the whole answer; a group selector would only narrow an answer
    /// that already arrived, and the group grammar (`--cpu`, `--full`) is the
    /// console's line, whose presence is what tells the guest a human is
    /// typing. See `MachineFactsProjection`.
    func machineFacts() async -> AgentIntegrationGuestRowReportResult
    /// The end of the guest's own log for this launch. `lines` is a count,
    /// never a file: the verb names nothing on the disk and this side must
    /// not invent a way for it to — see `GuestLogTailProjection`. Absent
    /// means the verb's own default.
    func tailGuestLog(lines: Int?) async
        -> AgentIntegrationGuestRowReportResult
    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult
    func guestFilesCapabilities() async
        -> AgentIntegrationGuestFileCapabilitiesResult
    func listGuestFiles(path: String, cursor: Int?) async
        -> AgentIntegrationGuestFileListResult
    func statGuestFile(path: String) async
        -> AgentIntegrationGuestFileStatResult
    /// Pull one bounded file off the machine into host-owned private
    /// storage. The caller names what to fetch and never where it lands —
    /// the mirror of the upload lane, which takes bytes and never a host
    /// path. See `GuestFilesDownloadProjection`.
    func downloadGuestFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult
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
    /// End the transfer in flight, in whichever direction it is going.
    ///
    /// No parameter, and none is available to invent: the lane is one
    /// transfer wide across BOTH directions (contract, `cancel`), so "the
    /// transfer" is never ambiguous — and the transfer id the wire message
    /// carries is this host's own, never a caller's to hold.
    func cancelTransfer() async -> AgentIntegrationTransferCancelResult
    /// Move, trash, restore or create one item beneath `guestRoot`. Four
    /// intentions on one method because they are one lane: they share the
    /// path space, the one `file.result` code vocabulary and one
    /// authorization, and `restore` consumes what `trash` answered.
    func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult
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
    /// Defaulted in the same edit that declared it, per the rule at the top
    /// of this file. "No host" and not an empty page: an empty page would
    /// carry an `outcome`, and every value in that vocabulary is a claim
    /// about a Macintosh nobody asked.
    public func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        .hostUnavailable
    }

    /// Declared with its default in the one edit, per the rule at the top of
    /// this file. "No host" and not an empty page: an empty listing reads as
    /// "nothing is installed on that Mac", which is a claim about a machine
    /// nobody reached.
    public func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult {
        .hostUnavailable
    }

    /// Defaulted with the guest-files lanes below it, and for the same
    /// reason: a client with no host to ask answers "no host" rather than
    /// making seven stub conformers in the test tree learn a new lane.
    public func downloadGuestFile(path: String) async
        -> AgentIntegrationGuestFileDownloadResult {
        .hostUnavailable(.host)
    }

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

    /// Defaulted with the trio above, and in the same edit that declared it:
    /// a client with no host to ask answers "no host" rather than making
    /// seven stub files in seven other capabilities' tests learn this lane.
    public func mutateGuestFile(
        _ mutation: AgentIntegrationGuestFileMutationRequest
    ) async -> AgentIntegrationGuestFileMutationResult {
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

    /// Defaulted in the same edit that added the requirement, per the rule
    /// at the top of this file: seven stub clients across the test tree
    /// implement only their own lanes, and a requirement without a default
    /// is seven compile errors in seven files named for other capabilities.
    public func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        .hostUnavailable
    }

    /// Declared with its default in the one edit, per the rule at the top of
    /// this file. "No host" and not an empty report: an empty set of groups
    /// would say a Macintosh was asked what it is and had nothing to say,
    /// which is a claim about a machine nobody reached.
    public func machineFacts() async
        -> AgentIntegrationGuestRowReportResult {
        .hostUnavailable
    }

    /// Declared with its default in the one edit, per the rule at the top of
    /// this file. "No host" and not an empty tail: a client with nothing to
    /// ask has not read a quiet log, and an empty answer would be a claim
    /// about a machine nobody reached.
    public func tailGuestLog(lines: Int?) async
        -> AgentIntegrationGuestRowReportResult {
        .hostUnavailable
    }

    /// Defaulted with the trio, `bringToFront` and `revealItem`, and
    /// arriving in the same edit as the requirement above — the rule at the
    /// top of this file.
    public func catalogSearch() async
        -> AgentIntegrationGuestRowReportResult {
        .hostUnavailable
    }

    /// Same reason again, and one more that is specific to this lane: "no
    /// host" is the only truthful answer a client with no host can give
    /// about a transfer, and `nothingToCancel` — which would also be
    /// harmless-looking — would assert that a machine nobody asked was
    /// quiet.
    public func cancelTransfer() async
        -> AgentIntegrationTransferCancelResult {
        .hostUnavailable
    }

    /// Nothing to address: this client answers "no host" to everything.
    public func addressing(_ selector: String?) -> AgentIntegrationClient {
        self
    }
}
