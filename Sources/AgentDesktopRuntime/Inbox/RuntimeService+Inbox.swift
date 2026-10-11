import AgentDesktopProtocol
import Foundation

// PR4: the platform Inbox (Hub v1 W06) and the reconciliation of unknown
// actions (W07, E2E-08, RT-19).
//
// The Inbox is derived from the Run records; nothing on it is a second
// ledger. Two kinds are made today:
// - unknown_reference: an action of a Run whose delivery is unknown. It is
//   open until a reconciliation says executed or not_executed.
// - question: a unit Run waiting for a person (phase waiting_input). It is
//   open while the Run waits.
// approval and external_reference are reserved in the contract; no Runtime
// source makes them yet.
//
// Who: the owner sees and handles every item. A paired client sees the items
// of its own Runs only (anything else does not exist for it) and handles
// none: inbox.resolve and run.reconcile are the owner's (Hub v1 §7:
// inbox.decide is verified_owner; reconcile owner or an explicit grant,
// which does not exist). Identity is the connection's, never a parameter.
//
// What it never does: change an outcome, retry, or replay. A reconciliation
// is appended beside the action; the receipt, the request ledger (the same
// requestId still answers action_delivery_unknown) and the Run's outcome
// (unknown) stay as they were. A new attempt is the caller's, with a new
// requestId.
extension RuntimeService {
    static let inboxPageLimit = 100

    /// One Inbox item, as built from the records.
    struct InboxEntry {
        enum Kind: String { case question, unknownReference = "unknown_reference" }
        var inboxId: String
        var kind: Kind
        var run: RunRecord
        var createdAt: String
        var revision: Int
        var open: Bool
        var action: JSONValue?
        var question: JSONValue?
        var resolution: JSONValue?
        var reconciliations: [Reconciliation] = []
        var actionRequestId: String?

        /// `withReconciliations` for inbox.show; `full` false hides the
        /// owner's notes and evidence from the client whose Run it is.
        func json(withReconciliations: Bool, full: Bool) -> JSONValue {
            var m: [(String, JSONValue)] = [
                ("inboxId", .string(inboxId)), ("kind", .string(kind.rawValue)), ("state", .string(open ? "open" : "resolved")),
                ("runId", .string(run.runId)), ("clientId", run.clientId.map(JSONValue.string) ?? .null),
                ("desktopId", .string(run.desktopId)), ("createdAt", .string(createdAt)), ("revision", .int(revision)),
                ("run", .obj([("phase", .string(run.phase.rawValue)), ("outcome", run.outcome.map { .string($0.rawValue) } ?? .null),
                              ("quiescence", .string(run.quiescence.rawValue)), ("revision", .int(run.revision)),
                              ("closingReason", run.closingReason.map(JSONValue.string) ?? .null)])),
            ]
            if let action { m.append(("action", action)) }
            if let question { m.append(("question", question)) }
            if let resolution { m.append(("resolution", resolution)) }
            if withReconciliations { m.append(("reconciliations", .array(reconciliations.map { $0.json(full: full) }))) }
            return .obj(m)
        }
    }

    /// What the Run's events say about one of its actions.
    private func unknownActionJSON(_ row: RunStore.UnknownActionRow, events: [JSONValue]) -> JSONValue {
        var kind: String?, dispatchedAt: String?, receipt: JSONValue?
        for e in events {
            let data = e["data"]
            switch e["type"]?.stringValue {
            case "action.accepted" where data?["requestId"]?.stringValue == row.requestId:
                kind = data?["kind"]?.stringValue
            case "action.dispatched" where data?["requestId"]?.stringValue == row.requestId:
                dispatchedAt = e["at"]?.stringValue
            case "action.unknown" where data?["receipt"]?["requestId"]?.stringValue == row.requestId:
                receipt = data?["receipt"]
            default: break
            }
        }
        var m: [(String, JSONValue)] = [("requestId", .string(row.requestId))]
        if let id = receipt?["receiptId"]?.stringValue { m.append(("receiptId", .string(id))) }
        if let kind, !kind.isEmpty { m.append(("kind", .string(String(kind.prefix(32))))) }
        if let at = receipt?["timing"]?["dispatchedAt"]?.stringValue ?? dispatchedAt { m.append(("dispatchedAt", .string(at))) }
        m.append(("becameUnknownAt", .string(row.at)))
        // Only the code: a message may quote what the app showed.
        let code = receipt?["reason"]?["code"]?.stringValue ?? (receipt == nil ? "runtime_restarted" : nil)
        if let code { m.append(("reasonCode", .string(code))) }
        return .obj(m)
    }

