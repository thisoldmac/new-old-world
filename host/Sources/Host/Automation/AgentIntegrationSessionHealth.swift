import Foundation
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif

/// The in-process, read-only boundary exposed by the optional local adapter.
///
/// This owns no listener lifecycle and sends nothing to the guest. Keeping
/// the projection beside the live listener prevents a companion process from
/// becoming a second owner of the guest connection.
@MainActor
final class AgentIntegrationHostAdapter {
    private let listener: GuestListener
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?

    init(listener: GuestListener) {
        self.listener = listener
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
}
