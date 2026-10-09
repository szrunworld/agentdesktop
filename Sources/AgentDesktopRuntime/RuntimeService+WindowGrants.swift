import AgentDesktopProtocol
import Foundation

/// Window grants (docs/security/window-grants.md, Kevin's ruling B of
/// 2026-10-09): a paired app reaches a window it did not launch itself on
/// that Desktop only through a grant for that one window — window ID, the
/// launch of its process, its app, the Desktop and the client — that the
/// user confirmed. Observe, act and persist are separate. Every use checks
/// the grant as it is now; a grant whose window closed, whose process or app
/// changed, or whose app or Desktop left the client's grant ends for good.
/// The owner (the user, in this process) needs none.
extension RuntimeService {
    /// How long a screenshot taken without the persist permission is kept.
    static let transientArtifactSeconds: TimeInterval = 120

    /// The client capability each window permission needs as well.
    static func capability(forWindowPermission p: String) -> String { p == "act" ? "act" : "observe" }

    /// Whether `c` launched that process on this Desktop: its own instance,
    /// reached through the app-level grant (A4), not one of the user's windows.
    func launchedHere(_ c: ConnectionState, _ d: DesktopRecord, _ process: ProcessIdentity) -> Bool {
        d.launchedBy[process] == c.clientId
    }

    // MARK: Checking

    /// Why a grant no longer holds, if it does not: the window as it is now,
    /// the process launch, the app, the client's grant. Nothing is ended here.
    func windowGrantFailure(_ g: HubStore.WindowGrant) -> (reason: String, sticky: Bool)? {
        if g.state != "active" { return (g.endedReason ?? g.state, false) }
        if g.expiresAt <= nowString { return ("window_grant_expired", false) }
        // The same launch of the same process.
        guard backend.processIdentity(g.process.pid) == g.process else { return ("process_changed", true) }
        // The same process with no window of that id: closed, for good. An
        // empty list counts too (Codex on 7629d6b): the granted window may
        // have been the process's only one, and an unreadable list ending a
        // grant only costs asking the user again (fail closed).
        let windows = backend.windows(pid: g.process.pid, bundleId: nil, includeOffscreen: true)
        guard let w = windows.first(where: { $0.windowId == g.windowId }) else { return ("window_closed", true) }
        guard w.bundleId == g.bundleId else { return ("app_changed", true) }
        // The client's own grant still covers the app and the Desktop.
        guard let cg = hub.grant(g.clientId), cg.state == "active", hub.client(g.clientId)?.state == "active" else {
            return ("grant_revoked", true)
        }
        guard cg.apps.contains(g.bundleId) else { return ("app_removed", true) }
        guard desktopAllowed(ConnectionState.paired(g.clientId), g.desktopId) else { return ("desktop_removed", true) }
        return nil
    }

    /// End a grant for good, delete what was kept only under it, and audit.
    func endWindowGrant(_ g: HubStore.WindowGrant, state: String = "ended", reason: String, by c: ConnectionState? = nil) {
        guard (try? hub.endWindowGrant(g.windowGrantId, state: state, reason: reason)) == true else { return }
        artifacts.removeTransients(windowGrantId: g.windowGrantId)
        hub.audit(connectionId: c?.connectionId ?? "runtime", clientId: g.clientId, method: "hub.windows", decision: state == "revoked" ? "revoked" : "ended",
                  reason: "\(g.windowGrantId) \(reason)")
    }

    /// Several grants ended at once (client removed, Desktop destroyed, …):
    /// their transient screenshots go and each is audited.
    func endedWindowGrants(_ ids: [String], state: String, reason: String) {
        for id in ids {
            artifacts.removeTransients(windowGrantId: id)
            hub.audit(connectionId: "runtime", clientId: hub.windowGrant(id)?.clientId ?? "?", method: "hub.windows",
                      decision: state == "revoked" ? "revoked" : "ended", reason: "\(id) \(reason)")
        }
    }

    /// The Desktop is gone: so is every window grant on it.
    func endWindowGrants(onDesktop desktopId: String) {
        let ids = (try? hub.endWindowGrants(desktopId: desktopId, reason: "desktop_destroyed")) ?? []
        endedWindowGrants(ids, state: "ended", reason: "desktop_destroyed")
    }

