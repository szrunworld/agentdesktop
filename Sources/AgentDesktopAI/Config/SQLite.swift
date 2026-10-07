import Foundation
import SQLite3

struct SQLiteError: Error, CustomStringConvertible {
    let code: Int32
    let message: String
    var description: String { "sqlite \(code): \(message)" }
}

enum SQLValue: Equatable {
    case null
    case int(Int64)
    case text(String)

    var text: String? { if case let .text(s) = self { return s }; return nil }
    var int: Int64? { if case let .int(i) = self { return i }; return nil }
}

private let SQLITE_TRANSIENT_DESTRUCTOR = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// A single SQLite connection. Not thread-safe; owned by one actor.
final class SQLiteDatabase {
    private var db: OpaquePointer?
    let path: String

    init(path: String) throws {
        self.path = path
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(path, &db, flags, nil)
        guard rc == SQLITE_OK else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "open failed"
            sqlite3_close(db)
            throw SQLiteError(code: rc, message: msg)
        }
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA foreign_keys=ON")
        try exec("PRAGMA busy_timeout=5000")
    }

    deinit { sqlite3_close(db) }

    func exec(_ sql: String) throws {
        var err: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &err)
        if rc != SQLITE_OK {
            let msg = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw SQLiteError(code: rc, message: msg)
        }
    }

    @discardableResult
    func run(_ sql: String, _ args: [SQLValue] = []) throws -> Int {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else { throw error(rc) }
        return Int(sqlite3_changes(db))
    }

    func rows(_ sql: String, _ args: [SQLValue] = []) throws -> [[SQLValue]] {
        let stmt = try prepare(sql, args)
        defer { sqlite3_finalize(stmt) }
        var out: [[SQLValue]] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return out }
            guard rc == SQLITE_ROW else { throw error(rc) }
            var row: [SQLValue] = []
            for i in 0..<sqlite3_column_count(stmt) {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_NULL: row.append(.null)
                case SQLITE_INTEGER: row.append(.int(sqlite3_column_int64(stmt, i)))
                default: row.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                }
            }
            out.append(row)
        }
    }

    func row(_ sql: String, _ args: [SQLValue] = []) throws -> [SQLValue]? {
        try rows(sql, args).first
    }

    /// Run `body` in an IMMEDIATE transaction; any throw rolls back.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        try exec("BEGIN IMMEDIATE")
        do {
            let v = try body()
            try exec("COMMIT")
            return v
        } catch {
            try? exec("ROLLBACK")
            throw error
        }
    }

    private func prepare(_ sql: String, _ args: [SQLValue]) throws -> OpaquePointer? {
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK else { throw error(rc) }
        for (i, a) in args.enumerated() {
            let idx = Int32(i + 1)
            switch a {
            case .null: sqlite3_bind_null(stmt, idx)
            case let .int(v): sqlite3_bind_int64(stmt, idx, v)
            case let .text(s): sqlite3_bind_text(stmt, idx, s, -1, SQLITE_TRANSIENT_DESTRUCTOR)
            }
        }
        return stmt
    }

    private func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: rc, message: String(cString: sqlite3_errmsg(db)))
    }
}
