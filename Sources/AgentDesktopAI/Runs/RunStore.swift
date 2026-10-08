import AgentDesktopProtocol
import Foundation

/// Points where a test can make the run store fail like a full disk.
public enum RunStoreFault: Sendable {
    case create, snapshot, event, inferenceReservation, inferenceReceipt, actionReservation, actionReceipt
}

/// GUI runs in the configuration database (spec §05.3, §05.4, §09.3,
/// §10.3): runs with their binding and latest snapshot, their events,
/// inference and action receipts. Same semantics as the in-memory
/// repository; reads are scoped to the caller.
extension ConfigStore {
    static let terminalRunStates: Set<String> = ["succeeded", "failed", "cancelled"]

    public func setRunStoreFault(_ fault: RunStoreFault, _ on: Bool) {
        if on { runStoreFaults.insert(fault) } else { runStoreFaults.remove(fault) }
    }

    private func faulted(_ f: RunStoreFault) throws {
        if runStoreFaults.contains(f) { throw SQLiteError(code: 13, message: "injected") }
    }

    // MARK: Runs

    func createRun(_ run: StoredGuiRun, idempotencyKey: String, digest: String) throws -> GuiRunCreateOutcome {
        if let row = try db.row("SELECT digest, run_id FROM gui_runs WHERE caller_scope=? AND idempotency_key=?",
                                [.text(run.callerScope), .text(idempotencyKey)]) {
            guard row[0].text == digest else {
                throw ContractError(.idempotencyConflict, "this idempotency key was used for a different run")
            }
            guard let id = row[1].text, let existing = try loadRun(runId: id, callerScope: run.callerScope) else {
                throw ContractError(.internalError, "internal error")
            }
            return .existing(existing)
        }
        let t = Self.timestamp(clock.now())
        do {
            try faulted(.create)
            try db.transaction {
                try db.run("""
                    INSERT INTO gui_runs(run_id, caller_scope, idempotency_key, digest, binding, start_result,
                      snapshot, state, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?,?,?)
                    """, [.text(run.runId), .text(run.callerScope), .text(idempotencyKey), .text(digest),
                          .text(run.binding.encoded()), .text(run.startResult.encoded()), .text(run.snapshot.encoded()),
                          .text(run.snapshot["state"]?.stringValue ?? "queued"), .text(t), .text(t)])
                for (kind, id) in Self.references(of: run.binding) {
                    try db.run("INSERT OR IGNORE INTO gui_run_refs VALUES(?,?,?)", [.text(run.runId), .text(kind.rawValue), .text(id)])
                }
            }
        } catch let e as SQLiteError where e.code == 19 {
            // Lost a race for the same key: answer as the winner did.
            return try createRun(run, idempotencyKey: idempotencyKey, digest: digest)
        } catch let e as ContractError {
            throw e
        } catch {
            throw ContractError(.auditUnavailable, "the run could not be recorded")
        }
        return .created(run)
    }

    /// Resources a binding pins: every candidate's GUI profile, model
    /// profile and connection.
    static func references(of binding: JSONValue) -> [(ConfigResourceKind, String)] {
        let candidates = [binding["primary"]].compactMap { $0 } + (binding["fallbackCandidates"]?.arrayValue ?? [])
        var out: [(ConfigResourceKind, String)] = []
        for c in candidates {
            if let id = c["guiProfile"]?["guiProfileId"]?.stringValue { out.append((.guiProfile, id)) }
            if let id = c["modelProfile"]?["modelProfileId"]?.stringValue { out.append((.modelProfile, id)) }
            if let id = c["connection"]?["connectionId"]?.stringValue { out.append((.connection, id)) }
        }
        return out
    }

    func loadRun(runId: String, callerScope: String) throws -> StoredGuiRun? {
        guard let r = try db.row("SELECT binding, start_result, snapshot FROM gui_runs WHERE run_id=? AND caller_scope=?",
                                 [.text(runId), .text(callerScope)]),
              let binding = r[0].text, let start = r[1].text, let snap = r[2].text else { return nil }
        return StoredGuiRun(runId: runId, callerScope: callerScope, binding: try StrictJSON.parse(binding),
                            startResult: try StrictJSON.parse(start), snapshot: try StrictJSON.parse(snap))
    }

