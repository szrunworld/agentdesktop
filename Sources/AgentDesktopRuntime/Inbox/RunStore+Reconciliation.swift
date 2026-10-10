import AgentDesktopProtocol
import CryptoKit
import Foundation

/// One finding about an action whose delivery is unknown (run.reconcile).
/// Append-only: it never changes the action's receipt, the request's
/// outcome or the Run's outcome (E2E-08, RT-19).
public struct Reconciliation: Equatable, Sendable {
    public enum Verdict: String, Sendable, CaseIterable {
        case executed, notExecuted = "not_executed", stillUnknown = "still_unknown"
        /// executed and not_executed close the question; still_unknown does not.
        public var isFinal: Bool { self != .stillUnknown }
    }

    public enum Source: String, Sendable {
        /// The Runtime checked it itself. Not accepted from callers yet.
        case runtimeObservation = "runtime_observation"
        case operatorAttestation = "operator_attestation"
        case externalReference = "external_reference"
    }

    public var reconciliationId: String
    public var runId: String
    public var actionRequestId: String
    public var sequence: Int
    public var verdict: Verdict
    public var source: Source
    public var note: String?
    public var evidenceRefs: [String]
    /// The principal that recorded it.
    public var by: String
    public var at: String
    /// The run.reconcile request that recorded it.
    public var requestId: String

    /// `full` false leaves out the owner's own words (note, evidence) for
    /// the client whose action it was.
    public func json(full: Bool = true) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("reconciliationId", .string(reconciliationId)), ("runId", .string(runId)),
            ("actionRequestId", .string(actionRequestId)), ("sequence", .int(sequence)),
            ("verdict", .string(verdict.rawValue)), ("source", .string(source.rawValue)),
        ]
        if full, let note { m.append(("note", .string(note))) }
        m += [("evidenceRefs", .array(full ? evidenceRefs.map(JSONValue.string) : [])), ("by", .string(by)),
              ("at", .string(at)), ("requestId", .string(requestId))]
        return .obj(m)
    }
}

