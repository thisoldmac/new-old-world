import Foundation
#if canImport(NOWAgentIntegration)
import NOWAgentIntegration
#endif

/// Projects the existing software.list -> exact listing path -> launch flow.
///
/// Paths remain inside this host-owned object. Callers receive only bounded
/// display fields and session-scoped opaque references.
@MainActor
final class AgentIntegrationSoftwareLaunch {
    private struct Identity: Hashable {
        let name: String
        let path: String
        let type: String?
        let creator: String?
        let version: String?
    }

    private struct ReferenceRecord {
        let sessionID: UUID
        let identity: Identity
    }

    private enum InventoryResult {
        case success([SoftwareEntry])
        case failure(AgentIntegrationLaunchSoftwareResult)
    }

    private enum CommandOutcome {
        case result(CommandResult)
        case timedOut
    }

    private static let maximumPages = 64
    private static let maximumReferences = 64

    private let listener: GuestListener
    private let commandTimeout: TimeInterval
    private let currentSessionID: @MainActor () -> UUID?
    private var references: [String: ReferenceRecord] = [:]
    private var referenceSessionID: UUID?
    private var actionInFlight = false

    init(listener: GuestListener,
         commandTimeout: TimeInterval,
         currentSessionID: @escaping @MainActor () -> UUID?) {
        self.listener = listener
        self.commandTimeout = commandTimeout
        self.currentSessionID = currentSessionID
    }

    func launch(_ selection: AgentIntegrationLaunchSelection,
                observedAt: Date = Date()) async
        -> AgentIntegrationLaunchSoftwareResult {
        guard let sessionID = currentSessionID() else {
            return .unavailable(.guest)
        }
        synchronizeReferences(to: sessionID)
        guard !actionInFlight else {
            return refused(
                "now-launch-busy",
                "Another New Old World software launch is in progress")
        }
        actionInFlight = true
        var releaseActionOnReturn = true
        defer {
            if releaseActionOnReturn {
                actionInFlight = false
            }
        }

        let selectedIdentity: Identity?
        switch selection {
        case .name(let name):
            guard !name.isEmpty,
                  name.unicodeScalars.count <=
                    AgentIntegrationLaunchPolicy.maximumNameScalars else {
                return refused(
                    "now-software-selection-invalid",
                    "Application names must contain 1 to 31 characters")
            }
            selectedIdentity = nil
        case .reference(let reference):
            guard let record = references[reference],
                  record.sessionID == sessionID else {
                return refused(
                    "now-software-reference-stale",
                    "The software reference is not current for this session")
            }
            selectedIdentity = record.identity
        }

        let inventoryResult = await loadInventory(sessionID: sessionID)
        let entries: [SoftwareEntry]
        switch inventoryResult {
        case .success(let value):
            entries = value
        case .failure(let failure):
            return failure
        }

        let selected: SoftwareEntry
        switch selection {
        case .name(let name):
            let matches = entries.filter {
                Self.exactHFSNameMatch($0.name, name)
            }
            guard !matches.isEmpty else {
                return .notFound(.init(
                    code: "now-software-not-found",
                    message: "No exact application name is current"))
            }
            guard matches.count == 1 else {
                let launchableMatches = Array(matches
                    .filter(\.isLaunchable)
                    .prefix(AgentIntegrationLaunchPolicy.maximumCandidates))
                let candidates = registeredCandidates(
                    launchableMatches, sessionID: sessionID)
                return .ambiguous(.init(
                    code: "now-software-ambiguous",
                    message:
                        "More than one exact application match is current",
                    matchCount: matches.count,
                    candidates: Array(candidates)))
            }
            selected = matches[0]

        case .reference:
            guard let selectedIdentity,
                  let current = entries.first(where: {
                      identity($0) == selectedIdentity
                  }) else {
                return refused(
                    "now-software-reference-stale",
                    "The selected application is no longer current")
            }
            selected = current
        }

        guard selected.isLaunchable else {
            return refused(
                "now-software-not-launchable",
                "The guest could not name an exact launch target")
        }
        guard currentSessionID() == sessionID else {
            return .unavailable(.guest)
        }

        let commandOutcome = await runLaunch(path: selected.path)
        guard case .result(let result) = commandOutcome else {
            releaseActionOnReturn = false
            return refused(
                "now-launch-outcome-unknown",
                "The paired guest did not acknowledge launch in time")
        }
        guard currentSessionID() == sessionID else {
            return .unavailable(.init(
                code: "now-launch-outcome-unknown",
                message:
                    "The paired guest changed while launch was in progress"))
        }
        guard result.ok else {
            return refused(
                "now-launch-refused",
                "The paired guest refused launch")
        }

        return .launched(.init(
            sessionID: sessionID,
            catalogObservedAt: observedAt,
            acknowledgedAt: Date(),
            software: registeredCandidate(selected, sessionID: sessionID),
            guestMessage: "Launch acknowledged by the paired guest"))
    }