    func saveRunSnapshot(runId: String, snapshot: JSONValue) throws {
        do {
            try faulted(.snapshot)
            let n = try db.run("UPDATE gui_runs SET snapshot=?, state=?, updated_at=? WHERE run_id=?",
                               [.text(snapshot.encoded()), .text(snapshot["state"]?.stringValue ?? "queued"),
                                .text(Self.timestamp(clock.now())), .text(runId)])
            guard n == 1 else { throw ContractError(.notFound, "run not found") }
        } catch let e as ContractError {
            throw e
        } catch {
            throw ContractError(.auditUnavailable, "the run snapshot could not be recorded")
        }
    }

    func appendRunEvent(runId: String, maxEvents: Int, _ build: @Sendable (Int) -> JSONValue) throws -> Int {
        guard let row = try db.row("SELECT last_sequence FROM gui_runs WHERE run_id=?", [.text(runId)]),
              let last = row[0].int else {
            throw ContractError(.notFound, "run not found")
        }
        let seq = Int(last) + 1
        guard seq <= maxEvents else { throw ContractError(.limitExceeded, "the run's event log is full") }
        do {
            try faulted(.event)
            try db.transaction {
                try db.run("INSERT INTO gui_events VALUES(?,?,?)", [.text(runId), .int(Int64(seq)), .text(build(seq).encoded())])
                try db.run("UPDATE gui_runs SET last_sequence=? WHERE run_id=? AND last_sequence=?",
                           [.int(Int64(seq)), .text(runId), .int(last)])
            }
        } catch {
            throw ContractError(.auditUnavailable, "the run event could not be recorded")
        }
        return seq
    }

    func runEvents(runId: String, afterSequence: Int, limit: Int) throws -> StoredEvents {
        guard let row = try db.row("SELECT last_sequence, kept_from FROM gui_runs WHERE run_id=?", [.text(runId)]) else {
            throw ContractError(.notFound, "run not found")
        }
        let bodies = try db.rows("SELECT body FROM gui_events WHERE run_id=? AND sequence>? ORDER BY sequence LIMIT ?",
                                 [.text(runId), .int(Int64(afterSequence)), .int(Int64(max(0, limit)))])
        return StoredEvents(events: try bodies.compactMap { try $0[0].text.map { try StrictJSON.parse($0) } },
                            oldestRetained: row[1].int.map(Int.init), lastSequence: Int(row[0].int ?? 0))
    }

    /// Retention: drop events with sequence < `keepFrom`; older cursors expire.
    public func pruneRunEvents(runId: String, keepFrom: Int) throws {
        try db.transaction {
            try db.run("DELETE FROM gui_events WHERE run_id=? AND sequence<?", [.text(runId), .int(Int64(keepFrom))])
            try db.run("UPDATE gui_runs SET kept_from=? WHERE run_id=?", [.int(Int64(keepFrom)), .text(runId)])
        }
    }

    /// Whether a non-terminal run pins this resource (protects delete, §04.1).
    func referencedByActiveRun(_ kind: ConfigResourceKind, _ id: String) throws -> Bool {
        let placeholders = Self.terminalRunStates.map { _ in "?" }.joined(separator: ",")
        return try db.row("""
            SELECT 1 FROM gui_run_refs f JOIN gui_runs r ON r.run_id=f.run_id
            WHERE f.kind=? AND f.resource_id=? AND r.state NOT IN (\(placeholders)) LIMIT 1
            """, [.text(kind.rawValue), .text(id)] + Self.terminalRunStates.sorted().map(SQLValue.text)) != nil
    }

    // MARK: Audit (§09.3)

