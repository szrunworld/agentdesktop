import AgentDesktopProtocol
import Foundation

/// hub.displays.* (docs/security/owner-display-attach.md, Kevin's ruling of
/// 2026-10-10): the owner, in the Agent Desktop window, opens one of the
/// user's displays to a paired client. Attaching stays the owner's alone
/// (A4: a paired client gets owner_only); the user confirms every attach in
/// the trusted window with Touch ID or the login password; the display
/// becomes a physical Desktop (one per display) listed in the client's
/// grant. That gives the client no window: each one still needs a window
/// grant (window-grants.md). Detaching takes the Desktop out of the grant,
/// ends the client's window grants on it in the same transaction, and cuts
/// its connections, as any narrowing does.
extension RuntimeService {
    func listDisplays(_ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        guard isOwner(c) else { return .failure(Self.ownerOnly("hub.displays.list")) }
        let items = platform.displays().map { d -> JSONValue in
            let attached = desktops.physical(displayId: d.displayId)
            var m: [(String, JSONValue)] = [("displayId", .int(Int(d.displayId))), ("name", .string(d.name)), ("frame", d.frame.json),
                                            ("hiDPI", .bool(d.hiDPI)), ("builtin", .bool(d.builtin)), ("origin", .string(d.origin.rawValue))]
            if let why = d.originDetail { m.append(("originDetail", .string(why))) }
            m.append(("attachable", .bool(d.origin == .physical && attached == nil)))
            if let attached { m.append(("desktopId", .string(attached.desktopId))) }
            return .obj(m)
        }
        return .success(.obj([("displays", .array(items))]))
    }

    static func ownerOnly(_ method: String) -> RuntimeError {
        RuntimeError("permission_denied", "\(method) is reserved to the owner of this AgentDesktop", phase: .request, notSent: true,
                     details: .obj([("reason", .string("owner_only"))]))
    }

