import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// One execution attempt and what happened in it. A Run that ended stays
/// queryable for the retention window; its record never means it is alive.
public struct RunRecord: Equatable, Sendable {
    public enum State: String, Sendable {
        case running, cancelling, completed, cancelled, failed, interrupted
        public var terminal: Bool { ![.running, .cancelling].contains(self) }
    }

    public var runId: String
    public var caller: uid_t
    /// "act": one action from a short command; "exec": a session exec shell.
    public var kind: String
    public var sessionId: String
    public var desktopId: String
    public var state: State
    /// True once it is certain no further input of this Run will be sent.
    public var quiescent: Bool
    public var createdAt: String
    public var endedAt: String?
    public var endReason: String?
    public var receipts: [String]

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("runId", .string(runId)), ("kind", .string(kind)), ("sessionId", .string(sessionId)),
            ("desktopId", .string(desktopId)), ("state", .string(state.rawValue)), ("quiescent", .bool(quiescent)),
            ("createdAt", .string(createdAt)),
        ]
        if let endedAt { m.append(("endedAt", .string(endedAt))) }
        if let endReason { m.append(("endReason", .string(endReason))) }
        m.append(("receipts", .array(receipts.map(JSONValue.string))))
        return .obj(m)
    }
}

/// Runs and their events in SQLite beside the request ledger. Events carry
/// a per-Run sequence number; a reader resumes after the last one it saw.
public final class RunStore: @unchecked Sendable {
    public static let retentionDays = 7
    private let db: SQLiteDatabase
    private let now: @Sendable () -> Date
    private let changed = NSCondition()

    public init(path: String?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try SQLiteDatabase(path: path)
        self.now = now
        try db.execute("""
            CREATE TABLE IF NOT EXISTS runs (run_id TEXT PRIMARY KEY, caller INTEGER NOT NULL, kind TEXT NOT NULL,
              session_id TEXT NOT NULL, desktop_id TEXT NOT NULL, state TEXT NOT NULL, quiescent INTEGER NOT NULL,
              created_at TEXT NOT NULL, ended_at TEXT, end_reason TEXT, receipts TEXT NOT NULL)
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS events (run_id TEXT NOT NULL, seq INTEGER NOT NULL, at TEXT NOT NULL,
              type TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (run_id, seq))
            """)
        // The host that ran them is gone, and its input with it.
        let at = Timestamp.string(now())
        for row in try db.query("SELECT run_id FROM runs WHERE state IN ('running','cancelling')") {
            let id = row[0] as! String
            try db.execute("UPDATE runs SET state = 'interrupted', quiescent = 1, ended_at = ?, end_reason = 'runtime_restarted' WHERE run_id = ?",
                           [.text(at), .text(id)])
            appendEvent(id, "run.ended", .obj([("state", .string("interrupted")), ("reason", .string("runtime_restarted"))]))
        }
        let cutoff = Timestamp.string(now().addingTimeInterval(-Double(Self.retentionDays) * 86400))
        try db.execute("DELETE FROM events WHERE run_id IN (SELECT run_id FROM runs WHERE created_at < ? AND ended_at IS NOT NULL)", [.text(cutoff)])
        try db.execute("DELETE FROM runs WHERE created_at < ? AND ended_at IS NOT NULL", [.text(cutoff)])
    }

    func create(_ r: RunRecord) {
        try? db.execute("""
            INSERT INTO runs (run_id, caller, kind, session_id, desktop_id, state, quiescent, created_at, receipts)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, '[]')
            """, [.text(r.runId), .int(Int64(r.caller)), .text(r.kind), .text(r.sessionId), .text(r.desktopId),
                  .text(r.state.rawValue), .text(r.createdAt)])
        appendEvent(r.runId, "run.started", .obj([("kind", .string(r.kind)), ("desktopId", .string(r.desktopId)),
                                                  ("sessionId", .string(r.sessionId))]))
    }

    func update(_ r: RunRecord) {
        let receipts = JSONValue.array(r.receipts.map(JSONValue.string)).encoded()
        try? db.execute("""
            UPDATE runs SET state = ?, quiescent = ?, ended_at = ?, end_reason = ?, receipts = ? WHERE run_id = ?
            """, [.text(r.state.rawValue), .int(r.quiescent ? 1 : 0), r.endedAt.map { .text($0) } ?? .null,
                  r.endReason.map { .text($0) } ?? .null, .text(receipts), .text(r.runId)])
        changed.lock(); changed.broadcast(); changed.unlock()
    }

    public func find(_ runId: String) -> RunRecord? {
        guard let row = try? db.query("""
            SELECT run_id, caller, kind, session_id, desktop_id, state, quiescent, created_at, ended_at, end_reason, receipts
            FROM runs WHERE run_id = ?
            """, [.text(runId)]).first else { return nil }
        let receipts = (try? StrictJSON.parse(row[10] as! String))?.arrayValue?.compactMap(\.stringValue) ?? []
        return RunRecord(runId: row[0] as! String, caller: uid_t(row[1] as! Int64), kind: row[2] as! String,
                         sessionId: row[3] as! String, desktopId: row[4] as! String,
                         state: RunRecord.State(rawValue: row[5] as! String) ?? .interrupted,
                         quiescent: (row[6] as! Int64) != 0, createdAt: row[7] as! String,
                         endedAt: row[8] as? String, endReason: row[9] as? String, receipts: receipts)
    }

    @discardableResult
    func appendEvent(_ runId: String, _ type: String, _ data: JSONValue) -> Int {
        let seq = ((try? db.query("SELECT COALESCE(MAX(seq), 0) FROM events WHERE run_id = ?", [.text(runId)]).first?[0]) as? Int64 ?? 0) + 1
        try? db.execute("INSERT INTO events (run_id, seq, at, type, data) VALUES (?, ?, ?, ?, ?)",
                        [.text(runId), .int(seq), .text(Timestamp.string(now())), .text(type), .text(data.encoded())])
        changed.lock(); changed.broadcast(); changed.unlock()
        return Int(seq)
    }

    public func events(_ runId: String, after: Int, limit: Int) -> [JSONValue] {
        ((try? db.query("SELECT seq, at, type, data FROM events WHERE run_id = ? AND seq > ? ORDER BY seq LIMIT ?",
                        [.text(runId), .int(Int64(after)), .int(Int64(limit))])) ?? []).map { r in
            .obj([("runId", .string(runId)), ("sequence", .int(Int(r[0] as! Int64))), ("at", .string(r[1] as! String)),
                  ("type", .string(r[2] as! String)), ("data", (try? StrictJSON.parse(r[3] as! String)) ?? .obj([]))])
        }
    }

    /// Wait until `predicate` holds for the Run or `deadline` passes.
    func wait(_ runId: String, until deadline: Date, _ predicate: (RunRecord) -> Bool) -> RunRecord? {
        changed.lock()
        defer { changed.unlock() }
        while true {
            let r = find(runId)
            if let r, predicate(r) { return r }
            if Date() >= deadline { return r }
            _ = changed.wait(until: min(deadline, Date().addingTimeInterval(0.5)))
        }
    }
}
