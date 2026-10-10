import AgentDesktopProtocol
import CryptoKit
import Foundation

/// The persistent record of every write request (CLI plan §05 幂等与未知投递).
/// The key is the verified caller (the connection's principal) plus requestId;
/// never the connection, PID or lease. The digest covers method, context
/// and params, so the same ID with other content is a conflict, and a
/// retry with the same content gets the original outcome without running
/// again. A request accepted before the host stopped and never finished
/// becomes `unknown` at the next start and stays that way.
public final class RequestLedger: @unchecked Sendable {
    public enum State: String, Sendable {
        case accepted, completed, failed, unknown
    }

    public struct Record: Equatable, Sendable {
        public var requestId: String
        public var method: String
        public var digest: String
        public var state: State
        public var acceptedAt: String
        public var finishedAt: String?
        public var outcome: JSONValue?
        /// The principal that made it, and the Desktop it named (A5;
        /// nil for requests recorded before the column existed or naming none).
        public var caller: String? = nil
        public var desktopId: String? = nil

        /// The record as request.show, request.list and request.export give it.
        public var json: JSONValue {
            var m: [(String, JSONValue)] = [("requestId", .string(requestId)), ("method", .string(method)),
                                            ("state", .string(state.rawValue)), ("acceptedAt", .string(acceptedAt))]
            if let finishedAt { m.append(("finishedAt", .string(finishedAt))) }
            if let outcome { m.append(("outcome", outcome)) }
            if let caller { m.append(("clientId", .string(caller))) }
            if let desktopId { m.append(("desktopId", .string(desktopId))) }
            return .obj(m)
        }
    }

    public enum Begin: Equatable, Sendable {
        /// First time: run it, then `finish`.
        case fresh
        /// Seen before with the same content.
        case existing(Record)
        /// Seen before with other content.
        case conflict(Record)
    }

    /// How long finished records are kept; older ones are pruned at start.
    public static let retentionDays = 7

    private let db: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let inFlight = NSCondition()
    private var running: Set<String> = []

