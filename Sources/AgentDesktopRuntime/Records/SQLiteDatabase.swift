import Foundation
import SQLite3

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A small serialized SQLite handle for the Runtime's records.
final class SQLiteDatabase: @unchecked Sendable {
    enum Value { case text(String), int(Int64), null }

    private var db: OpaquePointer?
    private let lock = NSLock()

    /// `path` nil keeps the database in memory (tests).
    init(path: String?) throws {
        let target = path ?? ":memory:"
        if let path { try Self.restrictToOwner(path) }
        guard sqlite3_open_v2(target, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "cannot open"
            sqlite3_close(db)
            throw RuntimeStoreError("sqlite open \(target): \(message)")
        }
        try execute("PRAGMA journal_mode=WAL")
        try execute("PRAGMA synchronous=FULL")
    }

    deinit { sqlite3_close(db) }

    /// Owner-only before SQLite opens it (SEC-01): the directory 0700, the
    /// file created 0600 (never briefly readable), and a database left
    /// readable by an earlier build repaired, its -wal and -shm included.
    /// SQLite gives new -wal and -shm files the main file's mode.
    static func restrictToOwner(_ path: String) throws {
        let fm = FileManager.default
        let dir = (path as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard chmod(dir, 0o700) == 0 else { throw RuntimeStoreError("cannot make \(dir) owner-only") }
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RuntimeStoreError("cannot open \(path): \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        guard fchmod(fd, 0o600) == 0 else { throw RuntimeStoreError("cannot make \(path) owner-only") }
        for suffix in ["-wal", "-shm", "-journal"] where fm.fileExists(atPath: path + suffix) {
            guard chmod(path + suffix, 0o600) == 0 else { throw RuntimeStoreError("cannot make \(path)\(suffix) owner-only") }
        }
    }

    func execute(_ sql: String, _ args: [Value] = []) throws {
        _ = try query(sql, args)
    }

    /// Rows as arrays of column values (text, integer or nil).
    @discardableResult
    func query(_ sql: String, _ args: [Value] = []) throws -> [[Any?]] {
        lock.lock()
        defer { lock.unlock() }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw RuntimeStoreError("sqlite prepare: \(String(cString: sqlite3_errmsg(db)))")
        }
        defer { sqlite3_finalize(stmt) }
        for (i, a) in args.enumerated() {
            let at = Int32(i + 1)
            switch a {
            case let .text(s): sqlite3_bind_text(stmt, at, s, -1, SQLITE_TRANSIENT)
            case let .int(v): sqlite3_bind_int64(stmt, at, v)
            case .null: sqlite3_bind_null(stmt, at)
            }
        }
        var rows: [[Any?]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw RuntimeStoreError("sqlite step: \(String(cString: sqlite3_errmsg(db)))") }
            var row: [Any?] = []
            for c in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, c) {
                case SQLITE_INTEGER: row.append(sqlite3_column_int64(stmt, c))
                case SQLITE_NULL: row.append(nil)
                default: row.append(String(cString: sqlite3_column_text(stmt, c)))
                }
            }
            rows.append(row)
        }
        return rows
    }

    /// Changed rows of the last statement on this connection.
    var changes: Int { Int(sqlite3_changes(db)) }

    /// Run `body` in one transaction under the handle's lock order.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try execute("COMMIT")
            return v
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

struct RuntimeStoreError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}
