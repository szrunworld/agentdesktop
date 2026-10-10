import AgentDesktopProtocol
import Foundation

// PR4: diagnostics.export (Hub v1 W08, HUB-T074). A read of what the Runtime
// already knows, written as one JSON document into an artifact of the caller.
//
// Read-only, like Endpoint Diagnostics (#154): it repairs nothing, removes no
// socket, restarts nothing, changes no grant and creates no Run. Its only
// write is its own artifact (as request.export's).
//
// Least data: metadata only. Never in it: credentials or tokens, screenshots
// or other artifacts, typed text or action parameters, request outcomes,
// window titles or app content, peer process facts (pid, executable path),
// free-text notes, the endpoint path. A last pass redacts anything shaped
// like a credential and drops credential-named keys, in case a self-reported
// field carries one.
//
// Scope: the owner sees every client; a paired client only itself, its own
// connections, Runs (with the run capability), requests and refusals, and
// the Desktops its grant covers. It needs observe, as request.export and
// artifact.read do.
extension RuntimeService {
    static let diagnosticsSections = ["runtime", "capabilities", "connections", "clients", "desktops", "runs", "requests",
                                      "authorization"]
    static let diagnosticsExcluded = [
        "credentials and tokens", "screenshots and other artifacts", "typed text and action parameters", "request outcomes",
        "window titles and app content", "peer process facts (pid, executable path)", "free-text notes", "the endpoint path",
    ]
    static let diagnosticsRunLimit = 500
    static let diagnosticsDefaultWindow: TimeInterval = 86_400
    static let diagnosticsMaxWindow: TimeInterval = 7 * 86_400

