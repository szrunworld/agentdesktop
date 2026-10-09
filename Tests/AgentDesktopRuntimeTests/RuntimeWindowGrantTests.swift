import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Window grants (docs/security/window-grants.md, Kevin's ruling B of
// 2026-10-09): an app grant is not a grant for the app's windows. A paired
// app reaches a window it did not launch itself on that Desktop only through
// a grant for that one window, confirmed by the user; observe, act and
// persist are separate; every use checks the grant as it is now, and a grant
// whose window, process or app changed ends for good. The seals of #145
// stay as they are: these tests turn them off only to reach the paths
// behind them.

private let wechat = "com.tencent.xinWeChat"

/// The user's display 1 with two WeChat windows (pid 202: 12 in front, 13
/// beside it), a physical Desktop on it made by the owner (test-only: the
/// product never turns physical Desktops on), and an app paired for WeChat
/// with that Desktop in its grant. The trusted window approves unless told
/// otherwise.
private final class Stage {
    let platform = FakePlatform()
    let backend: FixedBackend = {
        var b = FixedBackend()
        b.apps.append(AppSummary(process: ProcessIdentity(pid: 202, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: wechat,
                                 name: "微信", active: true, hidden: false))
        return b
    }()
    let s: RuntimeService
    let owner: ConnectionState
    let confirmer = FakeConfirmer()
    let desk: String
    var app: ConnectionState
    let appId: String
    let token: String

    init(capabilities: [String] = ["observe", "act", "desktop.manage", "run"], apps: [String] = [wechat]) throws {
        platform.windows[202] = [
            PlatformWindow(windowId: 12, pid: 202, appName: "微信", title: "文件传输助手", frame: Rect(x: 100, y: 100, width: 400, height: 300)),
            PlatformWindow(windowId: 13, pid: 202, appName: "微信", title: "最小化的窗口", frame: Rect(x: 700, y: 100, width: 300, height: 300)),
        ]
        platform.onScreen[12] = "physical-1"
        platform.onScreen[13] = "physical-1"
        s = platformService(platform, backend: backend)
        s.physicalDesktopsEnabled = true
        s.confirmer = confirmer
        owner = handshaken(s)
        desk = try #require(data(call(s, owner, "desktop.create", params: #"{"name":"main","physical":{}}"#))?["desktopId"]?.stringValue)
        (app, appId, token) = try pairedClient(s, capabilities: capabilities, desktops: [desk], apps: apps, name: "wechat-agent")
    }

    func request(_ permissions: [String], windowId: Int? = nil, bundleId: String = wechat, desktop: String? = nil,
                 on c: ConnectionState? = nil) -> RuntimeResponse {
        let w = windowId.map { #","windowId":\#($0)"# } ?? ""
        let perms = permissions.map { "\"\($0)\"" }.joined(separator: ",")
        return call(s, c ?? app, "hub.windows.request",
                    params: #"{"desktopId":"\#(desktop ?? desk)","bundleId":"\#(bundleId)"\#(w),"permissions":[\#(perms)]}"#)
    }

    func bind(_ windowId: Int, on c: ConnectionState? = nil) -> RuntimeResponse {
        call(s, c ?? app, "window.bind", params: #"{"desktopId":"\#(desk)","pid":202,"windowId":\#(windowId)}"#)
    }

    func session(on c: ConnectionState? = nil) throws -> String {
        try #require(data(call(s, c ?? app, "session.open", params: #"{"desktopId":"\#(desk)"}"#))?["sessionId"]?.stringValue)
    }

    func observe(_ sid: String, on c: ConnectionState? = nil) -> RuntimeResponse {
        call(s, c ?? app, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    }

    /// A new connection of the app with its credential.
    func reconnect() -> ConnectionState {
        let (c, _) = socketConnection(s, clientId: appId, token: token)
        return c
    }

    func reason(_ r: RuntimeResponse) -> String? { errorDetails(r)?["reason"]?.stringValue }
}

// MARK: Asking the user

@Test func aWindowGrantIsAskedForOneWindowAndConfirmedByTheUser() throws {
    let st = try Stage()
    let r = st.request(["observe", "act"])
    let g = try #require(data(r), "\(r.json.encoded())")
    #expect(contract.validate(g, "HubWindowGrant").isEmpty, "\(g.encoded())")
    #expect(g["window"]?["windowId"]?.intValue == 12, "the app's frontmost window on that display")
    #expect(g["window"]?["process"]?["startedAt"]?.stringValue != nil, "the launch, not the pid alone")
    #expect(g["permissions"]?.arrayValue?.compactMap(\.stringValue) == ["observe", "act"])
    // The user saw exactly that window, its Desktop and the permissions.
    let asked = try #require(st.confirmer.requests.last)
    #expect(asked.kind == .windowGrant)
    #expect(asked.details["window"]?["windowId"]?.intValue == 12)
    #expect(asked.details["window"]?["title"]?.stringValue?.hasPrefix("文件传输助手") == true)
    #expect(asked.details["desktop"]?["kind"]?.stringValue == "physical")
    #expect(asked.details["permissions"]?.arrayValue?.count == 2)
    #expect(g["confirmationId"]?.stringValue == asked.confirmationId)
    // It never outlives the app's own grant.
    let clientGrant = try #require(st.s.hub.grant(st.appId))
    #expect((g["expiresAt"]?.stringValue ?? "") <= clientGrant.expiresAt)
    // Named explicitly: the other window, asked separately.
    #expect(data(st.request(["observe"], windowId: 13)) == nil, "13 is off screen: not grantable")
    #expect(st.reason(st.request(["observe"], windowId: 13)) == "window_not_grantable")
    let audit = st.s.hub.auditEvents()
    #expect(audit.contains { $0["method"]?.stringValue == "hub.windows.request" && $0["decision"]?.stringValue == "granted" })
    #expect(!audit.contains { ($0["reason"]?.stringValue ?? "").contains("文件传输助手") }, "no window content in the audit")
}

@Test func whatTheUserDoesNotApproveGrantsNothing() throws {
    for (decision, reason) in [(ConfirmationDecision.denied, "user_denied"), (.cancelled, "user_cancelled"),
                               (.timedOut, "confirmation_timeout"), (.unavailable("no Touch ID"), "no_trusted_ui")] {
        let st = try Stage()
        st.confirmer.decide = { _ in decision }
        let r = st.request(["observe"])
        #expect(code(r) == "permission_denied" && st.reason(r) == reason, "\(reason)")
        #expect(st.s.hub.windowGrants(clientId: st.appId, includeEnded: true).isEmpty)
        // A refusal by the user holds the app back for a minute; no new prompt.
        if reason != "no_trusted_ui" {
            let asked = st.confirmer.requests.count
            #expect(st.reason(st.request(["observe"])) == "window_grant_cooldown")
            #expect(st.confirmer.requests.count == asked)
        }
    }
    // An approval of something else is no approval.
    let st = try Stage()
    st.confirmer.decide = { _ in .approved(digest: "0000") }
    #expect(st.reason(st.request(["observe"])) == "confirmation_mismatch")
    #expect(st.s.hub.windowGrants(clientId: st.appId).isEmpty)
    // No trusted window at all: refused.
    st.s.confirmer = nil
    #expect(st.reason(st.request(["observe"])) == "no_trusted_ui")
}

@Test func onlyAWindowOfAGrantedAppOnAGrantedDesktopWithTheCapabilitiesCanBeAskedFor() throws {
    let st = try Stage(capabilities: ["observe"])
    // An app the grant does not name: refused without asking, naming nothing.
    #expect(st.reason(st.request(["observe"], bundleId: "com.apple.calculator")) == "window_not_grantable")
    // act needs the act capability; persist the observe capability.
    #expect(st.reason(st.request(["act"])) == "capability")
    // A Desktop outside the grant does not exist for it.
    let other = try #require(data(call(st.s, st.owner, "desktop.create"))?["desktopId"]?.stringValue)
    #expect(code(st.request(["observe"], desktop: other)) == "not_found")
    #expect(st.confirmer.requests.isEmpty, "none of these reached the user")
    // Unpaired: nothing.
    let (anon, _) = socketConnection(st.s)
    #expect(code(st.request(["observe"], on: anon)) == "pairing_required")
    // The owner needs none.
    #expect(code(st.request(["observe"], on: st.owner)) == "invalid_argument")
}

@Test func aWindowThatChangesWhileTheUserDecidesIsNotGranted() throws {
    let st = try Stage()
    st.confirmer.decide = { [backend = st.backend] r in
        backend.opened.lock.withLock { _ = backend.opened.closed.insert(12) }
        return .approved(digest: r.digest)
    }
    let r = st.request(["observe"])
    #expect(code(r) == "conflict" && st.reason(r) == "target_changed")
    #expect(st.s.hub.windowGrants(clientId: st.appId, includeEnded: true).isEmpty)
    // Moved off the physical Desktop's display while the user decided: not granted either.
    let moved = try Stage()
    moved.confirmer.decide = { [platform = moved.platform] r in
        platform.lock.withLock { platform.onScreen[12] = nil }
        return .approved(digest: r.digest)
    }
    #expect(moved.reason(moved.request(["observe"], windowId: 12)) == "target_changed")
}

// MARK: One window, not the app

@Test func aGrantForOneWindowGivesNothingOnAnotherWindowOfTheSameApp() throws {
    let st = try Stage()
    _ = try #require(data(st.request(["observe", "act"])))
    // Window 12 binds; 13 (same app, same process) does not, nor does a bind without windowId.
    #expect(data(st.bind(12)) != nil)
    #expect(st.reason(st.bind(13)) == "bind_requires_grant")
    #expect(st.reason(call(st.s, st.app, "window.bind", params: #"{"desktopId":"\#(st.desk)","pid":202}"#)) == "bind_requires_grant")
    // Discovery shows the granted window only, however it is asked.
    for p in [#"{"includeOffscreen":true}"#, #"{"pid":202,"includeOffscreen":true}"#, #"{"bundleId":"\#(wechat)","includeOffscreen":true}"#] {
        let ids = data(call(st.s, st.app, "window.list", params: p))?["windows"]?.arrayValue?.compactMap { $0["windowId"]?.intValue }
        #expect(ids == [12], "\(p)")
    }
    // The owner binds 13 on the same Desktop: the app may neither see which
    // window it is nor observe or act on it.
    let sid = try st.session()
    #expect(data(st.bind(13, on: st.owner)) != nil)
    #expect(data(call(st.s, st.app, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"] == .null)
    #expect(data(call(st.s, st.owner, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"]?["windowId"]?.intValue == 13)
    let o = st.observe(sid)
    #expect(code(o) == "grant_missing" && st.reason(o) == "window_grant_missing")
    #expect(!st.platform.calls.contains { $0.contains("elements 202/13") }, "nothing of 13 was read for the app")
    let w = call(st.s, st.app, "wait", params: #"{"condition":{"kind":"elementPresent","label":"x"},"timeoutMs":300}"#,
                 context: #"{"sessionId":"\#(sid)"}"#)
    #expect(st.reason(w) == "window_grant_missing")
    #expect(!st.platform.calls.contains { $0.contains("elements 202/13") }, "nor by its wait")
}

// MARK: Observe, act and persist are separate

/// A paired app on its own virtual Desktop with the user's Calculator window
/// (pid 101, window 11) bound under a window grant of these permissions.
private func calculatorScene(_ permissions: [String]) throws -> (Scene, owner: ConnectionState, grant: HubStore.WindowGrant, token: String) {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (c, id, token) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage", "run"], desktops: ["created"],
                                      apps: ["com.apple.calculator"], name: "agent")
    let d = try created(s, c)
    let g = try grantWindow(s, clientId: id, desktopId: d, permissions: permissions)
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)) != nil)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    return (Scene(platform: platform, s: s, c: c, desktop: d, session: sid, snapshot: ""), owner, g, token)
}

@Test func observeWithoutActSendsNothing() throws {
    let (sc, _, _, _) = try calculatorScene(["observe"])
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    let r = act(sc, clickContinue, snapshot: snap)
    #expect(code(r) == "grant_missing" && errorDetails(r)?["reason"]?.stringValue == "window_act_not_granted")
    #expect(sc.platform.performed.isEmpty)
}

@Test func actWithoutObserveSeesNothing() throws {
    let (sc, owner, _, _) = try calculatorScene(["act"])
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(errorDetails(o)?["reason"]?.stringValue == "window_observe_not_granted")
    #expect(!sc.platform.calls.contains { $0.hasPrefix("screenshot") || $0.hasPrefix("elements") }, "nothing was captured for it")
    // Nor listed: a listing shows the title and frame (Codex on 7629d6b).
    #expect(data(call(sc.s, sc.c, "window.list", params: #"{"includeOffscreen":true}"#))?["windows"]?.arrayValue?.isEmpty == true)
    // It may still send input to the window it was granted (against a
    // snapshot the owner took).
    let snap = try #require(data(call(sc.s, owner, "observe", context: #"{"desktopId":"\#(sc.desktop)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: snap)) != nil)
    #expect(sc.platform.performed.count == 1)
}

@Test func withoutPersistAScreenshotIsTransientAndGoesWithTheGrant() throws {
    let (sc, owner, g, _) = try calculatorScene(["observe"])
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(contract.validate(o, "Observation").isEmpty, "\(o.encoded())")
    let image = try #require(o["image"])
    #expect(image["transient"]?.boolValue == true)
    let expires = try #require(image["expiresAt"]?.stringValue.flatMap(Timestamp.date))
    #expect(abs(expires.timeIntervalSinceNow - RuntimeService.transientArtifactSeconds) < 10)
    let id = try #require(image["artifactId"]?.stringValue)
    let file = try #require(sc.s.artifacts.file(of: id))
    let shown = try #require(data(call(sc.s, sc.c, "artifact.show", params: #"{"artifactId":"\#(id)"}"#)))
    #expect(contract.validate(shown, "Artifact").isEmpty && shown["transient"]?.boolValue == true)
    #expect(data(call(sc.s, sc.c, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) != nil)
    // Expired: gone, file and all.
    sc.s.artifacts.purgeTransients(now: Date().addingTimeInterval(RuntimeService.transientArtifactSeconds + 1))
    #expect(!FileManager.default.fileExists(atPath: file))
    #expect(code(call(sc.s, sc.c, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) == "not_found")
    // A new one goes when the user revokes the grant.
    let again = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["image"]?["artifactId"]?.stringValue)
    let file2 = try #require(sc.s.artifacts.file(of: again))
    #expect(data(call(sc.s, owner, "hub.windows.revoke", params: #"{"windowGrantId":"\#(g.windowGrantId)"}"#)) != nil)
    #expect(!FileManager.default.fileExists(atPath: file2))
    #expect(sc.s.artifacts.info(again) == nil)
}

@Test func withPersistTheScreenshotIsKeptButNotAfterTheUserRevokes() throws {
    let (sc, owner, g, token) = try calculatorScene(["observe", "persist"])
    let image = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["image"])
    #expect(image["transient"] == nil && image["expiresAt"] == nil)
    let id = try #require(image["artifactId"]?.stringValue)
    sc.s.artifacts.purgeTransients(now: Date().addingTimeInterval(3600))
    #expect(data(call(sc.s, sc.c, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) != nil, "kept")
    #expect(sc.s.hub.auditEvents().contains { $0["method"]?.stringValue == "window.persist" && $0["decision"]?.stringValue == "used" })
    // The user takes the grant back: the app cannot read what it kept under it.
    #expect(data(call(sc.s, owner, "hub.windows.revoke", params: #"{"windowGrantId":"\#(g.windowGrantId)"}"#)) != nil)
    let (back, _) = socketConnection(sc.s, clientId: sc.c.clientId, token: token)
    #expect(back.role == .paired)
    #expect(code(call(sc.s, back, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) == "not_found")
    // The owner (the user) still can.
    #expect(data(call(sc.s, owner, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) != nil)
}

@Test func aWindowTheAppLaunchedItselfNeedsNoWindowGrant() throws {
    let platform = FakePlatform()
    var backend = FixedBackend()
    backend.apps.append(AppSummary(process: ProcessIdentity(pid: 303, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.Notes",
                                   name: "Notes", active: false, hidden: false))
    backend.opened.windows = [WindowSummary(windowId: 31, process: ProcessIdentity(pid: 303, startedAt: "2026-10-08T01:00:00.000Z"),
                                            appName: "Notes", bundleId: "com.apple.Notes", title: "备忘录",
                                            frame: Rect(x: 2010, y: 10, width: 500, height: 400), onScreen: true)]
    let s = platformService(platform, backend: backend)
    let (c, _, _) = try pairedClient(s, capabilities: ["observe", "act", "desktop.manage"], desktops: ["created"],
                                     apps: ["com.apple.Notes"], name: "notes-agent")
    let d = try created(s, c)
    #expect(data(call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)) != nil)
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":303,"windowId":31}"#)) != nil)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let observed = call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    let image = data(observed)?["image"]
    #expect(image?["artifactId"] != nil && image?["transient"] == nil, "its own launch: kept as before: \(observed.json.encoded())")
    // And it lists it: a window of its own launch.
    #expect(data(call(s, c, "window.list"))?["windows"]?.arrayValue?.compactMap { $0["windowId"]?.intValue } == [31])
    #expect(s.hub.windowGrants(clientId: c.clientId).isEmpty)
}

// MARK: Lifecycle

@Test func aClosedWindowEndsItsGrantForGoodEvenIfTheIdComesBack() throws {
    let st = try Stage()
    let g = try #require(data(st.request(["observe"])))
    #expect(data(st.bind(12)) != nil)
    let sid = try st.session()
    #expect(data(st.observe(sid)) != nil)
    // The user closes the window.
    st.backend.opened.lock.withLock { _ = st.backend.opened.closed.insert(12) }
    let o = st.observe(sid)
    #expect(code(o) == "grant_missing" && st.reason(o) == "window_grant_ended")
    let ended = try #require(st.s.hub.windowGrant(g["windowGrantId"]?.stringValue ?? ""))
    #expect(ended.state == "ended" && ended.endedReason == "window_closed")
    // A window with the same id in the same process later inherits nothing.
    st.backend.opened.lock.withLock { _ = st.backend.opened.closed.remove(12) }
    #expect(st.reason(st.observe(sid)) == "window_grant_ended")
    #expect(st.s.hub.windowGrant(ended.windowGrantId)?.state == "ended")
    #expect(data(call(st.s, st.app, "window.list"))?["windows"]?.arrayValue?.isEmpty == true)
}

@Test func aRestartedProcessEndsTheGrantOfItsOldWindow() throws {
    let st = try Stage()
    let g = try #require(data(st.request(["observe", "act"])))
    #expect(data(st.bind(12)) != nil)
    let sid = try st.session()
    // WeChat restarts under the same pid; its new window 12 is another window.
    st.backend.opened.lock.withLock { _ = st.backend.opened.restarted.insert(202) }
    let o = st.observe(sid)
    #expect(code(o) != nil)
    #expect(st.s.hub.windowGrant(g["windowGrantId"]?.stringValue ?? "")?.endedReason == "process_changed")
    #expect(st.reason(st.bind(12)) == "bind_requires_grant")
}

@Test func revokingOrNarrowingEndsWindowAccessAtOnce() throws {
    // The user revokes the window grant: the app's connection is cut and a
    // new one finds nothing.
    do {
        let st = try Stage()
        let g = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
        #expect(data(st.bind(12)) != nil)
        let sid = try st.session()
        #expect(data(call(st.s, st.owner, "hub.windows.revoke", params: #"{"windowGrantId":"\#(g)"}"#)) != nil)
        #expect(st.reason(call(st.s, st.app, "desktop.list")) == "window_grant_revoked", "the old connection is cut")
        let back = st.reconnect()
        #expect(st.reason(st.observe(sid, on: back)) == "window_grant_ended")
        #expect(st.s.hub.windowGrant(g)?.state == "revoked")
        #expect(code(call(st.s, st.owner, "hub.windows.revoke", params: #"{"windowGrantId":"\#(g)"}"#)) == "conflict")
    }
    // The app is removed, or its grant revoked: every window grant goes.
    for method in ["hub.clients.revoke", "hub.grants.revoke"] {
        let st = try Stage()
        let g = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
        #expect(data(call(st.s, st.owner, method, params: #"{"clientId":"\#(st.appId)"}"#)) != nil)
        #expect(st.s.hub.windowGrant(g)?.state == "revoked", "\(method)")
    }
    // Its grant narrowed: WeChat or the Desktop left it.
    for (dropApp, expected) in [(true, "app_removed"), (false, "desktop_removed")] {
        let st = try Stage()
        let g = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
        let scope = dropApp ? #""desktops":["\#(st.desk)"],"apps":[]"# : #""desktops":[],"apps":["\#(wechat)"]"#
        let p = #"{"clientId":"\#(st.appId)","capabilities":["observe","act","desktop.manage","run"],\#(scope)}"#
        #expect(data(call(st.s, st.owner, "hub.grants.set", params: p)) != nil)
        let ended = st.s.hub.windowGrant(g)
        #expect(ended?.state == "ended" && ended?.endedReason == expected)
    }
    // A capability taken away takes its window permission with it.
    do {
        let st = try Stage()
        _ = try #require(data(st.request(["observe", "act"])))
        #expect(data(st.bind(12)) != nil)
        let p = #"{"clientId":"\#(st.appId)","capabilities":["act","desktop.manage","run"],"desktops":["\#(st.desk)"],"apps":["\#(wechat)"]}"#
        #expect(data(call(st.s, st.owner, "hub.grants.set", params: p)) != nil)
        let back = st.reconnect()
        let sid = try st.session(on: back)
        #expect(code(st.observe(sid, on: back)) == "grant_missing")
    }
}

@Test func anExpiredWindowGrantOrADestroyedDesktopRefusesAccess() throws {
    let st = try Stage()
    let id = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
    #expect(data(st.bind(12)) != nil)
    let sid = try st.session()
    // Expired.
    var g = try #require(st.s.hub.windowGrant(id))
    g.windowGrantId = "wg_expired"
    g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
    _ = try st.s.hub.endWindowGrant(id, state: "ended", reason: "test")
    try st.s.hub.addWindowGrant(g)
    #expect(st.reason(st.observe(sid)) == "window_grant_ended")
    // Destroyed Desktop.
    let st2 = try Stage()
    let id2 = try #require(data(st2.request(["observe"]))?["windowGrantId"]?.stringValue)
    #expect(data(call(st2.s, st2.owner, "desktop.destroy", params: #"{"desktopId":"\#(st2.desk)"}"#)) != nil)
    #expect(st2.s.hub.windowGrant(id2)?.endedReason == "desktop_destroyed")
}

@Test func anAppGivesUpItsOwnWindowGrantOnlyThroughTheUserAndNeverAnothers() throws {
    let st = try Stage()
    let mine = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
    // Its own: the user confirms (A4 R1), then it is revoked.
    let before = st.confirmer.requests.count
    #expect(data(call(st.s, st.app, "hub.windows.revoke", params: #"{"windowGrantId":"\#(mine)"}"#)) != nil)
    #expect(st.confirmer.requests.count == before + 1)
    #expect(st.confirmer.requests.last?.kind == .adminCall && st.confirmer.requests.last?.details["windowGrant"] != nil)
    #expect(st.s.hub.windowGrant(mine)?.state == "revoked")
    // Another app's: not even a verified client may (Codex on 09b8f7d), and
    // the user is not asked.
    let (other, otherId, _) = try pairedClient(st.s, capabilities: ["observe"], desktops: [st.desk], apps: [wechat], name: "other")
    let theirs = try grantWindow(st.s, clientId: otherId, desktopId: st.desk, windowId: 12, pid: 202, bundleId: wechat, permissions: ["observe"])
    _ = other
    let back = st.reconnect()
    let asked = st.confirmer.requests.count
    let r = call(st.s, back, "hub.windows.revoke", params: #"{"windowGrantId":"\#(theirs.windowGrantId)"}"#)
    #expect(st.reason(r) == "not_own_window_grant")
    let verified = asVerified(st.reconnect())
    #expect(st.reason(call(st.s, verified, "hub.windows.revoke", params: #"{"windowGrantId":"\#(theirs.windowGrantId)"}"#)) == "not_own_window_grant")
    #expect(st.confirmer.requests.count == asked)
    #expect(st.s.hub.windowGrant(theirs.windowGrantId)?.state == "active")
    // An id that does not exist asks nobody.
    #expect(code(call(st.s, back, "hub.windows.revoke", params: #"{"windowGrantId":"wg_nothing"}"#)) == "not_found")
    // It lists its own grants only.
    let list = data(call(st.s, back, "hub.windows.list", params: #"{"includeEnded":true}"#))?["windowGrants"]?.arrayValue ?? []
    #expect(list.allSatisfy { $0["clientId"]?.stringValue == st.appId } && list.count == 1)
    #expect(contract.validate(.obj([("windowGrants", .array(list))]), "HubWindowGrantList").isEmpty)
}

// MARK: Seals stay

@Test func theSealsKeepTheirProductDefaults() throws {
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: FakePlatform())
    #expect(s.physicalDesktopsEnabled == false)
    #expect(s.bindsOnlyLaunchedProcesses == true)
    #expect(s.refusesScreenCaptureWithoutBinding == true)
    // A window grant does not open them: the user's window still cannot be
    // pulled onto a virtual Desktop, and no physical Desktop is made.
    let owner = handshaken(s)
    #expect(code(call(s, owner, "desktop.create", params: #"{"physical":{}}"#)) == "permission_denied")
    let (c, id, _) = try pairedClient(s, capabilities: ["observe", "desktop.manage"], desktops: ["created"],
                                      apps: ["com.apple.calculator"], name: "agent")
    let d = try created(s, c)
    try grantWindow(s, clientId: id, desktopId: d)
    let r = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)
    #expect(code(r) == "permission_denied" && errorDetails(r)?["reason"]?.stringValue == "bind_requires_grant")
}

@Test func aWindowGrantRevokedJustBeforeTheInputGoesOutStopsIt() throws {
    let (sc, owner, g, _) = try calculatorScene(["observe", "act"])
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    // The last probe before dispatch (what is under the click) is where the
    // user's revocation lands: after the first check, before the input.
    final class Flag: @unchecked Sendable { var probed = false }
    let flag = Flag()
    sc.platform.hitAt = { [s = sc.s] _, _ in
        if !flag.probed {
            flag.probed = true
            _ = try? s.hub.endWindowGrant(g.windowGrantId, state: "revoked", reason: "window_grant_revoked")
        }
        return PlatformHit(role: "AXButton", texts: ["继续"], windowId: 11)
    }
    _ = owner
    let r = act(sc, clickContinue, snapshot: snap)
    #expect(code(r) == "grant_missing", "\(r.json.encoded())")
    #expect(flag.probed, "the probe ran between the two checks")
    #expect(sc.platform.performed.isEmpty, "nothing was sent after the revocation")
}

@Test func aGrantWhosePermissionsTheClientNoLongerBacksBindsNothing() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let (c, id, _) = try pairedClient(s, capabilities: ["observe", "desktop.manage"], desktops: ["created"],
                                      apps: ["com.apple.calculator"], name: "agent")
    let d = try created(s, c)
    // Granted act on the window, but the client has no act capability (any more).
    try grantWindow(s, clientId: id, desktopId: d, permissions: ["act"])
    let r = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)
    #expect(errorDetails(r)?["reason"]?.stringValue == "bind_requires_grant")
}

@Test func aWindowGrantRevokedWhileTheWindowIsReadAnswersNothing() async throws {
    try await offPoolConfirm {
        for method in ["observe", "wait"] {
            let (sc, _, g, _) = try calculatorScene(["observe"])
            let gate = DispatchSemaphore(value: 0)
            sc.platform.lock.withLock { sc.platform.axGate = gate }
            final class Out: @unchecked Sendable { var r: RuntimeResponse? }
            let out = Out(), done = DispatchSemaphore(value: 0)
            let params = method == "wait" ? #"{"condition":{"kind":"elementPresent","label":"继续"},"timeoutMs":3000}"# : "{}"
            Thread {
                out.r = call(sc.s, sc.c, method, params: params, context: #"{"sessionId":"\#(sc.session)"}"#)
                done.signal()
            }.start()
            let end = Date().addingTimeInterval(5)
            while sc.platform.lock.withLock({ sc.platform.axRunning }) == 0 && Date() < end { Thread.sleep(forTimeInterval: 0.01) }
            // The user revokes the window while its elements are being read.
            _ = try sc.s.hub.endWindowGrant(g.windowGrantId, state: "revoked", reason: "window_grant_revoked")
            sc.platform.lock.withLock { sc.platform.axGate = nil }
            gate.signal()
            #expect(done.wait(timeout: .now() + 5) == .success)
            let r = try #require(out.r)
            #expect(code(r) == "grant_missing", "\(method): \(r.json.encoded())")
            #expect(!r.json.encoded().contains("继续"), "\(method): nothing read is answered")
            if method == "observe" {
                // The screenshot taken before is gone with it.
                let left = (try? FileManager.default.contentsOfDirectory(atPath: sc.s.artifacts.directory)) ?? []
                #expect(!left.contains { $0.hasSuffix(".png") }, "\(left)")
            }
        }
    }
}

@Test func closingAProcesssOnlyWindowEndsTheGrantForGood() throws {
    // Calculator (pid 101) shows one window: once it closes, the process
    // lists none (Codex on 7629d6b), and the grant ends all the same.
    let (sc, _, g, _) = try calculatorScene(["observe"])
    let backend = try #require(sc.s.backend as? FixedBackend)
    backend.opened.lock.withLock { _ = backend.opened.closed.insert(11) }
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "grant_missing")
    #expect(sc.s.hub.windowGrant(g.windowGrantId)?.endedReason == "window_closed")
    backend.opened.lock.withLock { _ = backend.opened.closed.remove(11) }
    #expect(sc.s.hub.windowGrant(g.windowGrantId)?.state == "ended")
    #expect(code(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) == "grant_missing")
}

@Test func aWindowGrantNeverOutlivesTheClientsGrantInAbsoluteTime() throws {
    let st = try Stage()
    // While the user decides, the owner shortens the app's grant to a minute from now.
    let soon = Timestamp.string(Date().addingTimeInterval(60))
    st.confirmer.decide = { [s = st.s, id = st.appId] r in
        if var g = s.hub.grant(id) { g.expiresAt = soon; try? s.hub.putGrant(g) }
        return .approved(digest: r.digest)
    }
    let g = try #require(data(st.request(["observe"])))
    #expect((g["expiresAt"]?.stringValue ?? "~") <= soon, "\(g.encoded())")
}

@Test func aWindowGrantDoesNotOutliveItsDesktopOrTheRuntime() throws {
    // The Desktop is gone from the Runtime (as after a restart): the grant ends.
    let st = try Stage()
    let id = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
    st.s.desktops.remove(st.desk)
    #expect(data(call(st.s, st.app, "window.list"))?["windows"]?.arrayValue?.isEmpty == true)
    #expect(st.s.hub.windowGrant(id)?.endedReason == "desktop_destroyed")
    // A new Runtime over the same records ends every window grant at start.
    let again = try Stage()
    let id2 = try #require(data(again.request(["observe"]))?["windowGrantId"]?.stringValue)
    _ = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_next", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                 endpoint: "/tmp/t.sock", buildSource: "unknown"),
                       backend: again.backend, platform: again.platform, hub: again.s.hub)
    #expect(again.s.hub.windowGrant(id2)?.endedReason == "runtime_restarted")
}

