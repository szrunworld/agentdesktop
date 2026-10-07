import AgentDesktopContracts
import Foundation

/// What one recovery pass did.
public struct RunRecoveryReport: Equatable, Sendable {
    public let runtimeEpoch: UInt64
    /// Runs left waiting (or cancelling) on an input whose outcome is unknown.
    public let quarantinedRuns: [String]
    /// Runs ended because the runtime restarted with nothing in flight.
    public let endedRuns: [String]
    /// Pending or submitted inputs now recorded as unknown.
    public let unknownActions: [String]
    /// Model calls reserved but never finished, now marked interrupted.
    public let interruptedAttempts: Int
}

/// Restart recovery (spec §07.4). Runs at startup, before any new run:
///
/// - The runtime epoch moves on, so every window handle, lease and
///   snapshot taken before is void.
/// - An input written as pending or submitted but never confirmed becomes
///   unknown. Its run waits (cancelling if a cancel was accepted) with
///   ACTION_OUTCOME_UNKNOWN and its desktop stays quarantined. Nothing is
///   sent again: recovery reads no trace and replays nothing.
/// - A run with nothing in flight ends: cancelled if a cancel was accepted,
///   otherwise failed because the runtime restarted. No run continues on
///   its own.
/// - Reserved model calls become interrupted, with unknown usage.
public struct RunRecovery: Sendable {
    public let store: ConfigStore

    public init(store: ConfigStore) {
        self.store = store
    }

    public func recover() async throws -> RunRecoveryReport {
        try await store.recoverRuns()
    }
}

extension ConfigStore {
    func recoverRuns() throws -> RunRecoveryReport {
        let interrupted = try recoverLedger()
        let now = clock.now()
        let at = GuiTime.iso(now)
        var quarantined: [String] = []
        var ended: [String] = []
        var unknown: [String] = []
        let epoch: UInt64 = try db.transaction {
            try db.run("UPDATE runtime_state SET value=value+1 WHERE key='epoch'")
            let epoch = try runtimeEpoch()
            let placeholders = Self.terminalRunStates.map { _ in "?" }.joined(separator: ",")
            let runs = try db.rows("SELECT run_id, snapshot, last_sequence FROM gui_runs WHERE state NOT IN (\(placeholders)) ORDER BY created_at, run_id",
                                   Self.terminalRunStates.sorted().map(SQLValue.text))
            for r in runs {
                guard let runId = r[0].text, let text = r[1].text else { continue }
                var snap = try StrictJSON.parse(text)
                let wasState = snap["state"]?.stringValue ?? "queued"
                let cancelAccepted = wasState == "cancelling"
                var sequence = Int(r[2].int ?? 0)

                // Inputs of this run that never reached a settled verdict.
                let open = try db.rows("""
                    SELECT action_id, proposal_id, desktop_id, snapshot_id, binding_epoch, run_generation, action_type,
                           state, body, reserved_at, target
                    FROM action_receipts WHERE run_id=? AND reconciled=0 AND state IN ('pending','submitted','unknown')
                    ORDER BY reserved_at, action_id
                    """, [.text(runId)])
                var latestReceipt: JSONValue?
                var converted = false
                for a in open {
                    guard let actionId = a[0].text else { continue }
                    let receipt = Self.unknownReceipt(row: a, runId: runId, at: at)
                    if a[7].text != "unknown" {
                        try db.run("UPDATE action_receipts SET state='unknown', body=?, updated_at=? WHERE action_id=?",
                                   [.text(receipt.encoded()), .text(Self.timestamp(now)), .text(actionId)])
                        unknown.append(actionId)
                        converted = true
                    }
                    latestReceipt = receipt
                }

                // Already waiting on the same unknown input from an earlier
                // restart: it stays quarantined, nothing else changes.
                if latestReceipt != nil, !converted, wasState == "waiting_user" || wasState == "cancelling",
                   snap["waitingReasonCode"]?.stringValue == ErrorCode.actionOutcomeUnknown.rawValue {
                    quarantined.append(runId)
                    continue
                }
                let generation = (snap["currentGeneration"]?.intValue ?? 1) + 1
                snap = snap.setting("currentGeneration", .int(generation)).setting("updatedAt", .string(at))
                var events: [(String, String, String?)] = []   // (type, summary, state)
                if let latestReceipt {
                    let next = cancelAccepted ? "cancelling" : "waiting_user"
                    snap = snap.setting("state", .string(next))
                        .setting("waitingReasonCode", .string(ErrorCode.actionOutcomeUnknown.rawValue))
                        .setting("latestActionReceipt", latestReceipt)
                    events.append(("action_receipt", "runtime restarted: input outcome unknown", nil))
                    if next != wasState { events.append(("state_changed", "runtime restarted", next)) }
                    events.append(("waiting_user", ErrorCode.actionOutcomeUnknown.rawValue, nil))
                    quarantined.append(runId)
                } else if cancelAccepted {
                    snap = snap.setting("state", .string("cancelled")).setting("waitingReasonCode", .null)
                    events.append(("state_changed", "cancelled: runtime restarted", "cancelled"))
                    ended.append(runId)
                } else {
                    let error = ContractError(.internalError, "the runtime restarted before the run finished")
                    snap = snap.setting("state", .string("failed")).setting("waitingReasonCode", .null)
                        .setting("error", error.json)
                    events.append(("state_changed", "failed: runtime restarted", "failed"))
                    ended.append(runId)
                }
                let bindingEpoch = snap["binding"]?["bindingEpoch"]?.intValue ?? 1
                for (type, summary, state) in events {
                    sequence += 1
                    var m: [(String, JSONValue)] = [
                        ("sequence", .int(sequence)), ("runId", .string(runId)), ("occurredAt", .string(at)),
                        ("type", .string(type)), ("bindingEpoch", .int(bindingEpoch)), ("runGeneration", .int(generation)),
                        ("summary", .string(summary)),
                    ]
                    if let state { m.append(("state", .string(state))) }
                    if type == "action_receipt", let latestReceipt { m.append(("actionReceipt", latestReceipt)) }
                    try db.run("INSERT INTO gui_events VALUES(?,?,?)", [.text(runId), .int(Int64(sequence)), .text(JSONValue.obj(m).encoded())])
                }
                snap = snap.setting("lastSequence", .int(sequence))
                try db.run("UPDATE gui_runs SET snapshot=?, state=?, last_sequence=?, updated_at=? WHERE run_id=?",
                           [.text(snap.encoded()), .text(snap["state"]?.stringValue ?? "failed"), .int(Int64(sequence)),
                            .text(Self.timestamp(now)), .text(runId)])
            }
            return epoch
        }
        return RunRecoveryReport(runtimeEpoch: epoch, quarantinedRuns: quarantined, endedRuns: ended,
                                 unknownActions: unknown, interruptedAttempts: interrupted)
    }

