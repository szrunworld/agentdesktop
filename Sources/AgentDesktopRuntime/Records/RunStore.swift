import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// One platform Run (Architecture Decision v2.2 §3): an execution attempt
/// with an owner, an origin and a lifetime, and three independent facts —
/// where it is (phase), how it ended (outcome) and whether it can still send
/// input (quiescence). A Run that ended stays queryable for the retention
/// window; its record never means it is alive.
public struct RunRecord: Equatable, Sendable {
    /// Who holds the Run's authority.
    public enum Ownership: String, Sendable { case externalClient = "external_client", platform }
    /// Which part of the product started it.
    public enum Origin: String, Sendable, CaseIterable {
        case agentHub = "agent_hub", guiExplorer = "gui_explorer", workflowReplay = "workflow_replay", user
    }
    /// What ends it besides an explicit stop: the owner's control connection
    /// (Delegated) or nothing short of stop, revoke or global stop (Durable).
    public enum Lifetime: String, Sendable { case connectionScoped = "connection_scoped", platformDurable = "platform_durable" }
    public enum Phase: String, Sendable, CaseIterable {
        case queued, running, waitingApproval = "waiting_approval", waitingInput = "waiting_input", stopping, ended
    }
    public enum Outcome: String, Sendable, CaseIterable { case success, failed, cancelled, unknown }
    /// `confirmed` proves the Run can no longer send input through the
    /// Runtime; `pending` is a stop in progress; `not_confirmed` makes no claim.
    public enum Quiescence: String, Sendable { case notConfirmed = "not_confirmed", pending, confirmed }

    public var runId: String
    public var kind: String
    public var origin: Origin
    public var ownership: Ownership
    public var lifetime: Lifetime
    /// The principal behind an external_client Run (reserved for pairing:
    /// "local:<uid>" until AgentHub issues clientIds). nil for platform Runs.
    public var clientId: String?
    /// The control connection a connection_scoped Run lives on.
    public var connectionId: String?
    public var sessionId: String
    public var desktopId: String
    public var phase: Phase
    public var outcome: Outcome?
    public var quiescence: Quiescence
    public var closingReason: String?
    /// Grows with every change, so a reader can drop stale snapshots.
    public var revision: Int
    public var createdAt: String
    public var endedAt: String?
    public var receipts: [String]
    /// Actions of this Run whose delivery is unknown: they make the outcome unknown.
    public var unknownActions: Int

