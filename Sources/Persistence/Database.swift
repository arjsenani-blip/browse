import Foundation
import SQLite3

/// A value bound to, or read from, a SQLite statement.
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int64)
    case double(Double)
    case text(String)
    case blob(Data)
}

public struct DatabaseError: Error, CustomStringConvertible, Sendable {
    public let code: Int32
    public let message: String
    public let sql: String?
    public var description: String {
        "SQLite error \(code): \(message)" + (sql.map { " [\($0)]" } ?? "")
    }
}

/// Supplies the key for encryption at rest.
///
/// **Future work:** the system `SQLite3` has no encryption codec, so nothing consumes the key yet.
/// When we adopt SQLCipher (or the SQLite Encryption Extension), `Database.init` will call
/// `databaseKey()` and issue `PRAGMA key` right after `sqlite3_open_v2`, before any other statement.
/// A Keychain-backed provider belongs in `Credentials`. Until then, passing a provider that
/// returns a key fails loudly instead of silently writing plaintext.
public protocol DatabaseKeyProvider: Sendable {
    /// Raw key bytes, or nil to open unencrypted.
    func databaseKey() throws -> Data?
}

/// One row of a query result. Columns are read by index.
public struct Row {
    fileprivate let stmt: OpaquePointer

    public func isNull(_ i: Int32) -> Bool { sqlite3_column_type(stmt, i) == SQLITE_NULL }
    public func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
    public func int(_ i: Int32) -> Int { Int(sqlite3_column_int64(stmt, i)) }
    public func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
    public func string(_ i: Int32) -> String? {
        guard let p = sqlite3_column_text(stmt, i) else { return nil }
        return String(cString: p)
    }
    public func data(_ i: Int32) -> Data? {
        guard let p = sqlite3_column_blob(stmt, i) else { return nil }
        return Data(bytes: p, count: Int(sqlite3_column_bytes(stmt, i)))
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A thin wrapper over a sqlite3 connection: WAL, a prepared-statement cache, bind/step helpers
/// and (nestable) transactions.
///
/// Thread safety: every entry point takes a recursive lock, so a `Database` may be shared, but the
/// intended owner is a single actor (e.g. `HistoryStore`) which serialises access anyway.
public final class Database: @unchecked Sendable {
    private var handle: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    private var transactionDepth = 0

    /// - Parameter path: a file path, or `":memory:"` for a private in-memory database.
    public init(path: String, keyProvider: (any DatabaseKeyProvider)? = nil) throws {
        if let keyProvider, try keyProvider.databaseKey() != nil {
            throw DatabaseError(code: SQLITE_MISUSE, message: "encryption at rest is not available in this build (no SQLCipher)", sql: nil)
        }
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_NOMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close_v2(db)
            throw DatabaseError(code: rc, message: msg, sql: nil)
        }
        handle = db
        sqlite3_busy_timeout(db, 2000)
        if path != ":memory:" {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
        }
        try execute("PRAGMA foreign_keys=ON")
    }

    public convenience init(url: URL, keyProvider: (any DatabaseKeyProvider)? = nil) throws {
        try self.init(path: url.isFileURL ? url.path : url.absoluteString, keyProvider: keyProvider)
    }

    deinit {
        for stmt in cache.values { sqlite3_finalize(stmt) }
        sqlite3_close_v2(handle)
    }

    // MARK: Execution

    /// Runs one or more statements without bindings or results (DDL, pragmas).
    public func execute(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw DatabaseError(code: rc, message: msg, sql: sql)
        }
    }

    /// Runs a single statement with bindings; returns the number of rows changed.
    @discardableResult
    public func run(_ sql: String, _ bindings: [SQLValue] = []) throws -> Int {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc, sql) }
        return Int(sqlite3_changes(handle))
    }

    /// Runs a query and maps every row.
    public func query<T>(_ sql: String, _ bindings: [SQLValue] = [], _ map: (Row) throws -> T) throws -> [T] {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql, bindings)
        defer { sqlite3_reset(stmt); sqlite3_clear_bindings(stmt) }
        var out: [T] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw error(rc, sql) }
            out.append(try map(Row(stmt: stmt)))
        }
        return out
    }

    /// First row only, or nil.
    public func queryOne<T>(_ sql: String, _ bindings: [SQLValue] = [], _ map: (Row) throws -> T) throws -> T? {
        try query(sql, bindings, map).first
    }

    public var lastInsertRowID: Int64 {
        lock.lock(); defer { lock.unlock() }
        return sqlite3_last_insert_rowid(handle)
    }

    /// Runs `body` inside a transaction (a savepoint when nested). Rolls back on throw.
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        let name = "sp\(transactionDepth)"
        if transactionDepth == 0 { try execute("BEGIN IMMEDIATE") } else { try execute("SAVEPOINT \(name)") }
        transactionDepth += 1
        do {
            let value = try body()
            transactionDepth -= 1
            if transactionDepth == 0 { try execute("COMMIT") } else { try execute("RELEASE \(name)") }
            return value
        } catch {
            transactionDepth -= 1
            if transactionDepth == 0 {
                try? execute("ROLLBACK")
            } else {
                try? execute("ROLLBACK TO \(name)")
                try? execute("RELEASE \(name)")
            }
            throw error
        }
    }

    // MARK: Internals

    private var errorMessage: String { handle.map { String(cString: sqlite3_errmsg($0)) } ?? "no connection" }

    private func error(_ rc: Int32, _ sql: String?) -> DatabaseError {
        DatabaseError(code: rc, message: errorMessage, sql: sql)
    }

    private func prepare(_ sql: String, _ bindings: [SQLValue]) throws -> OpaquePointer {
        let stmt: OpaquePointer
        if let cached = cache[sql] {
            stmt = cached
        } else {
            var p: OpaquePointer?
            let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &p, nil)
            guard rc == SQLITE_OK, let p else { throw error(rc, sql) }
            cache[sql] = p
            stmt = p
        }
        for (i, value) in bindings.enumerated() {
            let idx = Int32(i + 1)
            let rc: Int32
            switch value {
            case .null: rc = sqlite3_bind_null(stmt, idx)
            case .int(let v): rc = sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): rc = sqlite3_bind_double(stmt, idx, v)
            case .text(let v): rc = sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                rc = v.withUnsafeBytes { sqlite3_bind_blob(stmt, idx, $0.baseAddress, Int32($0.count), SQLITE_TRANSIENT) }
            }
            guard rc == SQLITE_OK else {
                sqlite3_clear_bindings(stmt)
                throw error(rc, sql)
            }
        }
        return stmt
    }
}

// Convenience literals for bindings.
extension SQLValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByFloatLiteral, ExpressibleByNilLiteral {
    public init(stringLiteral value: String) { self = .text(value) }
    public init(integerLiteral value: Int64) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(nilLiteral: ()) { self = .null }
}

extension SQLValue {
    public static func optionalText(_ s: String?) -> SQLValue { s.map { .text($0) } ?? .null }
}
