import Foundation
import NOWAgentIntegration

enum MCPRecordsDatabaseError: Error {
    case noApplicationSupport
}

/// The durable record of what agents did: agents, their sessions, the
/// machines they touched, and every audited action — the persistent store
/// the in-memory glance never was. One actor owns the one connection;
/// everything the UI reads comes out as value types.
actor MCPRecordsDatabase {
    static let actionAgeLimit: TimeInterval = 180 * 24 * 60 * 60
    static let actionRowCap = 100_000

    private let connection: SQLiteConnection

    /// `~/Library/Application Support/New Old World/MCP Records`, or
    /// `MCP Records.<suffix>` under `NOW_PREFS_SUFFIX` — the same opt-in,
    /// env-only isolation `ProductIdentity.defaults` documents, so a
    /// suffixed second instance never writes the desk's real record.
    static func applicationSupportRoot(
        fileManager: FileManager = .default) throws -> URL {
        guard let support = fileManager.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first
        else { throw MCPRecordsDatabaseError.noApplicationSupport }
        var folder = "MCP Records"
        if let suffix = ProcessInfo.processInfo
            .environment["NOW_PREFS_SUFFIX"], !suffix.isEmpty {
            folder = "MCP Records.\(suffix)"
        }
        return support
            .appendingPathComponent(ProductIdentity.displayName,
                                    isDirectory: true)
            .appendingPathComponent(folder, isDirectory: true)
    }

    init(root: URL, fileManager: FileManager = .default,
         now: Date = Date()) throws {
        try fileManager.createDirectory(at: root,
                                        withIntermediateDirectories: true)
        connection = try SQLiteConnection(
            url: root.appendingPathComponent("records.sqlite",
                                             isDirectory: false))
        try MCPRecordsSchema.migrate(connection)
        try? Self.prune(connection, now: now)
    }

    // MARK: Recording

    /// A successful MCP initialize, with no request body or tool arguments.
    /// MCP transports always supply a session key; refusing a missing one
    /// here keeps separate anonymous connections from collapsing together.
    func recordInitialization(agent identity: MCPAgentIdentity,
                              at moment: Date) throws {
        guard let key = identity.sessionKey, !key.isEmpty else { return }
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let agentID = try upsertAgent(identity, at: moment)
            let sessionID = try upsertSession(
                agentID: agentID, key: key, at: moment)
            let touch = try connection.prepare("""
                UPDATE sessions
                SET first_initialized_at = COALESCE(first_initialized_at, ?),
                    last_initialized_at = ?
                WHERE id = ?
                """)
            try touch.bind(moment.timeIntervalSince1970, at: 1)
            try touch.bind(moment.timeIntervalSince1970, at: 2)
            try touch.bind(sessionID, at: 3)
            try touch.step()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    /// One audited action, in one transaction: upsert the agent, its
    /// session and the target, insert the action, advance the `last_seen`s.
    func record(event: HostProjectionAuditEvent,
                agent identity: MCPAgentIdentity,
                drivenGuest: String?,
                at moment: Date) throws {
        try connection.execute("BEGIN IMMEDIATE")
        do {
            let agentID = try upsertAgent(identity, at: moment)
            let sessionID = try identity.sessionKey.map {
                try upsertSession(agentID: agentID, key: $0, at: moment)
            }
            let machine = event.guest ?? drivenGuest
            let targetID = try machine.map {
                try upsertTarget($0, at: moment)
            }
            let insert = try connection.prepare("""
                INSERT INTO actions
                  (at, agent_id, session_id, target_id, capability, face,
                   outcome, reason)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """)
            try insert.bind(moment.timeIntervalSince1970, at: 1)
            try insert.bind(agentID, at: 2)
            if let sessionID {
                try insert.bind(sessionID, at: 3)
            } else {
                try insert.bind(nil as String?, at: 3)
            }
            if let targetID {
                try insert.bind(targetID, at: 4)
            } else {
                try insert.bind(nil as String?, at: 4)
            }
            try insert.bind(event.capability, at: 5)
            try insert.bind(event.face.rawValue, at: 6)
            try insert.bind(event.outcome.rawValue, at: 7)
            try insert.bind(event.reason, at: 8)
            try insert.step()
            try connection.execute("COMMIT")
        } catch {
            try? connection.execute("ROLLBACK")
            throw error
        }
    }

    private func upsertAgent(_ identity: MCPAgentIdentity,
                             at moment: Date) throws -> Int64 {
        let upsert = try connection.prepare("""
            INSERT INTO agents
              (kind, client_name, client_version, first_seen, last_seen)
            VALUES (?, ?, ?, ?, ?)
            ON CONFLICT(kind, client_name, client_version)
            DO UPDATE SET last_seen = excluded.last_seen
            RETURNING id
            """)
        try upsert.bind(identity.kind.databaseValue, at: 1)
        try upsert.bind(identity.clientName, at: 2)
        try upsert.bind(identity.clientVersion, at: 3)
        try upsert.bind(moment.timeIntervalSince1970, at: 4)
        try upsert.bind(moment.timeIntervalSince1970, at: 5)
        _ = try upsert.step()
        return upsert.int64(at: 0)
    }

    private func upsertSession(agentID: Int64, key: String,
                               at moment: Date) throws -> Int64 {
        let find = try connection.prepare("""
            SELECT id FROM sessions
            WHERE agent_id = ? AND session_key = ?
            """)
        try find.bind(agentID, at: 1)
        try find.bind(key, at: 2)
        if try find.step() {
            let id = find.int64(at: 0)
            let touch = try connection.prepare(
                "UPDATE sessions SET last_seen = ? WHERE id = ?")
            try touch.bind(moment.timeIntervalSince1970, at: 1)
            try touch.bind(id, at: 2)
            try touch.step()
            return id
        }
        let insert = try connection.prepare("""
            INSERT INTO sessions (agent_id, session_key, started_at,
                                  last_seen)
            VALUES (?, ?, ?, ?)
            """)
        try insert.bind(agentID, at: 1)
        try insert.bind(key, at: 2)
        try insert.bind(moment.timeIntervalSince1970, at: 3)
        try insert.bind(moment.timeIntervalSince1970, at: 4)
        try insert.step()
        return connection.lastInsertRowID
    }

    private func upsertTarget(_ machineID: String,
                              at moment: Date) throws -> Int64 {
        let upsert = try connection.prepare("""
            INSERT INTO targets (machine_id, first_seen, last_seen)
            VALUES (?, ?, ?)
            ON CONFLICT(machine_id)
            DO UPDATE SET last_seen = excluded.last_seen
            RETURNING id
            """)
        try upsert.bind(machineID, at: 1)
        try upsert.bind(moment.timeIntervalSince1970, at: 2)
        try upsert.bind(moment.timeIntervalSince1970, at: 3)
        _ = try upsert.step()
        return upsert.int64(at: 0)
    }

    // MARK: Queries

    func actions(matching query: MCPActionQuery) throws -> [MCPActionRow] {
        var sql = """
            SELECT a.id, a.at, a.agent_id, a.session_id, a.target_id,
                   a.capability, a.face, a.outcome, a.reason,
                   g.kind, g.client_name, g.client_version, t.machine_id
            FROM actions a
            JOIN agents g ON g.id = a.agent_id
            LEFT JOIN targets t ON t.id = a.target_id
            WHERE 1=1
            """
        var statementBinds:
            [(SQLiteStatement, Int32) throws -> Void] = []
        if let outcome = query.outcome {
            sql += " AND a.outcome = ?"
            statementBinds.append { try $0.bind(outcome.rawValue, at: $1) }
        }
        if let agentID = query.agentID {
            sql += " AND a.agent_id = ?"
            statementBinds.append { try $0.bind(agentID, at: $1) }
        }
        if let targetID = query.targetID {
            sql += " AND a.target_id = ?"
            statementBinds.append { try $0.bind(targetID, at: $1) }
        }
        if let sessionID = query.sessionID {
            sql += " AND a.session_id = ?"
            statementBinds.append { try $0.bind(sessionID, at: $1) }
        }
        if let before = query.beforeActionID {
            /* Rowid pages and orders: `at` alone cannot break ties or
               survive a clock stepping backwards. */
            sql += " AND a.id < ?"
            statementBinds.append { try $0.bind(before, at: $1) }
        }
        sql += " ORDER BY a.id DESC LIMIT \(max(1, query.limit))"

        let statement = try connection.prepare(sql)
        for (offset, bind) in statementBinds.enumerated() {
            try bind(statement, Int32(offset + 1))
        }
        var rows: [MCPActionRow] = []
        while try statement.step() {
            guard let action = Self.action(from: statement) else { continue }
            let agent = MCPAgentRecord(
                id: action.agentID,
                kind: MCPAgentIdentity.Kind(
                    databaseValue: statement.string(at: 9) ?? ""),
                clientName: statement.string(at: 10) ?? "",
                clientVersion: statement.string(at: 11) ?? "",
                firstSeen: Date(timeIntervalSince1970: 0),
                lastSeen: Date(timeIntervalSince1970: 0))
            rows.append(MCPActionRow(
                action: action,
                agentName: agent.displayName,
                targetMachine: statement.string(at: 12)))
        }
        return rows
    }

    func agents() throws -> [MCPAgentRecord] {
        let statement = try connection.prepare("""
            SELECT id, kind, client_name, client_version, first_seen,
                   last_seen
            FROM agents ORDER BY last_seen DESC
            """)
        var records: [MCPAgentRecord] = []
        while try statement.step() {
            records.append(Self.agent(from: statement))
        }
        return records
    }

    func latestInitialization(kind: MCPAgentIdentity.Kind) throws
        -> MCPInitializationEvidence? {
        let statement = try connection.prepare("""
            SELECT g.kind, g.client_name, g.client_version, s.session_key,
                   s.first_initialized_at, s.last_initialized_at
            FROM sessions s
            JOIN agents g ON g.id = s.agent_id
            WHERE g.kind = ? AND s.last_initialized_at IS NOT NULL
            ORDER BY s.last_initialized_at DESC, s.id DESC
            LIMIT 1
            """)
        try statement.bind(kind.databaseValue, at: 1)
        guard try statement.step(),
              let sessionKey = statement.string(at: 3) else { return nil }
        let agent = MCPAgentRecord(
            id: 0,
            kind: .init(databaseValue: statement.string(at: 0) ?? ""),
            clientName: statement.string(at: 1) ?? "",
            clientVersion: statement.string(at: 2) ?? "",
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeen: Date(timeIntervalSince1970: 0))
        return MCPInitializationEvidence(
            kind: agent.kind, agentName: agent.displayName,
            clientName: agent.clientName,
            clientVersion: agent.clientVersion,
            sessionKey: sessionKey,
            firstSeen: Date(timeIntervalSince1970: statement.double(at: 4)),
            lastSeen: Date(timeIntervalSince1970: statement.double(at: 5)))
    }

    func latestAction(kind: MCPAgentIdentity.Kind) throws -> MCPActionRow? {
        let agentIDs = try agents().filter { $0.kind == kind }.map(\.id)
        guard !agentIDs.isEmpty else { return nil }
        /* One kind may have several client identities. Querying them one at
           a time would make recency depend on agent order, so select once. */
        let placeholders = agentIDs.map { _ in "?" }.joined(separator: ",")
        let statement = try connection.prepare("""
            SELECT a.id, a.at, a.agent_id, a.session_id, a.target_id,
                   a.capability, a.face, a.outcome, a.reason,
                   g.kind, g.client_name, g.client_version, t.machine_id
            FROM actions a
            JOIN agents g ON g.id = a.agent_id
            LEFT JOIN targets t ON t.id = a.target_id
            WHERE a.agent_id IN (\(placeholders))
            ORDER BY a.id DESC LIMIT 1
            """)
        for (offset, id) in agentIDs.enumerated() {
            try statement.bind(id, at: Int32(offset + 1))
        }
        guard try statement.step(),
              let action = Self.action(from: statement) else { return nil }
        let agent = MCPAgentRecord(
            id: action.agentID,
            kind: .init(databaseValue: statement.string(at: 9) ?? ""),
            clientName: statement.string(at: 10) ?? "",
            clientVersion: statement.string(at: 11) ?? "",
            firstSeen: .distantPast, lastSeen: .distantPast)
        return MCPActionRow(action: action, agentName: agent.displayName,
                            targetMachine: statement.string(at: 12))
    }

    func agent(_ id: Int64) throws -> MCPAgentRecord? {
        let statement = try connection.prepare("""
            SELECT id, kind, client_name, client_version, first_seen,
                   last_seen
            FROM agents WHERE id = ?
            """)
        try statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return Self.agent(from: statement)
    }

    func targets() throws -> [MCPTargetRecord] {
        let statement = try connection.prepare("""
            SELECT id, machine_id, first_seen, last_seen
            FROM targets ORDER BY last_seen DESC
            """)
        var records: [MCPTargetRecord] = []
        while try statement.step() {
            records.append(Self.target(from: statement))
        }
        return records
    }

    func target(_ id: Int64) throws -> MCPTargetRecord? {
        let statement = try connection.prepare("""
            SELECT id, machine_id, first_seen, last_seen
            FROM targets WHERE id = ?
            """)
        try statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return Self.target(from: statement)
    }

    func session(_ id: Int64) throws -> MCPSessionRecord? {
        let statement = try connection.prepare("""
            SELECT id, agent_id, session_key, started_at, last_seen,
                   first_initialized_at, last_initialized_at
            FROM sessions WHERE id = ?
            """)
        try statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return MCPSessionRecord(
            id: statement.int64(at: 0),
            agentID: statement.int64(at: 1),
            sessionKey: statement.string(at: 2),
            startedAt: Date(
                timeIntervalSince1970: statement.double(at: 3)),
            lastSeen: Date(
                timeIntervalSince1970: statement.double(at: 4)),
            firstInitializedAt: statement.isNull(at: 5) ? nil : Date(
                timeIntervalSince1970: statement.double(at: 5)),
            lastInitializedAt: statement.isNull(at: 6) ? nil : Date(
                timeIntervalSince1970: statement.double(at: 6)))
    }

    func sessions(ofAgent agentID: Int64) throws -> [MCPSessionRecord] {
        let statement = try connection.prepare("""
            SELECT id, agent_id, session_key, started_at, last_seen,
                   first_initialized_at, last_initialized_at
            FROM sessions WHERE agent_id = ? ORDER BY last_seen DESC
            """)
        try statement.bind(agentID, at: 1)
        var records: [MCPSessionRecord] = []
        while try statement.step() {
            records.append(MCPSessionRecord(
                id: statement.int64(at: 0),
                agentID: statement.int64(at: 1),
                sessionKey: statement.string(at: 2),
                startedAt: Date(
                    timeIntervalSince1970: statement.double(at: 3)),
                lastSeen: Date(
                    timeIntervalSince1970: statement.double(at: 4)),
                firstInitializedAt: statement.isNull(at: 5) ? nil : Date(
                    timeIntervalSince1970: statement.double(at: 5)),
                lastInitializedAt: statement.isNull(at: 6) ? nil : Date(
                    timeIntervalSince1970: statement.double(at: 6))))
        }
        return records
    }

    func action(_ id: Int64) throws -> MCPActionRecord? {
        let statement = try connection.prepare("""
            SELECT id, at, agent_id, session_id, target_id, capability,
                   face, outcome, reason
            FROM actions WHERE id = ?
            """)
        try statement.bind(id, at: 1)
        guard try statement.step() else { return nil }
        return Self.action(from: statement)
    }

    func counts(agentID: Int64? = nil, targetID: Int64? = nil,
                sessionID: Int64? = nil) throws -> MCPOutcomeCounts {
        var sql = "SELECT outcome, COUNT(*) FROM actions WHERE 1=1"
        var binds: [(SQLiteStatement, Int32) throws -> Void] = []
        if let agentID {
            sql += " AND agent_id = ?"
            binds.append { try $0.bind(agentID, at: $1) }
        }
        if let targetID {
            sql += " AND target_id = ?"
            binds.append { try $0.bind(targetID, at: $1) }
        }
        if let sessionID {
            sql += " AND session_id = ?"
            binds.append { try $0.bind(sessionID, at: $1) }
        }
        sql += " GROUP BY outcome"
        let statement = try connection.prepare(sql)
        for (offset, bind) in binds.enumerated() {
            try bind(statement, Int32(offset + 1))
        }
        var counts = MCPOutcomeCounts()
        while try statement.step() {
            let tally = Int(statement.int64(at: 1))
            switch statement.string(at: 0) {
            case "answered": counts.answered = tally
            case "refused": counts.refused = tally
            case "denied": counts.denied = tally
            default: break
            }
        }
        return counts
    }

    // MARK: Retention

    /// Age first, then a hard cap; sessions that lost every action and went
    /// quiet go with them. Agents and targets are never auto-pruned — they
    /// are small, and they are the entities a person names.
    func prune(now: Date) throws {
        try Self.prune(connection, now: now)
    }

    /// Static so `init` can prune before the actor is fully formed.
    private static func prune(_ connection: SQLiteConnection,
                              now: Date) throws {
        let cutoff = now.timeIntervalSince1970 - actionAgeLimit
        try connection.execute(
            "DELETE FROM actions WHERE at < \(cutoff)")
        try connection.execute("""
            DELETE FROM actions WHERE id IN (
              SELECT id FROM actions ORDER BY id DESC
              LIMIT -1 OFFSET \(actionRowCap))
            """)
        try connection.execute("""
            DELETE FROM sessions
            WHERE last_seen < \(cutoff)
              AND id NOT IN (SELECT DISTINCT session_id FROM actions
                             WHERE session_id IS NOT NULL)
            """)
    }

    // MARK: Row builders

    private static func agent(from statement: SQLiteStatement)
        -> MCPAgentRecord {
        MCPAgentRecord(
            id: statement.int64(at: 0),
            kind: MCPAgentIdentity.Kind(
                databaseValue: statement.string(at: 1) ?? ""),
            clientName: statement.string(at: 2) ?? "",
            clientVersion: statement.string(at: 3) ?? "",
            firstSeen: Date(
                timeIntervalSince1970: statement.double(at: 4)),
            lastSeen: Date(
                timeIntervalSince1970: statement.double(at: 5)))
    }

    private static func target(from statement: SQLiteStatement)
        -> MCPTargetRecord {
        MCPTargetRecord(
            id: statement.int64(at: 0),
            machineID: statement.string(at: 1) ?? "",
            firstSeen: Date(
                timeIntervalSince1970: statement.double(at: 2)),
            lastSeen: Date(
                timeIntervalSince1970: statement.double(at: 3)))
    }

    /// Columns 0…8 in both the plain and the joined SELECT, in the same
    /// order, so one builder serves both.
    private static func action(from statement: SQLiteStatement)
        -> MCPActionRecord? {
        guard let face = HostInvokingFace(
                rawValue: statement.string(at: 6) ?? ""),
              let outcome = HostProjectionAuditEvent.Outcome(
                rawValue: statement.string(at: 7) ?? "") else {
            return nil
        }
        return MCPActionRecord(
            id: statement.int64(at: 0),
            at: Date(timeIntervalSince1970: statement.double(at: 1)),
            agentID: statement.int64(at: 2),
            sessionID: statement.isNull(at: 3)
                ? nil : statement.int64(at: 3),
            targetID: statement.isNull(at: 4)
                ? nil : statement.int64(at: 4),
            capability: statement.string(at: 5) ?? "",
            face: face,
            outcome: outcome,
            reason: statement.string(at: 8))
    }
}
