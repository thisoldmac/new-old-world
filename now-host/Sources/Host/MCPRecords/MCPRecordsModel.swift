import Foundation

/// Which record a person asked to see more of. The modal pivots between
/// these without leaving the sheet.
enum MCPInspectedEntity: Identifiable, Hashable {
    case agent(Int64)
    case target(Int64)
    case session(Int64)
    case action(Int64)

    var id: String {
        switch self {
        case .agent(let id): return "agent-\(id)"
        case .target(let id): return "target-\(id)"
        case .session(let id): return "session-\(id)"
        case .action(let id): return "action-\(id)"
        }
    }
}

/// Everything the entity sheet draws for one record: an identity header,
/// a facts grid, and the related records a person pivots through.
struct MCPEntityDetail: Equatable {
    struct Fact: Equatable, Identifiable {
        let label: String
        let value: String
        var id: String { label }
    }

    var title = ""
    var subtitle = ""
    var symbol = "questionmark.circle"
    var facts: [Fact] = []
    /// Related actions, newest first, each row tappable onward.
    var actions: [MCPActionRow] = []
    /// An agent's sessions; empty for other entities.
    var sessions: [MCPSessionRecord] = []
}

/// The history card's main-actor perch over the records store. The store is
/// the single source — the old in-memory ring is gone — and liveness comes
/// from the recorder's insertion stream.
@MainActor
final class MCPRecordsModel: ObservableObject {
    enum LoadState: Equatable {
        case loading
        case ready
        /// The store could not open; serving and the log are unaffected,
        /// and this sentence is what the card says instead of history.
        case unavailable(String)
    }

    @Published private(set) var rows: [MCPActionRow] = []
    @Published private(set) var agents: [MCPAgentRecord] = []
    @Published private(set) var targets: [MCPTargetRecord] = []
    @Published private(set) var lastStdioInitialization:
        MCPInitializationEvidence?
    @Published private(set) var lastStdioAction: MCPActionRow?
    @Published private(set) var loadState: LoadState = .loading
    @Published private(set) var canLoadMore = false
    @Published private(set) var filter = MCPActionQuery()

    private let recorder: MCPRecordsRecorder?
    private var liveTask: Task<Void, Never>?
    private var lifecycleTask: Task<Void, Never>?
    private var started = false

    init(recorder: MCPRecordsRecorder?) {
        self.recorder = recorder
        if recorder == nil {
            loadState = .unavailable(
                "The MCP records database could not be opened. Calls "
                    + "are still served and still reach the log.")
        }
    }

    deinit {
        liveTask?.cancel()
        lifecycleTask?.cancel()
    }

    func start() {
        guard !started, let recorder else { return }
        started = true
        Task { await refresh() }
        liveTask = Task { [weak self] in
            for await row in recorder.inserted {
                guard let self else { return }
                self.absorb(row)
            }
        }
        lifecycleTask = Task { [weak self] in
            for await evidence in recorder.initialized {
                guard let self else { return }
                if evidence.kind == .mcpStdio {
                    self.lastStdioInitialization = evidence
                }
                await self.refreshEntities()
            }
        }
    }

    func setFilter(_ filter: MCPActionQuery) {
        var next = filter
        next.beforeActionID = nil
        self.filter = next
        Task { await refresh() }
    }

    func refresh() async {
        guard let database = recorder?.database else { return }
        do {
            var query = filter
            query.beforeActionID = nil
            let fresh = try await database.actions(matching: query)
            rows = fresh
            canLoadMore = fresh.count >= query.limit
            agents = try await database.agents()
            targets = try await database.targets()
            lastStdioInitialization = try await database
                .latestInitialization(kind: .mcpStdio)
            lastStdioAction = try await database.latestAction(kind: .mcpStdio)
            loadState = .ready
        } catch {
            loadState = .unavailable("The record could not be read: "
                + "\(error)")
        }
    }

    func loadMore() async {
        guard let database = recorder?.database,
              let oldest = rows.last?.id else { return }
        var query = filter
        query.beforeActionID = oldest
        guard let older = try? await database.actions(matching: query)
        else { return }
        rows.append(contentsOf: older)
        canLoadMore = older.count >= query.limit
    }

    /// A live insertion belongs at the top only if the current filter
    /// would have found it; otherwise the count would quietly disagree
    /// with the filter's own claim.
    private func absorb(_ row: MCPActionRow) {
        guard loadState == .ready else { return }
        Task { await refreshEntities() }
        if let outcome = filter.outcome,
           row.action.outcome != outcome { return }
        if let agentID = filter.agentID,
           row.action.agentID != agentID { return }
        if let targetID = filter.targetID,
           row.action.targetID != targetID { return }
        if let sessionID = filter.sessionID,
           row.action.sessionID != sessionID { return }
        guard rows.first?.id != row.id else { return }
        rows.insert(row, at: 0)
    }