@Test func anotherAppsGrantIdIsNeverShownWithTheBinding() throws {
    let st = try Stage()
    let mine = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
    #expect(data(st.bind(12)) != nil)
    // A second app with its own grant for the same window on the same Desktop.
    let (other, otherId, _) = try pairedClient(st.s, capabilities: ["observe"], desktops: [st.desk], apps: [wechat], name: "other")
    let theirs = try grantWindow(st.s, clientId: otherId, desktopId: st.desk, windowId: 12, pid: 202, bundleId: wechat, permissions: ["observe"])
    let shown = data(call(st.s, other, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"]
    #expect(shown?["windowId"]?.intValue == 12)
    #expect(shown?["windowGrantId"]?.stringValue == theirs.windowGrantId, "its own grant, never the binder's")
    #expect(!(data(call(st.s, other, "desktop.list"))?.encoded() ?? "").contains(mine))
    #expect(data(call(st.s, st.app, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"]?["windowGrantId"]?.stringValue == mine)
}

@Test func aTransientScreenshotGoesAtItsExpiryWithNothingElseHappening() async throws {
    try await offPoolConfirm {
        let (sc, _, _, _) = try calculatorScene(["observe"])
        sc.s.transientArtifactLifetime = 0.3
        let image = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["image"])
        let id = try #require(image["artifactId"]?.stringValue)
        let file = try #require(sc.s.artifacts.file(of: id))
        #expect(FileManager.default.fileExists(atPath: file))
        let end = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: file) && Date() < end { Thread.sleep(forTimeInterval: 0.05) }
        #expect(!FileManager.default.fileExists(atPath: file), "deleted on time, with no later request")
    }
}