    func reserveRunInference(runId: String, stepIndex: Int, snapshotId: String) throws {
        do {
            try faulted(.inferenceReservation)
            try db.run("INSERT INTO gui_inference_steps VALUES(?,?,?,?)",
                       [.text(runId), .int(Int64(stepIndex)), .text(snapshotId), .text(Self.timestamp(clock.now()))])
        } catch {
            throw ContractError(.auditUnavailable, "the inference could not be recorded before the call")
        }
    }

    /// Insert once per inference attempt; a repeat is ignored.
    func recordRunInference(_ receipt: GuiInferenceReceipt) throws {
        do {
            try faulted(.inferenceReceipt)
            try db.run("INSERT OR IGNORE INTO gui_inference_receipts VALUES(?,?,?,?,?)",
                       [.text(receipt.record.reservationId), .text(receipt.runId), .int(Int64(receipt.stepIndex)),
                        .text(receipt.json.encoded()), .text(Self.timestamp(clock.now()))])
        } catch {
            throw ContractError(.auditUnavailable, "the inference receipt could not be recorded")
        }
    }

    /// The pending row written before any input. When it cannot be
    /// written, the executor must not be called.
    func reserveRunAction(_ p: GuiProposal, actionId: String, target: TargetIdentity?) throws -> String {
        guard case let .action(action) = p.body else {
            throw ContractError(.invalidAction, "only an action proposal reserves an input")
        }
        let t = Self.timestamp(clock.now())
        do {
            try faulted(.actionReservation)
            try db.run("""
                INSERT INTO action_receipts(action_id, run_id, proposal_id, desktop_id, snapshot_id, binding_epoch,
                  run_generation, action_type, state, target, body, runtime_epoch, reserved_at, updated_at)
                VALUES(?,?,?,?,?,?,?,?,'pending',?,NULL,?,?,?)
                """, [.text(actionId), .text(p.runId), .text(p.proposalId), .text(p.stamp.desktopId),
                      .text(p.stamp.snapshotId), .int(Int64(p.stamp.bindingEpoch)), .int(Int64(p.stamp.runGeneration)),
                      .text(action.kind.rawValue), target.map { SQLValue.text($0.json.encoded()) } ?? .null,
                      .int(Int64(try runtimeEpoch())), .text(t), .text(t)])
        } catch {
            throw ContractError(.auditUnavailable, "the input could not be recorded before execution")
        }
        return actionId
    }

    /// Record the executor's verdict. Settled states (confirmed, not_sent,
    /// rejected) are final: a repeat is ignored, so nothing counts twice.
    func recordRunAction(_ r: GuiActionReceipt) throws {
        guard let row = try db.row("SELECT state FROM action_receipts WHERE action_id=?", [.text(r.actionId)]),
              let state = row[0].text else {
            throw ContractError(.validationError, "receipt for an action that was never reserved")
        }
        if ["confirmed", "not_sent", "rejected"].contains(state) { return }
        do {
            try faulted(.actionReceipt)
            try db.run("UPDATE action_receipts SET state=?, body=?, updated_at=? WHERE action_id=?",
                       [.text(r.deliveryState.rawValue), .text(r.json.encoded()),
                        .text(Self.timestamp(clock.now())), .text(r.actionId)])
        } catch {
            throw ContractError(.auditUnavailable, "the action receipt could not be recorded")
        }
    }

    public func runtimeEpoch() throws -> UInt64 {
        UInt64(try db.row("SELECT value FROM runtime_state WHERE key='epoch'")?[0].int ?? 1)
    }

    /// Inputs whose outcome is unknown and not yet reconciled. Their
    /// conflict domain stays quarantined: the Runtime refuses new input on
    /// these desktops (DESKTOP_BUSY) until it reconciles them.
    public func unresolvedActions(desktopId: String? = nil) throws -> [(actionId: String, runId: String, desktopId: String)] {
        var sql = "SELECT action_id, run_id, desktop_id FROM action_receipts WHERE state IN ('pending','submitted','unknown') AND reconciled=0"
        var args: [SQLValue] = []
        if let desktopId { sql += " AND desktop_id=?"; args.append(.text(desktopId)) }
        return try db.rows(sql + " ORDER BY reserved_at, action_id", args).map { ($0[0].text ?? "", $0[1].text ?? "", $0[2].text ?? "") }
    }

