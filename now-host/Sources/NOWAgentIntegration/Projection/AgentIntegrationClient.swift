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
    /// Run one named diagnostic on the connected machine.
    ///
    /// One method for three capabilities, matching the one local operation
    /// P1a landed: none of the three takes an argument and all three answer
    /// the same row shape, so the probe is the whole request. **The three
    /// ROWS stay separate** — they are served by different guests, and
    /// availability is a property of a row (see
    /// `GuestDiagnosticsProjection`); what is shared is the lane, not the
    /// question.
    func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe) async
        -> AgentIntegrationGuestRowReportResult
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
    /// Open the live-stream bracket, on this caller's behalf.
    ///
    /// **The caller's identity is not a parameter and must not become one.**
    /// The host reads it off the accepted socket (`LOCAL_PEERPID`), which is
    /// the kernel's answer rather than a peer's claim — the same rule the uid
    /// gate keeps. An owner a caller could name is an owner a caller could
    /// name as somebody else.
    func startGuestStream(depth: Int, minIntervalMs: Int) async
        -> AgentIntegrationStreamResult
    /// Ask the open bracket for a whole frame and return its first page.
    /// Paged for capture's reason and by capture's machinery: a screen does
    /// not fit in one 16 KiB local response.
    func nextGuestStreamFrame() async -> AgentIntegrationStreamResult
    func fetchGuestStreamFramePage(frameID: UUID, offset: Int) async
        -> AgentIntegrationStreamResult
    /// Close the bracket. Not restricted to the agent that opened it: ending
    /// a stream is the one direction that needs no standing, and the person
    /// at the host can already do it from the page they watch it on.
    func stopGuestStream() async -> AgentIntegrationStreamResult
    /// Act on one addressed window — move, resize, zoom or close — by
    /// answering the owning application's own `FindWindow`. The reference is
    /// the caller's; the guest revalidates it against a live window before
    /// anything is dispatched. See `WindowActProjection`.
    func windowAct(_ request: AgentIntegrationWindowActRequest) async
        -> AgentIntegrationWindowActResult
    /// Read one addressed text element. See `TextGetProjection`.
    func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult
    /// Replace one addressed text element's contents. A replacement and not
    /// an append: there is no offset form. See `TextSetProjection`.
    func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult
    /// Act on one addressed control by answering the owning application's own
    /// `TrackControl` with a part code, so the application runs its real
    /// mouse-down handler. See `ControlActProjection`.
    func controlAct(_ request: AgentIntegrationControlActRequest) async
        -> AgentIntegrationControlActResult
    /// Perform one menu command by answering the owning application's own
    /// `MenuSelect`. Nothing is drawn and no tracking loop runs, so an item
    /// with no keyboard shortcut becomes reachable. See `MenuActProjection`.
    func menuAct(_ request: AgentIntegrationMenuActRequest) async
        -> AgentIntegrationMenuActResult
    /// Walk one process's on-screen elements and mint a reference for each.
    /// Nil observes the frontmost application, which is the contract's own
    /// default — and is a default for the WALK, never for an act: nothing
    /// downstream of this may address "whatever is frontmost". See
    /// `ObserveElementsProjection`.
    func observeElements(process: AgentIntegrationProcessSerial?) async
        -> AgentIntegrationElementObservationResult
    /// Read the immutable state already owned by the native Mirror. All four
    /// MCP projections share this one transport-neutral lane; none may start
    /// another guest observer or maintain another cache.
    func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult
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

    /* The four stream lanes, declared with their defaults in the one edit,
       per the rule at the top of this file. "No host" and not a closed
       bracket: a closed bracket is a claim that a lane exists and is free,
       and a client with nothing to ask has no lane at all. */

    public func startGuestStream(depth: Int, minIntervalMs: Int) async
        -> AgentIntegrationStreamResult {
        .hostUnavailable
    }

    public func nextGuestStreamFrame() async
        -> AgentIntegrationStreamResult {
        .hostUnavailable
    }

    public func fetchGuestStreamFramePage(frameID: UUID, offset: Int) async
        -> AgentIntegrationStreamResult {
        .hostUnavailable
    }

    public func stopGuestStream() async -> AgentIntegrationStreamResult {
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

    /// Declared with its default in the one edit, per the rule at the top of
    /// this file. "No host" and not an empty report: an empty row set would
    /// say a machine ran a diagnostic and measured nothing, which is a claim
    /// about a Macintosh nobody reached — and for `putstat`, whose zeroes are
    /// a real answer, it would be indistinguishable from one.
    public func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe) async
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

    /* The three act lanes, promoted from extension methods to requirements
       in the fold that registered their rows (2026-07-31), with the bodies
       they already had as their defaults — per the rule at the top of this
       file, and breaking no conformer.

       ONE THING CHANGED WITH THE PROMOTION, and it is the reason this is
       not a pure move. The old bodies answered `.hostUnavailable`, which
       was true of every client that could reach them: nothing was
       registered, so only stub clients with no host called these. A
       registered row is reachable from the real local client, where the app
       is running and a Macintosh is connected — and "New Old World host is
       unavailable" is then a false sentence about a host that is up. The
       reason is now `noActLane`, which says what is actually missing. The
       OUTCOME is unchanged and deliberately so: typed `unavailable`, never
       a refusal and never an empty success.

       CORRECTED 2026-08-01 — the last paragraph used to read "these stay
       defaults, and no conformer overrides one, because there is still no
       host lane to carry an act. The day one lands, the local client
       implements the three and these defaults keep the stub conformers in
       the test tree compiling."

       That day is this one, and the sentence held exactly as written: the
       local protocol grew `window_act`, `control_act`, `menu_act`,
       `text_get` and `text_set`; `AgentIntegrationLocalClient` implements
       all five; and `SocketAgentIntegrationClient` overrides them. These
       bodies are now the answer for the SEVEN STUB CONFORMERS ONLY, which
       is what they were reserved for, and `noActLane` is no longer reachable
       from the real local client.

       They are kept rather than deleted for that reason, and the reason is
       worth stating because "no host lane" now reads like stale text: a stub
       named for another capability has no host at all, and a requirement
       without a default is seven compile errors in seven files. What a stub
       must NOT answer is an empty success. */

    public func windowAct(
        _ request: AgentIntegrationWindowActRequest
    ) async -> AgentIntegrationWindowActResult {
        .unavailable(.noActLane(
            AgentIntegrationCapabilityNames.windowActCommand))
    }

    public func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult {
        .unavailable(.noActLane(
            AgentIntegrationCapabilityNames.textGetCommand))
    }

    public func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult {
        .unavailable(.noActLane(
            AgentIntegrationCapabilityNames.textSetCommand))
    }

    /* The two acts added beside `winact` on 2026-07-31, and the observation
       that mints what all of them take. Same defaults, same reason: the
       PowerPC guest now serves all three verbs, and this host still carries
       no lane to ask them down. That the guest half exists and this one does
       not is precisely what these two codes distinguish — a caller reading
       `now-act-lane-absent` or `now-observation-lane-absent` has been told
       the missing piece is HERE, which is a different thing from a machine
       that answered "I do not serve that". */

    public func controlAct(
        _ request: AgentIntegrationControlActRequest
    ) async -> AgentIntegrationControlActResult {
        .unavailable(.noActLane(
            AgentIntegrationCapabilityNames.controlActCommand))
    }

    public func menuAct(
        _ request: AgentIntegrationMenuActRequest
    ) async -> AgentIntegrationMenuActResult {
        .unavailable(.noActLane(
            AgentIntegrationCapabilityNames.menuActCommand))
    }

    /// The observation, and its own reason rather than the acts': nothing
    /// here acts, so "no act lane" would be a sentence about the wrong half.
    public func observeElements(
        process: AgentIntegrationProcessSerial?
    ) async -> AgentIntegrationElementObservationResult {
        .unavailable(.noObservationLane(
            AgentIntegrationCapabilityNames.elementsCommand))
    }

    public func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        .init(unavailable: .init(
            code: "now-mirror-state-lane-absent",
            message: "This client cannot read the host Mirror state engine"))
    }

    /// Nothing to address: this client answers "no host" to everything.
    public func addressing(_ selector: String?) -> AgentIntegrationClient {
        self
    }
}