/// The Inbox's records beside the Runs, in the Run store's database, so a
/// Run with an unreconciled action and its reconciliations live and go
/// together: reconciliations (append-only, enforced by triggers) and how an
/// Inbox item was resolved through inbox.resolve.
extension RunStore {
    static func createReconciliationTables(_ db: SQLiteDatabase) throws {
        try db.execute("""
            CREATE TABLE IF NOT EXISTS reconciliations (run_id TEXT NOT NULL, request_id TEXT NOT NULL, seq INTEGER NOT NULL,
              reconciliation_id TEXT NOT NULL UNIQUE, verdict TEXT NOT NULL CHECK (verdict IN ('executed', 'not_executed', 'still_unknown')),
              source TEXT NOT NULL, note TEXT, evidence TEXT NOT NULL, by_client TEXT NOT NULL, at TEXT NOT NULL,
              reconcile_request_id TEXT NOT NULL, PRIMARY KEY (run_id, request_id, seq))
            """)
        // Append-only: nothing in the Runtime updates or deletes one, and the
        // database refuses it should anything try.
        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS reconciliations_append_only_u BEFORE UPDATE ON reconciliations
            BEGIN SELECT RAISE(ABORT, 'reconciliations are append-only'); END
            """)
        try db.execute("""
            CREATE TRIGGER IF NOT EXISTS reconciliations_append_only_d BEFORE DELETE ON reconciliations
            BEGIN SELECT RAISE(ABORT, 'reconciliations are append-only'); END
            """)
        try db.execute("""
            CREATE TABLE IF NOT EXISTS inbox_resolutions (inbox_id TEXT PRIMARY KEY, how TEXT NOT NULL, by_client TEXT NOT NULL,
              at TEXT NOT NULL, request_id TEXT NOT NULL)
            """)
        try db.execute("CREATE INDEX IF NOT EXISTS events_by_type ON events (type, run_id)")
    }

    /// Runs that still have an action whose delivery is unknown and that no
    /// reconciliation settled (its latest says executed or not_executed).
    static let unresolvedRunsSQL = """
        SELECT r.run_id FROM runs r WHERE r.unknown_actions > (SELECT COUNT(*) FROM reconciliations c
          WHERE c.run_id = r.run_id AND c.verdict != 'still_unknown'
            AND c.seq = (SELECT MAX(c2.seq) FROM reconciliations c2 WHERE c2.run_id = c.run_id AND c2.request_id = c.request_id))
        """

    /// Whether this Run has an unknown action no reconciliation settled.
    func hasUnresolvedUnknown(_ runId: String) -> Bool {
        ((try? db.query("SELECT 1 FROM (\(Self.unresolvedRunsSQL)) WHERE run_id = ?", [.text(runId)]))?.isEmpty == false)
    }

    struct UnknownActionRow { var runId: String; var requestId: String; var at: String }

    /// Actions whose delivery is unknown, of Runs still kept, optionally of
    /// one Run, one client's Runs or one Desktop.
    func unknownActionRows(runId: String?, clientId: String?, desktopId: String?) -> [UnknownActionRow] {
        var sql = "SELECT o.run_id, o.request_id, o.at FROM action_outcomes o JOIN runs r ON r.run_id = o.run_id WHERE o.outcome = 'unknown'"
        var args: [SQLiteDatabase.Value] = []
        if let runId { sql += " AND o.run_id = ?"; args.append(.text(runId)) }
        if let clientId { sql += " AND r.client_id = ?"; args.append(.text(clientId)) }
        if let desktopId { sql += " AND r.desktop_id = ?"; args.append(.text(desktopId)) }
        return ((try? db.query(sql, args)) ?? []).map {
            UnknownActionRow(runId: $0[0] as! String, requestId: $0[1] as! String, at: $0[2] as! String)
        }
    }

    /// The recorded outcome of one action of a Run: completed, unknown, or
    /// nil (not an action of it, or one that was refused or failed).
    func actionOutcome(runId: String, requestId: String) -> String? {
        (try? db.query("SELECT outcome FROM action_outcomes WHERE run_id = ? AND request_id = ?",
                       [.text(runId), .text(requestId)]).first?[0]) as? String
    }

    struct QuestionRow { var runId: String; var firstAt: String; var reason: String }

    /// Runs that waited for a person (unit.needs_input), with when they first
    /// did and the latest reason.
    func questionRows(runId: String?, clientId: String?, desktopId: String?) -> [QuestionRow] {
        var sql = """
            SELECT e.run_id, MIN(e.at), (SELECT e2.data FROM events e2 WHERE e2.run_id = e.run_id AND e2.type = 'unit.needs_input'
              ORDER BY e2.seq DESC LIMIT 1)
            FROM events e JOIN runs r ON r.run_id = e.run_id WHERE e.type = 'unit.needs_input'
            """
        var args: [SQLiteDatabase.Value] = []
        if let runId { sql += " AND e.run_id = ?"; args.append(.text(runId)) }
        if let clientId { sql += " AND r.client_id = ?"; args.append(.text(clientId)) }
        if let desktopId { sql += " AND r.desktop_id = ?"; args.append(.text(desktopId)) }
        sql += " GROUP BY e.run_id"
        return ((try? db.query(sql, args)) ?? []).map { row in
            let data = (row[2] as? String).flatMap { try? StrictJSON.parse($0) }
            return QuestionRow(runId: row[0] as! String, firstAt: row[1] as! String,
                               reason: String((data?["reason"]?.stringValue ?? "").prefix(128)))
        }
    }

    private static func reconciliation(_ r: [Any?]) -> Reconciliation {
        let evidence = (r[7] as? String).flatMap { try? StrictJSON.parse($0) }?.arrayValue?.compactMap(\.stringValue) ?? []
        return Reconciliation(reconciliationId: r[3] as! String, runId: r[0] as! String, actionRequestId: r[1] as! String,
                              sequence: Int(r[2] as! Int64),
                              verdict: Reconciliation.Verdict(rawValue: r[4] as! String) ?? .stillUnknown,
                              source: Reconciliation.Source(rawValue: r[5] as! String) ?? .operatorAttestation,
                              note: r[6] as? String, evidenceRefs: evidence, by: r[8] as! String, at: r[9] as! String,
                              requestId: r[10] as! String)
    }

    private static let reconciliationColumns =
        "run_id, request_id, seq, reconciliation_id, verdict, source, note, evidence, by_client, at, reconcile_request_id"

    /// Every reconciliation of one action, oldest first.
    func reconciliations(runId: String, requestId: String) -> [Reconciliation] {
        ((try? db.query("SELECT \(Self.reconciliationColumns) FROM reconciliations WHERE run_id = ? AND request_id = ? ORDER BY seq",
                        [.text(runId), .text(requestId)])) ?? []).map(Self.reconciliation)
    }

    /// Append one reconciliation if the action still has `expectedRevision`
    /// of them (compare and append in one transaction): two people deciding
    /// at once never both land on the same view. A mismatch throws a
    /// revisionMismatch error naming the current count.
    func appendReconciliation(runId: String, requestId: String, expectedRevision: Int, verdict: Reconciliation.Verdict,
                              source: Reconciliation.Source, note: String?, evidenceRefs: [String], by: String,
                              reconcileRequestId: String) throws -> Reconciliation {
        try db.transaction {
            let count = Int((try db.query("SELECT COUNT(*) FROM reconciliations WHERE run_id = ? AND request_id = ?",
                                          [.text(runId), .text(requestId)]).first?[0] as? Int64) ?? 0)
            guard count == expectedRevision else {
                throw RuntimeStoreError("\(count)", kind: .revisionMismatch)
            }
            let r = Reconciliation(reconciliationId: DesktopRegistry.newId(prefix: "rec"), runId: runId, actionRequestId: requestId,
                                   sequence: count + 1, verdict: verdict, source: source, note: note, evidenceRefs: evidenceRefs,
                                   by: by, at: Timestamp.string(now()), requestId: reconcileRequestId)
            try db.execute("INSERT INTO reconciliations (\(Self.reconciliationColumns)) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)", [
                .text(r.runId), .text(r.actionRequestId), .int(Int64(r.sequence)), .text(r.reconciliationId),
                .text(r.verdict.rawValue), .text(r.source.rawValue), r.note.map { .text($0) } ?? .null,
                .text(JSONValue.array(r.evidenceRefs.map(JSONValue.string)).encoded()), .text(r.by), .text(r.at), .text(r.requestId),
            ])
            return r
        }
    }

    struct InboxResolutionRow { var how: String; var by: String; var at: String }

    func recordInboxResolution(_ inboxId: String, how: String, by: String, requestId: String) throws {
        try db.execute("INSERT OR IGNORE INTO inbox_resolutions (inbox_id, how, by_client, at, request_id) VALUES (?, ?, ?, ?, ?)",
                       [.text(inboxId), .text(how), .text(by), .text(Timestamp.string(now())), .text(requestId)])
    }

    func inboxResolution(_ inboxId: String) -> InboxResolutionRow? {
        (try? db.query("SELECT how, by_client, at FROM inbox_resolutions WHERE inbox_id = ?", [.text(inboxId)]).first).map {
            InboxResolutionRow(how: $0[0] as! String, by: $0[1] as! String, at: $0[2] as! String)
        }
    }

    /// The stable id of the Inbox item for an unknown action.
    static func unknownInboxId(runId: String, requestId: String) -> String {
        "inb_u_" + SHA256.hash(data: Data("\(runId)\n\(requestId)".utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func questionInboxId(runId: String) -> String { "inb_q_" + runId }
}