    /// The stored receipt of one action (nil body while still pending).
    public func actionReceipt(actionId: String) throws -> (state: String, body: JSONValue?, reconciled: Bool)? {
        guard let r = try db.row("SELECT state, body, reconciled FROM action_receipts WHERE action_id=?", [.text(actionId)]),
              let state = r[0].text else { return nil }
        return (state, try r[1].text.map { try StrictJSON.parse($0) }, r[2].int == 1)
    }

    /// The Runtime's existing reconciliation settled an unknown input. The
    /// row keeps its unknown state as history; the quarantine lifts.
    public func markActionReconciled(actionId: String) throws {
        let n = try db.run("UPDATE action_receipts SET reconciled=1, updated_at=? WHERE action_id=? AND state IN ('unknown','pending','submitted')",
                           [.text(Self.timestamp(clock.now())), .text(actionId)])
        guard n == 1 else { throw ContractError(.notFound, "no unresolved action \(actionId)") }
    }

    public func inferenceReceiptCount(runId: String) throws -> Int {
        Int(try db.row("SELECT COUNT(*) FROM gui_inference_receipts WHERE run_id=?", [.text(runId)])?[0].int ?? 0)
    }
}

/// `GuiRunRepository` over the configuration database.
public struct SQLiteGuiRunRepository: GuiRunRepository {
    public let store: ConfigStore
    public let maxEventsPerRun: Int

    public init(store: ConfigStore, maxEventsPerRun: Int = 100_000) {
        self.store = store
        self.maxEventsPerRun = maxEventsPerRun
    }

    public func create(_ run: StoredGuiRun, idempotencyKey: String, digest: String) async throws -> GuiRunCreateOutcome {
        try await store.createRun(run, idempotencyKey: idempotencyKey, digest: digest)
    }

    public func load(runId: String, callerScope: String) async throws -> StoredGuiRun? {
        try await store.loadRun(runId: runId, callerScope: callerScope)
    }

    public func saveSnapshot(runId: String, snapshot: JSONValue) async throws {
        try await store.saveRunSnapshot(runId: runId, snapshot: snapshot)
    }

    public func appendEvent(runId: String, _ build: @Sendable (Int) -> JSONValue) async throws -> Int {
        try await store.appendRunEvent(runId: runId, maxEvents: maxEventsPerRun, build)
    }

    public func events(runId: String, afterSequence: Int, limit: Int) async throws -> StoredEvents {
        try await store.runEvents(runId: runId, afterSequence: afterSequence, limit: limit)
    }

    public func prune(runId: String, keepFrom: Int) async throws {
        try await store.pruneRunEvents(runId: runId, keepFrom: keepFrom)
    }
}

/// `GuiAuditPort` over the configuration database. Writes happen before
/// the call or input they describe; a failed write is AUDIT_UNAVAILABLE.
public struct SQLiteGuiAuditPort: GuiAuditPort {
    public let store: ConfigStore
    private let newActionId: @Sendable () -> String

    public init(store: ConfigStore, newActionId: @escaping @Sendable () -> String = { ConfigStore.randomId("act") }) {
        self.store = store
        self.newActionId = newActionId
    }

    public func reserveInference(runId: String, stepIndex: Int, snapshotId: String) async throws {
        try await store.reserveRunInference(runId: runId, stepIndex: stepIndex, snapshotId: snapshotId)
    }

    public func recordInference(_ receipt: GuiInferenceReceipt) async throws {
        try await store.recordRunInference(receipt)
    }

    public func reserveAction(_ proposal: GuiProposal) async throws -> String {
        try await store.reserveRunAction(proposal, actionId: newActionId(), target: nil)
    }

    public func reserveAction(_ proposal: GuiProposal, target: TargetIdentity) async throws -> String {
        try await store.reserveRunAction(proposal, actionId: newActionId(), target: target)
    }

    public func recordAction(_ receipt: GuiActionReceipt) async throws {
        try await store.recordRunAction(receipt)
    }
}