    private func loadInventory(sessionID: UUID) async
        -> InventoryResult {
        var entries: [SoftwareEntry] = []
        var cursor: Int?
        var seenCursors: Set<Int> = []
        var pages = 0

        while true {
            let page = await softwarePage(cursor: cursor)
            guard currentSessionID() == sessionID else {
                return .failure(.unavailable(.guest))
            }
            switch page {
            case .failure:
                return .failure(.unavailable(.init(
                    code: "now-software-list-unavailable",
                    message:
                        "The paired guest software catalog is unavailable")))
            case .success(let listing):
                guard entries.count + listing.entries.count
                        <= AgentIntegrationLaunchPolicy
                            .maximumCatalogEntries else {
                    return .failure(refused(
                        "now-software-list-too-large",
                        "The software catalog exceeds the bounded agent view"))
                }
                entries.append(contentsOf: listing.entries)
                pages += 1
                guard listing.more else {
                    return .success(entries)
                }
                guard pages < Self.maximumPages,
                      let next = listing.cursor,
                      seenCursors.insert(next).inserted else {
                    return .failure(refused(
                        "now-software-list-invalid",
                        "The software catalog pagination is not bounded"))
                }
                cursor = next
            }
        }
    }

    private func softwarePage(cursor: Int?) async
        -> Result<SoftwareListing, GuestListener.FileFailure> {
        await withCheckedContinuation { continuation in
            listener.listSoftware(domain: "apps", cursor: cursor) {
                continuation.resume(returning: $0)
            }
        }
    }

    private func runLaunch(path: String) async -> CommandOutcome {
        await withCheckedContinuation { continuation in
            var settled = false
            var timeoutTask: Task<Void, Never>?
            listener.runCommand("launch", args: ["target": path]) {
                if settled {
                    self.actionInFlight = false
                    return
                }
                settled = true
                timeoutTask?.cancel()
                continuation.resume(returning: .result($0))
            }
            timeoutTask = Task { @MainActor in
                try? await Task.sleep(
                    nanoseconds: UInt64(commandTimeout * 1_000_000_000))
                guard !Task.isCancelled, !settled else { return }
                settled = true
                continuation.resume(returning: .timedOut)
            }
        }
    }

    private func synchronizeReferences(to sessionID: UUID) {
        guard referenceSessionID != sessionID else { return }
        referenceSessionID = sessionID
        references = [:]
    }

    private func registeredCandidates(
        _ entries: [SoftwareEntry],
        sessionID: UUID
    ) -> [AgentIntegrationSoftwareCandidate] {
        if references.count + entries.count > Self.maximumReferences {
            references = [:]
        }
        return entries.map {
            registeredCandidate($0, sessionID: sessionID)
        }
    }

    private func registeredCandidate(
        _ entry: SoftwareEntry,
        sessionID: UUID
    )
        -> AgentIntegrationSoftwareCandidate {
        let identity = identity(entry)
        let existing = references.first {
            $0.value.sessionID == sessionID && $0.value.identity == identity
        }?.key
        if existing == nil, references.count >= Self.maximumReferences {
            references = [:]
        }
        let reference = existing
            ?? AgentIntegrationLaunchPolicy.makeReference()
        references[reference] = .init(
            sessionID: sessionID, identity: identity)
        return .init(
            reference: reference,
            name: bounded(
                entry.name,
                scalars: AgentIntegrationLaunchPolicy.maximumNameScalars),
            version: entry.version.map {
                bounded(
                    $0,
                    scalars:
                        AgentIntegrationLaunchPolicy.maximumVersionScalars)
            },
            type: AgentIntegrationBoundedText.fourCC(entry.type),
            creator: AgentIntegrationBoundedText.fourCC(entry.creator),
            running: entry.running ?? false)
    }

    private func identity(_ entry: SoftwareEntry) -> Identity {
        .init(name: entry.name, path: entry.path, type: entry.type,
              creator: entry.creator, version: entry.version)
    }

    /// EqualString on the guest is full-name, case-insensitive, and
    /// diacritic-sensitive. These options preserve the same safety shape:
    /// no substring/fuzzy match and no diacritic folding.
    private static func exactHFSNameMatch(_ lhs: String, _ rhs: String)
        -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive, .literal])
            == .orderedSame
    }

    private func bounded(_ value: String, scalars: Int) -> String {
        AgentIntegrationBoundedText.prefix(value, scalars: scalars)
    }

    private func refused(_ code: String, _ message: String)
        -> AgentIntegrationLaunchSoftwareResult {
        .refused(.init(code: code, message: message))
    }
}
