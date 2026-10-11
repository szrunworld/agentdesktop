import AgentDesktopProtocol
import Foundation

// Lane UI-A (Runs、Inbox 与 Store; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-A's mock state (read and written with the MockRuntime's lock held).
final class MockRunsLane: @unchecked Sendable {
    /// Exports written so far (request.export, diagnostics.export).
    var exports = 0
    /// Reconciliations per unknown action ("runId|requestId"), oldest first.
    var reconciliations: [String: [JSONValue]] = [:]
    /// Runs that waited for a person, with the unit executor's reason.
    var questions: [String: String] = [:]
    /// How a question item was resolved here (inbox.resolve), by inboxId.
    var resolutions: [String: JSONValue] = [:]
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-A models (each must be in RuntimeCatalog.implemented).
    static let runsLaneMethods: [String] = ["request.list", "request.export", "inbox.list", "inbox.show", "inbox.resolve",
                                            "run.reconcile", "diagnostics.export"]

    /// Lane UI-A's answer to one of `runsLaneMethods` (lock held).
    func runsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        switch method {
        case "request.list":
            let all = requestRecordsLocked(p)
            let offset = p["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let limit = p["limit"]?.intValue ?? 50
            let page = Array(all.dropFirst(offset).prefix(limit))
            let next: JSONValue = offset + page.count < all.count ? .string(String(offset + page.count)) : .null
            return .obj([("requests", .array(page)), ("next", next)])
        case "request.export":
            let all = requestRecordsLocked(p)
            let cap = 10_000
            let kept = Array(all.prefix(cap))
            var filter: [(String, JSONValue)] = []
            for key in ["method", "state", "desktopId", "clientId", "since"] { if let v = p[key] { filter.append((key, v)) } }
            let doc = JSONValue.obj([
                ("apiVersion", .string(RuntimeAPI.version)), ("exportedAt", .string(stamp())), ("filter", .obj(filter)),
                ("count", .int(kept.count)), ("truncated", .bool(all.count > cap)), ("requests", .array(kept)),
            ])
            let bytes = doc.encodedData()
            lanes.runs.exports += 1
            let artifactId = "art_export_" + String(format: "%03d", lanes.runs.exports)
            let meta = JSONValue.obj([("artifactId", .string(artifactId)), ("mediaType", .string("application/json")),
                                      ("byteSize", .int(bytes.count)), ("sha256", .string(Self.sha256(bytes))),
                                      ("createdAt", .string(stamp()))])
            artifactsById[artifactId] = (meta, bytes)
            return .obj([("artifact", meta), ("count", .int(kept.count)), ("truncated", .bool(all.count > cap))])
        case "inbox.list", "inbox.show", "inbox.resolve", "run.reconcile":
            return try inboxLane(method, p)
        case "diagnostics.export":
            return diagnosticsLocked(p)
        default:
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
    }

    /// The ledger as request.list gives it: newest first, each record with
    /// the caller and the Desktop it named (from its receipt's Run), after
    /// the filters in `p`.
    func requestRecordsLocked(_ p: JSONValue) -> [JSONValue] {
        var out: [JSONValue] = requests.values.map { r in
            var r = r
            let outcome = r["outcome"]
            let receipt = outcome?["error"]?["details"]?["receipt"] ?? (outcome?["delivery"] != nil ? outcome : nil)
            let run = receipt.flatMap { rc in runs.first { $0["runId"] == rc["runId"] } }
            let client = run?["clientId"].flatMap(\.stringValue) ?? "local:501"
            r = r.setting("clientId", .string(client))
            // As the Runtime's ledger keeps it: a success under outcome.data.
            if let o = outcome, !o.isNull, o["error"] == nil, o["data"] == nil { r = r.setting("outcome", .obj([("data", o)])) }
            if let d = receipt?["desktopId"] ?? r["desktopId"] { r = r.setting("desktopId", d) }
            return r
        }
        if let m = p["method"]?.stringValue { out = out.filter { $0["method"]?.stringValue == m } }
        if let s = p["state"]?.stringValue { out = out.filter { $0["state"]?.stringValue == s } }
        if let d = p["desktopId"]?.stringValue { out = out.filter { $0["desktopId"]?.stringValue == d } }
        if let c = p["clientId"]?.stringValue { out = out.filter { $0["clientId"]?.stringValue == c } }
        if let since = p["since"]?.stringValue.flatMap(Timestamp.date) {
            out = out.filter { ($0["acceptedAt"]?.stringValue.flatMap(Timestamp.date) ?? .distantPast) >= since }
        }
        return out.sorted {
            let a = $0["acceptedAt"]?.stringValue ?? "", b = $1["acceptedAt"]?.stringValue ?? ""
            return a == b ? ($0["requestId"]?.stringValue ?? "") > ($1["requestId"]?.stringValue ?? "") : a > b
        }
    }

    /// Adds a GUI unit Run (kind unit, as GUI Explorer starts it) with its
    /// `Run.unit` facts; `verification` is RunUnit.verification.status
    /// (matched / contradicted / inconclusive / not_run). Returns its runId.
    @discardableResult
    public func addUnitRun(desktopId: String, phase: String = "ended", outcome: String? = "success",
                           verification: String = "not_run", mode: String = "explore") -> String {
        let id = addRun(desktopId: desktopId, kind: "unit", origin: "gui_explorer", phase: phase, outcome: outcome)
        lock.withLock {
            guard let i = runs.firstIndex(where: { $0["runId"]?.stringValue == id }) else { return }
            var v: [(String, JSONValue)] = [("status", .string(verification))]
            if verification != "not_run" {
                let at = stamp()
                v.append(("observationId", .string("obs_verify_\(id)")))
                v.append(("checkedAt", .string(at)))
                if verification == "matched" || verification == "contradicted" {
                    appendEventLocked(id, "unit.verification", .obj([
                        ("status", .string(verification)), ("verifierId", .string("mock")),
                        ("observationId", .string("obs_verify_\(id)")), ("checkedAt", .string(at)),
                    ]))
                }
            }
            runs[i] = runs[i].setting("unit", .obj([
                ("mode", .string(mode)), ("goalHash", .string("sha256:" + String(repeating: "0", count: 63) + "1")),
                ("guiProfileId", .null), ("guiProfileRevision", .null), ("verification", .obj(v)),
            ]))
        }
        return id
    }

    /// An input the Runtime refused before sending it: `action.accepted`
    /// then `action.refused` with its reason, and a failed request whose
    /// error says it was not sent. Returns the requestId.
    @discardableResult
    public func addRefusedAction(runId: String, code: String = "input_disabled") -> String {
        lock.withLock {
            let requestId = "req_" + String(format: "%03d", requests.count + 1)
            let accepted = stamp()
            appendEventLocked(runId, "action.accepted", .obj([("requestId", .string(requestId)), ("kind", .string("click"))]))
            appendEventLocked(runId, "action.refused", .obj([("requestId", .string(requestId)), ("reason", .obj([
                ("code", .string(code)), ("message", .string(Self.mockMessage(code))),
            ]))]))
            let desk = runs.first { $0["runId"]?.stringValue == runId }?["desktopId"] ?? .null
            requests[requestId] = .obj([
                ("requestId", .string(requestId)), ("method", .string("act")), ("state", .string("failed")),
                ("acceptedAt", .string(accepted)), ("finishedAt", .string(stamp())), ("desktopId", desk),
                ("outcome", .obj([("error", RuntimeError(code, Self.mockMessage(code), phase: .handler, notSent: true).json)])),
            ])
            return requestId
        }
    }
}

// MARK: Inbox, reconciliation, diagnostics (U9)

extension MockRuntime {
    /// A GUI unit Run waiting for a person (`unit.needs_input`), which the
    /// Inbox shows as a question. Returns its runId.
    @discardableResult
    public func addQuestionRun(desktopId: String, reason: String = "login_required") -> String {
        let id = addUnitRun(desktopId: desktopId, phase: "waiting_input", outcome: nil)
        lock.withLock {
            appendEventLocked(id, "unit.needs_input", .obj([("reason", .string(reason))]))
            lanes.runs.questions[id] = reason
        }
        return id
    }

