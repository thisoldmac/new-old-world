import Foundation
import NOWAgentIntegration

/// The in-process, narrow boundary exposed by the optional local adapter.
///
/// This owns no listener lifecycle. Guest-dependent projections route only
/// through the live listener, preventing a companion process from becoming a
/// second owner of the guest connection.
@MainActor
final class AgentIntegrationHostAdapter {
    private let listener: GuestListener
    private let launchCommandTimeout: TimeInterval
    /// Injected for the same reason as the launch timeout beside it: the real
    /// one is 42 s, and a test that had to wait it out to prove the timeout
    /// path is a test nobody runs.
    private let catalogSearchTimeout: TimeInterval
    /// Injected for the reason the two above are, and one of its own: this
    /// bound is the ONLY watchdog on a `vprobe`, since the guest has none.
    private let diagnosticsTimeout: TimeInterval
    private let artifactApprovals: AgentIntegrationArtifactApprovalStore?
    private let mirrorEngines: MirrorStateEngineRegistry?
    private lazy var processControl = AgentIntegrationProcessControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        currentGuest: { [unowned self] in activeReference() })
    private lazy var softwareLaunch = AgentIntegrationSoftwareLaunch(
        listener: listener,
        commandTimeout: launchCommandTimeout,
        currentSessionID: { [unowned self] in connectedSessionID() })
    /// Beside the launch control, which consumes the same family and hands
    /// back none of it — this one is the family's own caller.
    private lazy var softwareInventoryControl =
        AgentIntegrationSoftwareInventory(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var revealControl = AgentIntegrationRevealItem(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var logTailControl = AgentIntegrationGuestLogTail(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var machineFactsControl = AgentIntegrationMachineFacts(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var censusControl = AgentIntegrationCensus(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var capabilityLedger = AgentIntegrationCapabilityLedger(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var captureControl = AgentIntegrationCaptureControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    /* Beside the capture control, because it is the same lane seen the other
       way round: one picture now, or the bracket that produces them until
       somebody stops it. The ownership rule that makes the second safe lives
       in the control, not here. */
    private lazy var streamControl = AgentIntegrationStreamControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var transferControl = AgentIntegrationTransferControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var catalogSearch = AgentIntegrationCatalogSearch(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        commandTimeout: catalogSearchTimeout)
    /* Beside the catalog search, because it is the same kind of thing: a
       measurement of the machine, bounded here because the guest does not
       bound it. Injected timeout for the same reason as the two above — the
       real one is 40 s and a test that waited it out is a test nobody
       runs. */
    private lazy var diagnostics = AgentIntegrationDiagnostics(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        commandTimeout: diagnosticsTimeout)
    /* The act lane. Beside the reveal control rather than the capture one,
       because it is the same kind of thing: a bounded command.request to the
       guest's ordinary dispatch, not a bulk transfer that has to hold a lane
       — see the head of `AgentIntegrationActControl` for why an act must not
       contend with the stream that draws the scene it is acting on. */
    private lazy var actControl = AgentIntegrationActControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        sendCommand: { [unowned self] verb, args, completion in
            self.listener.runScheduledCommand(
                verb, typed: args, purpose: .interaction(verb),
                workClass: .humanInteractive, completion: completion)
        })
    private lazy var artifactTransfer = AgentIntegrationArtifactTransfer(
        listener: listener,
        approvals: artifactApprovals,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var mirrorState = mirrorEngines.map { engines in
        MirrorStateProjectionService(
            engines: engines,
            currentGuest: { [unowned self] in self.listener.activeKey },
            metrics: { [unowned self] in self.mirrorMetrics?() ?? nil },
            lifecycle: { [unowned self] in self.mirrorLifecycle?() ?? nil })
    }
    /// Bound after construction because the Mirror source is made lazily and
    /// owns the timelines; this service only reads them.
    private var mirrorMetrics: (() -> AgentIntegrationMirrorMetrics?)?

    private var mirrorLifecycle: (() -> AgentIntegrationMirrorLifecycle?)?

    func bindMirrorLifecycle(
        _ read: @escaping () -> AgentIntegrationMirrorLifecycle?) {
        mirrorLifecycle = read
    }

    func bindMirrorMetrics(
        _ read: @escaping () -> AgentIntegrationMirrorMetrics?) {
        mirrorMetrics = read
    }

    /// Bound the same way and for the same reason as the metrics reader:
    /// the Mirror source is made lazily and owns the executor, and this
    /// service only asks it to run the gesture a click would have run.
    private var mirrorDriver:
        ((AgentIntegrationMirrorDriveRequest)
            -> AgentIntegrationMirrorDriveResult)?

    func bindMirrorDriver(
        _ drive: @escaping (AgentIntegrationMirrorDriveRequest)
            -> AgentIntegrationMirrorDriveResult) {
        mirrorDriver = drive
    }

    /// Bound like the driver above and for the same reason: the window
    /// belongs to the app, and this service only asks for the one a
    /// menu item would have opened.
    private var mirrorOpener: (() -> HostSurfaceOutcome)?

    func bindMirrorOpener(_ open: @escaping () -> HostSurfaceOutcome) {
        mirrorOpener = open
    }

    /// The agent face on the host's own Mirror. Refusing when nothing is
    /// bound is the honest answer for a headless adapter — and it is a
    /// TYPED refusal rather than silence, because the caller with no
    /// route is exactly the caller who otherwise reaches for the
    /// desktop.
    func openMirror() -> AgentIntegrationMirrorOpenResult {
        guard let mirrorOpener else {
            return .init(unavailable: .init(
                code: "now-mirror-window-absent",
                message: "This host adapter has no window layer, so there "
                    + "is no Mirror to open."))
        }
        switch mirrorOpener() {
        case .showing(let wasOpen, let detail):
            return .init(alreadyOpen: wasOpen, detail: detail)
        case .refused(let code, let reason):
            return .init(unavailable: .init(
                code: "now-mirror-open-" + code, message: reason))
        }
    }

    func driveMirror(_ request: AgentIntegrationMirrorDriveRequest)
        -> AgentIntegrationMirrorDriveResult {
        guard let mirrorDriver else {
            return .init(unavailable: .init(
                code: "now-mirror-drive-unavailable",
                message: "The Mirror is not running, so nothing can be "
                    + "driven through it. Launch with --open-mirror, or "
                    + "open it from NOW's Mirror page."))
        }
        return mirrorDriver(request)
    }
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?

    init(
        listener: GuestListener,
        launchCommandTimeout: TimeInterval = 32,
        catalogSearchTimeout: TimeInterval =
            AgentIntegrationCatalogSearchPolicy.commandTimeout,
        diagnosticsTimeout: TimeInterval =
            AgentIntegrationDiagnosticsPolicy.commandTimeout,
        artifactApprovals: AgentIntegrationArtifactApprovalStore? = nil,
        mirrorEngines: MirrorStateEngineRegistry? = nil
    ) {
        self.listener = listener
        self.launchCommandTimeout = launchCommandTimeout
        self.catalogSearchTimeout = catalogSearchTimeout
        self.diagnosticsTimeout = diagnosticsTimeout
        self.artifactApprovals = artifactApprovals
        self.mirrorEngines = mirrorEngines
    }

    func sessionHealth(observedAt: Date = Date())
        -> AgentIntegrationSessionHealthResult {
        switch listener.state {
        case .idle:
            clearSession()
            return .available(.init(
                state: .notListening,
                observedAt: observedAt,
                listeningPort: nil,
                sessionID: nil,
                guest: nil,
                failure: nil))

        case .listening(let port):
            clearSession()
            return .available(.init(
                state: .listening,
                observedAt: observedAt,
                listeningPort: port,
                sessionID: nil,
                guest: nil,
                failure: nil))

        case .failed(let reason):
            clearSession()
            return .available(.init(
                state: .failed,
                observedAt: observedAt,
                listeningPort: nil,
                sessionID: nil,
                guest: nil,
                failure: reason))

        case .connected(let guestName):
            let health = listener.health
            refreshSession(connectedAt: health?.connectedAt)
            let guest = AgentIntegrationSessionHealth.Guest(
                reference: activeReference(),
                name: health?.guestName ?? guestName,
                version: health?.guestVersion,
                build: health?.guestBuild,
                agentAccess: health?.guestAgentAccess,
                operatingSystem: health?.guestOS,
                connectedAt: health?.connectedAt,
                lastTraffic: health?.lastTraffic,
                quietFor: health.map {
                    max(0, observedAt.timeIntervalSince($0.lastTraffic))
                },
                pingsAnswered: health?.pingsAnswered,
                framesReceived: health?.framesReceived)
            return .available(.init(
                state: .connected,
                observedAt: observedAt,
                listeningPort: listener.boundPort,
                sessionID: sessionID,
                guest: guest,
                roster: roster(),
                failure: nil))
        }
    }

    /// Reads a complete, bounded snapshot from the current paired guest.
    ///
    /// Nothing is cached as a fallback: a disconnected or changing session
    /// returns unavailable rather than presenting an old process table.
    func processList(observedAt: Date? = nil) async
        -> AgentIntegrationProcessListResult {
        await processControl.list(observedAt: observedAt ?? Date())
    }

    /// What the CONNECTED guest can do — never who it is. The derivation
    /// and its probing policy live in the ledger.
    func sessionCapabilities(probeCostly: Bool = false) async
        -> AgentIntegrationSessionCapabilitiesResult {
        await capabilityLedger.report(probeCostly: probeCostly)
    }

    func mirrorRead(_ request: AgentIntegrationMirrorReadRequest) async
        -> AgentIntegrationMirrorReadResult {
        guard let mirrorState else {
            return .init(unavailable: .init(
                code: "now-mirror-state-lane-absent",
                message: "This host adapter has no Mirror state engine"))
        }
        return await mirrorState.read(request)
    }

    func requestQuit(reference: String, requestedAt: Date = Date()) async
        -> AgentIntegrationQuitResult {
        await processControl.requestQuit(
            reference: reference, requestedAt: requestedAt)
    }

    /// Bring one observed process forward. The confirmed-versus-accepted
    /// distinction, and why it cannot come off the wire, is in
    /// `AgentIntegrationProcessControl`.
    func bringToFront(reference: String, requestedAt: Date = Date()) async
        -> AgentIntegrationFrontResult {
        await processControl.bringToFront(
            reference: reference, requestedAt: requestedAt)
    }

    /// What the connected machine says it is — every `gestalt` group in one
    /// call, in the guest's own words. Adjacent to the census above rather
    /// than composed from it: `AgentIntegrationMachineFacts` and
    /// `MachineFactsProjection` carry the difference in plane and shape.
    func machineFacts() async -> AgentIntegrationGuestRowReportResult {
        await machineFactsControl.read()
    }

    /// One page of one software domain. The domain is required and there is no
    /// all-domains form; `apps` at cursor 1 is a whole-volume sweep, and
    /// `AgentIntegrationSoftwareInventory` carries what this side may and may
    /// not do with what comes back.
    func softwareInventory(
        domain: AgentIntegrationSoftwareDomain, cursor: Int?
    ) async -> AgentIntegrationSoftwareInventoryResult {
        await softwareInventoryControl.page(domain: domain, cursor: cursor)
    }

    /// One page of one hardware-census probe. The probe's own outcome is a
    /// fact about the machine and lives inside a completed result;
    /// `AgentIntegrationCensus` carries why that is not this call's outcome.
    func census(probe: String, cursor: Int?) async
        -> AgentIntegrationCensusResult {
        await censusControl.page(probe: probe, cursor: cursor)
    }

    /// Show one item in the connected machine's own Finder. A completed
    /// answer means the machine was ASKED — the guest's Apple Event requests
    /// no reply — and `AgentIntegrationRevealItem` carries the whole of why.
    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        await revealControl.reveal(target: target)
    }

    /// Act on one addressed window. A completed answer means the event was
    /// DISPATCHED to the window's own application, never that the window
    /// moved — `AgentIntegrationActControl` carries why that distinction is
    /// the whole design and where the claim is read from.
    func windowAct(_ request: AgentIntegrationWindowActRequest) async
        -> AgentIntegrationWindowActResult {
        await actControl.windowAct(request)
    }

    /// Act on one addressed control, by answering its application's own
    /// `TrackControl` with a part code.
    func controlAct(_ request: AgentIntegrationControlActRequest) async
        -> AgentIntegrationControlActResult {
        await actControl.controlAct(request)
    }

    /// Perform one menu command, by answering the application's own
    /// `MenuSelect`. `titleLeft` is the identity check rather than a
    /// parameter — see `AgentIntegrationMenuActRequest`.
    func menuAct(_ request: AgentIntegrationMenuActRequest) async
        -> AgentIntegrationMenuActResult {
        await actControl.menuAct(request)
    }

    /// Post one keystroke into the connected guest's front application, by
    /// the input plane's `key` verb — not an act plane call, so it does not
    /// go through `actControl.dispatch()`; `AgentIntegrationActControl.key`
    /// carries the whole of why. `posted` means the guest queued it, never
    /// that the application acted on it.
    func key(_ request: AgentIntegrationKeyRequest) async
        -> AgentIntegrationKeyResult {
        await actControl.key(request)
    }

    /// Read one addressed text element. The one third of the act plane that
    /// changes nothing, and the one a machine can serve while refusing the
    /// two that drive it.
    func getElementText(element: String) async
        -> AgentIntegrationTextReadingResult {
        await actControl.getElementText(element: element)
    }

    /// Replace one addressed text element's whole contents. A replacement
    /// and not an append: there is no offset form.
    func setElementText(element: String, text: String) async
        -> AgentIntegrationTextSetResult {
        await actControl.setElementText(element: element, text: text)
    }

    /// Walk one process's on-screen elements and mint a reference for each.
    /// The act plane's argument producer: nothing else on this side makes a
    /// `now-element-…`, so the five above are unreachable without it. Nil
    /// walks the frontmost application — a default for the WALK, and there
    /// is no spelling downstream for "act on whatever is frontmost".
    func observeElements(process: AgentIntegrationProcessSerial?) async
        -> AgentIntegrationElementObservationResult {
        await actControl.observeElements(process: process)
    }

    /// The end of the connected machine's own log for this launch. It names
    /// no file and cannot be pointed at one; `AgentIntegrationGuestLogTail`
    /// carries the whole of why, and what a log line can still disclose.
    func tailGuestLog(lines: Int?) async
        -> AgentIntegrationGuestRowReportResult {
        await logTailControl.tail(lines: lines)
    }

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection,
                        observedAt: Date = Date()) async
        -> AgentIntegrationLaunchSoftwareResult {
        await softwareLaunch.launch(selection, observedAt: observedAt)
    }

    /// What a whole-volume application sweep costs on the connected machine.
    /// The bound on the wait, and why a second one is refused rather than
    /// queued, live in `AgentIntegrationCatalogSearch`.
    func measureCatalogSearch(observedAt: Date = Date()) async
        -> AgentIntegrationGuestRowReportResult {
        await catalogSearch.measure(observedAt: observedAt)
    }

    /// Run one named diagnostic — `vprobe`, `shotdiag` or `putstat`. One
    /// entry point for three capabilities because they are one lane and one
    /// bound; which of them the connected machine answers is the capability
    /// ledger's question, not this call's. `AgentIntegrationDiagnostics`
    /// carries the bound and why a second run is refused rather than queued.
    func runDiagnostic(_ probe: AgentIntegrationDiagnosticProbe,
                       observedAt: Date = Date()) async
        -> AgentIntegrationGuestRowReportResult {
        await diagnostics.run(probe, observedAt: observedAt)
    }

    /// One picture of the connected machine's screen, staged for the pages
    /// the local surface has to carry it in. The lane's own reasoning lives
    /// in `AgentIntegrationCaptureControl`.
    func capture(depth: Int) async -> AgentIntegrationCaptureResult {
        await captureControl.capture(depth: depth)
    }

    func capturePage(captureID: UUID, offset: Int)
        -> AgentIntegrationCaptureResult {
        captureControl.page(captureID: captureID, offset: offset)
    }

    func abandonCapture() -> AgentIntegrationCaptureResult {
        captureControl.abandon()
    }

    /// The live-stream bracket's four calls. Why an agent-opened bracket ends
    /// itself, and what ends it, is `AgentIntegrationStreamControl`'s.
    func startStream(depth: Int, minIntervalMs: Int)
        -> AgentIntegrationStreamResult {
        streamControl.start(depth: depth, minIntervalMs: minIntervalMs)
    }

    func nextStreamFrame() async -> AgentIntegrationStreamResult {
        await streamControl.nextFrame()
    }

    func streamFramePage(frameID: UUID, offset: Int)
        -> AgentIntegrationStreamResult {
        streamControl.page(frameID: frameID, offset: offset)
    }

    func stopStream() -> AgentIntegrationStreamResult {
        streamControl.stop()
    }

    /// Ends the file transfer in flight, either direction. The lane's own
    /// reasoning — and why the answer says `asked` rather than `cancelled` —
    /// lives in `AgentIntegrationTransferControl`.
    func cancelTransfer() -> AgentIntegrationTransferCancelResult {
        transferControl.cancel()
    }

    func approveArtifact(
        sourceURL: URL,
        destination: String,
        convertText: Bool
    ) -> Result<AgentIntegrationArtifactApprovalNotice,
                AgentIntegrationArtifactApprovalError> {
        guard let sessionID = connectedSessionID() else {
            return .failure(.unavailable(
                "A paired New Old World guest is required for approval"))
        }
        guard let artifactApprovals else {
            return .failure(.unavailable(
                "Artifact approval staging is unavailable"))
        }
        return artifactApprovals.approve(
            sourceURL: sourceURL,
            destination: destination,
            convertText: convertText,
            sessionID: sessionID)
    }

    func transferApprovedArtifact(receipt: String) async
        -> AgentIntegrationArtifactTransferResult {
        await artifactTransfer.transfer(receipt: receipt)
    }

    /// The session token this surface scopes its references to.
    ///
    /// It is no longer minted here. The listener already mints one
    /// identity per CONNECTION — the session id — and this is the UUID
    /// inside it, so the token that scopes a process reference and the
    /// `<machine>-<uuid>` a caller sees are two readings of one fact
    /// rather than two facts that can disagree. Two connections to the
    /// same machine are two tokens, which is what the references have
    /// always meant.
    private func refreshSession(connectedAt: Date?) {
        if let live = listener.activeKey?.session {
            if sessionID != live { sessionID = live }
            sessionConnectedAt = connectedAt
            return
        }
        guard sessionID != nil else {
            self.sessionID = UUID()
            sessionConnectedAt = connectedAt
            return
        }
        guard let connectedAt else { return }
        guard let previous = sessionConnectedAt else {
            sessionConnectedAt = connectedAt
            return
        }
        guard previous != connectedAt else { return }
        self.sessionID = UUID()
        sessionConnectedAt = connectedAt
    }

    /// The machine the request-shaped API is driving, named.
    func activeReference() -> AgentIntegrationGuestReference? {
        listener.guests.first(where: \.isActive).map(Self.reference)
    }

    /// Every connected machine. A caller needs the whole list to discover
    /// the id it must pass to address one that is not being driven.
    func roster() -> [AgentIntegrationGuestReference] {
        listener.guests.map(Self.reference)
    }

    private static func reference(_ guest: ConnectedGuest)
        -> AgentIntegrationGuestReference {
        AgentIntegrationGuestReference(
            id: guest.id.slug,
            sessionID: guest.sessionID,
            name: guest.label,
            reportedName: guest.name,
            idIsAutoAssigned: guest.idIsAutoAssigned,
            idIsAnchored: guest.idIsAnchored)
    }

    /// Whether this host can answer for the machine a caller named.
    ///
    /// Nil to proceed. Otherwise the typed reason, which is never a
    /// substitute answer from another machine: being handed the wrong
    /// Mac's process table while believing you asked about yours is the
    /// exact failure this addressing exists to prevent.
    ///
    /// **Addressing is an assertion, not a switch.** Naming a machine
    /// says which one you mean; it does not point the host at it. The
    /// request-shaped listener API drives one session at a time by
    /// construction, and making an agent call silently re-point it would
    /// take the console out from under whoever is sitting at it. So a
    /// caller that names a connected-but-not-driven machine is refused
    /// with that machine, the driven one, and the whole roster in the
    /// message — enough to say what to do next.
    ///
    /// This is availability by ADDRESS and does not touch availability by
    /// CAPABILITY. What a guest can do is still asked of the guest and
    /// never inferred from which guest it is; this only decides whether
    /// the question reaches the machine the caller meant.
    func addressingRefusal(_ selector: String?)
        -> AgentIntegrationUnavailable? {
        guard let selector, !selector.isEmpty else { return nil }
        let connected = listener.guests
        guard let active = connected.first(where: \.isActive) else {
            return .guest
        }
        /* A session id is precise and is checked first, because it is
           also parseable as nothing else. */
        if let key = GuestKey.parse(selector) {
            if key == active.key { return nil }
            if connected.contains(where: { $0.key == key }) {
                return .notAddressed(
                    asking: key.machine.slug,
                    driving: active.id.slug,
                    connected: connected.map(\.id.slug))
            }
            return .sessionEnded(selector)
        }
        guard let wanted = GuestID(selector) else {
            return .notConnected(selector)
        }
        if wanted == active.id { return nil }
        if connected.contains(where: { $0.id == wanted }) {
            return .notAddressed(
                asking: wanted.slug,
                driving: active.id.slug,
                connected: connected.map(\.id.slug))
        }
        return .notConnected(wanted.slug)
    }

    private func clearSession() {
        guard sessionID != nil else { return }
        sessionID = nil
        sessionConnectedAt = nil
        capabilityLedger.forgetGuest()
        captureControl.forgetGuest()
        streamControl.forgetGuest()
    }

    func connectedSessionID() -> UUID? {
        guard case .connected = listener.state else {
            clearSession()
            return nil
        }
        refreshSession(connectedAt: listener.health?.connectedAt)
        return sessionID
    }

}
