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
    /// WHICH machine an answer is about. A projection, not a decision:
    /// nothing here reads it to choose what may be done — availability is
    /// still decided by capability — it is stamped on the answer so a
    /// caller is never left inferring whose process table it holds.
    private let currentGuest: @MainActor () -> AgentIntegrationGuestReference?
    private var records: [Identity: ReferenceRecord] = [:]
    private var referenceSessionID: UUID?
    private var quitInFlight = false
    private var frontInFlight = false

    init(listener: GuestListener,
         currentSessionID: @escaping @MainActor () -> UUID?,
         currentGuest: @escaping @MainActor ()
            -> AgentIntegrationGuestReference? = { nil }) {
        self.listener = listener
        self.currentSessionID = currentSessionID
        self.currentGuest = currentGuest
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

    /// Bring one recently observed process forward, and say whether the
    /// switch is CONFIRMED or only accepted.
    ///
    /// The revalidation is quit's, line for line in intent: the reference
    /// must be this session's and inside its age bound, and the PSN must
    /// still carry the same full identity. What differs is the end — quit
    /// stops at "the request was sent" because nothing on this platform can
    /// tell it more, and front CAN be told more, by one further listing.
    ///
    /// `process.result` cannot carry the difference (`ok` and a reason,
    /// nothing else), and the guests' own dispatch says so: `ok:true` means
    /// `SetFrontProcess` was accepted, and the switch lands when the guest
    /// next yields. So the confirmation is a second `process.list` read here
    /// — a different subsystem from the one just asked, which is what makes
    /// it evidence rather than the same answer twice.
    func bringToFront(reference: String, requestedAt: Date = Date()) async
        -> AgentIntegrationFrontResult {
        guard let sessionID = currentSessionID() else {
            clearReferences()
            return .unavailable(.guest)
        }
        synchronizeReferences(to: sessionID)
        guard AgentIntegrationQuitPolicy.isValidReference(reference),
              let record = records.values.first(where: {
                  $0.reference == reference && $0.sessionID == sessionID
              }) else {
            return staleFront()
        }
        let age = requestedAt.timeIntervalSince(record.observedAt)
        guard age >= 0,
              age <= AgentIntegrationQuitPolicy.maximumReferenceAge else {
            return staleFront()
        }
        /* Its own flag rather than quit's. They are different asks with
           different costs, and one lane for both would let a quit sitting
           on a Save dialog refuse a front switch that takes two seconds.
           Both still serialise against themselves, which is what the flag
           is for: two fronts in flight would race to confirm each other's
           switch. */
        guard !frontInFlight else {
            return refusedFront(
                "now-front-busy",
                "Another New Old World front switch is in progress")
        }
        frontInFlight = true
        defer { frontInFlight = false }

        let entries: [ProcessEntry]
        switch await loadEntries(sessionID: sessionID) {
        case .failure:
            return currentSessionID() == sessionID
                ? refusedFront(
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
            /* A refusal, where quit calls not-running an outcome: quit's
               asked-for state already holds when nothing is running, and
               this one's cannot. A caller whose next step assumes a window
               is up must not read "it is not there" as done. */
            return refusedFront(
                "now-process-not-found",
                "The selected process is no longer running")
        }
        guard identity(current) == record.identity else {
            return staleFront()
        }

        let revalidatedAt = Date()
        let driveResult = await driveFront(
            high: record.identity.high, low: record.identity.low)
        guard currentSessionID() == sessionID else {
            return .unavailable(.init(
                code: "now-front-outcome-unknown",
                message:
                    "The paired guest changed while the front switch was in progress"))
        }
        switch driveResult {
        case .failure:
            return refusedFront(
                "now-front-outcome-unknown",
                "The paired guest did not answer the front request")
        case .success(let result) where !result.ok:
            return refusedFront(
                "now-front-refused",
                "The paired guest would not bring it to the front")
        case .success:
            break
        }

        /* Accepted. Everything from here decides only WHICH success, and a
           failure to confirm is `unconfirmed` rather than a refusal: the ask
           landed, and reporting it as refused would be a worse lie than
           reporting it as unverified. */
        var outcome = AgentIntegrationFrontOutcome.unconfirmed
        var observedAt = Date()
        if case .success(let confirming) = await loadEntries(
            sessionID: sessionID),
           currentSessionID() == sessionID {
            observedAt = Date()
            /* `front` is optional on the wire, and absent is not false: a
               listing that carries no flag confirms nothing, which is the
               same answer as a switch that has not landed. */
            if let target = confirming.first(where: {
                $0.psnHigh == record.identity.high
                    && $0.psnLow == record.identity.low
            }), target.front == true {
                outcome = .fronted
            }
        }
        return .completed(.init(
            reference: reference,
            name: boundedName(current.name),
            outcome: outcome,
            revalidatedAt: revalidatedAt,
            observedAt: observedAt))
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

    private func driveFront(high: Int, low: Int) async
        -> Result<ProcessResult, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.driveProcess(
                psnHigh: high, psnLow: low, verb: .front
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
            guest: currentGuest(),
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

    /* The front lane's own two, because its envelope is the shared
       projected result rather than quit's five-case one. Same wordings on
       purpose: a caller holding one stale reference should not have to
       learn two vocabularies for the same fact about it. */
    private func staleFront() -> AgentIntegrationFrontResult {
        .refused(.init(
            code: "now-process-reference-stale",
            message:
                "The process reference is not current for this session"))
    }

    private func refusedFront(_ code: String, _ message: String)
        -> AgentIntegrationFrontResult {
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