    private func unknownEntry(_ row: RunStore.UnknownActionRow, run: RunRecord, events: [JSONValue]) -> InboxEntry {
        let recs = runs.reconciliations(runId: row.runId, requestId: row.requestId)
        let settled = recs.last.flatMap { $0.verdict.isFinal ? $0 : nil }
        var resolution: JSONValue?
        if let settled {
            resolution = .obj([("how", .string("reconciled")), ("verdict", .string(settled.verdict.rawValue)),
                               ("by", .string(settled.by)), ("at", .string(settled.at))])
        }
        return InboxEntry(inboxId: RunStore.unknownInboxId(runId: row.runId, requestId: row.requestId), kind: .unknownReference,
                          run: run, createdAt: row.at, revision: recs.count, open: settled == nil,
                          action: unknownActionJSON(row, events: events), question: nil, resolution: resolution,
                          reconciliations: recs, actionRequestId: row.requestId)
    }

    private func questionEntry(_ row: RunStore.QuestionRow, run: RunRecord) -> InboxEntry {
        let inboxId = RunStore.questionInboxId(runId: run.runId)
        let open = run.phase == .waitingInput
        var resolution: JSONValue?
        if !open {
            if let done = runs.inboxResolution(inboxId) {
                resolution = .obj([("how", .string(done.how)), ("by", .string(done.by)), ("at", .string(done.at))])
            } else {
                resolution = .obj([("how", .string("run_ended")), ("at", .string(run.endedAt ?? row.firstAt))])
            }
        }
        return InboxEntry(inboxId: inboxId, kind: .question, run: run, createdAt: row.firstAt, revision: run.revision, open: open,
                          action: nil, question: .obj([("reason", .string(row.reason))]), resolution: resolution)
    }

    /// An item before it is loaded: enough to order and page it, from one
    /// row of the store (Codex on dbbbc30: only a page is loaded).
    struct InboxStub {
        var key: RunStore.InboxKey
        var unknown: RunStore.UnknownActionRow?
        var question: RunStore.QuestionRow?
    }

    /// One page of Inbox items, newest first, not yet loaded, and the cursor
    /// after it. Each kind's query reads at most `limit + 1` rows; the two
    /// are merged here (Codex on 5386e9d).
    func inboxStubs(kind: String?, _ q: RunStore.InboxQuery) -> (stubs: [InboxStub], next: String?) {
        var out: [InboxStub] = []
        if kind == nil || kind == InboxEntry.Kind.unknownReference.rawValue {
            out += runs.unknownActionRows(q).map {
                InboxStub(key: .init(at: $0.at, tag: "u", runId: $0.runId, requestId: $0.requestId), unknown: $0)
            }
        }
        if kind == nil || kind == InboxEntry.Kind.question.rawValue {
            out += runs.questionRows(q).map {
                InboxStub(key: .init(at: $0.firstAt, tag: "q", runId: $0.runId, requestId: ""), question: $0)
            }
        }
        out.sort { $0.key > $1.key }
        guard out.count > q.limit else { return (out, nil) }
        let page = Array(out.prefix(q.limit))
        return (page, page.last?.key.cursor)
    }

    /// Load one item: its Run, the events of its action, its reconciliations.
    func inboxEntry(_ stub: InboxStub) -> InboxEntry? {
        if let row = stub.unknown {
            guard let r = runs.find(row.runId) else { return nil }
            return unknownEntry(row, run: r, events: runs.actionEvents(runId: row.runId, requestId: row.requestId))
        }
        if let row = stub.question {
            guard let r = runs.find(row.runId) else { return nil }
            return questionEntry(row, run: r)
        }
        return nil
    }

