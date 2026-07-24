import Foundation
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif

/// The in-process, narrow boundary exposed by the optional local adapter.
///
/// This owns no listener lifecycle and sends nothing to the guest. Keeping
/// the projection beside the live listener prevents a companion process from
/// becoming a second owner of the guest connection.
@MainActor
final class AgentIntegrationHostAdapter {
    private struct ProcessIdentity: Hashable {
        let high: Int
        let low: Int
    }

    private static let maximumProcesses = 48
    private static let maximumPages = 8
    private static let maximumNameScalars = 32

    private let listener: GuestListener
    private let launchCommandTimeout: TimeInterval
    private lazy var softwareLaunch = AgentIntegrationSoftwareLaunch(
        listener: listener,
        commandTimeout: launchCommandTimeout,
        currentSessionID: { [unowned self] in connectedSessionID() })
    private var sessionID: UUID?
    private var sessionConnectedAt: Date?
    private var processReferences: [ProcessIdentity: UUID] = [:]

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
        guard let expectedSessionID = connectedSessionID() else {
            return .guestUnavailable
        }

        var entries: [ProcessEntry] = []
        var cursor: Int?
        var seenCursors: Set<Int> = []
        var pages = 0
        while true {
            let page = await processPage(cursor: cursor)
            guard connectedSessionID() == expectedSessionID else {
                return .guestUnavailable
            }
            switch page {
            case .failure:
                return .unavailable(.init(
                    code: "now-process-list-unavailable",
                    message: "The paired guest process list is unavailable"))
            case .success(let listing):
                guard entries.count + listing.processes.count
                        <= Self.maximumProcesses else {
                    return processListTooLarge()
                }
                entries.append(contentsOf: listing.processes)
                pages += 1
                guard listing.more else {
                    return makeProcessSnapshot(
                        entries,
                        sessionID: expectedSessionID,
                        observedAt: observedAt ?? Date())
                }
                guard pages < Self.maximumPages,
                      let next = listing.cursor,
                      seenCursors.insert(next).inserted else {
                    return processListTooLarge()
                }
                cursor = next
            }
        }
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
        processReferences = [:]
    }

    private func clearSession() {
        sessionID = nil
        sessionConnectedAt = nil
        processReferences = [:]
    }

    private func connectedSessionID() -> UUID? {
        guard case .connected = listener.state else {
            clearSession()
            return nil
        }
        refreshSession(connectedAt: listener.health?.connectedAt)
        return sessionID
    }

    private func processPage(cursor: Int?) async
        -> Result<ProcessListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listProcesses(cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func makeProcessSnapshot(
        _ entries: [ProcessEntry],
        sessionID: UUID,
        observedAt: Date
    ) -> AgentIntegrationProcessListResult {
        let liveIdentities = Set(entries.compactMap(processIdentity))
        processReferences = processReferences.filter {
            liveIdentities.contains($0.key)
        }
        let processes = entries.map { entry in
            AgentIntegrationObservedProcess(
                reference: processReference(for: entry),
                name: boundedName(entry.name),
                kind: processKind(entry.kind),
                code: AgentIntegrationBoundedText.fourCC(entry.code),
                creator: AgentIntegrationBoundedText.fourCC(entry.creator),
                sizeKB: entry.sizeKB.flatMap { $0 >= 0 ? $0 : nil },
                front: entry.front ?? false)
        }
        return .available(.init(
            sessionID: sessionID,
            observedAt: observedAt,
            processes: processes))
    }

    private func processReference(for entry: ProcessEntry) -> String? {
        guard let identity = processIdentity(entry) else { return nil }
        if let existing = processReferences[identity] {
            return "now-process-\(existing.uuidString.lowercased())"
        }
        let reference = UUID()
        processReferences[identity] = reference
        return "now-process-\(reference.uuidString.lowercased())"
    }

    private func processIdentity(_ entry: ProcessEntry) -> ProcessIdentity? {
        guard let high = entry.psnHigh, let low = entry.psnLow else {
            return nil
        }
        return .init(high: high, low: low)
    }

    private func boundedName(_ value: String) -> String {
        String(value.unicodeScalars.prefix(Self.maximumNameScalars))
    }

    private func processKind(_ value: String)
        -> AgentIntegrationObservedProcess.Kind {
        switch value {
        case "application": return .application
        case "background": return .background
        case "finder": return .finder
        default: return .unknown
        }
    }

    private func processListTooLarge()
        -> AgentIntegrationProcessListResult {
        .unavailable(.init(
            code: "now-process-list-too-large",
            message: "The paired guest process list exceeds the bounded agent view"))
    }
}
