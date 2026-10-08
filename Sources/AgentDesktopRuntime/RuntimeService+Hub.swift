import AgentDesktopProtocol
import Foundation

/// hub.* (A4, docs/plan/04 §4.2–4.4): pairing, clients, grants and
/// connections. Pairing may be asked by anyone connected; the rest is the
/// owner's. A credential goes only to the connection that asked to pair,
/// once.
extension RuntimeService {
    static let defaultGrantDuration: TimeInterval = 3600

    func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    func startPairing(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let requested = p["requested"] ?? .obj([])
        let unknown = strings(requested["capabilities"]).filter { !HubStore.capabilities.contains($0) }
        guard unknown.isEmpty else {
            return .failure(.invalidArgument("unknown capabilities: \(unknown.joined(separator: ", "))"))
        }
        do {
            let pairing = try hub.startPairing(connectionId: c.connectionId, agentName: p["agentName"]?.stringValue ?? "",
                                               publisher: p["publisher"]?.stringValue, requested: requested,
                                               callerFacts: c.callerFacts)
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.pairing.start", decision: "requested",
                      reason: pairing.pairingId)
            return .success(.obj([("pairingId", .string(pairing.pairingId)), ("shortCode", .string(pairing.shortCode)),
                                  ("state", .string(pairing.state)), ("expiresAt", .string(pairing.expiresAt))]))
        } catch {
            return .failure(RuntimeError("audit_unavailable", "the pairing store is unavailable", phase: .handler, notSent: true))
        }
    }

    /// The pairing's state; to the connection that asked, the credential of
    /// an approved pairing, once.
    func pairingStatus(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["pairingId"]?.stringValue ?? ""
        guard let pairing = hub.pairing(id), isOwner(c) || pairing.connectionId == c.connectionId else {
            return .failure(.notFound("no pairing \(id)"))
        }
        var out: [(String, JSONValue)] = [("pairingId", .string(pairing.pairingId)), ("state", .string(pairing.state)),
                                          ("expiresAt", .string(pairing.expiresAt))]
        if let clientId = pairing.clientId { out.append(("clientId", .string(clientId))) }
        if pairing.connectionId == c.connectionId, pairing.state == "approved", let clientId = pairing.clientId,
           let token = hub.collect(pairing.pairingId) {
            out.append(("credential", .obj([("clientId", .string(clientId)), ("token", .string(token))])))
            if let g = hub.grant(clientId) { out.append(("grant", g.json)) }
        }
        return .success(.obj(out))
    }

    /// The grant the owner gives, within what was asked for.
    func grantFrom(_ p: JSONValue, requested: JSONValue?, clientId: String) -> Result<HubStore.Grant, RuntimeError> {
        let caps = strings(p["capabilities"]), desks = strings(p["desktops"]), apps = strings(p["apps"])
        let unknown = caps.filter { !HubStore.capabilities.contains($0) }
        guard unknown.isEmpty else { return .failure(.invalidArgument("unknown capabilities: \(unknown.joined(separator: ", "))")) }
        if let requested {
            let more = caps.filter { !strings(requested["capabilities"]).contains($0) }
                + desks.filter { !strings(requested["desktops"]).contains($0) }
                + apps.filter { !strings(requested["apps"]).contains($0) }
            guard more.isEmpty else {
                return .failure(.invalidArgument("a grant can only hold what the app asked for; not asked: \(more.joined(separator: ", "))"))
            }
        }
        let seconds = Double(p["durationSeconds"]?.intValue ?? Int(Self.defaultGrantDuration))
        guard seconds > 0, seconds <= HubStore.maxGrantDuration else {
            return .failure(.invalidArgument("durationSeconds must be between 1 and \(Int(HubStore.maxGrantDuration))"))
        }
        return .success(HubStore.Grant(clientId: clientId, capabilities: caps, desktops: desks, apps: apps,
                                       expiresAt: Timestamp.string(now().addingTimeInterval(seconds)), revision: 0, state: "active"))
    }

    func approvePairing(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["pairingId"]?.stringValue ?? ""
        guard let pairing = hub.pairing(id) else { return .failure(.notFound("no pairing \(id)")) }
        guard pairing.state == "requested" else {
            return .failure(RuntimeError("conflict", "pairing \(id) is \(pairing.state)", phase: .handler, notSent: true,
                                         details: .obj([("state", .string(pairing.state))])))
        }
        switch grantFrom(p["grant"] ?? .obj([]), requested: pairing.requested, clientId: "") {
        case let .failure(e): return .failure(e)
        case let .success(g):
            do {
                let (client, grant) = try hub.approve(pairing, grant: g)
                hub.audit(connectionId: c.connectionId, clientId: client.clientId, method: "hub.pairing.approve", decision: "approved",
                          reason: pairing.pairingId)
                return .success(.obj([("client", client.json), ("grant", grant.json)]))
            } catch {
                return .failure(RuntimeError("audit_unavailable", "the pairing store is unavailable", phase: .handler, notSent: true))
            }
        }
    }

    func denyPairing(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["pairingId"]?.stringValue ?? ""
        guard let pairing = hub.pairing(id) else { return .failure(.notFound("no pairing \(id)")) }
        guard pairing.state == "requested" else {
            return .failure(RuntimeError("conflict", "pairing \(id) is \(pairing.state)", phase: .handler, notSent: true))
        }
        try? hub.deny(pairing)
        hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.pairing.deny", decision: "denied", reason: id)
        return .success(.obj([("pairingId", .string(id)), ("state", .string("denied"))]))
    }

    func listClients() -> Result<JSONValue, RuntimeError> {
        .success(.obj([("clients", .array(hub.clients().map { c in
            c.json.setting("grant", hub.grant(c.clientId)?.json ?? .null)
        })), ("pairings", .array(hub.pairings().map(\.json)))]))
    }

    func showClient(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        let id = p["clientId"]?.stringValue ?? ""
        guard let client = hub.client(id) else { return .failure(.notFound("no client \(id)")) }
        let connections = openConnections.all.filter { $0.connection.clientId == id }.map { $0.connection.connectionId }
        return .success(client.json.setting("grant", hub.grant(id)?.json ?? .null)
            .setting("connections", .array(connections.map(JSONValue.string))))
    }

    /// Remove a client (soft): its credential stops working, its Runs stop,
    /// its open connections are refused from the next request on.
    func revokeClient(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["clientId"]?.stringValue ?? ""
        guard (try? hub.revoke(id)) ?? nil != nil, let client = hub.client(id) else { return .failure(.notFound("no client \(id)")) }
        // The linearization point: from here nothing more reaches the app.
        cutConnections(of: id, reason: "client_revoked")
        execution.stopRuns(ofClient: id, reason: "client_revoked")
        // Its sessions close too, so they hold no Desktop open.
        sessions.closeAll(caller: id, at: nowString)
        hub.audit(connectionId: c.connectionId, clientId: id, method: "hub.clients.revoke", decision: "revoked", reason: "owner")
        return .success(client.json)
    }

    func listGrants() -> Result<JSONValue, RuntimeError> {
        .success(.obj([("grants", .array(hub.clients().compactMap { hub.grant($0.clientId)?.json }))]))
    }

    /// Replace a client's grant. Narrowing applies to the next request and
    /// the next action at once; Runs on Desktops the grant no longer covers
    /// are stopped.
    func setGrant(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["clientId"]?.stringValue ?? ""
        guard let client = hub.client(id), client.state == "active" else { return .failure(.notFound("no active client \(id)")) }
        switch grantFrom(p, requested: nil, clientId: id) {
        case let .failure(e): return .failure(e)
        case let .success(g):
            let epoch = hub.policyEpoch
            guard let saved = try? hub.setGrant(g) else {
                return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable", phase: .handler, notSent: true))
            }
            // Narrowed: its connections are cut, it reconnects under the new grant.
            if hub.policyEpoch != epoch { cutConnections(of: id, reason: "grant_narrowed") }
            var filter = RunStore.ListFilter()
            filter.clientId = id
            filter.activeOnly = true
            for r in runs.list(filter, after: nil, limit: 500).runs
            where !desktopAllowed(ConnectionState.paired(id), r.desktopId) || !saved.capabilities.contains("run") {
                _ = execution.stop(runId: r.runId, reason: "grant_narrowed", endAs: .cancelled)
            }
            hub.audit(connectionId: c.connectionId, clientId: id, method: "hub.grants.set", decision: "granted",
                      reason: "revision \(saved.revision)")
            return .success(saved.json)
        }
    }

    func revokeGrant(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["clientId"]?.stringValue ?? ""
        guard var g = hub.grant(id) else { return .failure(.notFound("no grant for \(id)")) }
        g.state = "revoked"
        guard let saved = try? hub.setGrant(g) else {
            return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable", phase: .handler, notSent: true))
        }
        cutConnections(of: id, reason: "grant_revoked")
        execution.stopRuns(ofClient: id, reason: "grant_revoked")
        hub.audit(connectionId: c.connectionId, clientId: id, method: "hub.grants.revoke", decision: "revoked", reason: "owner")
        return .success(saved.json)
    }

    func listConnections() -> Result<JSONValue, RuntimeError> {
        .success(.obj([("connections", .array(openConnections.all.map { e in
            .obj([("connectionId", .string(e.connection.connectionId)), ("clientId", .string(e.connection.clientId)),
                  ("role", .string(e.connection.role.rawValue)), ("clientName", e.connection.clientName.map(JSONValue.string) ?? .null),
                  ("callerFacts", e.connection.callerFacts), ("since", .string(e.since))])
        }))]))
    }
}

extension ConnectionState {
    /// A stand-in for a paired client, to ask what its grant covers.
    static func paired(_ clientId: String) -> ConnectionState {
        let c = ConnectionState(socketPeer: getuid(), pid: nil, executable: nil)
        c.clientId = clientId
        c.role = .paired
        return c
    }
}