    /// The item with this id the caller may see, or not_found (another
    /// client's item does not exist for it; the attempt is audited).
    func visibleInboxEntry(_ inboxId: String, _ c: ConnectionState) -> Result<InboxEntry, RuntimeError> {
        let mine = isOwner(c) ? nil : c.clientId
        var stub: InboxStub?
        var q = RunStore.InboxQuery()
        q.state = "all"
        if inboxId.hasPrefix("inb_q_") {
            q.runId = String(inboxId.dropFirst("inb_q_".count))
            q.limit = 1
            stub = inboxStubs(kind: InboxEntry.Kind.question.rawValue, q).stubs.first
        } else if let runId = RunStore.runId(ofUnknownInboxId: inboxId) {
            // The id names its Run: only that Run's unknown actions are read.
            q.runId = runId
            q.limit = 100_000
            stub = inboxStubs(kind: InboxEntry.Kind.unknownReference.rawValue, q).stubs.first {
                RunStore.unknownInboxId(runId: $0.key.runId, requestId: $0.key.requestId) == inboxId
            }
        }
        let found = stub.flatMap(inboxEntry)
        guard let found else { return .failure(.notFound("no inbox item \(inboxId)")) }
        if let mine, found.run.clientId != mine {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "inbox", decision: "denied",
                      reason: "foreign_inbox_item", runId: found.run.runId)
            return .failure(.notFound("no inbox item \(inboxId)"))
        }
        return .success(found)
    }

    func listInbox(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let limit = min(p["limit"]?.intValue ?? 50, Self.inboxPageLimit)
        let state = p["state"]?.stringValue ?? "open"
        // A paired client: its own Runs, whatever clientId it names.
        let clientId = isOwner(c) ? p["clientId"]?.stringValue : c.clientId
        var q = RunStore.InboxQuery()
        q.runId = p["runId"]?.stringValue
        q.clientId = clientId
        q.desktopId = p["desktopId"]?.stringValue
        q.state = state
        q.limit = limit
        if let cursor = p["cursor"]?.stringValue {
            guard let key = RunStore.InboxKey(cursor: cursor) else {
                return .failure(RuntimeError("invalid_argument", "cursor is not one this Runtime gave", phase: .request, notSent: true,
                                             details: .obj([("reason", .string("bad_cursor"))])))
            }
            q.after = key
        }
        let (items, next) = inboxStubs(kind: p["kind"]?.stringValue, q)
        let full = isOwner(c)
        // Only the page is loaded.
        let page = items.compactMap(inboxEntry)
        return .success(.obj([("items", .array(page.map { $0.json(withReconciliations: false, full: full) })),
                              ("next", next.map(JSONValue.string) ?? .null)]))
    }

    func showInbox(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        visibleInboxEntry(p["inboxId"]?.stringValue ?? "", c).map { $0.json(withReconciliations: true, full: isOwner(c)) }
    }

    private func ownerOnly(_ method: String, _ c: ConnectionState) -> RuntimeError? {
        guard !isOwner(c) else { return nil }
        // authorization() refuses a paired client before this; kept so the
        // handler never relies on that alone.
        return RuntimeError("permission_denied", "\(method) is reserved to the owner of this AgentDesktop", phase: .request,
                            notSent: true, details: .obj([("reason", .string("owner_only"))]))
    }

    private static func revisionConflict(_ current: Int, _ expected: Int) -> RuntimeError {
        RuntimeError("conflict", "the item is at revision \(current), not \(expected); read it again before deciding",
                     phase: .handler, notSent: true,
                     details: .obj([("reason", .string("revision_conflict")), ("currentRevision", .int(current))]))
    }

    /// inbox.resolve (owner): an open question item's Run is stopped, as
    /// run.cancel stops it. Nothing else is sent; nothing is answered for it.
    func resolveInbox(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        if let e = ownerOnly("inbox.resolve", c) { return .failure(e) }
        let p = request.params
        let entry: InboxEntry
        switch visibleInboxEntry(p["inboxId"]?.stringValue ?? "", c) {
        case let .failure(e): return .failure(e)
        case let .success(x): entry = x
        }
        guard entry.kind == .question else {
            return .failure(RuntimeError("invalid_argument", "an unknown action is reconciled with run.reconcile, not resolved here",
                                         phase: .request, notSent: true, details: .obj([("reason", .string("use_run_reconcile"))])))
        }
        guard entry.open else {
            return .failure(RuntimeError("conflict", "inbox item \(entry.inboxId) is already resolved", phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("already_resolved"))])))
        }
        let expected = p["expectedRevision"]?.intValue ?? -1
        guard entry.revision == expected else { return .failure(Self.revisionConflict(entry.revision, expected)) }
        // The comparison and the stop in one step (Codex on 831d28d): a
        // second decision, or a run.cancel, made on the same view loses.
        let stop: JSONValue
        switch execution.stop(runId: entry.run.runId, reason: "inbox_cancel", endAs: .cancelled,
                              onlyIf: { $0.phase == .waitingInput && $0.revision == expected }) {
        case .accepted?: stop = Self.stopReceipt(runs.find(entry.run.runId) ?? entry.run, terminal: false)
        case .alreadyTerminal?, .notFound?, nil:
            let now = runs.find(entry.run.runId)
            if let now, now.phase == .waitingInput { return .failure(Self.revisionConflict(now.revision, expected)) }
            return .failure(RuntimeError("conflict", "inbox item \(entry.inboxId) is already resolved", phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("already_resolved"))])))
        }
        // Who resolved it, beside the Run's own record. The stop stands even
        // if this note cannot be written: the item then reads run_ended.
        do {
            try runs.recordInboxResolution(entry.inboxId, how: "run_cancelled", by: c.clientId, requestId: request.requestId)
        } catch {
            // The stop stands; the store that could not record it is unhealthy.
            runs.latchWriteFailure(error)
            execution.auditStorageFailed()
        }
        let item = visibleInboxEntry(entry.inboxId, c).map { $0.json(withReconciliations: true, full: true) }
        return item.map { .obj([("item", $0), ("stop", stop)]) }
    }

    /// run.reconcile (owner): append one reconciliation to an action whose
    /// delivery is unknown, of a Run that has ended. Changes nothing else.
    func reconcileAction(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        if let e = ownerOnly("run.reconcile", c) { return .failure(e) }
        let p = request.params
        let runId = p["runId"]?.stringValue ?? ""
        let actionId = p["actionRequestId"]?.stringValue ?? ""
        guard let run = runs.find(runId) else { return .failure(.notFound("no run \(runId)")) }
        switch runs.actionOutcome(runId: runId, requestId: actionId) {
        case "unknown"?:
            break
        case nil where !runs.actionEvents(runId: runId, requestId: actionId).contains(where: {
            $0["type"]?.stringValue == "action.accepted"
        }):
            return .failure(.notFound("no action \(actionId) in run \(runId)"))
        default:
            return .failure(RuntimeError("invalid_argument", "action \(actionId) has a known outcome; only an unknown delivery is reconciled",
                                         phase: .request, notSent: true, details: .obj([("reason", .string("not_unknown"))])))
        }
        // Quiescence first (E2E-08): while the Run may still send input, a
        // finding about one of its actions could already be out of date.
        guard run.phase == .ended, run.quiescence == .confirmed else {
            return .failure(RuntimeError("conflict", "run \(runId) is \(run.phase.rawValue); reconcile once it has ended",
                                         phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("not_quiescent")), ("phase", .string(run.phase.rawValue)),
                                                        ("quiescence", .string(run.quiescence.rawValue))])))
        }
        guard let verdict = p["verdict"]?.stringValue.flatMap(Reconciliation.Verdict.init(rawValue:)) else {
            return .failure(.schemaInvalid("verdict"))
        }
        let source = p["source"]?.stringValue.flatMap(Reconciliation.Source.init(rawValue:)) ?? .operatorAttestation
        let expected = p["expectedRevision"]?.intValue ?? -1
        let recorded: Reconciliation
        do {
            recorded = try runs.appendReconciliation(
                runId: runId, requestId: actionId, expectedRevision: expected, verdict: verdict, source: source,
                note: p["note"]?.stringValue, evidenceRefs: p["evidenceRefs"]?.arrayValue?.compactMap(\.stringValue) ?? [],
                by: c.clientId, reconcileRequestId: request.requestId)
        } catch let e as RuntimeStoreError where e.isRevisionMismatch {
            return .failure(Self.revisionConflict(Int(e.description) ?? 0, expected))
        } catch {
            // Fail closed, as any other audit write (Codex P1 on dbbbc30): the
            // store is latched unhealthy and input stops everywhere.
            runs.latchWriteFailure(error)
            execution.auditStorageFailed()
            return .failure(RuntimeError("audit_unavailable", "the reconciliation could not be recorded: \(error)", phase: .handler,
                                         notSent: true))
        }
        let inboxId = RunStore.unknownInboxId(runId: runId, requestId: actionId)
        return visibleInboxEntry(inboxId, c).map { item in
            .obj([("reconciliation", recorded.json()), ("item", item.json(withReconciliations: true, full: true)),
                  ("run", (runs.find(runId) ?? run).json)])
        }
    }
}
