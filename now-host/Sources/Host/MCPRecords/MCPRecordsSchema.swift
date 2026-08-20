import Foundation

/// The records store's DDL, versioned through `PRAGMA user_version`.
///
/// The schema stores exactly what `HostProjectionAuditEvent` carries plus
/// identity, and successful initialize timestamps on that identity's session.
/// **There is no arguments or payload column, and one must never be
/// added** — both routes refuse arguments deliberately, and a store
/// with a spare TEXT column is how they would come back.
enum MCPRecordsSchema {
    static let currentVersion: Int32 = 2

    static func migrate(_ connection: SQLiteConnection) throws {
        if connection.userVersion < 1 {
            try connection.execute("""
                CREATE TABLE agents (
                  id             INTEGER PRIMARY KEY,
                  kind           TEXT NOT NULL,
                  client_name    TEXT NOT NULL DEFAULT '',
                  client_version TEXT NOT NULL DEFAULT '',
                  first_seen     REAL NOT NULL,
                  last_seen      REAL NOT NULL,
                  UNIQUE(kind, client_name, client_version)
                );
                CREATE TABLE sessions (
                  id          INTEGER PRIMARY KEY,
                  agent_id    INTEGER NOT NULL
                              REFERENCES agents(id) ON DELETE CASCADE,
                  session_key TEXT,
                  started_at  REAL NOT NULL,
                  last_seen   REAL NOT NULL
                );
                CREATE TABLE targets (
                  id         INTEGER PRIMARY KEY,
                  machine_id TEXT NOT NULL UNIQUE,
                  first_seen REAL NOT NULL,
                  last_seen  REAL NOT NULL
                );
                CREATE TABLE actions (
                  id         INTEGER PRIMARY KEY,
                  at         REAL NOT NULL,
                  agent_id   INTEGER NOT NULL
                             REFERENCES agents(id) ON DELETE CASCADE,
                  session_id INTEGER
                             REFERENCES sessions(id) ON DELETE SET NULL,
                  target_id  INTEGER
                             REFERENCES targets(id) ON DELETE SET NULL,
                  capability TEXT NOT NULL,
                  face       TEXT NOT NULL,
                  outcome    TEXT NOT NULL
                             CHECK (outcome IN
                                    ('answered','refused','denied')),
                  reason     TEXT
                );
                CREATE INDEX actions_at ON actions(at DESC);
                CREATE INDEX actions_agent
                    ON actions(agent_id, at DESC);
                CREATE INDEX actions_target
                    ON actions(target_id, at DESC);
                CREATE INDEX actions_session
                    ON actions(session_id, at DESC);
                CREATE INDEX sessions_agent ON sessions(agent_id);
                """)
            connection.userVersion = 1
        }
        if connection.userVersion < 2 {
            try connection.execute("""
                ALTER TABLE sessions
                  ADD COLUMN first_initialized_at REAL;
                ALTER TABLE sessions
                  ADD COLUMN last_initialized_at REAL;
                CREATE INDEX sessions_last_initialized
                  ON sessions(last_initialized_at DESC);
                """)
            connection.userVersion = 2
        }
    }
}
