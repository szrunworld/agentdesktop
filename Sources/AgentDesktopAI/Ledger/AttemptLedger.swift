import AgentDesktopProtocol
import Foundation

/// Points where a test can make the ledger fail like a full or broken disk.
public enum LedgerFault: Sendable {
    case reserve, finish
}

/// The model call ledger in the configuration database (spec §09.3,
/// §10.3 `inference_attempts`). Every started call is one row; the row is
/// written before any HTTP and finished whatever the outcome.
extension ConfigStore {
    /// Reserve an attempt. Refused (AUDIT_UNAVAILABLE) while the same
    /// budget scope has an attempt whose end could not be recorded: progress
    /// stops until the Runtime resolves it, instead of running untraceably.
    public func reserveAttempt(context: AiCallContext, target: AiResolvedModel) throws -> ResourceID {
        if ledgerFaults.contains(.reserve) {
            throw ContractError(.auditUnavailable, "the call ledger cannot record a new attempt")
        }
        let interrupted = (try? hasInterrupted(context.budgetScopeRef)) ?? true
        if blockedBudgetScopes.contains(context.budgetScopeRef) || interrupted {
            throw ContractError(.auditUnavailable, "an earlier model call of this run or operation was not recorded; resolve it first")
        }
        var step: SQLValue = .null, level: SQLValue = .null
        switch context.purpose {
        case let .guiStep(p): step = .int(Int64(p.stepIndex))
        case let .capabilityTest(p): level = .text(p.level.rawValue)
        }
        do {
            try db.run("""
                INSERT INTO inference_attempts(attempt_id, purpose, run_id, operation_id, step_index, level,
                  caller_scope, budget_scope, connection_id, connection_revision, model_profile_id,
                  model_profile_revision, credential_id, requested_model_id, state, reserved_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,'reserved',?)
                """, [
                    .text(context.inferenceAttemptId), .text(context.purpose.persistedName),
                    context.purpose.runId.map(SQLValue.text) ?? .null,
                    context.purpose.operationId.map(SQLValue.text) ?? .null,
                    step, level, .text(context.callerScopeRef), .text(context.budgetScopeRef),
                    .text(target.connection.connectionId), .int(Int64(target.connection.revision)),
                    .text(target.model.modelProfileId), .int(Int64(target.model.revision)),
                    .text(target.connection.credentialIdentityRef), .text(target.model.modelId),
                    .text(Self.timestamp(clock.now())),
                ])
        } catch let e as SQLiteError where e.code == 19 {
            throw ContractError(.validationError, "inference attempt id was already reserved")
        } catch {
            throw ContractError(.auditUnavailable, "the call ledger cannot record a new attempt")
        }
        return context.inferenceAttemptId
    }

    /// Record an attempt's end. A second finish for the same attempt is
    /// ignored, so nothing is ever counted twice.
    public func finishAttempt(_ r: AiCallRecord) throws {
        do {
            if ledgerFaults.contains(.finish) { throw SQLiteError(code: 10, message: "injected") }
            guard let row = try db.row("SELECT state FROM inference_attempts WHERE attempt_id=?", [.text(r.reservationId)]) else {
                throw ContractError(.validationError, "finish without a reservation")
            }
            guard row[0].text == "reserved" else { return }
            func i(_ v: Int?) -> SQLValue { v.map { .int(Int64($0)) } ?? .null }
            func t(_ v: String?) -> SQLValue { v.map(SQLValue.text) ?? .null }
            try db.run("""
                UPDATE inference_attempts SET state=?, started_at=?, ended_at=?, latency_ms=?, actual_model_id=?,
                  upstream_request_id=?, http_status=?, finish_reason=?, input_tokens=?, output_tokens=?,
                  cache_read_tokens=?, cache_write_tokens=?, total_tokens=?, cost_amount=?, cost_currency=?,
                  cost_source=?, pricing_revision=?, error_code=?, discarded=?
                WHERE attempt_id=? AND state='reserved'
                """, [
                    .text(r.state.rawValue), .text(Self.timestamp(r.startedAt)), .text(Self.timestamp(r.endedAt)),
                    .int(Int64(r.latencyMs)), t(r.actualModelId), t(r.upstreamRequestId), i(r.httpStatus),
                    t(r.finishReason), i(r.usage?.inputTokens), i(r.usage?.outputTokens),
                    i(r.usage?.cacheReadTokens), i(r.usage?.cacheWriteTokens), i(r.usage?.totalTokens),
                    t(r.cost?.amount), t(r.cost?.currency), t(r.cost?.source.rawValue), t(r.cost?.pricingRevision),
                    t(r.error?.code.rawValue), .int(r.discarded ? 1 : 0), .text(r.reservationId),
                ])
        } catch let e as ContractError {
            throw e
        } catch {
            blockedBudgetScopes.insert(r.context.budgetScopeRef)
            throw ContractError(.auditUnavailable, "the call ledger cannot record the attempt's end")
        }
    }

