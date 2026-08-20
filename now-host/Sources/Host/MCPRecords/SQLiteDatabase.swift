import Foundation
import SQLite3

/// The first SQL in this repository, kept deliberately small: open, exec,
/// prepare/bind/step, `user_version`. NOW owns it the way it owns its JSON
/// stores — no dependency, no ORM, and errors as thrown values that carry
/// SQLite's own words.
///
/// Neither type is Sendable on purpose. A connection belongs to whichever
/// actor opened it; handing statements across executors is exactly the
/// misuse the compiler should refuse.
enum SQLiteError: Error, Equatable {
    case openFailed(code: Int32, message: String)
    case executeFailed(code: Int32, message: String)
    case prepareFailed(code: Int32, message: String)
    case bindFailed(code: Int32, message: String)
    case stepFailed(code: Int32, message: String)
}

final class SQLiteConnection {
    private var handle: OpaquePointer?

    /// `SQLITE_TRANSIENT`: SQLite copies bound bytes before returning, so a
    /// Swift string's storage may go away the moment `bind` does.
    fileprivate static let transient = unsafeBitCast(
        -1 as Int, to: sqlite3_destructor_type.self)

    init(url: URL) throws {
        var handle: OpaquePointer?
        let code = sqlite3_open_v2(
            url.path, &handle,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard code == SQLITE_OK, let handle else {
            let message = handle.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "out of memory"
            sqlite3_close(handle)
            throw SQLiteError.openFailed(code: code, message: message)
        }
        self.handle = handle
        /* WAL lets a reader see a consistent state mid-write and makes the
           cross-process case (two unsuffixed instances) serialize instead
           of corrupt; busy_timeout bounds how long a writer waits before
           the recorder's drop-on-error policy takes the loss. */
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA foreign_keys=ON")
        try execute("PRAGMA busy_timeout=2000")
    }

    deinit {
        sqlite3_close_v2(handle)
    }

    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let code = sqlite3_exec(handle, sql, nil, nil, &message)
        guard code == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(message)
            throw SQLiteError.executeFailed(code: code, message: text)
        }
        sqlite3_free(message)
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        let code = sqlite3_prepare_v2(handle, sql, -1, &statement, nil)
        guard code == SQLITE_OK, let statement else {
            throw SQLiteError.prepareFailed(
                code: code, message: String(cString: sqlite3_errmsg(handle)))
        }
        return SQLiteStatement(statement: statement, connection: handle)
    }

    var userVersion: Int32 {
        get {
            guard let statement = try? prepare("PRAGMA user_version"),
                  (try? statement.step()) == true else { return 0 }
            return Int32(statement.int64(at: 0))
        }
        set {
            try? execute("PRAGMA user_version = \(newValue)")
        }
    }

    var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }
}

final class SQLiteStatement {
    private let statement: OpaquePointer
    private let connection: OpaquePointer?

    fileprivate init(statement: OpaquePointer,
                     connection: OpaquePointer?) {
        self.statement = statement
        self.connection = connection
    }

    deinit {
        sqlite3_finalize(statement)
    }

    func bind(_ value: Int64, at index: Int32) throws {
        try check(sqlite3_bind_int64(statement, index, value),
                  as: SQLiteError.bindFailed)
    }

    func bind(_ value: Double, at index: Int32) throws {
        try check(sqlite3_bind_double(statement, index, value),
                  as: SQLiteError.bindFailed)
    }

    func bind(_ value: String, at index: Int32) throws {
        try check(sqlite3_bind_text(statement, index, value, -1,
                                    SQLiteConnection.transient),
                  as: SQLiteError.bindFailed)
    }

    func bind(_ value: String?, at index: Int32) throws {
        if let value {
            try bind(value, at: index)
        } else {
            try check(sqlite3_bind_null(statement, index),
                      as: SQLiteError.bindFailed)
        }
    }

    /// True while a row is available.
    @discardableResult
    func step() throws -> Bool {
        switch sqlite3_step(statement) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        case let code:
            throw SQLiteError.stepFailed(
                code: code, message: connection.map {
                    String(cString: sqlite3_errmsg($0))
                } ?? "unknown")
        }
    }

    func int64(at column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(at column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func string(at column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    func isNull(at column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    private func check(_ code: Int32,
                       as failure: (Int32, String) -> SQLiteError) throws {
        guard code == SQLITE_OK else {
            throw failure(code, connection.map {
                String(cString: sqlite3_errmsg($0))
            } ?? "unknown")
        }
    }
}
