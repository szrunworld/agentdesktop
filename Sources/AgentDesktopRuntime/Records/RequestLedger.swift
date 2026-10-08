import AgentDesktopContracts
import AgentDesktopProtocol
import CryptoKit
import Foundation

/// The persistent record of every write request (CLI plan §05 幂等与未知投递).
/// The key is the verified caller (the connection's uid) plus requestId;
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
        try db.execute("""
            CREATE TABLE IF NOT EXISTS requests (
              caller INTEGER NOT NULL, request_id TEXT NOT NULL, method TEXT NOT NULL,
              digest TEXT NOT NULL, state TEXT NOT NULL, accepted_at TEXT NOT NULL,
              finished_at TEXT, outcome TEXT, PRIMARY KEY (caller, request_id))
            """)
        // Added with act; older ledgers gain the column.
        if (try? db.query("SELECT dispatch_started_at FROM requests LIMIT 0")) == nil {
            try db.execute("ALTER TABLE requests ADD COLUMN dispatch_started_at TEXT")
        }
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
    public func begin(caller: uid_t, _ request: RuntimeRequest) throws -> Begin {
        let key = "\(caller)/\(request.requestId)"
        let digest = Self.digest(request)
        inFlight.lock()
        while running.contains(key) { inFlight.wait() }
        defer { inFlight.unlock() }
        if let existing = try record(caller: caller, requestId: request.requestId) {
            return existing.digest == digest ? .existing(existing) : .conflict(existing)
        }
        try db.execute("""
            INSERT INTO requests (caller, request_id, method, digest, state, accepted_at)
            VALUES (?, ?, ?, ?, 'accepted', ?)
            """, [.int(Int64(caller)), .text(request.requestId), .text(request.method), .text(digest),
                  .text(Timestamp.string(now()))])
        running.insert(key)
        return .fresh
    }

    /// The delivery boundary of an act: from here on, input may reach the
    /// app, so an interruption leaves the outcome unknown.
    public func markDispatching(caller: uid_t, requestId: String) throws {
        try db.execute("UPDATE requests SET dispatch_started_at = ? WHERE caller = ? AND request_id = ?",
                        [.text(Timestamp.string(now())), .int(Int64(caller)), .text(requestId)])
    }

    /// Store the outcome of a fresh request.
    public func finish(caller: uid_t, requestId: String, _ result: Result<JSONValue, RuntimeError>) throws {
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
                         .int(Int64(caller)), .text(requestId)])
    }

    public func record(caller: uid_t, requestId: String) throws -> Record? {
        let rows = try db.query("""
            SELECT request_id, method, digest, state, accepted_at, finished_at, outcome
            FROM requests WHERE caller = ? AND request_id = ?
            """, [.int(Int64(caller)), .text(requestId)])
        guard let r = rows.first else { return nil }
        return Record(requestId: r[0] as! String, method: r[1] as! String, digest: r[2] as! String,
                      state: State(rawValue: r[3] as! String) ?? .unknown, acceptedAt: r[4] as! String,
                      finishedAt: r[5] as? String,
                      outcome: (r[6] as? String).flatMap { try? StrictJSON.parse($0) })
    }

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
