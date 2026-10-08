import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A4 SEC-04 (launching apps needs a grant) and SEC-05 (window discovery
// shows nothing a client was not granted), end to end: a real RuntimeServer
// on a socket, socket clients with real credentials, the whole
// authorization chain. The refusal reasons are the ones #153's interim seal
// gives (launch_requires_grant, window_discovery_requires_grant).

private func offPool(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread { do { try body(); k.resume() } catch { k.resume(throwing: error) } }.start()
    }
}

/// A Runtime on a socket, an owner (the host's own connection) and a way to
/// pair clients the way the trusted window would.
private final class Stage {
    let platform = FakePlatform()
    let s: RuntimeService
    let owner: ConnectionState
    let server: RuntimeServer
    let dir: String
    let path: String

    init() throws {
        s = platformService(platform)
        owner = handshaken(s)
        dir = try socketDirectory()
        path = dir + "/runtime.sock"
        server = RuntimeServer(path: path, service: s)
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func pair(_ capabilities: [String], desktops: [String] = ["created"], apps: [String] = [], name: String = "app") throws -> ClientCredential {
        let (_, id, token) = try pairedClient(s, capabilities: capabilities, desktops: desktops, apps: apps, name: name)
        return ClientCredential(clientId: id, token: token)
    }

    func client(_ credential: ClientCredential?) -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"), timeout: 5,
                            credential: credential)
    }
}

/// The outcome of one call over the socket: data, or the error's code and reason.
private func send(_ c: SocketRuntimeClient, _ method: String, _ params: JSONValue = .obj([]), context: RequestContext? = nil)
    -> (data: JSONValue?, code: String?, reason: String?) {
    var r = RuntimeRequest(requestId: RuntimeRequest.newId(), method: method, params: params)
    if let context { r.context = context }
    do { return (try c.call(r), nil, nil) } catch let e as RuntimeError {
        return (nil, e.code, e.details?["reason"]?.stringValue)
    } catch { return (nil, "\(error)", nil) }
}

private func launch(_ desktop: String, _ bundle: String) -> JSONValue {
    .obj([("desktopId", .string(desktop)), ("bundleId", .string(bundle))])
}

private func launches(_ p: FakePlatform) -> [String] { p.lock.withLock { p.calls.filter { $0.hasPrefix("launch") } } }

// MARK: SEC-04 launching apps

@Test func sec04OnlyAGrantedClientLaunchesAndOnlyItsGrantedApps() async throws {
    try await offPool {
        let st = try Stage()
        // Unpaired: refused before anything.
        let anon = st.client(nil)
        defer { anon.close() }
        #expect(send(anon, "app.launch", launch("d_x", "com.apple.calculator")).code == "pairing_required")
        // Paired without desktop.manage.
        let viewer = st.client(try st.pair(["observe"], name: "viewer"))
        defer { viewer.close() }
        let v = send(viewer, "app.launch", launch("d_x", "com.apple.calculator"))
        #expect(v.code == "grant_missing" && v.reason == "launch_requires_grant")
        // Granted: its own Desktop, its own apps only.
        let launcher = st.client(try st.pair(["observe", "desktop.manage"], apps: ["com.apple.calculator"], name: "launcher"))
        defer { launcher.close() }
        let desk = try #require(send(launcher, "desktop.create").data?["desktopId"]?.stringValue)
        #expect(send(launcher, "app.launch", launch(desk, "com.apple.calculator")).data != nil)
        let notes = send(launcher, "app.launch", launch(desk, "com.apple.Notes"))
        #expect(notes.code == "grant_missing" && notes.reason == "launch_requires_grant", "an app the grant does not name")
        // By path instead of bundle id: no app identity to check, refused.
        let byPath = send(launcher, "app.launch", .obj([("desktopId", .string(desk)), ("path", .string("/System/Applications/Calculator.app"))]))
        #expect(byPath.reason == "launch_requires_grant")
        // Onto a Desktop it did not create.
        let ownersDesk = try #require(data(call(st.s, st.owner, "desktop.create"))?["desktopId"]?.stringValue)
        #expect(send(launcher, "app.launch", launch(ownersDesk, "com.apple.calculator")).code == "not_found")
        // Its own Desktop named in the context, the owner's in the params.
        let mixed = send(launcher, "app.launch", launch(ownersDesk, "com.apple.calculator"), context: RequestContext(desktopId: desk))
        #expect(mixed.reason == "target_mismatch")
        #expect(launches(st.platform).count == 1, "only the one granted launch reached the platform: \(launches(st.platform))")
    }
}

@Test func sec04ExpiryRevocationAndForgedIdentityStopLaunching() async throws {
    try await offPool {
        let st = try Stage()
        let cred = try st.pair(["observe", "desktop.manage"], apps: ["com.apple.calculator"])
        let c = st.client(cred)
        defer { c.close() }
        let desk = try #require(send(c, "desktop.create").data?["desktopId"]?.stringValue)
        // Expired.
        var g = try #require(st.s.hub.grant(cred.clientId))
        let renewed = g.expiresAt
        g.expiresAt = Timestamp.string(Date().addingTimeInterval(-1))
        try st.s.hub.putGrant(g)
        #expect(send(c, "app.launch", launch(desk, "com.apple.calculator")).code == "grant_expired")
        g.expiresAt = renewed
        try st.s.hub.putGrant(g)
        // Forged: another client's id with this token, or an id in the request.
        let other = try st.pair(["observe"], name: "other")
        let forged = st.client(ClientCredential(clientId: other.clientId, token: cred.token))
        defer { forged.close() }
        #expect(send(forged, "app.launch", launch(desk, "com.apple.calculator")).code == "permission_denied")
        let viewer = st.client(other)
        defer { viewer.close() }
        let claimed = send(viewer, "app.launch", .obj([("desktopId", .string(desk)), ("bundleId", .string("com.apple.calculator")),
                                                      ("clientId", .string(cred.clientId))]))
        #expect(claimed.code != nil && claimed.data == nil, "refused (its own grant has no launch)")
        // The launcher itself, claiming the other's id in the request: the contract refuses the field.
        let claimedByLauncher = send(c, "app.launch", .obj([("desktopId", .string(desk)), ("bundleId", .string("com.apple.calculator")),
                                                           ("clientId", .string(other.clientId))]))
        #expect(claimedByLauncher.code == "schema_invalid")
        // Revoked: the open connection is cut, a new one refused.
        #expect(data(call(st.s, st.owner, "hub.clients.revoke", params: #"{"clientId":"\#(cred.clientId)"}"#)) != nil)
        #expect(send(c, "app.launch", launch(desk, "com.apple.calculator")).data == nil)
        let again = st.client(cred)
        defer { again.close() }
        #expect(send(again, "app.launch", launch(desk, "com.apple.calculator")).code == "client_revoked")
        #expect(launches(st.platform).isEmpty)
    }
}

