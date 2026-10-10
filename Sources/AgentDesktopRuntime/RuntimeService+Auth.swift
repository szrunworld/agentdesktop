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
    /// Methods a paired app may call with any grant. Asking the user for a
    /// window checks the capabilities its permissions need in the handler,
    /// and a client lists only its own window grants.
    static let pairedBaseline: Set<String> = ["runtime.status", "hub.windows.request", "hub.windows.list"]
    /// The grant capability each method needs. Methods in none of these
    /// lists (stopAll, enableInput, ai.*, gui.runs.*, the rest of hub.*)
    /// are the owner's.
    static let capabilityOf: [String: String] = {
        var m: [String: String] = [:]
        for x in ["desktop.list", "desktop.show", "app.list", "window.list", "observe", "observe.region", "wait", "artifact.show",
                  "artifact.read", "session.show", "request.show"] { m[x] = "observe" }
        for x in ["act", "session.open", "session.close"] { m[x] = "act" }
        for x in ["desktop.create", "desktop.destroy", "app.launch", "window.bind", "window.unbind"] { m[x] = "desktop.manage" }
        for x in ["run.start", "run.attach", "run.finish", "run.show", "run.events", "run.wait", "run.cancel", "run.list",
                  "events.subscribe", "events.unsubscribe"] { m[x] = "run" }
        m["unit.run"] = "unit.run"
        // A paired app stops its own Runs (#153's plan); the global stop that
        // closes input admission is the owner's (the host window).
        m["runtime.stopAll"] = "run"
        return m
    }()

    func isOwner(_ c: ConnectionState) -> Bool { c.role == .owner || c.elevatedFor != nil }

    /// The reasons #153 (the interim seal) gave for these methods, kept so
    /// clients see the same refusal once grants replace the seal.
    static let grantReason: [String: String] = ["app.launch": "launch_requires_grant",
                                                "app.list": "window_discovery_requires_grant",
                                                "window.list": "window_discovery_requires_grant",
                                                "gui.runs.start": "gui_run_requires_grant", "gui.runs.get": "gui_run_requires_grant",
                                                "gui.runs.cancel": "gui_run_requires_grant", "gui.runs.events": "gui_run_requires_grant"]

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
        if let reason = c.cutReason { return deny(Self.cutError(c, reason), "connection_cut") }
        // An owner-only method a paired client may still ask the user for.
        if Self.confirmableMethods.contains(method) {
            if let e = accessError(c, method: "runtime.status") { return deny(e, e.details?["reason"]?.stringValue ?? e.code) }
            return confirmAdminCall(request, c)
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
        // Every session, Run and Desktop the request names, in its context
        // or its params, is checked; they must agree (A4 review H1: checking
        // one while the handler uses another let an app reach any Desktop).
        let sessionIds = Set([request.context.sessionId, request.params["sessionId"]?.stringValue].compactMap { $0 })
        for sid in sessionIds where sessions.find(sid, caller: c.clientId) == nil && sessions.exists(sid) {
            return deny(.notFound("no session \(sid)"), "foreign_session")
        }
        let runIds = Set([request.context.runId, request.params["runId"]?.stringValue].compactMap { $0 })
        for runId in runIds {
            if let run = runs.find(runId), run.clientId != c.clientId { return deny(.notFound("no run \(runId)"), "foreign_run") }
        }
        let named = targetDesktops(request, c)
        if named.count > 1 {
            return deny(RuntimeError("invalid_argument", "the request names more than one Desktop (\(named.sorted().joined(separator: ", "))); name one",
                                     phase: .request, notSent: true, details: .obj([("reason", .string("target_mismatch"))])),
                        "target_mismatch")
        }
        if let desktopId = named.first, let e = desktopError(c, desktopId) {
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
                                notSent: true, details: .obj([("reason", .string(Self.grantReason[method] ?? "owner_only"))]))
        }
        guard g.capabilities.contains(capability) else {
            return RuntimeError("grant_missing", "\(method) needs the \(capability) capability, which \(c.clientId) was not granted",
                                phase: .request, notSent: true,
                                details: .obj([("reason", .string(Self.grantReason[method] ?? "capability")), ("capability", .string(capability))]))
        }
        return nil
    }

    /// Every Desktop a request names: its context's and params' desktopId and
    /// the Desktops of the caller's sessions it names.
    func targetDesktops(_ request: RuntimeRequest, _ c: ConnectionState) -> Set<String> {
        var out: Set<String> = []
        for sid in [request.context.sessionId, request.params["sessionId"]?.stringValue].compactMap({ $0 }) {
            if let d = sessions.find(sid, caller: c.clientId)?.desktopId { out.insert(d) }
        }
        for d in [request.context.desktopId, request.params["desktopId"]?.stringValue].compactMap({ $0 }) { out.insert(d) }
        return out
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
        // A paired app launches by bundle id only: the engine prefers a path,
        // which the grant does not name (round-five review M1).
        if request.method == "app.launch", c.role == .paired, p["path"] != nil {
            return RuntimeError("grant_missing", "starting an app by path needs a grant this client cannot hold; name it by bundle id",
                                phase: .request, notSent: true, details: .obj([("reason", .string("launch_requires_grant"))]))
        }
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
            // Names nothing: not the app a pid belongs to, not whether that
            // pid exists (#153 parity, SEC-05); a launch echoes nothing either.
            let launch = request.method == "app.launch"
            return RuntimeError("grant_missing",
                                launch ? "starting this app needs a launch grant for it, which this client does not have"
                                       : "binding this window needs a grant for its app, which this client does not have",
                                phase: .request, notSent: true,
                                details: .obj([("reason", .string(launch ? "launch_requires_grant" : "bind_requires_grant"))]))
        }
        return nil
    }

    /// Right before input goes out: the grant as it is now (a revocation or
    /// expiry while the action waited for the Desktop stops it).
    /// The error on a connection the owner cut (revoked, grant revoked or
    /// narrowed): reconnect with a credential that is still valid.
    static func cutError(_ c: ConnectionState, _ reason: String) -> RuntimeError {
        let code = reason == "client_revoked" ? "client_revoked" : "grant_missing"
        return RuntimeError(code, "the owner withdrew the access of \(c.clientId) on this connection (\(reason)); reconnect",
                            phase: .request, notSent: true, details: .obj([("reason", .string(reason))]))
    }

    /// Withdraw access at once on every open connection of a client: after
    /// this returns, nothing more is sent to it (see ConnectionState.cut).
    func cutConnections(of clientId: String, reason: String) {
        for e in openConnections.all where e.connection.clientId == clientId {
            e.connection.cut(reason)
            hub.audit(connectionId: e.connection.connectionId, clientId: clientId, method: "connection", decision: "cut", reason: reason,
                      runId: e.connection.subscription?.runId)
        }
    }

    /// A read answered after its caller lost access: the error to send
    /// instead of the answer, audited.
    func accessLost(_ request: RuntimeRequest, _ c: ConnectionState) -> RuntimeError? {
        guard c.role == .paired, !Self.openMethods.contains(request.method) else { return nil }
        // A confirmed owner call answers unless the client itself lost access.
        let method = c.elevatedFor == request.requestId ? "runtime.status" : request.method
        let e = c.cutReason.map { Self.cutError(c, $0) } ?? accessError(c, method: method)
        guard let e else { return nil }
        hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: request.method, decision: "withheld",
                  reason: e.details?["reason"]?.stringValue ?? e.code, runId: request.context.runId)
        return e
    }

    /// A paired connection's event stream ends once its access is gone
    /// (revoked, expired, or no longer granted `run`).
    public func subscriptionRevoked(_ c: ConnectionState) -> Bool {
        guard c.role == .paired, c.subscription != nil,
              let e = c.cutReason.map({ Self.cutError(c, $0) }) ?? accessError(c, method: "events.subscribe") else { return false }
        hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "events.subscribe", decision: "denied",
                  reason: e.details?["reason"]?.stringValue ?? e.code, runId: c.subscription?.runId)
        c.subscription = nil
        return true
    }

    func recheckAct(_ c: ConnectionState, desktopId: String, method: String = "act") -> RuntimeError? {
        guard c.role == .paired else { return nil }
        if let reason = c.cutReason { return Self.cutError(c, reason) }
        if let e = accessError(c, method: method) { return e }
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
            // The caller is who the connection is; what it claimed is only noted.
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "runtime.handshake", decision: "denied",
                      reason: "\(reason) (claimed \(String(claimed.prefix(80))))")
            return RuntimeError(code, message, phase: .handshake, notSent: true, details: .obj([("reason", .string(reason))]))
        }
        if claimed.hasPrefix("local:") {
            // The owner is the Agent Desktop window, never a socket client.
            guard let owner = testSocketOwnerToken, claimed == "local:\(c.peerUID)",
                  HubStore.same(HubStore.hash(token), HubStore.hash(owner)) else {
                return refuse("permission_denied", "no socket client is the owner of AgentDesktop; pair this app (hub.pairing.start)",
                              "owner_not_on_socket")
            }
            c.clientId = claimed
            c.role = .owner
            return nil
        }
        switch hub.authenticate(clientId: claimed, token: token) {
        case let .client(client):
            // S2: a client that paired as verified code must be that code now,
            // as the kernel reports it for this socket; a copied token alone
            // does not do.
            if let requirement = CodeIdentity(json: client.codeIdentity).requirement {
                guard let token = c.peerAuditToken, codeVerifier.satisfies(auditToken: token, requirement: requirement) else {
                    return refuse("permission_denied", "this program is not the one \(client.clientId) paired as", "code_identity_mismatch")
                }
            }
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
        .obj([("clientId", .string(c.clientId)), ("role", .string(c.role.rawValue)), ("connectionId", .string(c.connectionId)),
              ("codeIdentityLevel", .string(c.codeIdentity.level.rawValue))])
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
