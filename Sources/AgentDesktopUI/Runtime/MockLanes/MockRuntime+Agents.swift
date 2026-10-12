import AgentDesktopProtocol
import Foundation

// Lane UI-C (Agents 页; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.

/// Lane UI-C's mock state (read and written with the MockRuntime's lock held).
final class MockAgentsLane: @unchecked Sendable {
    /// Open connections as `hub.connections.list` reports them.
    var connections: [JSONValue] = []
    /// Window grants (HubWindowGrant), active and ended.
    var windowGrants: [JSONValue] = []
    /// Pairing requests (HubPairing) for `hub.pairing.status`. The base mock's
    /// `hub.clients.list` answers `pairings: []` (MockRuntime.swift is shared;
    /// see the PR's coordination note), so these only reach the status call.
    var pairings: [JSONValue] = []
    var nextConnection = 1
    var nextWindowGrant = 1
    var nextPairing = 1

    init() {
        // The main window's own in-process connection: the owner.
        connections.append(.obj([
            ("connectionId", .string("conn_owner")), ("clientId", .string("local:501")), ("role", .string("owner")),
            ("clientName", .string("AgentDesktop main window")), ("callerFacts", .obj([])),
            ("since", .string("2026-10-08T00:00:00.000Z")),
        ]))
    }
}

extension MockRuntime {
    /// Methods lane UI-C models (each must be in RuntimeCatalog.implemented).
    /// `hub.pairing.approve` / `deny` are left out on purpose: the main window
    /// never decides a pairing; the user does in the trusted window.
    static let agentsLaneMethods: [String] = [
        "hub.clients.show", "hub.clients.revoke", "hub.grants.set", "hub.grants.revoke",
        "hub.connections.list", "hub.windows.list", "hub.windows.revoke", "hub.pairing.status",
    ]

