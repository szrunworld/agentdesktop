import AgentDesktopProtocol
import Foundation

/// A4: who may call what. Identity comes only from the connection — the
/// main window in this process, the owner credential, or a paired app's
/// credential shown in runtime.handshake — never from params. Every request
/// of a paired app is checked against its current client state and grant
/// (no cached decision), and an action is checked once more right before
/// its input goes out.
extension RuntimeService {
    /// Methods anyone connected may call, paired or not.
    static let openMethods: Set<String> = ["runtime.handshake", "runtime.capabilities", "hub.pairing.start", "hub.pairing.status"]
    /// Methods a paired app may call with any grant.
    static let pairedBaseline: Set<String> = ["runtime.status"]
    /// The grant capability each method needs. Methods in none of these
    /// lists (stopAll, enableInput, ai.*, gui.runs.*, the rest of hub.*)
    /// are the owner's.
    static let capabilityOf: [String: String] = {
        var m: [String: String] = [:]
        for x in ["desktop.list", "desktop.show", "app.list", "window.list", "observe", "wait", "artifact.show",
                  "artifact.read", "session.show", "request.show"] { m[x] = "observe" }
        for x in ["act", "session.open", "session.close"] { m[x] = "act" }
        for x in ["desktop.create", "desktop.destroy", "app.launch", "window.bind", "window.unbind"] { m[x] = "desktop.manage" }
        for x in ["run.start", "run.attach", "run.finish", "run.show", "run.events", "run.wait", "run.cancel", "run.list",
                  "events.subscribe", "events.unsubscribe"] { m[x] = "run" }
        m["unit.run"] = "unit.run"
        return m
    }()

    func isOwner(_ c: ConnectionState) -> Bool { c.role == .owner }