@Test func aWindowWhoseProcessLaunchCannotBeIdentifiedIsNotGrantable() throws {
    let st = try Stage()
    st.backend.opened.lock.withLock { _ = st.backend.opened.startUnknown.insert(202) }
    #expect(st.reason(st.request(["observe"])) == "window_identity_unverified")
    #expect(st.confirmer.requests.isEmpty)
}

@Test func aWindowGrantIsRecordedOnlyAgainstTheParentRevisionItWasCheckedFor() throws {
    let st = try Stage()
    let parent = try #require(st.s.hub.grant(st.appId))
    let g = HubStore.WindowGrant(windowGrantId: "wg_race", clientId: st.appId, desktopId: st.desk, windowId: 12,
                                 process: st.backend.processIdentity(202), bundleId: wechat, appName: "微信", permissions: ["observe"],
                                 state: "active", endedReason: nil, createdAt: Timestamp.string(Date()),
                                 expiresAt: Timestamp.string(Date().addingTimeInterval(60)), confirmationId: nil)
    // The owner changed the app's grant after the checks: nothing is recorded.
    _ = try st.s.hub.setGrant(parent)
    #expect(throws: (any Error).self) { try st.s.hub.addWindowGrant(g, parentRevision: parent.revision) }
    // Nor for an app the grant does not name.
    var other = g
    other.windowGrantId = "wg_other"
    other.bundleId = "com.apple.calculator"
    #expect(throws: (any Error).self) { try st.s.hub.addWindowGrant(other) }
    #expect(st.s.hub.windowGrant("wg_race") == nil && st.s.hub.windowGrant("wg_other") == nil)
}

