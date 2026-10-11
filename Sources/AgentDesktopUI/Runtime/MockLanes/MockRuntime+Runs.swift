import AgentDesktopProtocol
import Foundation

// Lane UI-A (Runs、Inbox 与 Store; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-A's mock state (read and written with the MockRuntime's lock held).
final class MockRunsLane: @unchecked Sendable {
    /// Exports written so far (request.export).
    var exports = 0
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-A models (each must be in RuntimeCatalog.implemented).
    static let runsLaneMethods: [String] = ["request.list", "request.export"]

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