    /// Why the caller may not make this request, if it may not.
    func authorization(_ request: RuntimeRequest, _ c: ConnectionState) -> RuntimeError? {
        let method = request.method
        if Self.openMethods.contains(method) || c.role == .owner { return nil }
        func deny(_ e: RuntimeError, _ reason: String) -> RuntimeError {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied", reason: reason,
                      runId: request.context.runId)
            return e
        }
        guard c.role == .paired else {
            return deny(RuntimeError("pairing_required", "pair this app with AgentDesktop first (hub.pairing.start); \(method) needs a paired client",
                                     phase: .request, notSent: true), "unpaired")
        }
        if let e = accessError(c, method: method) { return deny(e, e.details?["reason"]?.stringValue ?? e.code) }
        // Attaching one of the user's own displays puts the user's real
        // windows in reach: only the owner does that. An owner may still
        // list such a Desktop's id in an app's grant.
        if method == RuntimeMethod.desktopCreate.rawValue, request.params["physical"] != nil {
            return deny(RuntimeError("permission_denied", "attaching a physical display is reserved to the owner of this AgentDesktop",
                                     phase: .request, notSent: true, details: .obj([("reason", .string("owner_only"))])),
                        "physical_display")
        }
        // Another client's session or Run, named in the request: it does
        // not exist for this caller, and the attempt is on record.
        if let sid = request.context.sessionId, sessions.find(sid, caller: c.clientId) == nil, sessions.exists(sid) {
            return deny(.notFound("no session \(sid)"), "foreign_session")
        }
        if let runId = request.context.runId ?? request.params["runId"]?.stringValue,
           let run = runs.find(runId), run.clientId != c.clientId {
            return deny(.notFound("no run \(runId)"), "foreign_run")
        }
        if let desktopId = targetDesktop(request, c), let e = desktopError(c, desktopId) {
            return deny(e, "desktop_out_of_grant")
        }
        if let e = appError(request, c) { return deny(e, "app_out_of_grant") }
        return nil
    }

    /// The client and its grant as they are now, and the method's capability.
    func accessError(_ c: ConnectionState, method: String) -> RuntimeError? {
        guard let client = hub.client(c.clientId), client.state == "active" else {
            return RuntimeError("client_revoked", "\(c.clientId) was removed from AgentDesktop; pair again to continue",
                                phase: .request, notSent: true, details: .obj([("reason", .string("client_revoked"))]))
        }
        guard let g = hub.grant(client.clientId), g.state == "active" else {
            return RuntimeError("grant_missing", "\(c.clientId) holds no active grant", phase: .request, notSent: true,
                                details: .obj([("reason", .string("no_grant"))]))
        }
        guard g.expiresAt > Timestamp.string(now()) else {
            return RuntimeError("grant_expired", "the grant of \(c.clientId) expired at \(g.expiresAt); ask the owner to renew it",
                                phase: .request, notSent: true, details: .obj([("reason", .string("grant_expired"))]))
        }
        if Self.pairedBaseline.contains(method) { return nil }
        guard let capability = Self.capabilityOf[method] else {
            return RuntimeError("permission_denied", "\(method) is reserved to the owner of this AgentDesktop", phase: .request,
                                notSent: true, details: .obj([("reason", .string("owner_only"))]))
        }
        guard g.capabilities.contains(capability) else {
            return RuntimeError("grant_missing", "\(method) needs the \(capability) capability, which \(c.clientId) was not granted",
                                phase: .request, notSent: true,
                                details: .obj([("reason", .string("capability")), ("capability", .string(capability))]))
        }
        return nil
    }

    /// The Desktop a request is aimed at, from its session, context or params.
    func targetDesktop(_ request: RuntimeRequest, _ c: ConnectionState) -> String? {
        if let sid = request.context.sessionId { return sessions.find(sid, caller: c.clientId)?.desktopId }
        if let did = request.context.desktopId { return did }
        return request.params["desktopId"]?.stringValue
    }

    func desktopAllowed(_ c: ConnectionState, _ desktopId: String) -> Bool {
        if c.role == .owner { return true }
        guard let g = hub.grant(c.clientId), g.state == "active" else { return false }
        if g.desktops.contains(desktopId) { return true }
        return g.desktops.contains("created") && desktops.find(desktopId)?.createdBy == c.clientId
    }

    func desktopError(_ c: ConnectionState, _ desktopId: String) -> RuntimeError? {
        // A Desktop the grant does not cover does not exist for this client.
        desktopAllowed(c, desktopId) ? nil : .notFound("no desktop \(desktopId)")
    }

    func appAllowed(_ c: ConnectionState, bundleId: String?) -> Bool {
        if c.role == .owner { return true }
        guard let bundleId, let g = hub.grant(c.clientId) else { return false }
        return g.apps.contains(bundleId)
    }

    /// app.launch and window.bind only for the apps the grant names.
    func appError(_ request: RuntimeRequest, _ c: ConnectionState) -> RuntimeError? {
        let p = request.params
        let bundle: String?
        switch request.method {
        case "app.launch":
            bundle = p["bundleId"]?.stringValue
        case "window.bind":
            let pid = p["pid"]?.intValue.map(Int32.init)
            bundle = backend.applications(includeBackground: true).first { $0.process.pid == pid }?.bundleId
        default:
            return nil
        }
        guard appAllowed(c, bundleId: bundle) else {
            return RuntimeError("grant_missing", "\(bundle ?? "this app") is not among the apps \(c.clientId) was granted",
                                phase: .request, notSent: true,
                                details: .obj([("reason", .string("app")), ("bundleId", bundle.map(JSONValue.string) ?? .null)]))
        }
        return nil
    }

    /// Right before input goes out: the grant as it is now (a revocation or
    /// expiry while the action waited for the Desktop stops it).
    func recheckAct(_ c: ConnectionState, desktopId: String) -> RuntimeError? {
        guard c.role == .paired else { return nil }
        if let e = accessError(c, method: "act") { return e }
        return desktopAllowed(c, desktopId) ? nil
            : RuntimeError("grant_missing", "desktop \(desktopId) left the grant of \(c.clientId)", phase: .handler, notSent: true,
                           details: .obj([("reason", .string("desktop"))]))
    }

    // MARK: Handshake

    /// Authenticate a runtime.handshake credential. In-process owners keep
    /// their role; a socket connection is the owner with the owner
    /// credential, a paired app with its own, unpaired without one.
    func authenticate(_ credential: JSONValue?, _ c: ConnectionState) -> RuntimeError? {
        guard let credential, credential != .null else { return nil }
        let claimed = credential["clientId"]?.stringValue ?? ""
        let token = credential["token"]?.stringValue ?? ""
        func refuse(_ code: String, _ message: String, _ reason: String) -> RuntimeError {
            hub.audit(connectionId: c.connectionId, clientId: claimed, method: "runtime.handshake", decision: "denied", reason: reason)
            return RuntimeError(code, message, phase: .handshake, notSent: true, details: .obj([("reason", .string(reason))]))
        }
        if claimed == "local:\(c.peerUID)" {
            guard HubStore.same(HubStore.hash(token), HubStore.hash(ownerCredential)) else {
                return refuse("permission_denied", "the owner credential does not match", "bad_credential")
            }
            c.clientId = claimed
            c.role = .owner
            return nil
        }
        switch hub.authenticate(clientId: claimed, token: token) {
        case let .client(client):
            c.clientId = client.clientId
            c.role = .paired
            return nil
        case .revoked:
            return refuse("client_revoked", "\(claimed) was removed from AgentDesktop; pair again", "client_revoked")
        case .unknown:
            return refuse("permission_denied", "the credential does not prove \(claimed.isEmpty ? "any client" : claimed)", "bad_credential")
        }
    }

    func principalJSON(_ c: ConnectionState) -> JSONValue {
        .obj([("clientId", .string(c.clientId)), ("role", .string(c.role.rawValue)), ("connectionId", .string(c.connectionId))])
    }
}

/// Socket connections that finished their handshake, for hub.connections.list.
final class ConnectionRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var open: [String: (connection: ConnectionState, since: String)] = [:]

    func add(_ c: ConnectionState, at: String) { lock.withLock { open[c.connectionId] = (c, at) } }
    func remove(_ c: ConnectionState) { _ = lock.withLock { open.removeValue(forKey: c.connectionId) } }
    var all: [(connection: ConnectionState, since: String)] { lock.withLock { Array(open.values) } }
}
