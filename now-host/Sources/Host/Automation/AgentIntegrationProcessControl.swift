import Foundation
import NOWAgentIntegration

/// Owns the bounded process observation and cooperative-quit projection.
///
/// A reference is only a recent observation. Quit always re-lists, compares
/// the full observed identity, then lets the guest revalidate the PSN again.
@MainActor
final class AgentIntegrationProcessControl {
    private struct Identity: Hashable {
        let high: Int
        let low: Int
        let name: String
        let kind: String
        let code: String?
        let creator: String?
    }

    private struct ReferenceRecord {
        let reference: String
        let sessionID: UUID
        let identity: Identity
        let observedAt: Date
    }

    private enum InventoryResult {
        case success([ProcessEntry])
        case failure(AgentIntegrationProcessListResult)
    }

    private static let maximumProcesses = 48
    private static let maximumPages = 8

    private let listener: GuestListener
    private let currentSessionID: @MainActor () -> UUID?
    private var records: [Identity: ReferenceRecord] = [:]
    private var referenceSessionID: UUID?
    private var quitInFlight = false

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?) {
        self.listener = listener
        self.currentSessionID = currentSessionID
    }

    func list(observedAt: Date = Date())
        async -> AgentIntegrationProcessListResult {
        guard let sessionID = currentSessionID() else {
            clearReferences()
            return .guestUnavailable
        }
        synchronizeReferences(to: sessionID)
        switch await loadEntries(sessionID: sessionID) {
        case .failure(let failure):
            return failure
        case .success(let entries):
            return makeSnapshot(
                entries, sessionID: sessionID, observedAt: observedAt)
        }
    }

    func requestQuit(reference: String, requestedAt: Date = Date()) async
        -> AgentIntegrationQuitResult {
        guard let sessionID = currentSessionID() else {
            clearReferences()
            return .unavailable(.guest)
        }
        synchronizeReferences(to: sessionID)
        guard AgentIntegrationQuitPolicy.isValidReference(reference),
              let record = records.values.first(where: {
                  $0.reference == reference && $0.sessionID == sessionID
              }) else {
            return stale()
        }
        let age = requestedAt.timeIntervalSince(record.observedAt)
        guard age >= 0,
              age <= AgentIntegrationQuitPolicy.maximumReferenceAge else {
            return stale()
        }
        guard !quitInFlight else {
            return refused(
                "now-quit-busy",
                "Another New Old World cooperative quit is in progress")
        }
        quitInFlight = true
        defer { quitInFlight = false }

        let entries: [ProcessEntry]
        switch await loadEntries(sessionID: sessionID) {
        case .failure:
            return currentSessionID() == sessionID
                ? refused(
                    "now-process-list-unavailable",
                    "The paired guest process list is unavailable")
                : .unavailable(.guest)
        case .success(let current):
            entries = current
        }
        guard currentSessionID() == sessionID else {
            return .unavailable(.guest)
        }
        guard let current = entries.first(where: {
            $0.psnHigh == record.identity.high
                && $0.psnLow == record.identity.low
        }) else {
            return .notFound(.init(
                code: "now-process-not-found",
                message: "The selected process is no longer running"))
        }
        guard identity(current) == record.identity else {
            return stale()
        }

        let revalidatedAt = Date()
        let driveResult = await driveQuit(
            high: record.identity.high, low: record.identity.low)
        guard currentSessionID() == sessionID else {
            return .unavailable(.init(
                code: "now-quit-outcome-unknown",
                message:
                    "The paired guest changed while quit was in progress"))
        }
        switch driveResult {
        case .failure:
            return refused(
                "now-quit-outcome-unknown",
                "The paired guest did not acknowledge cooperative quit")
        case .success(let result) where !result.ok:
            return refused(
                "now-quit-refused",
                "The paired guest refused cooperative quit")
        case .success:
            return .requestSent(.init(
                sessionID: sessionID,
                snapshotObservedAt: record.observedAt,
                revalidatedAt: revalidatedAt,
                acknowledgedAt: Date(),
                process: .init(
                    reference: reference,
                    name: boundedName(current.name),
                    kind: processKind(current.kind),
                    code: AgentIntegrationBoundedText.fourCC(current.code),
                    creator:
                        AgentIntegrationBoundedText.fourCC(current.creator)),
                guestMessage:
                    "Cooperative quit request acknowledged by the paired guest"))
        }
    }

    private func loadEntries(sessionID: UUID) async -> InventoryResult {
        var entries: [ProcessEntry] = []
        var cursor: Int?
        var seenCursors: Set<Int> = []
        var pages = 0
        while true {
            let page = await processPage(cursor: cursor)
            guard currentSessionID() == sessionID else {
                return .failure(.guestUnavailable)
            }
            switch page {
            case .failure:
                return .failure(.unavailable(.init(
                    code: "now-process-list-unavailable",
                    message:
                        "The paired guest process list is unavailable")))
            case .success(let listing):
                guard entries.count + listing.processes.count
                        <= Self.maximumProcesses else {
                    return .failure(processListTooLarge())
                }
                entries.append(contentsOf: listing.processes)
                pages += 1
                guard listing.more else {
                    return .success(entries)
                }
                guard pages < Self.maximumPages,
                      let next = listing.cursor,
                      seenCursors.insert(next).inserted else {
                    return .failure(processListTooLarge())
                }
                cursor = next
            }
        }
    }

    private func processPage(cursor: Int?) async
        -> Result<ProcessListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listProcesses(cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func driveQuit(high: Int, low: Int) async
        -> Result<ProcessResult, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.driveProcess(
                psnHigh: high, psnLow: low, verb: .quit
            ) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func makeSnapshot(
        _ entries: [ProcessEntry],
        sessionID: UUID,
        observedAt: Date
    ) -> AgentIntegrationProcessListResult {
        let liveIdentities = Set(entries.compactMap(identity))
        records = records.filter { liveIdentities.contains($0.key) }
        let processes = entries.map { entry in
            AgentIntegrationObservedProcess(
                reference: processReference(
                    for: entry, sessionID: sessionID,
                    observedAt: observedAt),
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

    private func processReference(
        for entry: ProcessEntry,
        sessionID: UUID,
        observedAt: Date
    ) -> String? {
        guard let identity = identity(entry) else { return nil }
        let reference = records[identity]?.reference
            ?? AgentIntegrationQuitPolicy.makeReference()
        records[identity] = .init(
            reference: reference,
            sessionID: sessionID,
            identity: identity,
            observedAt: observedAt)
        return reference
    }

    private func identity(_ entry: ProcessEntry) -> Identity? {
        guard let high = entry.psnHigh, let low = entry.psnLow else {
            return nil
        }
        return .init(
            high: high,
            low: low,
            name: entry.name,
            kind: entry.kind,
            code: entry.code,
            creator: entry.creator)
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

    private func boundedName(_ value: String) -> String {
        AgentIntegrationBoundedText.prefix(
            value, scalars: AgentIntegrationQuitPolicy.maximumNameScalars)
    }

    private func synchronizeReferences(to sessionID: UUID) {
        guard referenceSessionID != sessionID else { return }
        referenceSessionID = sessionID
        records = [:]
    }

    private func clearReferences() {
        referenceSessionID = nil
        records = [:]
    }

    private func stale() -> AgentIntegrationQuitResult {
        .stale(.init(
            code: "now-process-reference-stale",
            message:
                "The process reference is not current for this session"))
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationQuitResult {
        .refused(.init(code: code, message: message))
    }

    private func processListTooLarge()
        -> AgentIntegrationProcessListResult {
        .unavailable(.init(
            code: "now-process-list-too-large",
            message:
                "The paired guest process list exceeds the bounded agent view"))
    }
}