    /// The sample's Inbox (U9): an ended Run with an action to reconcile,
    /// and a GUI unit Run waiting for a person. Returns their runIds.
    @discardableResult
    public func addInboxSample(desktopId: String) -> (unknown: String, question: String) {
        let lost = addRun(desktopId: desktopId, phase: "ended", outcome: "unknown", receipts: 1, unknownActions: 1)
        addAction(runId: lost, delivery: "unknown", execution: "unknown")
        return (lost, addQuestionRun(desktopId: desktopId))
    }

    /// Every Inbox item, newest first, with its reconciliations.
    func inboxItemsLocked() -> [JSONValue] {
        var out: [JSONValue] = []
        for r in requests.values where r["method"]?.stringValue == "act" && r["state"]?.stringValue == "unknown" {
            let receipt = r["outcome"]?["data"] ?? r["outcome"]?["error"]?["details"]?["receipt"]
            guard let runId = receipt?["runId"]?.stringValue, let run = runs.first(where: { $0["runId"]?.stringValue == runId }),
                  let requestId = r["requestId"]?.stringValue else { continue }
            let recs = lanes.runs.reconciliations["\(runId)|\(requestId)"] ?? []
            let settled = recs.last { ["executed", "not_executed"].contains($0["verdict"]?.stringValue ?? "") }
            var action: [(String, JSONValue)] = [("requestId", .string(requestId))]
            if let rc = receipt?["receiptId"] { action.append(("receiptId", rc)) }
            action.append(("kind", .string("click")))
            if let at = receipt?["timing"]?["dispatchedAt"], !at.isNull { action.append(("dispatchedAt", at)) }
            let became = r["finishedAt"] ?? r["acceptedAt"] ?? .string(stamp())
            action.append(("becameUnknownAt", became))
            action.append(("reasonCode", .string("action_delivery_unknown")))
            var m = inboxBase("inb_u_\(runId)_\(requestId)", kind: "unknown_reference", run: run, createdAt: became,
                              revision: recs.count, open: settled == nil)
            m.append(("action", .obj(action)))
            if let settled {
                m.append(("resolution", .obj([("how", .string("reconciled")), ("verdict", settled["verdict"]!),
                                              ("by", settled["by"]!), ("at", settled["at"]!)])))
            }
            m.append(("reconciliations", .array(recs)))
            out.append(.obj(m))
        }
        for (runId, reason) in lanes.runs.questions {
            guard let run = runs.first(where: { $0["runId"]?.stringValue == runId }) else { continue }
            let id = "inb_q_\(runId)"
            let open = run["phase"]?.stringValue == "waiting_input"
            var m = inboxBase(id, kind: "question", run: run, createdAt: run["createdAt"] ?? .string(stamp()),
                              revision: run["revision"]?.intValue ?? 1, open: open)
            m.append(("question", .obj([("reason", .string(reason))])))
            if !open {
                m.append(("resolution", lanes.runs.resolutions[id]
                    ?? .obj([("how", .string("run_ended")), ("at", run["endedAt"] ?? run["createdAt"]!)])))
            }
            m.append(("reconciliations", .array([])))
            out.append(.obj(m))
        }
        return out.sorted {
            let a = $0["createdAt"]?.stringValue ?? "", b = $1["createdAt"]?.stringValue ?? ""
            return a == b ? ($0["inboxId"]?.stringValue ?? "") > ($1["inboxId"]?.stringValue ?? "") : a > b
        }
    }