    private func refreshEntities() async {
        guard let database = recorder?.database else { return }
        do {
            agents = try await database.agents()
            targets = try await database.targets()
            lastStdioInitialization = try await database
                .latestInitialization(kind: .mcpStdio)
            lastStdioAction = try await database.latestAction(kind: .mcpStdio)
        } catch {
            /* A live refresh is best-effort like recording itself. The last
               complete snapshot stays visible; the full refresh path owns
               the unavailable state when the store cannot be read. */
        }
    }

    // MARK: Entity detail

    func detail(for entity: MCPInspectedEntity) async -> MCPEntityDetail {
        guard let database = recorder?.database else {
            return MCPEntityDetail(title: "Record unavailable")
        }
        do {
            switch entity {
            case .agent(let id):
                guard let agent = try await database.agent(id) else {
                    return missing("agent")
                }
                let counts = try await database.counts(agentID: id)
                return MCPEntityDetail(
                    title: agent.displayName,
                    subtitle: Self.kindSentence(agent.kind),
                    symbol: "person.crop.circle",
                    facts: seenFacts(first: agent.firstSeen,
                                     last: agent.lastSeen)
                        + outcomeFacts(counts),
                    actions: try await database.actions(
                        matching: MCPActionQuery(agentID: id, limit: 25)),
                    sessions: try await database.sessions(ofAgent: id))
            case .target(let id):
                guard let target = try await database.target(id) else {
                    return missing("machine")
                }
                let counts = try await database.counts(targetID: id)
                return MCPEntityDetail(
                    title: target.machineID,
                    subtitle: "Machine driven by agents",
                    symbol: "desktopcomputer",
                    facts: seenFacts(first: target.firstSeen,
                                     last: target.lastSeen)
                        + outcomeFacts(counts),
                    actions: try await database.actions(
                        matching: MCPActionQuery(targetID: id, limit: 25)))
            case .session(let id):
                guard let session = try await database.session(id) else {
                    return missing("session")
                }
                let counts = try await database.counts(sessionID: id)
                let agent = try await database.agent(session.agentID)
                return MCPEntityDetail(
                    title: session.sessionKey ?? "Session \(id)",
                    subtitle: "One connection by "
                        + (agent?.displayName ?? "an agent"),
                    symbol: "point.3.connected.trianglepath.dotted",
                    facts: [
                        .init(label: "Started",
                              value: Self.stamp(session.startedAt)),
                        .init(label: "Last seen",
                              value: Self.stamp(session.lastSeen)),
                    ] + outcomeFacts(counts),
                    actions: try await database.actions(
                        matching: MCPActionQuery(sessionID: id, limit: 25)))
            case .action(let id):
                guard let action = try await database.action(id) else {
                    return missing("action")
                }
                let agent = try await database.agent(action.agentID)
                var facts: [MCPEntityDetail.Fact] = [
                    .init(label: "When", value: Self.stamp(action.at)),
                    .init(label: "Capability", value: action.capability),
                    .init(label: "Face", value: action.face.rawValue),
                    .init(label: "Outcome",
                          value: action.outcome.rawValue),
                    .init(label: "Agent",
                          value: agent?.displayName ?? "unknown"),
                ]
                if let targetID = action.targetID,
                   let target = try await database.target(targetID) {
                    facts.append(.init(label: "Machine",
                                       value: target.machineID))
                }
                if let reason = action.reason {
                    facts.append(.init(label: "Reason", value: reason))
                }
                return MCPEntityDetail(
                    title: AgentActivityEvent.title(
                        for: action.capability),
                    subtitle: "One recorded invocation",
                    symbol: action.outcome == .answered
                        ? "checkmark.circle" : "hand.raised.circle",
                    facts: facts)
            }
        } catch {
            return MCPEntityDetail(
                title: "Record unavailable",
                subtitle: "\(error)")
        }
    }

    private func missing(_ noun: String) -> MCPEntityDetail {
        MCPEntityDetail(
            title: "No such \(noun)",
            subtitle: "May have been pruned from the record.")
    }

    private func seenFacts(first: Date, last: Date)
        -> [MCPEntityDetail.Fact] {
        [.init(label: "First seen", value: Self.stamp(first)),
         .init(label: "Last seen", value: Self.stamp(last))]
    }

    private func outcomeFacts(_ counts: MCPOutcomeCounts)
        -> [MCPEntityDetail.Fact] {
        var facts: [MCPEntityDetail.Fact] = [
            .init(label: "Answered", value: "\(counts.answered)"),
        ]
        if counts.refused > 0 {
            facts.append(.init(label: "Refused",
                               value: "\(counts.refused)"))
        }
        if counts.denied > 0 {
            facts.append(.init(label: "Denied by the machine",
                               value: "\(counts.denied)"))
        }
        return facts
    }

    private static func kindSentence(_ kind: MCPAgentIdentity.Kind)
        -> String {
        switch kind {
        case .api: return "An application using the NOW API"
        case .mcpHTTP: return "An MCP client over HTTP"
        case .mcpStdio: return "An MCP client over Standard Input"
        case .chat: return "The host's own chat harness"
        case .appIntent: return "An App Intent invocation"
        case .unknown: return "An unknown historical client"
        }
    }

    private static let clock: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    private static func stamp(_ date: Date) -> String {
        clock.string(from: date)
    }
}