    /// The caller's live grants for this window of this launch on this
    /// Desktop. Grants found no longer holding are ended here (sticky).
    func liveWindowGrants(_ c: ConnectionState, desktopId: String, windowId: UInt32, process: ProcessIdentity) -> [HubStore.WindowGrant] {
        hub.windowGrants(clientId: c.clientId).filter { g in
            guard g.desktopId == desktopId, g.windowId == windowId, g.process == process else { return false }
            if let f = windowGrantFailure(g) {
                if f.sticky { endWindowGrant(g, reason: f.reason) }
                return false
            }
            return true
        }
    }

    /// The permissions a grant gives now: what the user confirmed, as far as
    /// the client's grant still backs it with a capability.
    func effectivePermissions(_ g: HubStore.WindowGrant) -> Set<String> {
        guard let cg = hub.grant(g.clientId), cg.state == "active" else { return [] }
        return Set(g.permissions.filter { cg.capabilities.contains(Self.capability(forWindowPermission: $0)) })
    }

    /// For one use of the window bound on `d`: nil when the caller needs no
    /// window grant (the owner, a window of a launch it made here); else
    /// the grant that allows `permission`, or the refusal. Audited.
    func windowUse(_ c: ConnectionState, _ d: DesktopRecord, _ b: TargetBinding, _ permission: String, method: String,
                   audit: Bool = true) throws -> HubStore.WindowGrant? {
        guard c.role == .paired, !launchedHere(c, d, b.process) else { return nil }
        func refuse(_ reason: String, _ message: String) -> RuntimeError {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "window.\(permission)", decision: "denied", reason: reason)
            return RuntimeError("grant_missing", message, phase: .handler, notSent: true, details: .obj([("reason", .string(reason))]))
        }
        let all = hub.windowGrants(clientId: c.clientId, includeEnded: true).filter {
            $0.desktopId == d.desktopId && $0.windowId == b.windowId && $0.process == b.process
        }
        let live = liveWindowGrants(c, desktopId: d.desktopId, windowId: b.windowId, process: b.process)
        guard !live.isEmpty else {
            // Say why when there was one (it ended, expired); name nothing of the window.
            let why = all.compactMap { windowGrantFailure($0)?.reason }.first
            throw refuse(why == nil ? "window_grant_missing" : "window_grant_ended",
                         why == nil ? "the bound window is not one this client was granted; ask the user (hub.windows.request)"
                                    : "the grant for the bound window no longer holds (\(why!)); ask the user again")
        }
        guard let g = live.first(where: { effectivePermissions($0).contains(permission) }) else {
            throw refuse("window_\(permission)_not_granted", "the window grant does not allow \(permission) on the bound window")
        }
        if audit {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "window.\(permission)", decision: "used",
                      reason: "\(g.windowGrantId) \(method)")
        }
        return g
    }

    /// Whether the caller may see which window is bound on `d` (desktop.show,
    /// desktop.list): the owner, its own launch, or any live grant for it.
    func mayKnowBinding(_ c: ConnectionState, _ d: DesktopRecord, _ b: TargetBinding) -> Bool {
        guard c.role == .paired else { return true }
        if launchedHere(c, d, b.process) { return true }
        return !liveWindowGrants(c, desktopId: d.desktopId, windowId: b.windowId, process: b.process).isEmpty
    }

    /// window.list for a paired app: only windows it holds a live grant with
    /// observe for (a listing shows the title and frame; Codex on 7629d6b)
    /// and windows of launches it made on a Desktop.
    func visibleToPaired(_ c: ConnectionState, _ w: WindowSummary) -> Bool {
        guard appAllowed(c, bundleId: w.bundleId) else { return false }
        if desktops.list().contains(where: { launchedHere(c, $0, w.process) }) { return true }
        return hub.windowGrants(clientId: c.clientId).contains { g in
            guard g.windowId == w.windowId, g.process == w.process else { return false }
            if let f = windowGrantFailure(g) {
                if f.sticky { endWindowGrant(g, reason: f.reason) }
                return false
            }
            return effectivePermissions(g).contains("observe")
        }
    }

    /// The Desktop as this caller may see it: a binding it may not know of
    /// shows as none.
    func desktopJSON(_ d: DesktopRecord, for c: ConnectionState) -> JSONValue {
        d.lock.withLock {
            var json = d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
            if let b = d.binding, !mayKnowBinding(c, d, b) { json = json.setting("binding", .null) }
            return json
        }
    }

    /// A paired app's screenshot of a whole Desktop (no bound window, only
    /// where the screen-capture seal is off): only when every window on that
    /// screen is of a launch it made there.
    func wholeScreenRefusal(_ c: ConnectionState, _ d: DesktopRecord) -> RuntimeError? {
        guard c.role == .paired, let platform else { return nil }
        let others = platform.stack(on: d.screen).filter { !launchedHere(c, d, backend.processIdentity($0.pid)) }
        guard others.isEmpty else {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "window.observe", decision: "denied",
                      reason: "screen_capture_requires_grant")
            return RuntimeError("invalid_target",
                                "desktop \(d.desktopId) shows windows this client was not granted; bind a granted window to observe it",
                                phase: .handler, notSent: true, details: .obj([("reason", .string("screen_capture_requires_grant"))]))
        }
        return nil
    }

    /// Whether an artifact taken under a window grant is out of the caller's
    /// reach now. Kept (persist) ones stay readable after the window is gone,
    /// but not once the user revoked the grant. Transient ones only until
    /// they expire and only while the grant is live and allows observe.
    func windowArtifactRefusal(_ info: ArtifactStore.Info, _ c: ConnectionState) -> Bool {
        if info.expiresAt == nil {
            guard c.role == .paired, let id = info.windowGrantId else { return false }
            return hub.windowGrant(id)?.state != "ended" && hub.windowGrant(id)?.state != "active"
        }
        let expiresAt = info.expiresAt!
        if expiresAt <= nowString { artifacts.remove(info.artifactId); return true }
        guard let id = info.windowGrantId else { return false }
        guard let g = hub.windowGrant(id) else { artifacts.remove(info.artifactId); return true }
        if let f = windowGrantFailure(g) {
            if f.sticky { endWindowGrant(g, reason: f.reason) }
            artifacts.removeTransients(windowGrantId: id)
            return true
        }
        if c.role == .paired, !effectivePermissions(g).contains("observe") { return true }
        return false
    }

    // MARK: hub.windows.*

    /// Ask the user for one window: shown exactly as it will be granted.
    func requestWindowGrant(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard c.role == .paired else {
            return .failure(.invalidArgument("the owner reaches every window; only a paired app asks for a window grant"))
        }
        func refuse(_ reason: String, _ message: String, code: String = "grant_missing") -> Result<JSONValue, RuntimeError> {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.windows.request", decision: "denied", reason: reason)
            return .failure(RuntimeError(code, message, phase: .request, notSent: true, details: .obj([("reason", .string(reason))])))
        }
        let permissions = strings(p["permissions"])
        let bundleId = p["bundleId"]?.stringValue ?? ""
        guard let cg = hub.grant(c.clientId), cg.state == "active" else { return refuse("no_grant", "\(c.clientId) holds no active grant") }
        for perm in permissions where !cg.capabilities.contains(Self.capability(forWindowPermission: perm)) {
            return refuse("capability", "\(perm) on a window needs the \(Self.capability(forWindowPermission: perm)) capability, which \(c.clientId) was not granted")
        }
        let notGrantable = "no window of an app in this client's grant can be granted there"
        guard appAllowed(c, bundleId: bundleId) else { return refuse("window_not_grantable", notGrantable) }
        guard case let .success(d) = desktop(p["desktopId"]) else { return .failure(.notFound("no desktop \(p["desktopId"]?.stringValue ?? "")")) }
        if confirmationGate.coolingDown("window:" + c.clientId, now: now()) {
            return refuse("window_grant_cooldown", "the user just refused this client a window; ask again in a minute", code: "permission_denied")
        }
        // The window: the one named, or the app's frontmost, where this
        // Desktop can bind it (on its display for a physical Desktop).
        let wanted = p["windowId"]?.intValue.flatMap { UInt32(exactly: $0) }
        let candidates = backend.windows(pid: nil, bundleId: bundleId, includeOffscreen: false).filter { w in
            guard w.bundleId == bundleId, w.frame.width >= 2, w.frame.height >= 2, wanted == nil || w.windowId == wanted else { return false }
            if d.kind == .physical { return platform?.window(on: d.screen, pid: w.process.pid, windowId: w.windowId) != nil }
            return true
        }
        guard let w = candidates.first, backend.processIdentity(w.process.pid) == w.process else {
            return refuse("window_not_grantable", notGrantable)
        }
        let requested = Double(p["durationSeconds"]?.intValue ?? Int(Self.defaultGrantDuration))
        let untilClientGrant = (Timestamp.date(cg.expiresAt) ?? now()).timeIntervalSince(now())
        // What the user is shown; the grant then ends at that long after the
        // approval or at the client's own expiry, whichever comes first.
        let seconds = Int(max(1, min(requested, untilClientGrant)))
        let details = JSONValue.obj([
            ("desktop", .obj([("desktopId", .string(d.desktopId)), ("kind", .string(d.kind.rawValue)),
                              ("displayId", .int(Int(d.screen.displayId)))])),
            ("window", .obj([("windowId", .int(Int(w.windowId))), ("process", w.process.json), ("appName", .string(w.appName)),
                             ("bundleId", .string(bundleId)), ("title", w.title.map(JSONValue.string) ?? .null), ("frame", w.frame.json)])),
            ("permissions", .array(permissions.map(JSONValue.string))), ("durationSeconds", .int(seconds)),
        ])
        var confirmation: String?
        let decision = confirm(.windowGrant, by: c, action: "hub.windows.request", details: details,
                               confirmed: { confirmation = $0 })
        if case let .failure(e) = decision {
            if ["user_denied", "user_cancelled", "confirmation_timeout"].contains(e.details?["reason"]?.stringValue ?? "") {
                confirmationGate.coolDown("window:" + c.clientId, until: now().addingTimeInterval(ConfirmationGate.cooldown))
            }
            return .failure(e)
        }
        // Access may have gone, or the window changed, while the user decided.
        if let reason = c.cutReason { return .failure(Self.cutError(c, reason)) }
        if let e = accessError(c, method: "hub.windows.request") { return .failure(e) }
        // Never past the client's grant as it is now, in absolute time (Codex
        // on 7629d6b: an interval taken before the prompt outlived it).
        let afterApproval = Timestamp.string(now().addingTimeInterval(Double(seconds)))
        let clientExpiry = hub.grant(c.clientId)?.expiresAt ?? nowString
        let grant = HubStore.WindowGrant(
            windowGrantId: DesktopRegistry.newId(prefix: "wg"), clientId: c.clientId, desktopId: d.desktopId, windowId: w.windowId,
            process: w.process, bundleId: bundleId, appName: w.appName, permissions: permissions, state: "active", endedReason: nil,
            createdAt: nowString, expiresAt: min(afterApproval, clientExpiry), confirmationId: confirmation)
        if d.state == "destroyed" || desktops.find(d.desktopId) == nil || !desktopAllowed(c, d.desktopId) || !appAllowed(c, bundleId: bundleId)
            || permissions.contains(where: { !(hub.grant(c.clientId)?.capabilities.contains(Self.capability(forWindowPermission: $0)) ?? false) })
            || windowGrantFailure(grant) != nil
            || (d.kind == .physical && platform?.window(on: d.screen, pid: w.process.pid, windowId: w.windowId) == nil) {
            hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.windows.request", decision: "denied", reason: "target_changed")
            return .failure(RuntimeError("conflict", "the window or this client's access changed while the user was asked; ask again",
                                         phase: .handler, notSent: true, details: .obj([("reason", .string("target_changed"))])))
        }
        do { try hub.addWindowGrant(grant) } catch {
            return .failure(RuntimeError("conflict", "this client's access changed while the user was asked; ask again",
                                         phase: .handler, notSent: true, details: .obj([("reason", .string("target_changed"))])))
        }
        hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "hub.windows.request", decision: "granted",
                  reason: "\(grant.windowGrantId) \(permissions.joined(separator: ","))")
        return .success(grant.json)
    }

    func listWindowGrants(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let mine = isOwner(c) ? nil : c.clientId
        // Grants found no longer holding end before they are listed.
        for g in hub.windowGrants(clientId: mine) {
            if let f = windowGrantFailure(g), f.sticky { endWindowGrant(g, reason: f.reason) }
        }
        let list = hub.windowGrants(clientId: mine, includeEnded: p["includeEnded"]?.boolValue ?? false)
        return .success(.obj([("windowGrants", .array(list.map(\.json)))]))
    }

    /// Withdraw one window grant: its transient screenshots go and the
    /// client's connections are cut (as for a narrowed grant).
    func revokeWindowGrant(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["windowGrantId"]?.stringValue ?? ""
        guard let g = hub.windowGrant(id) else { return .failure(.notFound("no window grant \(id)")) }
        guard g.state == "active" else {
            return .failure(RuntimeError("conflict", "window grant \(id) is \(g.state)", phase: .handler, notSent: true,
                                         details: .obj([("state", .string(g.state))])))
        }
        endWindowGrant(g, state: "revoked", reason: "window_grant_revoked", by: c)
        cutConnections(of: g.clientId, reason: "window_grant_revoked")
        return .success((hub.windowGrant(id) ?? g).json)
    }
}