    /// Recorded instead of an input path the executor never reported.
    public static let unrecordedInputPath = "unrecorded"

    /// The receipt of an input recovered after a restart: unknown, aimed at
    /// the target recorded with its pending row, started no earlier than
    /// that row, with no evidence and no confirmation, because none exists.
    static func unknownReceipt(row a: [SQLValue], runId: String, at: String) -> JSONValue {
        if let text = a[8].text, let stored = try? StrictJSON.parse(text) {
            return stored.setting("deliveryState", .string("unknown"))
                .setting("reasonCode", .string(ErrorCode.actionOutcomeUnknown.rawValue))
                .setting("updatedAt", .string(at))
        }
        let reservedAt = a[9].text.flatMap(ConfigStore.parseTimestamp).map(GuiTime.iso) ?? at
        return .obj([
            ("actionId", .string(a[0].text ?? "")), ("proposalId", .string(a[1].text ?? "")), ("runId", .string(runId)),
            ("desktopId", .string(a[2].text ?? "")), ("snapshotId", .string(a[3].text ?? "")),
            ("bindingEpoch", .int(Int(a[4].int ?? 1))), ("runGeneration", .int(Int(a[5].int ?? 1))),
            ("actionType", .string(a[6].text ?? "")), ("deliveryState", .string("unknown")),
            ("executionTarget", a[10].text.flatMap { try? StrictJSON.parse($0) } ?? .null),
            ("inputPath", .string(unrecordedInputPath)), ("startedAt", .string(reservedAt)), ("endedAt", .null),
            ("evidenceRefs", .array([])), ("createdAt", .string(reservedAt)), ("updatedAt", .string(at)),
            ("confirmationObservationId", .null), ("reasonCode", .string(ErrorCode.actionOutcomeUnknown.rawValue)),
        ])
    }
}