    /// Attach a display for a client: shown to the user exactly as it will
    /// be applied, then the Desktop (new or the one already attached to that
    /// display) is added to the client's grant at the revision the user saw.
    func attachDisplay(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        guard isOwner(c) else { return .failure(Self.ownerOnly("hub.displays.attach")) }
        guard let raw = p["displayId"]?.intValue, let displayId = UInt32(exactly: raw) else {
            return .failure(.invalidArgument("displayId must fit an unsigned 32-bit display ID"))
        }
        let clientId = p["clientId"]?.stringValue ?? ""
        guard let client = hub.client(clientId), client.state == "active", let grant = hub.grant(clientId), grant.state == "active" else {
            return .failure(.notFound("no active client \(clientId)"))
        }
        guard grant.expiresAt > nowString else {
            return .failure(RuntimeError("conflict", "the grant of \(clientId) expired at \(grant.expiresAt); renew it before opening a display to it",
                                         phase: .handler, notSent: true, details: .obj([("reason", .string("grant_expired"))])))
        }
        func refuse(_ reason: String, _ message: String) -> Result<JSONValue, RuntimeError> {
            hub.audit(connectionId: c.connectionId, clientId: clientId, method: "hub.displays.attach", decision: "denied", reason: reason)
            return .failure(RuntimeError("permission_denied", message, phase: .handler, notSent: true, details: .obj([("reason", .string(reason))])))
        }
        // The display as the platform proves it now; only a physical one.
        guard let display = platform.displays().first(where: { $0.displayId == displayId }) else {
            return .failure(.notFound("display \(displayId) is not one of the active displays"))
        }
        guard display.origin == .physical else {
            return refuse("display_not_physical",
                          "display \(displayId) is not proved to be one of your physical displays (\(display.origin.rawValue)\(display.originDetail.map { ": " + $0 } ?? ""))")
        }
        let existing = desktops.physical(displayId: displayId)
        let name: String
        if let given = p["name"]?.stringValue {
            name = given
        } else if let existing {
            name = existing.name
        } else {
            // A default name the owner has not used yet.
            let base = String(display.name.prefix(60))
            name = desktops.names(createdBy: c.clientId).contains(base) ? "\(base) · \(displayId)" : base
        }
        if existing == nil, desktops.names(createdBy: c.clientId).contains(name) {
            return .failure(RuntimeError("conflict", "a desktop named \(name) exists", phase: .handler, notSent: true))
        }
        // What the user is shown is what is applied: this display, this
        // Desktop, this client at this revision of its grant.
        let details = JSONValue.obj([
            ("display", .obj([("displayId", .int(Int(displayId))), ("name", .string(display.name)), ("frame", display.frame.json),
                              ("hiDPI", .bool(display.hiDPI)), ("builtin", .bool(display.builtin)), ("origin", .string(display.origin.rawValue))])),
            ("desktop", .obj([("desktopId", existing.map { .string($0.desktopId) } ?? .null), ("name", .string(name)), ("kind", .string("physical"))])),
            ("client", .obj([("clientId", .string(clientId)), ("agentName", .string(client.agentName)),
                             ("publisher", client.publisher.map(JSONValue.string) ?? .null), ("codeIdentity", client.codeIdentity),
                             ("callerFacts", client.callerFacts), ("grant", grant.json)])),
        ])
        let seenRevision = grant.revision
        if case let .failure(e) = confirm(.displayAttach, by: c, action: "hub.displays.attach", details: details) { return .failure(e) }
        // Checked again after the user decided: the client and its grant,
        // and the display, as they are now.
        guard let g2 = hub.grant(clientId), g2.state == "active", hub.client(clientId)?.state == "active", g2.revision == seenRevision else {
            return .failure(RuntimeError("conflict", "\(clientId) changed while the user was asked; ask again", phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("target_changed"))])))
        }
        // Expired while the user decided (Codex on a6a9088): nothing is
        // attached to a grant that no longer works.
        guard g2.expiresAt > nowString else {
            return .failure(RuntimeError("conflict", "the grant of \(clientId) expired while the user was asked; renew it first", phase: .handler,
                                         notSent: true, details: .obj([("reason", .string("grant_expired"))])))
        }
        guard platform.displays().first(where: { $0.displayId == displayId })?.origin == .physical else {
            return .failure(RuntimeError("conflict", "display \(displayId) changed while the user was asked; ask again", phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("display_changed"))])))
        }
        createLock.lock()
        defer { createLock.unlock() }
        let d: DesktopRecord
        let created: Bool
        if let attached = desktops.physical(displayId: displayId), attached.state != "destroyed" {
            d = attached
            created = false
        } else {
            do {
                // Nothing is created: the handle only names the display.
                let screen = try platform.attachDisplay(displayId)
                d = desktops.add(desktopId: DesktopRegistry.newId(prefix: "d"), name: name, screen: screen, createdAt: nowString,
                                 kind: .physical, createdBy: c.clientId)
                created = true
            } catch let e as PlatformError {
                return .failure(e.runtimeError)
            } catch {
                return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
            }
        }
        var g = g2
        if !g.desktops.contains(d.desktopId) { g.desktops.append(d.desktopId) }
        let saved: HubStore.Grant
        do {
            (saved, _) = try hub.setGrant(g, expectedRevision: seenRevision, endingWindowGrants: nil)
        } catch is RuntimeStoreError {
            if created { desktops.remove(d.desktopId) }
            return .failure(RuntimeError("conflict", "\(clientId) changed while the user was asked; ask again", phase: .handler, notSent: true,
                                         details: .obj([("reason", .string("target_changed"))])))
        } catch {
            if created { desktops.remove(d.desktopId) }
            return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable; nothing was attached", phase: .handler, notSent: true))
        }
        hub.audit(connectionId: c.connectionId, clientId: clientId, method: "hub.displays.attach", decision: "granted",
                  reason: "\(d.desktopId) display \(displayId) revision \(saved.revision)")
        return .success(.obj([("desktop", desktopJSON(d)), ("grant", saved.json), ("created", .bool(created))]))
    }

    /// Take a physical Desktop back from one client, or from every client
    /// and destroy its record. Each client's window grants on it end in the
    /// same transaction as its grant changes; its connections are cut and
    /// its Runs and sessions on that Desktop stop, as for any narrowing.
    func detachDisplay(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard platform != nil else { return .failure(.capabilityMissing("no desktop platform")) }
        guard isOwner(c) else { return .failure(Self.ownerOnly("hub.displays.detach")) }
        let id = p["desktopId"]?.stringValue ?? ""
        guard let d = desktops.find(id), d.state != "destroyed" else { return .failure(.notFound("no desktop \(id)")) }
        guard d.kind == .physical else {
            return .failure(.invalidArgument("desktop \(id) is virtual; change the client's grant (hub.grants.set) or destroy it (desktop.destroy)"))
        }
        let only = p["clientId"]?.stringValue
        if let only, hub.client(only) == nil { return .failure(.notFound("no client \(only)")) }
        let touched: [HubStore.Grant]
        switch takeDesktopFromGrants(id, only: only, by: c) {
        case let .failure(e): return .failure(e)
        case let .success(g): touched = g
        }
        var destroyed = false
        if only == nil {
            // The record goes; the display and every window on it are the
            // user's and are not touched. Whatever still held the Desktop
            // (the owner's own Run or session) is stopped: the owner asked.
            let dropped = withDesktop(.string(id)) { d in
                if let holder = execution.holder(of: id) { _ = execution.stop(runId: holder, reason: "display_detached", endAs: .cancelled) }
                sessions.closeAll(desktopId: id, at: nowString)
                d.state = "destroyed"
                d.generation += 1
                d.binding = nil
                desktops.remove(id)
                observations.forget(desktopId: id)
                endWindowGrants(onDesktop: id)
                return .bool(true)
            }
            if case let .failure(e) = dropped { return .failure(e) }
            destroyed = true
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.displays.detach", decision: "ended", reason: "\(id) display_detached")
        }
        return .success(.obj([("desktopId", .string(id)), ("destroyed", .bool(destroyed)), ("grants", .array(touched.map(\.json)))]))
    }

    /// Remove a Desktop from the grants of one client (`only`) or of every
    /// client: each one's window grants on it end in the same transaction,
    /// its connections are cut, its Runs and sessions there stop. Shared by
    /// hub.displays.detach and the owner's desktop.destroy of a physical
    /// Desktop (Codex on a6a9088: no grant keeps a dropped Desktop's id).
    /// With `endingWindowGrants` false the window grants were already ended
    /// by the caller (desktop.destroy, reason desktop_destroyed) and keep
    /// that reason.
    func takeDesktopFromGrants(_ id: String, only: String?, by c: ConnectionState, endingWindowGrants: Bool = true)
        -> Result<[HubStore.Grant], RuntimeError> {
        var touched: [HubStore.Grant] = []
        for client in hub.clients() where only == nil || client.clientId == only {
            guard var g = hub.grant(client.clientId), g.desktops.contains(id) else { continue }
            g.desktops.removeAll { $0 == id }
            let saved: HubStore.Grant
            let ended: [(id: String, reason: String)]
            do {
                (saved, ended) = try hub.setGrant(g, endingWindowGrants: endingWindowGrants ? { w in w.desktopId == id ? "desktop_removed" : nil } : nil)
            } catch {
                return .failure(RuntimeError("audit_unavailable", "the grant store is unavailable; \(client.clientId) still holds desktop \(id)",
                                             phase: .handler, notSent: true))
            }
            for e in ended { endedWindowGrants([e.id], state: hub.windowGrant(e.id)?.state ?? "ended", reason: e.reason) }
            cutConnections(of: client.clientId, reason: "grant_narrowed")
            for r in activeRuns(of: client.clientId) where r.desktopId == id {
                _ = execution.stop(runId: r.runId, reason: "grant_narrowed", endAs: .cancelled)
            }
            sessions.closeAll(desktopId: id, caller: client.clientId, at: nowString)
            hub.audit(connectionId: c.connectionId, clientId: client.clientId, method: "hub.displays.detach", decision: "revoked",
                      reason: "\(id) revision \(saved.revision)")
            touched.append(saved)
        }
        return .success(touched)
    }
}