    /// After a restart, attempts that were reserved but never finished are
    /// marked interrupted: their usage is unknown, never zero, and their
    /// run or operation makes no further model call until resolved.
    @discardableResult
    public func recoverLedger() throws -> Int {
        try db.run("UPDATE inference_attempts SET state='interrupted', error_code=? WHERE state='reserved'",
                   [.text(ErrorCode.auditUnavailable.rawValue)])
    }

    /// The Runtime looked at an interrupted attempt and settled it; the
    /// budget scope may make calls again. The row stays as history.
    public func resolveInterruptedAttempts(budgetScope: String) throws {
        blockedBudgetScopes.remove(budgetScope)
        try db.run("UPDATE inference_attempts SET discarded=1 WHERE budget_scope=? AND state='interrupted'", [.text(budgetScope)])
    }

    private func hasInterrupted(_ budgetScope: String) throws -> Bool {
        try db.row("SELECT 1 FROM inference_attempts WHERE budget_scope=? AND state='interrupted' AND discarded=0 LIMIT 1",
                   [.text(budgetScope)]) != nil
    }

    public func setLedgerFault(_ fault: LedgerFault, _ on: Bool) {
        if on { ledgerFaults.insert(fault) } else { ledgerFaults.remove(fault) }
    }

    /// Ledger rows of one caller for usage, oldest first. Interrupted and
    /// reserved rows count as attempts with unknown usage.
    public func usageRows(callerScope: String) throws -> [UsageRow] {
        let rows = try db.rows("""
            SELECT attempt_id, COALESCE(started_at, reserved_at), connection_id, input_tokens, output_tokens,
                   cache_read_tokens, cache_write_tokens, total_tokens, cost_amount, cost_currency, cost_source,
                   pricing_revision
            FROM inference_attempts WHERE caller_scope=? ORDER BY reserved_at, attempt_id
            """, [.text(callerScope)])
        return rows.compactMap { r in
            guard let id = r[0].text, let start = r[1].text.flatMap(Self.parseTimestamp), let conn = r[2].text else { return nil }
            func n(_ v: SQLValue) -> Int? { v.int.map(Int.init) }
            let tokens = UsageTokens(inputTokens: n(r[3]), outputTokens: n(r[4]), cacheReadTokens: n(r[5]),
                                     cacheWriteTokens: n(r[6]), totalTokens: n(r[7]))
            let any = [tokens.inputTokens, tokens.outputTokens, tokens.totalTokens].contains { $0 != nil }
            var cost: CostEstimate?
            if let amount = r[8].text, let currency = r[9].text,
               let source = r[10].text.flatMap(CostEstimate.Source.init(rawValue:)) {
                cost = CostEstimate(amount: amount, currency: currency, source: source, pricingRevision: r[11].text)
            }
            return UsageRow(inferenceAttemptId: id, startedAt: start, connectionId: conn,
                            usage: any ? tokens : nil, cost: cost)
        }
    }

    /// Ledger rows for one budget scope (a run or an operation), as
    /// (attemptId, state, level) for diagnostics and tests.
    public func attempts(budgetScope: String) throws -> [(id: String, state: String, level: String?)] {
        try db.rows("SELECT attempt_id, state, level FROM inference_attempts WHERE budget_scope=? ORDER BY reserved_at, attempt_id",
                    [.text(budgetScope)]).map { ($0[0].text ?? "", $0[1].text ?? "", $0[2].text) }
    }

    static func parseTimestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

/// `AiCallLedgerPort` over the configuration database.
public struct SQLiteAiCallLedger: AiCallLedgerPort {
    public let store: ConfigStore

    public init(store: ConfigStore) {
        self.store = store
    }

    public func reserve(context: AiCallContext, target: AiResolvedModel) async throws -> ResourceID {
        try await store.reserveAttempt(context: context, target: target)
    }

    public func finish(_ record: AiCallRecord) async throws {
        try await store.finishAttempt(record)
    }
}