    public var isEnded: Bool { phase == .ended }

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("runId", .string(runId)), ("kind", .string(kind)), ("origin", .string(origin.rawValue)),
            ("ownership", .string(ownership.rawValue)), ("lifetime", .string(lifetime.rawValue)),
            ("clientId", clientId.map(JSONValue.string) ?? .null), ("connectionId", connectionId.map(JSONValue.string) ?? .null),
            ("sessionId", .string(sessionId)), ("desktopId", .string(desktopId)),
            ("phase", .string(phase.rawValue)), ("outcome", outcome.map { .string($0.rawValue) } ?? .null),
            ("quiescence", .string(quiescence.rawValue)), ("closingReason", closingReason.map(JSONValue.string) ?? .null),
            ("revision", .int(revision)), ("createdAt", .string(createdAt)),
        ]
        if let endedAt { m.append(("endedAt", .string(endedAt))) }
        m.append(("receipts", .array(receipts.map(JSONValue.string))))
        m.append(("unknownActions", .int(unknownActions)))
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
    private static let columns = """
        run_id, kind, origin, ownership, lifetime, client_id, connection_id, session_id, desktop_id, phase, outcome,
        quiescence, closing_reason, revision, created_at, ended_at, receipts, unknown_actions
        """

    public init(path: String?, now: @escaping @Sendable () -> Date = { Date() }) throws {
        db = try SQLiteDatabase(path: path)
        self.now = now
        // The pre-v2.2 table (one state column) is kept aside, never reread.
        if (try? db.query("SELECT state FROM runs LIMIT 0")) != nil {
            try db.execute("ALTER TABLE runs RENAME TO runs_pre_v22")
        }
        try db.execute("""
            CREATE TABLE IF NOT EXISTS runs (run_id TEXT PRIMARY KEY, kind TEXT NOT NULL, origin TEXT NOT NULL,
              ownership TEXT NOT NULL, lifetime TEXT NOT NULL, client_id TEXT, connection_id TEXT,
              session_id TEXT NOT NULL, desktop_id TEXT NOT NULL, phase TEXT NOT NULL, outcome TEXT,
              quiescence TEXT NOT NULL, closing_reason TEXT, revision INTEGER NOT NULL, created_at TEXT NOT NULL,
              ended_at TEXT, receipts TEXT NOT NULL, unknown_actions INTEGER NOT NULL DEFAULT 0,
              CHECK (phase != 'ended' OR quiescence = 'confirmed'))
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS runs_by_created ON runs (created_at, run_id)")
        try db.execute("""
            CREATE TABLE IF NOT EXISTS events (run_id TEXT NOT NULL, seq INTEGER NOT NULL, at TEXT NOT NULL,
              type TEXT NOT NULL, data TEXT NOT NULL, PRIMARY KEY (run_id, seq))
            """)
        try recoverAfterRestart()
        let cutoff = Timestamp.string(now().addingTimeInterval(-Double(Self.retentionDays) * 86400))
        try db.execute("DELETE FROM events WHERE run_id IN (SELECT run_id FROM runs WHERE created_at < ? AND ended_at IS NOT NULL)", [.text(cutoff)])
        try db.execute("DELETE FROM runs WHERE created_at < ? AND ended_at IS NOT NULL", [.text(cutoff)])
    }

    /// The host that ran them is gone, and its input with it: every Run not
    /// ended ends now, quiescent. If an action had crossed its delivery
    /// boundary without a recorded result, or any action was already
    /// unknown, the outcome is unknown; nothing is redone (ADR v2.2 §3).
    private func recoverAfterRestart() throws {
        let at = Timestamp.string(now())
        for row in try db.query("SELECT run_id, unknown_actions, revision FROM runs WHERE phase != 'ended'") {
            let id = row[0] as! String
            var unknown = Int(row[1] as! Int64)
            unknown += inFlightActions(id)
            let outcome: RunRecord.Outcome = unknown > 0 ? .unknown : .cancelled
            try db.execute("""
                UPDATE runs SET phase = 'ended', outcome = ?, quiescence = 'confirmed', closing_reason = 'runtime_restarted',
                  ended_at = ?, unknown_actions = ?, revision = ? WHERE run_id = ?
                """, [.text(outcome.rawValue), .text(at), .int(Int64(unknown)), .int((row[2] as! Int64) + 1), .text(id)])
            appendEvent(id, "run.ended", .obj([("phase", .string("ended")), ("outcome", .string(outcome.rawValue)),
                                               ("reason", .string("runtime_restarted"))]))
        }
    }

    /// Actions dispatched with no result event after them.
    private func inFlightActions(_ runId: String) -> Int {
        var open = Set<String>()
        for e in events(runId, after: 0, limit: 100_000) {
            let rid = e["data"]?["requestId"]?.stringValue ?? e["data"]?["receipt"]?["requestId"]?.stringValue
            guard let rid else { continue }
            switch e["type"]?.stringValue {
            case "action.dispatched": open.insert(rid)
            case "action.completed", "action.failed", "action.unknown": open.remove(rid)
            default: break
            }
        }
        return open.count
    }

    private func values(_ r: RunRecord) -> [SQLiteDatabase.Value] {
        func opt(_ s: String?) -> SQLiteDatabase.Value { s.map { .text($0) } ?? .null }
        return [.text(r.runId), .text(r.kind), .text(r.origin.rawValue), .text(r.ownership.rawValue), .text(r.lifetime.rawValue),
                opt(r.clientId), opt(r.connectionId), .text(r.sessionId), .text(r.desktopId), .text(r.phase.rawValue),
                opt(r.outcome?.rawValue), .text(r.quiescence.rawValue), opt(r.closingReason), .int(Int64(r.revision)),
                .text(r.createdAt), opt(r.endedAt), .text(JSONValue.array(r.receipts.map(JSONValue.string)).encoded()),
                .int(Int64(r.unknownActions))]
    }

    func create(_ r: RunRecord) {
        try? db.execute("INSERT INTO runs (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", values(r))
        appendEvent(r.runId, "run.started", .obj([
            ("kind", .string(r.kind)), ("origin", .string(r.origin.rawValue)), ("ownership", .string(r.ownership.rawValue)),
            ("lifetime", .string(r.lifetime.rawValue)), ("desktopId", .string(r.desktopId)), ("sessionId", .string(r.sessionId)),
        ]))
    }

    func update(_ r: RunRecord) {
        try? db.execute("INSERT OR REPLACE INTO runs (\(Self.columns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", values(r))
        changed.lock(); changed.broadcast(); changed.unlock()
    }

    static func record(_ row: [Any?]) -> RunRecord {
        RunRecord(runId: row[0] as! String, kind: row[1] as! String,
                  origin: RunRecord.Origin(rawValue: row[2] as! String) ?? .agentHub,
                  ownership: RunRecord.Ownership(rawValue: row[3] as! String) ?? .externalClient,
                  lifetime: RunRecord.Lifetime(rawValue: row[4] as! String) ?? .connectionScoped,
                  clientId: row[5] as? String, connectionId: row[6] as? String,
                  sessionId: row[7] as! String, desktopId: row[8] as! String,
                  phase: RunRecord.Phase(rawValue: row[9] as! String) ?? .ended,
                  outcome: (row[10] as? String).flatMap(RunRecord.Outcome.init(rawValue:)),
                  quiescence: RunRecord.Quiescence(rawValue: row[11] as! String) ?? .confirmed,
                  closingReason: row[12] as? String, revision: Int(row[13] as! Int64), createdAt: row[14] as! String,
                  endedAt: row[15] as? String,
                  receipts: (try? StrictJSON.parse(row[16] as! String))?.arrayValue?.compactMap(\.stringValue) ?? [],
                  unknownActions: Int(row[17] as! Int64))
    }

    public func find(_ runId: String) -> RunRecord? {
        (try? db.query("SELECT \(Self.columns) FROM runs WHERE run_id = ?", [.text(runId)]).first).map(Self.record)
    }

    public struct ListFilter: Sendable {
        public var clientId: String?
        public var origin: RunRecord.Origin?
        public var phase: RunRecord.Phase?
        public var desktopId: String?
        public var activeOnly = false
        public init() {}
    }

    /// Newest first; `after` is the last item's cursor ("createdAt|runId").
    public func list(_ f: ListFilter, after: String?, limit: Int) -> (runs: [RunRecord], next: String?) {
        var sql = "SELECT \(Self.columns) FROM runs WHERE 1 = 1"
        var args: [SQLiteDatabase.Value] = []
        if let c = f.clientId { sql += " AND client_id = ?"; args.append(.text(c)) }
        if let o = f.origin { sql += " AND origin = ?"; args.append(.text(o.rawValue)) }
        if let p = f.phase { sql += " AND phase = ?"; args.append(.text(p.rawValue)) }
        if let d = f.desktopId { sql += " AND desktop_id = ?"; args.append(.text(d)) }
        if f.activeOnly { sql += " AND phase != 'ended'" }
        if let after {
            let parts = after.split(separator: "|", maxSplits: 1).map(String.init)
            if parts.count == 2 {
                sql += " AND (created_at < ? OR (created_at = ? AND run_id < ?))"
                args += [.text(parts[0]), .text(parts[0]), .text(parts[1])]
            }
        }
        sql += " ORDER BY created_at DESC, run_id DESC LIMIT ?"
        args.append(.int(Int64(limit + 1)))
        var rows = ((try? db.query(sql, args)) ?? []).map(Self.record)
        var next: String?
        if rows.count > limit {
            rows.removeLast()
            next = rows.last.map { "\($0.createdAt)|\($0.runId)" }
        }
        return (rows, next)
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

    /// Events of every Run in the order they were written, after a global
    /// cursor (the event's rowid), optionally only Runs of one principal.
    public func eventsSince(_ cursor: Int, clientId: String?, limit: Int) -> [(cursor: Int, event: JSONValue)] {
        let rows = (try? db.query("""
            SELECT e.rowid, e.run_id, e.seq, e.at, e.type, e.data FROM events e JOIN runs r ON r.run_id = e.run_id
            WHERE e.rowid > ? AND (? IS NULL OR r.client_id = ?) ORDER BY e.rowid LIMIT ?
            """, [.int(Int64(cursor)), clientId.map { .text($0) } ?? .null, clientId.map { .text($0) } ?? .null,
                  .int(Int64(limit))])) ?? []
        return rows.map { r in
            (Int(r[0] as! Int64), .obj([("runId", .string(r[1] as! String)), ("sequence", .int(Int(r[2] as! Int64))),
                                        ("at", .string(r[3] as! String)), ("type", .string(r[4] as! String)),
                                        ("data", (try? StrictJSON.parse(r[5] as! String)) ?? .obj([]))]))
        }
    }

    /// The global cursor range still stored: (oldest - 1, newest).
    public func eventCursorRange() -> (floor: Int, latest: Int) {
        let r = (try? db.query("SELECT COALESCE(MIN(rowid), 1) - 1, COALESCE(MAX(rowid), 0) FROM events").first) ?? nil
        return (Int(r?[0] as? Int64 ?? 0), Int(r?[1] as? Int64 ?? 0))
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