    func inboxBase(_ id: String, kind: String, run: JSONValue, createdAt: JSONValue, revision: Int, open: Bool) -> [(String, JSONValue)] {
        [("inboxId", .string(id)), ("kind", .string(kind)), ("state", .string(open ? "open" : "resolved")),
         ("runId", run["runId"]!), ("clientId", run["clientId"] ?? .null), ("desktopId", run["desktopId"]!),
         ("createdAt", createdAt), ("revision", .int(revision)),
         ("run", .obj([("phase", run["phase"]!), ("outcome", run["outcome"] ?? .null), ("quiescence", run["quiescence"]!),
                       ("revision", run["revision"] ?? .int(1)), ("closingReason", run["closingReason"] ?? .null)]))]
    }

    /// An item as inbox.list gives it: without its reconciliations.
    static func listed(_ item: JSONValue) -> JSONValue {
        guard case let .object(pairs) = item else { return item }
        return .object(pairs.filter { $0.key != "reconciliations" })
    }

    static func refusal(_ code: String, _ reason: String, _ extra: [(String, JSONValue)] = []) -> RuntimeError {
        RuntimeError(code, mockMessage(code), phase: .handler, notSent: true, details: .obj([("reason", .string(reason))] + extra))
    }

    func inboxLane(_ method: String, _ p: JSONValue) throws -> JSONValue {
        let all = inboxItemsLocked()
        func item(_ id: String) throws -> JSONValue {
            guard let i = all.first(where: { $0["inboxId"]?.stringValue == id }) else { throw RuntimeError.notFound("no inbox item \(id)") }
            return i
        }
        switch method {
        case "inbox.list":
            var items = all
            let state = p["state"]?.stringValue ?? "open"
            if state != "all" { items = items.filter { $0["state"]?.stringValue == state } }
            for key in ["kind", "runId", "desktopId", "clientId"] {
                if let v = p[key]?.stringValue { items = items.filter { $0[key]?.stringValue == v } }
            }
            let offset = p["cursor"]?.stringValue.flatMap(Int.init) ?? 0
            let limit = p["limit"]?.intValue ?? 50
            let page = Array(items.dropFirst(offset).prefix(limit))
            let next: JSONValue = offset + page.count < items.count ? .string(String(offset + page.count)) : .null
            return .obj([("items", .array(page.map(Self.listed))), ("next", next)])
        case "inbox.show":
            return try item(p["inboxId"]!.stringValue!)
        case "inbox.resolve":
            let it = try item(p["inboxId"]!.stringValue!)
            guard it["kind"]?.stringValue == "question" else { throw Self.refusal("invalid_argument", "use_run_reconcile") }
            guard it["state"]?.stringValue == "open" else { throw Self.refusal("conflict", "already_resolved") }
            let rev = it["revision"]?.intValue ?? 0
            guard p["expectedRevision"]?.intValue == rev else {
                throw Self.refusal("conflict", "revision_conflict", [("currentRevision", .int(rev))])
            }
            let runId = it["runId"]!.stringValue!
            stopLocked(runId, reason: "inbox_cancel")
            let id = it["inboxId"]!.stringValue!
            lanes.runs.resolutions[id] = .obj([("how", .string("run_cancelled")), ("by", .string("local:501")), ("at", .string(stamp()))])
            let r = try run(runId)
            let stop = JSONValue.obj([
                ("cancelRequest", .obj([("accepted", .bool(true)), ("scope", .obj([("kind", .string("run")), ("id", .string(runId))]))])),
                ("execution", .obj([("phase", r["phase"]!), ("quiescence", r["quiescence"]!), ("outcome", r["outcome"]!),
                                    ("revision", r["revision"]!)])),
            ])
            return .obj([("item", try item(id)), ("stop", stop)])
        default: // run.reconcile
            let runId = p["runId"]!.stringValue!, actionId = p["actionRequestId"]!.stringValue!
            let r = try run(runId)
            guard let it = all.first(where: { $0["kind"]?.stringValue == "unknown_reference" && $0["runId"]?.stringValue == runId
                && $0["action"]?["requestId"]?.stringValue == actionId }) else {
                throw Self.refusal("invalid_argument", "not_unknown")
            }
            guard r["phase"]?.stringValue == "ended", r["quiescence"]?.stringValue == "confirmed" else {
                throw Self.refusal("conflict", "not_quiescent")
            }
            let key = "\(runId)|\(actionId)"
            let recs = lanes.runs.reconciliations[key] ?? []
            guard p["expectedRevision"]?.intValue == recs.count else {
                throw Self.refusal("conflict", "revision_conflict", [("currentRevision", .int(recs.count))])
            }
            var rec: [(String, JSONValue)] = [
                ("reconciliationId", .string("rec_\(recs.count + 1)_\(actionId)")), ("runId", .string(runId)),
                ("actionRequestId", .string(actionId)), ("sequence", .int(recs.count + 1)), ("verdict", p["verdict"]!),
                ("source", p["source"] ?? .string("operator_attestation")),
            ]
            if let note = p["note"] { rec.append(("note", note)) }
            rec += [("evidenceRefs", p["evidenceRefs"] ?? .array([])), ("by", .string("local:501")), ("at", .string(stamp())),
                    ("requestId", .string("req_reconcile_\(recs.count + 1)"))]
            lanes.runs.reconciliations[key] = recs + [.obj(rec)]
            let after = inboxItemsLocked().first { $0["inboxId"] == it["inboxId"] }!
            return .obj([("reconciliation", .obj(rec)), ("item", after), ("run", r)])
        }
    }

