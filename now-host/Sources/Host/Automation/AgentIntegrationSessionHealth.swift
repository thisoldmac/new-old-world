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
    private let artifactApprovals: AgentIntegrationArtifactApprovalStore?
    private lazy var processControl = AgentIntegrationProcessControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        currentGuest: { [unowned self] in activeReference() })
    private lazy var softwareLaunch = AgentIntegrationSoftwareLaunch(
        listener: listener,
        commandTimeout: launchCommandTimeout,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var revealControl = AgentIntegrationRevealItem(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var logTailControl = AgentIntegrationGuestLogTail(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var capabilityLedger = AgentIntegrationCapabilityLedger(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var captureControl = AgentIntegrationCaptureControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var transferControl = AgentIntegrationTransferControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var catalogSearch = AgentIntegrationCatalogSearch(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() },
        commandTimeout: catalogSearchTimeout)
    private lazy var artifactTransfer = AgentIntegrationArtifactTransfer(
        listener: listener,
        approvals: artifactApprovals,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?

    init(
        listener: GuestListener,
        launchCommandTimeout: TimeInterval = 32,
        catalogSearchTimeout: TimeInterval =
            AgentIntegrationCatalogSearchPolicy.commandTimeout,
        artifactApprovals: AgentIntegrationArtifactApprovalStore? = nil
    ) {
        self.listener = listener
        self.launchCommandTimeout = launchCommandTimeout
        self.catalogSearchTimeout = catalogSearchTimeout
        self.artifactApprovals = artifactApprovals
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

    /// Show one item in the connected machine's own Finder. A completed
    /// answer means the machine was ASKED — the guest's Apple Event requests
    /// no reply — and `AgentIntegrationRevealItem` carries the whole of why.
    func revealItem(target: String) async
        -> AgentIntegrationGuestRowReportResult {
        await revealControl.reveal(target: target)
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
            name: guest.name,
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
