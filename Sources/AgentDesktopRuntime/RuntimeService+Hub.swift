import AgentDesktopProtocol
import Foundation

/// hub.* (A4, docs/plan/04 §4.2–4.4): pairing, clients, grants and
/// connections. Pairing may be asked by anyone connected; the rest is the
/// owner's. A credential goes only to the connection that asked to pair,
/// once.
extension RuntimeService {
    static let defaultGrantDuration: TimeInterval = 3600
    static let maxOpenPairings = 20
    static var busyRetry: TimeInterval = 2

    func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    /// A name an app gives itself is shown to the user: one line of
    /// printable text, no control, line-separator or bidi characters that
    /// could fake or hide lines of the confirmation (A4 review M2).
    static func showableName(_ s: String?, max: Int) -> Bool {
        guard let s else { return true }
        guard !s.isEmpty, s.count <= max else { return false }
        return s.unicodeScalars.allSatisfy { u in
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
            default: return true
            }
        }
    }

    func startPairing(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard Self.showableName(p["agentName"]?.stringValue ?? "", max: 64), Self.showableName(p["publisher"]?.stringValue, max: 128) else {
            return .failure(.invalidArgument("agentName and publisher must be one line of printable text"))
        }
        let requested = p["requested"] ?? .obj([])
        let unknown = strings(requested["capabilities"]).filter { !HubStore.capabilities.contains($0) }
        guard unknown.isEmpty else {
            return .failure(.invalidArgument("unknown capabilities: \(unknown.joined(separator: ", "))"))
        }
        // Bounded waiting: one open request per program, a few in all (review M3).
        let open = hub.pairings()
        let program = gateKey(c)
        if confirmationGate.coolingDown(cooldownKey(c), now: now()) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.pairing.start", decision: "denied", reason: "pairing_cooldown")
            return .failure(RuntimeError("permission_denied", "the user just refused this program; try again in a minute",
                                         phase: .request, notSent: true, details: .obj([("reason", .string("pairing_cooldown"))])))
        }
        if open.count >= Self.maxOpenPairings
            || open.contains(where: { Self.programKey(callerFacts: $0.callerFacts, codeIdentity: $0.codeIdentity, fallback: $0.connectionId) == program }) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.pairing.start", decision: "denied", reason: "pairing_busy")
            return .failure(RuntimeError("permission_denied", "a pairing request from this program is already waiting; answer it first",
                                         phase: .request, notSent: true, details: .obj([("reason", .string("pairing_busy"))])))
        }
        // What the user will be asked to allow, exactly as it will be applied.
        let proposed: HubStore.Grant
        switch grantFrom(requested, requested: requested, clientId: "") {
        case let .failure(e): return .failure(e)
        case let .success(g): proposed = g
        }
        do {
            let pairing = try hub.startPairing(connectionId: c.connectionId, agentName: p["agentName"]?.stringValue ?? "",
                                               publisher: p["publisher"]?.stringValue, requested: requested,
                                               callerFacts: c.callerFacts, codeIdentity: c.codeIdentity.json)
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.pairing.start", decision: "requested",
                      reason: pairing.pairingId)
            // The user answers in the Agent Desktop window; the app polls
            // hub.pairing.status meanwhile. Off the connection's thread.
            // Without a trusted window nothing approves it but the host's own
            // in-process owner, or it expires.
            if confirmer != nil {
                let thread = Thread { [self] in self.askToPair(pairing, proposed, c) }
                thread.name = "agentdesktop.runtime.pairing"
                thread.start()
            }
            return .success(.obj([("pairingId", .string(pairing.pairingId)), ("shortCode", .string(pairing.shortCode)),
                                  ("state", .string(pairing.state)), ("expiresAt", .string(pairing.expiresAt))]))
        } catch {
            return .failure(RuntimeError("audit_unavailable", "the pairing store is unavailable", phase: .handler, notSent: true))
        }
    }

    /// The user decides a pairing: approved exactly as shown (the grant's
    /// duration counts from the approval), anything else denies it.
    func askToPair(_ pairing: HubStore.Pairing, _ proposed: HubStore.Grant, _ c: ConnectionState) {
        let seconds = pairing.requested["durationSeconds"]?.intValue ?? Int(Self.defaultGrantDuration)
        let details = JSONValue.obj([("capabilities", .array(proposed.capabilities.map(JSONValue.string))),
                                     ("desktops", .array(proposed.desktops.map(JSONValue.string))),
                                     ("apps", .array(proposed.apps.map(JSONValue.string))),
                                     ("durationSeconds", .int(max(seconds, 1)))])
        // Asked again while the line is full (re-review): it is not denied
        // for that, and not left waiting unseen either.
        var decision: Result<Void, RuntimeError>
        while true {
            decision = confirm(.pairing, by: c, action: "hub.pairing.start", details: details, agentName: pairing.agentName,
                               publisher: pairing.publisher, shortCode: pairing.shortCode)
            guard case let .failure(e) = decision, e.details?["reason"]?.stringValue == "confirmation_busy",
                  hub.pairing(pairing.pairingId)?.state == "requested" else { break }
            Thread.sleep(forTimeInterval: Self.busyRetry)
        }
        guard let current = hub.pairing(pairing.pairingId), current.state == "requested" else { return }
        switch decision {
        case .success:
            var g = proposed
            g.expiresAt = Timestamp.string(now().addingTimeInterval(Double(max(seconds, 1))))
            if let (client, _) = try? hub.approve(current, grant: g) {
                hub.audit(connectionId: c.connectionId, clientId: client.clientId, method: "hub.pairing.start", decision: "approved",
                          reason: pairing.pairingId)
            }
        case let .failure(e):
            try? hub.deny(current)
            if ["user_denied", "user_cancelled", "confirmation_timeout"].contains(e.details?["reason"]?.stringValue ?? "") {
                confirmationGate.coolDown(cooldownKey(c), until: now().addingTimeInterval(ConfirmationGate.cooldown))
            }
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
        // Told "denied" only when it is (Codex review P2).
        do { try hub.deny(pairing) } catch {
            return .failure(RuntimeError("audit_unavailable", "the pairing store is unavailable; the pairing is not denied", phase: .handler, notSent: true))
        }
        guard hub.pairing(id)?.state == "denied" else {
            return .failure(RuntimeError("conflict", "pairing \(id) was decided meanwhile", phase: .handler, notSent: true))
        }
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
        guard let revoked = try? hub.revokeEndingWindowGrants(id), let client = hub.client(id) else {
            return .failure(.notFound("no client \(id)"))
        }
        // Its window grants ended with it, in the same transaction; what was
        // kept only under them goes.
        endedWindowGrants(revoked.windowGrants, state: "revoked", reason: "client_revoked")
        // The linearization point: from here nothing more reaches the app.
        cutConnections(of: id, reason: "client_revoked")
        accessWithdrawn(id)
        execution.stopRuns(ofClient: id, reason: "client_revoked")
        // Its sessions close too, so they hold no Desktop open.
        sessions.closeAll(caller: id, at: nowString)
        hub.audit(connectionId: c.connectionId, clientId: id, method: "hub.clients.revoke", decision: "revoked", reason: "owner")
        return .success(client.json)
    }

    /// Tell the in-process services that started work for `clientId` (the AI
    /// service's operations) to stop it (A4 R4).
    func accessWithdrawn(_ clientId: String) {
        for observer in accessObservers.all { observer(clientId) }
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
        case var .success(g):
            let viaConfirmation = c.role != .owner
            if viaConfirmation {
                // A paired client's confirmed call never brings back a grant
                // the owner revoked (that takes pairing again), and an
                // unverified one cannot extend it, however long the user took.
                guard let old = hub.grant(id), old.state == "active" else {
                    return .failure(RuntimeError("conflict", "the grant of \(id) is not active; it pairs again", phase: .handler, notSent: true,
                                                 details: .obj([("reason", .string("grant_not_active"))])))
                }
                // Never later than it was, for an unverified caller or for any
                // client changing its own grant (R1; focused review L1).
                if c.codeIdentity.level != .verified || id == c.clientId, g.expiresAt > old.expiresAt { g.expiresAt = old.expiresAt }
            }
            let epoch = hub.policyEpoch
            let saved: HubStore.Grant
            var endedWindows: [(id: String, reason: String)] = []
            do {
                if viaConfirmation, c.approvedTargetRevision == nil {
                    return .failure(RuntimeError("conflict", "no grant revision was confirmed; ask again", phase: .handler, notSent: true,
                                                 details: .obj([("reason", .string("target_changed"))])))
                }
                // Window grants for an app or Desktop the new grant no longer
                // covers end with it, in the same transaction (window-grants.md).
                let next = g
                (saved, endedWindows) = try hub.setGrant(g, expectedRevision: viaConfirmation ? c.approvedTargetRevision : nil,
                                                         endingWindowGrants: { [self] w in
                    if !next.apps.contains(w.bundleId) { return "app_removed" }
                    let created = next.desktops.contains("created") && desktops.find(w.desktopId)?.createdBy == id
                    return next.desktops.contains(w.desktopId) || created ? nil : "desktop_removed"
                })
            } catch let e as RuntimeStoreError where viaConfirmation {
                return .failure(RuntimeError("conflict", e.description, phase: .handler, notSent: true,
                                             details: .obj([("reason", .string("target_changed"))])))
            } catch {
                return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable", phase: .handler, notSent: true))
            }
            // Audited as what each became: an ended grant swept here is revoked.
            for e in endedWindows { endedWindowGrants([e.id], state: hub.windowGrant(e.id)?.state ?? "ended", reason: e.reason) }
            // Narrowed: its connections are cut, it reconnects under the new grant.
            if hub.policyEpoch != epoch { cutConnections(of: id, reason: "grant_narrowed") }
            for r in activeRuns(of: id)
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
        // Its window grants end with it, in the same transaction.
        guard let (saved, ended) = try? hub.setGrant(g, endingWindowGrants: nil) else {
            return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable", phase: .handler, notSent: true))
        }
        endedWindowGrants(ended.map(\.id), state: "revoked", reason: "grant_revoked")
        cutConnections(of: id, reason: "grant_revoked")
        accessWithdrawn(id)
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
