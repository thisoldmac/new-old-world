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
    private let artifactApprovals: AgentIntegrationArtifactApprovalStore?
    private lazy var processControl = AgentIntegrationProcessControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var softwareLaunch = AgentIntegrationSoftwareLaunch(
        listener: listener,
        commandTimeout: launchCommandTimeout,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var capabilityLedger = AgentIntegrationCapabilityLedger(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var artifactTransfer = AgentIntegrationArtifactTransfer(
        listener: listener,
        approvals: artifactApprovals,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?

    init(
        listener: GuestListener,
        launchCommandTimeout: TimeInterval = 32,
        artifactApprovals: AgentIntegrationArtifactApprovalStore? = nil
    ) {
        self.listener = listener
        self.launchCommandTimeout = launchCommandTimeout
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
                name: health?.guestName ?? guestName,
                version: health?.guestVersion,
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

    func launchSoftware(_ selection: AgentIntegrationLaunchSelection,
                        observedAt: Date = Date()) async
        -> AgentIntegrationLaunchSoftwareResult {
        await softwareLaunch.launch(selection, observedAt: observedAt)
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

    private func refreshSession(connectedAt: Date?) {
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

    private func clearSession() {
        guard sessionID != nil else { return }
        sessionID = nil
        sessionConnectedAt = nil
        capabilityLedger.forgetGuest()
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