    /// Lane UI-C's answer to one of `agentsLaneMethods` (lock held).
    func agentsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        let lane = lanes.agents
        switch method {
        case "hub.clients.show":
            let id = p["clientId"]?.stringValue ?? ""
            guard let c = clients.first(where: { $0["clientId"]?.stringValue == id }) else { throw RuntimeError.notFound("no client \(id)") }
            return c.setting("connections", .array(agentsConnectionIds(id)))
        case "hub.clients.revoke":
            let id = p["clientId"]?.stringValue ?? ""
            guard let i = clients.firstIndex(where: { $0["clientId"]?.stringValue == id }) else { throw RuntimeError.notFound("no client \(id)") }
            var c = clients[i].setting("state", .string("revoked")).setting("revokedAt", .string(stamp()))
            if var g = c["grant"], !g.isNull {
                g = g.setting("state", .string("revoked")).setting("revision", .int((g["revision"]?.intValue ?? 0) + 1))
                c = c.setting("grant", g)
            }
            clients[i] = c
            agentsEndWindowGrants(of: id, state: "revoked", reason: "client_revoked") { _ in true }
            agentsCut(id)
            agentsStopRuns(of: id, reason: "client_revoked") { _ in true }
            return clients[i].setting("connections", .array([]))
        case "hub.grants.set":
            let id = p["clientId"]?.stringValue ?? ""
            guard let i = clients.firstIndex(where: { $0["clientId"]?.stringValue == id }),
                  clients[i]["state"]?.stringValue == "active", let old = clients[i]["grant"], !old.isNull else {
                throw RuntimeError.notFound("no active client \(id)")
            }
            let seconds = Double(p["durationSeconds"]?.intValue ?? 3600)
            let caps = p["capabilities"] ?? .array([]), desks = p["desktops"] ?? .array([]), apps = p["apps"] ?? .array([])
            let grant = old.setting("capabilities", caps).setting("desktops", desks).setting("apps", apps)
                .setting("expiresAt", .string(Timestamp.string(base.addingTimeInterval(clock + seconds))))
                .setting("revision", .int((old["revision"]?.intValue ?? 0) + 1)).setting("state", .string("active"))
            clients[i] = clients[i].setting("grant", grant)
            let appSet = Set((apps.arrayValue ?? []).compactMap(\.stringValue))
            let deskSet = Set((desks.arrayValue ?? []).compactMap(\.stringValue))
            let timeShortened = (grant["expiresAt"]?.stringValue ?? "") < (old["expiresAt"]?.stringValue ?? "")
            let observeRemoved = (old["capabilities"]?.arrayValue ?? []).contains(.string("observe")) && !(caps.arrayValue ?? []).contains(.string("observe"))
            let narrowed = timeShortened || !Set((old["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue)).isSubset(of: Set((caps.arrayValue ?? []).compactMap(\.stringValue)))
                || !Set((old["desktops"]?.arrayValue ?? []).compactMap(\.stringValue)).isSubset(of: deskSet)
                || !Set((old["apps"]?.arrayValue ?? []).compactMap(\.stringValue)).isSubset(of: appSet)
            for w in lane.windowGrants.indices where lane.windowGrants[w]["clientId"]?.stringValue == id
                && ["active", "ended"].contains(lane.windowGrants[w]["state"]?.stringValue ?? "") {
                let g = lane.windowGrants[w]
                let reason = observeRemoved ? "observe_removed" : timeShortened ? "grant_shortened" : !appSet.contains(g["window"]?["bundleId"]?.stringValue ?? "") ? "app_removed"
                    : !deskSet.contains(g["desktopId"]?.stringValue ?? "") ? "desktop_removed" : nil
                if let reason { lane.windowGrants[w] = g.setting("state", .string(observeRemoved || timeShortened || g["state"]?.stringValue == "ended" ? "revoked" : "ended")).setting("endedReason", .string(reason)) }
            }
            if narrowed { agentsCut(id) }
            agentsStopRuns(of: id, reason: "grant_narrowed") { run in
                !deskSet.contains(run["desktopId"]?.stringValue ?? "")
                    || !Set((caps.arrayValue ?? []).compactMap(\.stringValue)).contains(run["kind"]?.stringValue == "unit" ? "unit.run" : "run")
            }
            return grant
        case "hub.grants.revoke":
            let id = p["clientId"]?.stringValue ?? ""
            guard let i = clients.firstIndex(where: { $0["clientId"]?.stringValue == id }), let old = clients[i]["grant"], !old.isNull else {
                throw RuntimeError.notFound("no grant for \(id)")
            }
            let grant = old.setting("state", .string("revoked")).setting("revision", .int((old["revision"]?.intValue ?? 0) + 1))
            clients[i] = clients[i].setting("grant", grant)
            agentsEndWindowGrants(of: id, state: "revoked", reason: "grant_revoked") { _ in true }
            agentsCut(id)
            agentsStopRuns(of: id, reason: "grant_revoked") { _ in true }
            return grant
        case "hub.connections.list":
            return .obj([("connections", .array(lane.connections))])
        case "hub.windows.list":
            let all = p["includeEnded"]?.boolValue ?? false
            return .obj([("windowGrants", .array(lane.windowGrants.filter { all || $0["state"]?.stringValue == "active" }))])
        case "hub.windows.revoke":
            let id = p["windowGrantId"]?.stringValue ?? ""
            guard let w = lane.windowGrants.firstIndex(where: { $0["windowGrantId"]?.stringValue == id }) else {
                throw RuntimeError.notFound("no window grant \(id)")
            }
            let g = lane.windowGrants[w]
            guard g["state"]?.stringValue != "revoked" else {
                throw RuntimeError("conflict", "window grant \(id) is revoked", phase: .handler, notSent: true,
                                   details: .obj([("state", .string("revoked"))]))
            }
            var next = g.setting("state", .string("revoked"))
            if g["state"]?.stringValue == "active" { next = next.setting("endedReason", .string("window_grant_revoked")) }
            lane.windowGrants[w] = next
            agentsCut(g["clientId"]?.stringValue ?? "")
            return next
        case "hub.pairing.status":
            let id = p["pairingId"]?.stringValue ?? ""
            guard let pairing = lane.pairings.first(where: { $0["pairingId"]?.stringValue == id }) else {
                throw RuntimeError.notFound("no pairing \(id)")
            }
            // The owner is never the asking connection: no credential, ever.
            var out: [(String, JSONValue)] = [("pairingId", .string(id)), ("state", pairing["state"] ?? .string("requested")),
                                              ("expiresAt", pairing["expiresAt"] ?? .string(stamp()))]
            if let c = pairing["clientId"]?.stringValue { out.append(("clientId", .string(c))) }
            return .obj(out)
        default:
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
    }

    // MARK: Helpers (lock held)

    func agentsConnectionIds(_ clientId: String) -> [JSONValue] {
        lanes.agents.connections.filter { $0["clientId"]?.stringValue == clientId }.compactMap { $0["connectionId"] }
    }

    /// The linearization point of a revocation: the app's connections go.
    func agentsCut(_ clientId: String) {
        lanes.agents.connections.removeAll { $0["clientId"]?.stringValue == clientId }
    }

    func agentsEndWindowGrants(of clientId: String, state: String, reason: String, where match: (JSONValue) -> Bool) {
        let lane = lanes.agents
        for w in lane.windowGrants.indices where lane.windowGrants[w]["clientId"]?.stringValue == clientId
            && ["active", "ended"].contains(lane.windowGrants[w]["state"]?.stringValue ?? "") && match(lane.windowGrants[w]) {
            var g = lane.windowGrants[w].setting("state", .string(state))
            if lane.windowGrants[w]["state"]?.stringValue == "active" { g = g.setting("endedReason", .string(reason)) }
            lane.windowGrants[w] = g
        }
    }

    /// The client's Runs that are still going move to stopping/pending
    /// (the Runtime's stop; quiescence comes later).
    func agentsStopRuns(of clientId: String, reason: String, where match: (JSONValue) -> Bool) {
        let ids = runs.filter {
            $0["clientId"]?.stringValue == clientId && ["queued", "running", "waiting_approval", "waiting_input"].contains($0["phase"]?.stringValue ?? "") && match($0)
        }.compactMap { $0["runId"]?.stringValue }
        for id in ids { stopLocked(id, reason: reason) }
    }

    // MARK: Scenario building (only contract fields)

    /// Adds an open connection of a paired client; returns its connectionId.
    @discardableResult
    public func addConnection(clientId: String, name: String? = nil, pid: Int = 7100) -> String {
        lock.withLock {
            let lane = lanes.agents
            let id = "conn_" + String(format: "%03d", lane.nextConnection)
            lane.nextConnection += 1
            let label = name ?? clients.first { $0["clientId"]?.stringValue == clientId }?["agentName"]?.stringValue
            lane.connections.append(.obj([
                ("connectionId", .string(id)), ("clientId", .string(clientId)), ("role", .string("paired")),
                ("clientName", label.map(JSONValue.string) ?? .null), ("callerFacts", .obj([("pid", .int(pid))])),
                ("since", .string(stamp())),
            ]))
            return id
        }
    }

    /// Adds a window grant; returns its windowGrantId.
    @discardableResult
    public func addWindowGrant(clientId: String, desktopId: String, appName: String, bundleId: String, windowId: Int = 9101,
                               pid: Int = 4300, permissions: [String] = ["observe"], state: String = "active",
                               endedReason: String? = nil) -> String {
        lock.withLock {
            let lane = lanes.agents
            let id = "wg_" + String(format: "%03d", lane.nextWindowGrant)
            lane.nextWindowGrant += 1
            var m: [(String, JSONValue)] = [
                ("windowGrantId", .string(id)), ("clientId", .string(clientId)), ("desktopId", .string(desktopId)),
                ("window", .obj([("windowId", .int(windowId)),
                                 ("process", .obj([("pid", .int(pid)), ("startedAt", .string(Timestamp.string(base)))])),
                                 ("bundleId", .string(bundleId)), ("appName", .string(appName))])),
                ("permissions", .array(permissions.map(JSONValue.string))), ("state", .string(state)),
                ("createdAt", .string(stamp())), ("expiresAt", .string(Timestamp.string(base.addingTimeInterval(3600)))),
            ]
            if let endedReason { m.append(("endedReason", .string(endedReason))) }
            lane.windowGrants.append(.obj(m))
            return id
        }
    }

    /// Adds a pairing request as the Runtime records it; returns its pairingId.
    @discardableResult
    public func addPairing(agentName: String, shortCode: String = "482916", capabilities: [String] = ["observe"],
                           desktops: [String] = [], level: String = "same_user", state: String = "requested") -> String {
        lock.withLock {
            let lane = lanes.agents
            let id = "pair_" + String(format: "%03d", lane.nextPairing)
            lane.nextPairing += 1
            lane.pairings.append(.obj([
                ("pairingId", .string(id)), ("shortCode", .string(shortCode)), ("agentName", .string(agentName)),
                ("publisher", .null),
                ("requested", .obj([("capabilities", .array(capabilities.map(JSONValue.string))),
                                    ("desktops", .array(desktops.map(JSONValue.string)))])),
                ("callerFacts", .obj([("pid", .int(9130))])),
                ("codeIdentity", .obj([("level", .string(level)), ("hardenedRuntime", .bool(level == "verified"))])),
                ("state", .string(state)), ("expiresAt", .string(Timestamp.string(base.addingTimeInterval(clock + 600)))),
                ("clientId", .null),
            ]))
            return id
        }
    }

    /// The pairing requests as `hub.clients.list` would list them (for
    /// tests and renders, until the base mock lists them itself).
    public var agentsPairings: [JSONValue] { lock.withLock { lanes.agents.pairings } }

    /// Changes a pairing's state, as the trusted window would.
    public func decidePairing(_ pairingId: String, state: String, clientId: String? = nil) {
        lock.withLock {
            guard let i = lanes.agents.pairings.firstIndex(where: { $0["pairingId"]?.stringValue == pairingId }) else { return }
            var p = lanes.agents.pairings[i].setting("state", .string(state))
            if let clientId { p = p.setting("clientId", .string(clientId)) }
            lanes.agents.pairings[i] = p
        }
    }

    /// Attributes a Run to a paired client (the base mock starts Runs as local:501).
    public func assignRun(_ runId: String, toClient clientId: String) {
        lock.withLock {
            guard let i = runs.firstIndex(where: { $0["runId"]?.stringValue == runId }) else { return }
            runs[i] = runs[i].setting("clientId", .string(clientId))
        }
    }

    /// Sets a client's code identity as the Runtime would have read it.
    public func setCodeIdentity(_ clientId: String, level: String, identifier: String? = nil, teamId: String? = nil) {
        lock.withLock {
            guard let i = clients.firstIndex(where: { $0["clientId"]?.stringValue == clientId }) else { return }
            var m: [(String, JSONValue)] = [("level", .string(level)), ("hardenedRuntime", .bool(level == "verified"))]
            if let identifier { m.append(("identifier", .string(identifier))) }
            if let teamId { m.append(("teamId", .string(teamId))) }
            clients[i] = clients[i].setting("codeIdentity", .obj(m))
        }
    }

    /// The Agents page's sample: two paired apps (one verified, one not),
    /// open connections, window grants with the three permissions, and Runs
    /// of each app; built on `sample()` so the other pages stay as they are.
    public static func agentsSample() -> MockRuntime {
        let m = sample()
        let wechat = "app:mock-001"
        m.setCodeIdentity(wechat, level: "verified", identifier: "com.example.wechat-agent", teamId: "ABCDE12345")
        let boss = m.addClient(name: "BOSS 助手", capabilities: ["observe", "act", "run"], apps: ["com.google.Chrome"])
        m.addConnection(clientId: wechat, pid: 7101)
        m.addConnection(clientId: wechat, pid: 7102)
        m.addConnection(clientId: boss, pid: 7201)
        let desks = m.lock.withLock { m.desktops.compactMap { $0["desktopId"]?.stringValue } }
        m.addWindowGrant(clientId: wechat, desktopId: desks[0], appName: "微信", bundleId: "com.tencent.xinWeChat",
                         windowId: 9101, pid: 4301, permissions: ["observe", "act"])
        m.addWindowGrant(clientId: wechat, desktopId: desks[0], appName: "微信", bundleId: "com.tencent.xinWeChat",
                         windowId: 9102, pid: 4301, permissions: ["observe", "act", "persist"])
        m.addWindowGrant(clientId: wechat, desktopId: desks[1], appName: "微信", bundleId: "com.tencent.xinWeChat",
                         windowId: 9077, pid: 4122, permissions: ["observe"], state: "ended", endedReason: "window_closed")
        let runIds = m.lock.withLock { m.runs.filter { $0["phase"]?.stringValue != "ended" }.compactMap { $0["runId"]?.stringValue } }
        if runIds.count >= 2 {
            m.assignRun(runIds[0], toClient: wechat)
            m.assignRun(runIds[1], toClient: boss)
        }
        return m
    }
}
