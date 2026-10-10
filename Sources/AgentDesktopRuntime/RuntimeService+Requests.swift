import AgentDesktopProtocol
import Foundation

// A5: the action records (Design P19–P20). Every write request the Runtime
// accepted, as the request ledger holds it (7 days): filtered and paged by
// request.list, written whole to an artifact by request.export. A record is
// what request.show gives for it. The owner sees every caller's; a paired
// app only its own.
extension RuntimeService {
    static let requestPageLimit = 100
    /// A page stops early rather than break the frame limit.
    static let requestPageBytes = 768 * 1024
    /// At most this many records go into one export.
    static let requestExportLimit = 10_000

    /// The Desktop a write names, recorded with it: params.desktopId, else
    /// the Desktop of its session or Run.
    func namedDesktop(_ request: RuntimeRequest, _ c: ConnectionState) -> String? {
        if let d = request.params["desktopId"]?.stringValue { return d }
        if let sid = request.context.sessionId ?? request.params["sessionId"]?.stringValue,
           let s = sessions.find(sid, caller: c.clientId) { return s.desktopId }
        if let rid = request.context.runId ?? request.params["runId"]?.stringValue { return runs.find(rid)?.desktopId }
        return nil
    }

    private func requestFilter(_ p: JSONValue, _ c: ConnectionState) -> RequestLedger.Filter {
        var f = RequestLedger.Filter()
        f.caller = isOwner(c) ? p["clientId"]?.stringValue : c.clientId
        f.method = p["method"]?.stringValue
        f.state = p["state"]?.stringValue.flatMap(RequestLedger.State.init(rawValue:))
        f.desktopId = p["desktopId"]?.stringValue
        f.since = p["since"]?.stringValue
        return f
    }

    func listRequests(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let limit = min(p["limit"]?.intValue ?? 50, Self.requestPageLimit)
        do {
            let page = try ledger.list(requestFilter(p, c), after: p["cursor"]?.stringValue, limit: limit)
            var items: [JSONValue] = []
            var bytes = 0
            var next = page.next
            for (i, r) in page.records.enumerated() {
                let item = r.json
                bytes += item.encoded().utf8.count
                // Large outcomes: the page ends before the frame would.
                if bytes > Self.requestPageBytes, i > 0 {
                    next = RequestLedger.cursor(page.records[i - 1])
                    break
                }
                items.append(item)
            }
            return .success(.obj([("requests", .array(items)), ("next", next.map(JSONValue.string) ?? .null)]))
        } catch {
            return .failure(RuntimeError("audit_unavailable", "the request ledger cannot be read: \(error)", phase: .handler))
        }
    }

    /// request.export: the matching records, newest first, as one JSON
    /// document in an artifact of the caller (read it with artifact.read).
    func exportRequests(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let filter = requestFilter(p, c)
        let records: [RequestLedger.Record]
        let truncated: Bool
        do {
            let page = try ledger.list(filter, after: nil, limit: Self.requestExportLimit)
            records = page.records
            truncated = page.next != nil
        } catch {
            return .failure(RuntimeError("audit_unavailable", "the request ledger cannot be read: \(error)", phase: .handler))
        }
        let exportedAt = nowString
        var applied: [(String, JSONValue)] = []
        for key in ["clientId", "method", "state", "desktopId", "since"] { if let v = p[key] { applied.append((key, v)) } }
        if !isOwner(c) { applied = applied.filter { $0.0 != "clientId" } + [("clientId", .string(c.clientId))] }
        let document = JSONValue.obj([
            ("apiVersion", .string(RuntimeAPI.version)), ("exportedAt", .string(exportedAt)),
            ("filter", .obj(applied)), ("count", .int(records.count)), ("truncated", .bool(truncated)),
            ("requests", .array(records.map(\.json))),
        ])
        let bucket = "export:" + c.clientId
        do {
            try artifacts.admit(bucket: bucket)
        } catch let e as RuntimeError {
            return .failure(e)
        } catch {
            return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
        }
        let artifactId = DesktopRegistry.newId(prefix: "art")
        do {
            try Data(document.encoded().utf8).write(to: URL(fileURLWithPath: artifacts.path(for: artifactId, ext: "json")))
            let info = try artifacts.register(artifactId, mediaType: "application/json", clientId: c.clientId, runId: nil,
                                              createdAt: exportedAt, bucket: bucket)
            return .success(.obj([("artifact", info.json), ("count", .int(records.count)), ("truncated", .bool(truncated))]))
        } catch {
            artifacts.release(bucket: bucket)
            try? FileManager.default.removeItem(atPath: artifacts.path(for: artifactId, ext: "json"))
            if let e = error as? RuntimeError { return .failure(e) }
            return .failure(RuntimeError("internal_error", "cannot write the export: \(error)", phase: .handler))
        }
    }
}
