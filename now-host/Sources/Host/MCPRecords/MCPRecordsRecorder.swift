import Foundation
import NOWAgentIntegration

/// The fire-and-forget facade the audit fan-out calls. Serving is never
/// gated on the record: a failed insert drops that row and says so once in
/// the log, because an agent call that succeeded must not become an error
/// over bookkeeping.
final class MCPRecordsRecorder: @unchecked Sendable {
    /// Readable so the history model queries the same store this writes.
    let database: MCPRecordsDatabase
    private let insertions: AsyncStream<MCPActionRow>.Continuation
    private let lifecycleInsertions:
        AsyncStream<MCPInitializationEvidence>.Continuation
    /* One warning per launch, not one per drop: a wedged disk during a busy
       agent run must not flood the log it is warning into. Lock-guarded —
       the flag is the only mutable state behind the @unchecked. */
    private let warnedLock = NSLock()
    private var warned = false
    /// Live UI updates: every recorded action, as the joined row the
    /// history card draws, in insertion order.
    let inserted: AsyncStream<MCPActionRow>
    let initialized: AsyncStream<MCPInitializationEvidence>

    init(database: MCPRecordsDatabase) {
        self.database = database
        var continuation: AsyncStream<MCPActionRow>.Continuation!
        inserted = AsyncStream { continuation = $0 }
        insertions = continuation
        var lifecycleContinuation:
            AsyncStream<MCPInitializationEvidence>.Continuation!
        initialized = AsyncStream { lifecycleContinuation = $0 }
        lifecycleInsertions = lifecycleContinuation
    }

    func record(event: HostProjectionAuditEvent,
                agent: MCPAgentIdentity,
                drivenGuest: String?,
                at moment: Date = Date()) {
        let database = database
        let insertions = insertions
        Task {
            do {
                try await database.record(event: event, agent: agent,
                                          drivenGuest: drivenGuest,
                                          at: moment)
                let row = try await database.actions(
                    matching: MCPActionQuery(limit: 1)).first
                if let row { insertions.yield(row) }
            } catch {
                guard self.shouldWarn() else { return }
                let detail = "MCP record dropped: \(error) — further "
                    + "drops this launch will not be reported"
                await MainActor.run {
                    HostLog.shared.write(.warn, "agent", detail)
                }
            }
        }
    }

    func recordInitialization(agent: MCPAgentIdentity,
                              at moment: Date = Date()) async {
        do {
            try await database.recordInitialization(agent: agent, at: moment)
            if let evidence = try await database.latestInitialization(
                    kind: agent.kind) {
                lifecycleInsertions.yield(evidence)
            }
        } catch {
            guard shouldWarn() else { return }
            let detail = "MCP initialization record dropped: \(error) — "
                + "further drops this launch will not be reported"
            await MainActor.run {
                HostLog.shared.write(.warn, "agent", detail)
            }
        }
    }

    private func shouldWarn() -> Bool {
        warnedLock.lock()
        defer { warnedLock.unlock() }
        guard !warned else { return false }
        warned = true
        return true
    }
}
