import Foundation
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif

/// The in-process, narrow boundary exposed by the optional local adapter.
///
/// This owns no listener lifecycle. Guest-dependent projections route only
/// through the live listener, preventing a companion process from becoming a
/// second owner of the guest connection.
@MainActor
final class AgentIntegrationHostAdapter {
    private let listener: GuestListener
    private let launchCommandTimeout: TimeInterval
    private lazy var processControl = AgentIntegrationProcessControl(
        listener: listener,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private lazy var softwareLaunch = AgentIntegrationSoftwareLaunch(
        listener: listener,
        commandTimeout: launchCommandTimeout,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?

    init(listener: GuestListener, launchCommandTimeout: TimeInterval = 32) {
        self.listener = listener
        self.launchCommandTimeout = launchCommandTimeout
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
        sessionID = nil
        sessionConnectedAt = nil
    }

    private func connectedSessionID() -> UUID? {
        guard case .connected = listener.state else {
            clearSession()
            return nil
        }
        refreshSession(connectedAt: listener.health?.connectedAt)
        return sessionID
    }

}