// MARK: SEC-05 window discovery

/// Anything in a reply that names one of the user's other apps' windows.
private func leaks(_ v: JSONValue?) -> [String] {
    let text = v?.encoded() ?? ""
    return ["微信", "文件传输助手", "最小化的窗口", "com.tencent.xinWeChat", "\"pid\":202"].filter { text.contains($0) }
}

@Test func sec05NoTitlesPidsOrAppNamesWithoutAGrant() async throws {
    try await offPool {
        let st = try Stage()
        let anon = st.client(nil)
        defer { anon.close() }
        for m in ["app.list", "window.list"] {
            let r = send(anon, m, m == "window.list" ? .obj([("includeOffscreen", .bool(true))]) : .obj([("includeBackground", .bool(true))]))
            #expect(r.code == "pairing_required", "\(m)")
        }
        // Paired, but no observe: refused with the seal's reason.
        let actor = st.client(try st.pair(["act"], name: "actor"))
        defer { actor.close() }
        for m in ["app.list", "window.list"] {
            let r = send(actor, m)
            #expect(r.code == "grant_missing" && r.reason == "window_discovery_requires_grant", "\(m)")
        }
        // Observe, no apps: empty, nothing of the user's.
        let blind = st.client(try st.pair(["observe"], apps: [], name: "blind"))
        defer { blind.close() }
        let a0 = send(blind, "app.list", .obj([("includeBackground", .bool(true))])).data
        let w0 = send(blind, "window.list", .obj([("includeOffscreen", .bool(true))])).data
        #expect(a0?["apps"]?.arrayValue?.isEmpty == true && w0?["windows"]?.arrayValue?.isEmpty == true)
        // Even asking by the other app's pid or bundle id.
        let byPid = send(blind, "window.list", .obj([("pid", .int(202)), ("includeOffscreen", .bool(true))])).data
        let byBundle = send(blind, "window.list", .obj([("bundleId", .string("com.tencent.xinWeChat"))])).data
        #expect(leaks(a0).isEmpty && leaks(w0).isEmpty && leaks(byPid).isEmpty && leaks(byBundle).isEmpty)
        // Granted one app: that app's windows only.
        let calc = st.client(try st.pair(["observe"], apps: ["com.apple.calculator"], name: "calc"))
        defer { calc.close() }
        let w1 = send(calc, "window.list", .obj([("includeOffscreen", .bool(true))])).data
        #expect(w1?["windows"]?.arrayValue?.map { $0["bundleId"]?.stringValue } == ["com.apple.calculator"])
        #expect(leaks(w1).isEmpty && leaks(send(calc, "app.list", .obj([("includeBackground", .bool(true))])).data).isEmpty)
        // Other ways in: Desktops it may not see, hub listings.
        #expect(leaks(send(calc, "desktop.list").data).isEmpty)
        #expect(send(calc, "hub.connections.list").data == nil)
    }
}

@Test func sec05NarrowingOrRevokingAppliesToEveryListingAtOnce() async throws {
    try await offPool {
        let st = try Stage()
        let cred = try st.pair(["observe"], apps: ["com.apple.calculator", "com.tencent.xinWeChat"], name: "wide")
        let c = st.client(cred)
        defer { c.close() }
        let before = send(c, "window.list", .obj([("includeOffscreen", .bool(true))])).data
        #expect(!leaks(before).isEmpty, "while granted it does see WeChat")
        // Narrowed: the open connection is cut; reconnecting, WeChat is gone
        // from every listing.
        #expect(data(call(st.s, st.owner, "hub.grants.set",
                          params: #"{"clientId":"\#(cred.clientId)","capabilities":["observe"],"desktops":["created"],"apps":["com.apple.calculator"]}"#)) != nil)
        #expect(send(c, "window.list").data == nil, "the old connection answers nothing more")
        let after = st.client(cred)
        defer { after.close() }
        for (m, p) in [("window.list", JSONValue.obj([("includeOffscreen", .bool(true))])), ("window.list", .obj([("pid", .int(202))])),
                       ("app.list", .obj([("includeBackground", .bool(true))]))] {
            #expect(leaks(send(after, m, p).data).isEmpty, "\(m) \(p.encoded())")
        }
        // Revoked: nothing at all.
        #expect(data(call(st.s, st.owner, "hub.clients.revoke", params: #"{"clientId":"\#(cred.clientId)"}"#)) != nil)
        #expect(send(after, "window.list").data == nil)
        let gone = st.client(cred)
        defer { gone.close() }
        #expect(send(gone, "app.list").code == "client_revoked")
    }
}