    /// diagnostics.export as the owner sees it: counts only, never content.
    func diagnosticsLocked(_ p: JSONValue) -> JSONValue {
        let names = p["sections"]?.arrayValue?.compactMap(\.stringValue)
            ?? ["runtime", "capabilities", "connections", "clients", "desktops", "runs", "requests", "authorization"]
        let count: [String: Int] = ["runtime": 1, "capabilities": Self.modeled.count, "connections": 1, "clients": clients.count,
                                    "desktops": desktops.count, "runs": runs.count, "requests": requests.count, "authorization": 0]
        let since = p["since"] ?? .string(Timestamp.string(base))
        let manifest = JSONValue.obj([
            ("scope", .obj([("role", .string("owner")), ("clientId", .string("local:501"))])), ("since", since),
            ("sections", .array(names.map { .obj([("name", .string($0)), ("items", .int(count[$0] ?? 0))]) })),
            ("excluded", .array(["credentials and tokens", "screenshots and other artifacts", "typed text and action parameters",
                                 "request outcomes", "window titles and app content", "peer process facts (pid, executable path)",
                                 "free-text notes", "the endpoint path"].map(JSONValue.string))),
        ])
        if p["preview"]?.boolValue == true { return .obj([("preview", .bool(true)), ("manifest", manifest)]) }
        let doc = JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("exportedAt", .string(stamp())), ("manifest", manifest),
                                 ("sections", .obj(names.map { ($0, .obj([("items", .int(count[$0] ?? 0))])) }))])
        let bytes = doc.encodedData()
        lanes.runs.exports += 1
        let artifactId = "art_diag_" + String(format: "%03d", lanes.runs.exports)
        let meta = JSONValue.obj([("artifactId", .string(artifactId)), ("mediaType", .string("application/json")),
                                  ("byteSize", .int(bytes.count)), ("sha256", .string(Self.sha256(bytes))), ("createdAt", .string(stamp()))])
        artifactsById[artifactId] = (meta, bytes)
        return .obj([("preview", .bool(false)), ("manifest", manifest), ("artifact", meta)])
    }
}