    func exportDiagnostics(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let owner = isOwner(c)
        let mine = owner ? nil : c.clientId
        let chosen = p["sections"]?.arrayValue?.compactMap(\.stringValue) ?? Self.diagnosticsSections
        let floor = now().addingTimeInterval(-Self.diagnosticsMaxWindow)
        var from = p["since"]?.stringValue.flatMap(Timestamp.date) ?? now().addingTimeInterval(-Self.diagnosticsDefaultWindow)
        if from < floor { from = floor }
        let since = Timestamp.string(from)

        var sections: [(String, JSONValue)] = []
        var counts: [(String, Int)] = []
        for name in Self.diagnosticsSections where chosen.contains(name) {
            let (value, items) = diagnosticsSection(name, since: since, mine: mine, c)
            sections.append((name, value))
            counts.append((name, items))
        }
        let manifest = JSONValue.obj([
            ("scope", .obj([("role", .string(owner ? "owner" : "paired")), ("clientId", .string(c.clientId))])),
            ("since", .string(since)),
            ("sections", .array(counts.map { .obj([("name", .string($0.0)), ("items", .int($0.1))]) })),
            ("excluded", .array(Self.diagnosticsExcluded.map(JSONValue.string))),
        ])
        if p["preview"]?.boolValue == true {
            return .success(.obj([("preview", .bool(true)), ("manifest", manifest)]))
        }
        let exportedAt = nowString
        let document = Self.redacted(.obj([
            ("apiVersion", .string(RuntimeAPI.version)), ("kind", .string("agentdesktop.diagnostics")),
            ("exportedAt", .string(exportedAt)), ("manifest", manifest), ("sections", .obj(sections)),
        ]))
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
            return .success(.obj([("preview", .bool(false)), ("manifest", manifest), ("artifact", info.json)]))
        } catch {
            artifacts.release(bucket: bucket)
            try? FileManager.default.removeItem(atPath: artifacts.path(for: artifactId, ext: "json"))
            if let e = error as? RuntimeError { return .failure(e) }
            return .failure(RuntimeError("internal_error", "cannot write the diagnostics: \(error)", phase: .handler))
        }
    }

    /// One section and how many items it holds.
    private func diagnosticsSection(_ name: String, since: String, mine: String?, _ c: ConnectionState) -> (JSONValue, Int) {
        switch name {
        case "runtime":
            let perms = backend.permissions()
            return (.obj([
                ("product", .string(identity.product)), ("productVersion", .string(identity.productVersion)),
                ("apiVersion", .string(identity.apiVersion)), ("instanceId", .string(identity.instanceId)),
                ("startedAt", .string(identity.startedAt)), ("uptimeSeconds", .int(Int(max(0, now().timeIntervalSince(startedAt))))),
                ("buildSource", .string(identity.buildSource)), ("platform", backend.platform.json),
                ("desktopPlatform", .bool(platform != nil)),
                ("inputAdmission", .string(execution.inputAdmission.rawValue)),
                ("auditStorage", .string(execution.auditUnavailable ? "failed" : "healthy")),
                ("permissions", .obj([("screenRecording", .string(perms.screenRecording.rawValue)),
                                      ("accessibility", .string(perms.accessibility.rawValue))])),
                ("features", .array(backend.features().map(JSONValue.string))),
            ]), 1)
        case "capabilities":
            let served = extensions.names
            let names = contract.methods
                .filter { RuntimeMethod(rawValue: $0.method).map(implemented) ?? served.contains($0.method) }.map(\.method)
            return (.obj([("methods", .array(names.map(JSONValue.string)))]), names.count)
        case "connections":
            let open = openConnections.all.filter { mine == nil || $0.connection.clientId == mine }
            return (.array(open.map { e in
                .obj([("connectionId", .string(e.connection.connectionId)), ("clientId", .string(e.connection.clientId)),
                      ("role", .string(e.connection.role.rawValue)), ("since", .string(e.since)),
                      ("codeIdentityLevel", .string(e.connection.codeIdentity.level.rawValue)),
                      ("subscribed", .bool(e.connection.isSubscribed))])
            }), open.count)
        case "clients":
            let clients = hub.clients().filter { mine == nil || $0.clientId == mine }
            return (.array(clients.map { cl in
                var m: [(String, JSONValue)] = [
                    ("clientId", .string(cl.clientId)), ("agentName", .string(String(cl.agentName.prefix(64)))),
                    ("state", .string(cl.state)), ("registeredAt", .string(cl.registeredAt)),
                    ("codeIdentityLevel", cl.codeIdentity["level"] ?? .null),
                ]
                if let at = cl.revokedAt { m.append(("revokedAt", .string(at))) }
                if let g = hub.grant(cl.clientId) {
                    m.append(("grant", .obj([("state", .string(g.state)), ("revision", .int(g.revision)),
                                             ("expiresAt", .string(g.expiresAt)),
                                             ("capabilities", .array(g.capabilities.map(JSONValue.string))),
                                             ("desktopCount", .int(g.desktops.count)), ("appCount", .int(g.apps.count))])))
                }
                return .obj(m)
            }), clients.count)
        case "desktops":
            let visible = desktops.list().filter { desktopAllowed(c, $0.desktopId) }
            return (.array(visible.map { d in
                .obj([("desktopId", .string(d.desktopId)), ("kind", .string(d.kind.rawValue)), ("createdAt", .string(d.createdAt)),
                      ("bound", .bool(d.boundPID != nil)), ("lease", execution.holder(of: d.desktopId).map(JSONValue.string) ?? .null)])
            }), visible.count)
        case "runs":
            // A paired client without the run capability sees no Runs here
            // either (it may export with observe alone, as request.export).
            if mine != nil, hub.grant(c.clientId)?.capabilities.contains("run") != true { return (.array([]), 0) }
            var f = RunStore.ListFilter()
            f.clientId = mine
            var out: [RunRecord] = []
            var cursor: String?
            repeat {
                let page = runs.list(f, after: cursor, limit: 200)
                let fresh = page.runs.filter { $0.createdAt >= since || !$0.isEnded }
                out += fresh
                // Newest first: once a page is all older and ended, the rest is too.
                cursor = fresh.isEmpty ? nil : page.next
            } while cursor != nil && out.count < Self.diagnosticsRunLimit
            out = Array(out.prefix(Self.diagnosticsRunLimit))
            return (.array(out.map(diagnosticsRun)), out.count)
        case "requests":
            var f = RequestLedger.Filter()
            f.caller = mine
            f.since = Timestamp.date(since)
            var counts: [String: (String, String, Int)] = [:]
            var cursor: String?
            var scanned = 0
            repeat {
                guard let page = try? ledger.list(f, after: cursor, limit: 1000) else { break }
                for r in page.records { counts["\(r.method)|\(r.state.rawValue)", default: (r.method, r.state.rawValue, 0)].2 += 1 }
                scanned += page.records.count
                cursor = page.next
            } while cursor != nil && scanned < 100_000
            let rows = counts.values.sorted { ($0.0, $0.1) < ($1.0, $1.1) }
            return (.obj([("truncated", .bool(cursor != nil)),
                          ("byMethodAndState", .array(rows.map { .obj([("method", .string($0.0)), ("state", .string($0.1)),
                                                                        ("count", .int($0.2))]) }))]), rows.count)
        case "authorization":
            let rows = hub.refusalCounts(since: since, clientId: mine)
            return (.obj([("refusals", .array(rows.map { .obj([("method", .string($0.method)), ("decision", .string($0.decision)),
                                                               ("reason", .string($0.reason)), ("count", .int($0.count))]) }))]),
                    rows.count)
        default:
            return (.null, 0)
        }
    }

    /// A Run's metadata and its stop evidence, from its events: when a stop
    /// was accepted, when it became quiescent, when it ended.
    private func diagnosticsRun(_ r: RunRecord) -> JSONValue {
        var stop: [(String, JSONValue)] = []
        for e in runs.events(r.runId, after: 0, limit: 100_000) {
            guard let at = e["at"]?.stringValue else { continue }
            switch e["type"]?.stringValue {
            case "stop.accepted", "run.finishing": if !stop.contains(where: { $0.0 == "acceptedAt" }) { stop.append(("acceptedAt", .string(at))) }
            case "run.quiescent": stop.append(("quiescentAt", .string(at)))
            default: break
            }
        }
        var m: [(String, JSONValue)] = [
            ("runId", .string(r.runId)), ("kind", .string(r.kind)), ("origin", .string(r.origin.rawValue)),
            ("ownership", .string(r.ownership.rawValue)), ("lifetime", .string(r.lifetime.rawValue)),
            ("clientId", r.clientId.map(JSONValue.string) ?? .null), ("desktopId", .string(r.desktopId)),
            ("phase", .string(r.phase.rawValue)), ("outcome", r.outcome.map { .string($0.rawValue) } ?? .null),
            ("quiescence", .string(r.quiescence.rawValue)), ("closingReason", r.closingReason.map(JSONValue.string) ?? .null),
            ("revision", .int(r.revision)), ("createdAt", .string(r.createdAt)),
            ("receiptCount", .int(r.receipts.count)), ("unknownActions", .int(r.unknownActions)),
        ]
        if let ended = r.endedAt { stop.append(("endedAt", .string(ended))) }
        m.append(("stop", .obj(stop)))
        return .obj(m)
    }

    /// Keys that name a secret are dropped; any value shaped like a
    /// credential is replaced. Defence in depth: no section reads one.
    static let secretKeys: Set<String> = ["token", "credential", "secret", "password", "apikey", "api_key", "attachtoken",
                                          "cookie"]

    static func redacted(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(members):
            return .object(members.filter { !secretKeys.contains($0.key.lowercased()) }
                .map { (key: $0.key, value: redacted($0.value)) })
        case let .array(items):
            return .array(items.map(redacted))
        case let .string(s):
            return .string(redactedText(s))
        default:
            return v
        }
    }

    static func redactedText(_ s: String) -> String {
        var out = s
        for pattern in [#"adt1_[A-Za-z0-9_\-]{8,}"#, #"sk-[A-Za-z0-9_\-]{16,}"#, #"(?i)bearer\s+[A-Za-z0-9._\-]{8,}"#] {
            out = out.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return out
    }
}