@Test func narrowingAndItsWindowGrantEndingsAreOneTransaction() throws {
    let st = try Stage()
    let id = try #require(data(st.request(["observe"]))?["windowGrantId"]?.stringValue)
    var g = try #require(st.s.hub.grant(st.appId))
    g.apps = []
    let (saved, ended) = try st.s.hub.setGrant(g, endingWindowGrants: { $0.bundleId == wechat ? "app_removed" : nil })
    #expect(saved.apps.isEmpty && ended.map(\.id) == [id])
    #expect(st.s.hub.windowGrant(id)?.state == "ended")
    // Putting the app back brings nothing back.
    g.apps = [wechat]
    _ = try st.s.hub.setGrant(g)
    #expect(st.s.hub.windowGrant(id)?.state == "ended")
}

@Test func aDesktopDestroyedWhileTheUserDecidesLeavesNoGrant() throws {
    let st = try Stage()
    st.confirmer.decide = { [s = st.s, owner = st.owner, desk = st.desk] r in
        _ = call(s, owner, "desktop.destroy", params: #"{"desktopId":"\#(desk)"}"#)
        return .approved(digest: r.digest)
    }
    let r = st.request(["observe"])
    #expect(code(r) == "conflict" || code(r) == "not_found", "\(r.json.encoded())")
    #expect(st.s.hub.windowGrants(clientId: st.appId).isEmpty)
}

@Test func aLaunchWithoutAStartTimeIsNotTheClientsOwn() throws {
    let platform = FakePlatform()
    var backend = FixedBackend()
    backend.apps.append(AppSummary(process: ProcessIdentity(pid: 303, startedAt: nil), bundleId: "com.apple.Notes",
                                   name: "Notes", active: false, hidden: false))
    backend.opened.startUnknown = [303]
    let s = platformService(platform, backend: backend)
    let (c, _, _) = try pairedClient(s, capabilities: ["observe", "desktop.manage"], desktops: ["created"],
                                     apps: ["com.apple.Notes"], name: "notes-agent")
    let d = try created(s, c)
    #expect(data(call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)) != nil)
    // The pid alone proves nothing: no exemption from window grants.
    let r = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":303,"windowId":31}"#)
    #expect(errorDetails(r)?["reason"]?.stringValue == "bind_requires_grant")
}

@Test func aGrantThatAllowsNothingAnyMoreShowsNoBinding() throws {
    let st = try Stage()
    _ = try #require(data(st.request(["act"])))
    #expect(data(st.bind(12)) != nil)
    #expect(data(call(st.s, st.app, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"]?["windowId"]?.intValue == 12)
    // The owner takes act away and leaves observe: the act-only grant allows nothing.
    let p = #"{"clientId":"\#(st.appId)","capabilities":["observe","desktop.manage","run"],"desktops":["\#(st.desk)"],"apps":["\#(wechat)"]}"#
    #expect(data(call(st.s, st.owner, "hub.grants.set", params: p)) != nil)
    let back = st.reconnect()
    #expect(data(call(st.s, back, "desktop.show", params: #"{"desktopId":"\#(st.desk)"}"#))?["binding"] == .null)
    #expect(!(data(call(st.s, back, "desktop.list"))?.encoded() ?? "").contains("\"windowId\":12"))
}

@Test func anArtifactRemovedFromManyPlacesAtOnceIsCountedOnce() async throws {
    try await offPoolConfirm {
        let (sc, _, g, _) = try calculatorScene(["observe"])
        for _ in 0..<3 { _ = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#) }
        let bucket = "session:" + sc.session
        #expect(sc.s.artifacts.count(bucket: bucket) == 3)
        let ids = ((try? FileManager.default.contentsOfDirectory(atPath: sc.s.artifacts.directory)) ?? [])
            .compactMap(ArtifactStore.artifactId(ofFile:))
        let group = DispatchGroup()
        for _ in 0..<8 {
            group.enter()
            Thread {
                for id in Set(ids) { sc.s.artifacts.remove(id) }
                sc.s.artifacts.removeTransients(windowGrantId: g.windowGrantId)
                group.leave()
            }.start()
        }
        group.wait()
        #expect(sc.s.artifacts.count(bucket: bucket) == 0, "each removal counted once, never below zero")
        // A new one counts from zero again.
        _ = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
        #expect(sc.s.artifacts.count(bucket: bucket) == 1)
    }
}