    /// `path` nil keeps the ledger in memory (tests).
    public init(path: String?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try SQLiteDatabase(path: path)
        self.now = now
        // Before A4 the caller was the connection's uid; every paired app has
        // the same uid, so the key is now the principal (clientId). The old
        // table is kept aside, never reread (retention is a week anyway).
        let callerType = (try? db.query("SELECT type FROM pragma_table_info('requests') WHERE name = 'caller'"))?.first?[0] as? String
        if callerType?.uppercased() == "INTEGER" {
            try db.execute("ALTER TABLE requests RENAME TO requests_pre_a4")
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS requests (
              caller TEXT NOT NULL, request_id TEXT NOT NULL, method TEXT NOT NULL,
              digest TEXT NOT NULL, state TEXT NOT NULL, accepted_at TEXT NOT NULL,
              finished_at TEXT, outcome TEXT, PRIMARY KEY (caller, request_id))
            """)
        // Added with act; older ledgers gain the column.
        if (try? db.query("SELECT dispatch_started_at FROM requests LIMIT 0")) == nil {
            try db.execute("ALTER TABLE requests ADD COLUMN dispatch_started_at TEXT")
        }
        // Added with request.list (A5).
        if (try? db.query("SELECT desktop_id FROM requests LIMIT 0")) == nil {
            try db.execute("ALTER TABLE requests ADD COLUMN desktop_id TEXT")
        }
        try db.execute("CREATE INDEX IF NOT EXISTS requests_by_time ON requests (accepted_at DESC, request_id DESC)")
        // In flight when the previous host stopped. An act that never
        // reached its delivery boundary certainly sent no input; anything
        // else may have taken effect and is unknown.
        let notDispatched = JSONValue.obj([("error", RuntimeError(
            "execution_failed", "the Runtime stopped before this action was dispatched; no input was sent",
            phase: .handler, notSent: true, details: .obj([("delivery", .string("not_dispatched"))])).json)])
        try db.execute("""
            UPDATE requests SET state = 'failed', outcome = ?, finished_at = ?
            WHERE state = 'accepted' AND method = 'act' AND dispatch_started_at IS NULL
            """, [.text(notDispatched.encoded()), .text(Timestamp.string(now()))])
        try db.execute("UPDATE requests SET state = 'unknown' WHERE state = 'accepted'")
        let cutoff = Timestamp.string(now().addingTimeInterval(-Double(Self.retentionDays) * 86400))
        try db.execute("DELETE FROM requests WHERE accepted_at < ? AND state != 'accepted'", [.text(cutoff)])
    }

    /// Canonical digest of what the request asks for.
    public static func digest(_ request: RuntimeRequest) -> String {
        let canonical = JSONValue.obj([
            ("method", .string(request.method)),
            ("context", request.context.json),
            ("params", request.params),
        ]).canonical.encoded()
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Record the request as accepted, unless it is already known. A
    /// duplicate that arrives while the original runs waits for it.
    public func begin(caller: String, _ request: RuntimeRequest, desktopId: String? = nil) throws -> Begin {
        let key = "\(caller)/\(request.requestId)"
        let digest = Self.digest(request)
        inFlight.lock()
        while running.contains(key) { inFlight.wait() }
        defer { inFlight.unlock() }
        if let existing = try record(caller: caller, requestId: request.requestId) {
            return existing.digest == digest ? .existing(existing) : .conflict(existing)
        }
        try db.execute("""
            INSERT INTO requests (caller, request_id, method, digest, state, accepted_at, desktop_id)
            VALUES (?, ?, ?, ?, 'accepted', ?, ?)
            """, [.text(caller), .text(request.requestId), .text(request.method), .text(digest),
                  .text(Timestamp.string(now())), desktopId.map { .text($0) } ?? .null])
        running.insert(key)
        return .fresh
    }

    /// The delivery boundary of an act: from here on, input may reach the
    /// app, so an interruption leaves the outcome unknown.
    public func markDispatching(caller: String, requestId: String) throws {
        try db.execute("UPDATE requests SET dispatch_started_at = ? WHERE caller = ? AND request_id = ?",
                        [.text(Timestamp.string(now())), .text(caller), .text(requestId)])
    }

    /// Drop a fresh request that certainly did nothing, so its requestId can
    /// be retried; duplicates waiting on it then run as fresh.
    public func forget(caller: String, requestId: String) throws {
        defer {
            inFlight.lock()
            running.remove("\(caller)/\(requestId)")
            inFlight.broadcast()
            inFlight.unlock()
        }
        try db.execute("DELETE FROM requests WHERE caller = ? AND request_id = ? AND state = 'accepted'",
                       [.text(caller), .text(requestId)])
    }

    /// Store the outcome of a fresh request.
    public func finish(caller: String, requestId: String, _ result: Result<JSONValue, RuntimeError>) throws {
        // Always wake duplicate callers, even when the outcome cannot be saved.
        defer {
            inFlight.lock()
            running.remove("\(caller)/\(requestId)")
            inFlight.broadcast()
            inFlight.unlock()
        }
        let (state, outcome): (State, JSONValue) = {
            switch result {
            case let .success(d): return (.completed, .obj([("data", d)]))
            case let .failure(e): return (.failed, .obj([("error", e.json)]))
            }
        }()
        try db.execute("UPDATE requests SET state = ?, finished_at = ?, outcome = ? WHERE caller = ? AND request_id = ?",
                        [.text(state.rawValue), .text(Timestamp.string(now())), .text(outcome.encoded()),
                         .text(caller), .text(requestId)])
    }

    private static let columns = "request_id, method, digest, state, accepted_at, finished_at, outcome, caller, desktop_id"

    private static func row(_ r: [Any?]) -> Record {
        Record(requestId: r[0] as! String, method: r[1] as! String, digest: r[2] as! String,
               state: State(rawValue: r[3] as! String) ?? .unknown, acceptedAt: r[4] as! String,
               finishedAt: r[5] as? String,
               outcome: (r[6] as? String).flatMap { try? StrictJSON.parse($0) },
               caller: r[7] as? String, desktopId: r[8] as? String)
    }

    public func record(caller: String, requestId: String) throws -> Record? {
        try db.query("SELECT \(Self.columns) FROM requests WHERE caller = ? AND request_id = ?",
                     [.text(caller), .text(requestId)]).first.map(Self.row)
    }

    /// What request.list and request.export select. Every field narrows.
    public struct Filter: Sendable {
        public var caller: String?
        public var method: String?
        public var state: State?
        public var desktopId: String?
        public var since: Date?
        public init() {}
    }

    /// Records newest first, `limit` of them after the cursor
    /// (acceptedAt|requestId|caller of the last one given); `next` is nil at the end.
    public func list(_ f: Filter, after: String?, limit: Int) throws -> (records: [Record], next: String?) {
        var sql = "SELECT \(Self.columns) FROM requests WHERE 1 = 1"
        var args: [SQLiteDatabase.Value] = []
        if let c = f.caller { sql += " AND caller = ?"; args.append(.text(c)) }
        if let m = f.method { sql += " AND method = ?"; args.append(.text(m)) }
        if let st = f.state { sql += " AND state = ?"; args.append(.text(st.rawValue)) }
        if let d = f.desktopId { sql += " AND desktop_id = ?"; args.append(.text(d)) }
        // Compared in the ledger's own spelling (UTC, milliseconds, Z), so any
        // valid date-time the caller gave compares right (Codex on a0c3211);
        // never older than the retention, whether or not a restart pruned it.
        var from = now().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        if let since = f.since, since > from { from = since }
        sql += " AND accepted_at >= ?"
        args.append(.text(Timestamp.string(from)))
        if let after {
            let p = after.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            if p.count == 3 {
                sql += " AND (accepted_at < ? OR (accepted_at = ? AND (request_id < ? OR (request_id = ? AND caller < ?))))"
                args += [.text(p[0]), .text(p[0]), .text(p[1]), .text(p[1]), .text(p[2])]
            }
        }
        sql += " ORDER BY accepted_at DESC, request_id DESC, caller DESC LIMIT ?"
        args.append(.int(Int64(limit + 1)))
        var rows = try db.query(sql, args).map(Self.row)
        var next: String?
        if rows.count > limit {
            rows.removeLast()
            next = rows.last.map(Self.cursor)
        }
        return (rows, next)
    }

    static func cursor(_ r: Record) -> String { "\(r.acceptedAt)|\(r.requestId)|\(r.caller ?? "")" }

    /// What the original request answered, for a duplicate.
    public static func replay(_ record: Record) -> Result<JSONValue, RuntimeError> {
        switch record.state {
        case .completed:
            return .success(record.outcome?["data"] ?? .obj([]))
        case .failed:
            return .failure(record.outcome?["error"].flatMap(RuntimeError.init(json:))
                ?? RuntimeError("execution_failed", "the original request failed", phase: .handler))
        case .unknown, .accepted:
            return .failure(RuntimeError(
                "request_acceptance_unknown",
                "request \(record.requestId) was accepted before the Runtime restarted and its outcome is unknown; check the target before deciding on a new request",
                phase: .handler, details: .obj([("requestId", .string(record.requestId))])))
        }
    }
}

extension JSONValue {
    /// Object members sorted by key, recursively: one spelling per value.
    var canonical: JSONValue {
        switch self {
        case let .object(members):
            return .object(members.sorted { $0.key < $1.key }.map { (key: $0.key, value: $0.value.canonical) })
        case let .array(items):
            return .array(items.map(\.canonical))
        default:
            return self
        }
    }
}
