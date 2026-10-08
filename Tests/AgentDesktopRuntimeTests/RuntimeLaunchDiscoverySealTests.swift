import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Until launch and window-discovery grants (PR3: SEC-04, SEC-05), a socket
// client cannot start apps or list apps and windows. The host's own window
// does both through its in-process connection. Product defaults, real
// RuntimeServer, real socket.

private func sealedServer(_ platform: FakePlatform) throws -> (RuntimeService, RuntimeServer, String, String) {
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_seal", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: path, buildSource: "unknown"),
                           backend: FixedBackend(), platform: platform)
    let server = RuntimeServer(path: path, service: s)
    try server.start()
    return (s, server, path, dir)
}

private func exchange(_ c: RawConnection, _ line: String) throws -> JSONValue {
    c.send(line + "\n")
    return try c.read()
}

/// Nothing a refusal says may name an app, a window, a title or a pid.
private func namesNothing(_ v: JSONValue) -> Bool {
    let text = String(decoding: v.encodedData(), as: UTF8.self)
    return !["Calculator", "calculator", "微信", "xinWeChat", "文件传输助手", "最小化", "101", "202"].contains { text.contains($0) }
}

@Test func theProductRefusesLaunchAndDiscoveryToSocketClients() throws {
    let platform = FakePlatform()
    let (s, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    #expect(s.socketLaunchRequiresGrant && s.socketDiscoveryRequiresGrant, "the product defaults")
    let c = try RawConnection(path)
    #expect(try exchange(c, handshakeLine)["ok"]?.boolValue == true)
    let desk = try exchange(c, requestLine("desktop.create", id: "dc_1", params: #"{"name":"seal"}"#))
    let d = try #require(desk["data"]?["desktopId"]?.stringValue)
    let before = platform.calls

    // app.launch: refused before the ledger and the platform; a retry with
    // the same requestId is refused again (nothing was recorded).
    for _ in 0..<2 {
        let r = try exchange(c, requestLine("app.launch", id: "al_1", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.calculator","newInstance":true}"#))
        #expect(r["error"]?["code"]?.stringValue == "permission_denied")
        #expect(r["error"]?["details"]?["reason"]?.stringValue == "launch_requires_grant")
        #expect(r["error"]?["notSent"]?.boolValue == true)
        #expect(namesNothing(r))
    }
    #expect(platform.calls == before, "the platform got no call: \(platform.calls)")
    #expect(s.desktops.find(d)?.launched.isEmpty == true)

    // Every listing, with every filter, is refused the same way.
    let listings: [(String, String)] = [
        ("app.list", "{}"), ("app.list", #"{"includeBackground":true}"#),
        ("window.list", "{}"), ("window.list", #"{"pid":202}"#), ("window.list", #"{"bundleId":"com.tencent.xinWeChat"}"#),
        ("window.list", #"{"includeOffscreen":true}"#),
    ]
    for (i, (method, params)) in listings.enumerated() {
        let r = try exchange(c, requestLine(method, id: "ls_\(i)", params: params))
        #expect(r["error"]?["code"]?.stringValue == "permission_denied", "\(method) \(params)")
        #expect(r["error"]?["details"]?["reason"]?.stringValue == "window_discovery_requires_grant")
        #expect(r["data"] == nil)
        #expect(namesNothing(r), "\(method) \(params): \(r)")
    }
    // A second connection, whatever it calls itself, is a socket client too.
    let other = try RawConnection(path)
    let hostName = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs_2","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"AgentDesktop","version":"1"}}}"#
    #expect(try exchange(other, hostName)["ok"]?.boolValue == true)
    let r = try exchange(other, requestLine("window.list", id: "ls_x"))
    #expect(r["error"]?["details"]?["reason"]?.stringValue == "window_discovery_requires_grant")
}

@Test func theHostsOwnConnectionStillLaunchesAndLists() throws {
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_seal", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: platform)
    let host = handshaken(s)
    #expect(host.origin == .host)
    #expect(data(call(s, host, "window.list"))?["windows"]?.arrayValue?.isEmpty == false)
    #expect(data(call(s, host, "app.list"))?["apps"]?.arrayValue?.isEmpty == false)
    let d = try created(s, host)
    #expect(data(call(s, host, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.Notes"}"#)) != nil)
}

@Test func aConnectionFromTheServerIsASocketConnection() {
    #expect(ConnectionState(socketPeer: getuid()).origin == .socket)
    #expect(ConnectionState(peerUID: getuid()).origin == .host)
}

@Test func aSocketClientCannotStartAGuiRunOnTheHostsRights() throws {
    let platform = FakePlatform()
    let (s, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    #expect(s.socketGuiRunRequiresGrant, "the product default")
    // A GUI service that would run on the host's ports: it must never be reached.
    final class Count: @unchecked Sendable { let lock = NSLock(); var methods: [String] = [] }
    let reached = Count()
    let handler: ExtensionMethod = { call in
        reached.lock.withLock { reached.methods.append(call.method) }
        return .success(.obj([("runs", .array([]))]))
    }
    s.registerExtensions(["gui.runs.start": handler, "gui.runs.get": handler])
    let c = try RawConnection(path)
    #expect(try exchange(c, handshakeLine)["ok"]?.boolValue == true)
    let before = platform.calls
    for _ in 0..<2 {
        let r = try exchange(c, requestLine("gui.runs.start", id: "gr_1", params: #"{"desktopId":"d_x","goal":"read the chat"}"#))
        #expect(r["error"]?["code"]?.stringValue == "permission_denied")
        #expect(r["error"]?["details"]?["reason"]?.stringValue == "gui_run_requires_grant")
        #expect(r["error"]?["notSent"]?.boolValue == true)
    }
    // The runs that exist are the host's: reading them is refused too.
    let get = try exchange(c, requestLine("gui.runs.get", id: "gg_1", params: #"{"runId":"gr_x"}"#))
    #expect(get["error"]?["details"]?["reason"]?.stringValue == "gui_run_requires_grant")
    #expect(reached.lock.withLock { reached.methods }.isEmpty, "no GUI service was reached")
    #expect(platform.calls == before, "nothing observed")
    #expect(try s.ledger.record(caller: ~getuid(), requestId: "gr_1") == nil, "nothing recorded")
}

/// Counts every backend read (apps, windows), to show a refusal reads none.
struct CountingBackend: RuntimeBackend {
    final class Count: @unchecked Sendable { let lock = NSLock(); var n = 0 }
    var base = FixedBackend()
    let count = Count()
    var platform: Platform { base.platform }
    func permissions() -> BackendPermissions { base.permissions() }
    func features() -> [String] { base.features() }
    func applications(includeBackground: Bool) -> [AppSummary] {
        count.lock.withLock { count.n += 1 }
        return base.applications(includeBackground: includeBackground)
    }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { base.processIdentity(pid) }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        count.lock.withLock { count.n += 1 }
        return base.windows(pid: pid, bundleId: bundleId, includeOffscreen: includeOffscreen)
    }
}

@Test func aRefusalWritesNoLedgerEntryAndReadsNoBackend() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let backend = CountingBackend()
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_seal", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: path, buildSource: "unknown"),
                           backend: backend, platform: platform)
    let server = RuntimeServer(path: path, service: s)
    try server.start()
    defer { server.stop() }
    let c = try RawConnection(path)
    _ = try exchange(c, handshakeLine)
    let d = try #require(try exchange(c, requestLine("desktop.create", id: "dc_9", params: "{}"))["data"]?["desktopId"]?.stringValue)
    let reads = backend.count.lock.withLock { backend.count.n }
    _ = try exchange(c, requestLine("app.launch", id: "al_9", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.calculator"}"#))
    _ = try exchange(c, requestLine("window.list", id: "wl_9"))
    _ = try exchange(c, requestLine("app.list", id: "ap_9"))
    #expect(backend.count.lock.withLock { backend.count.n } == reads, "no backend read")
    #expect(try s.ledger.record(caller: ~getuid(), requestId: "al_9") == nil, "the refused write is not in the ledger")
    #expect(try s.ledger.record(caller: ~getuid(), requestId: "dc_9") != nil, "a socket client's own write is, under its own key")
}

// b9's B1: what the main window created is not the socket client's.
@Test func aSocketClientDoesNotSeeOrUseTheHostsDesktopsSessionsRequestsOrRuns() throws {
    let platform = FakePlatform()
    let (s, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    // The main window, in-process: a Desktop with Notes launched and bound,
    // a session, an observation, a request in the ledger.
    let host = handshaken(s)
    let hostDesk = try created(s, host, name: "main-window")
    let launched = try #require(data(call(s, host, "app.launch", id: "host-launch",
                                          params: #"{"desktopId":"\#(hostDesk)","bundleId":"com.apple.Notes"}"#)))
    let pid = try #require(launched["process"]?["pid"]?.intValue)
    #expect(data(call(s, host, "window.bind", params: #"{"desktopId":"\#(hostDesk)","pid":\#(pid)}"#)) != nil)
    let hostSession = try #require(data(call(s, host, "session.open", params: #"{"desktopId":"\#(hostDesk)"}"#))?["sessionId"]?.stringValue)
    let hostRun = try #require(data(call(s, host, "run.start", context: #"{"sessionId":"\#(hostSession)"}"#))?["run"]?["runId"]?.stringValue)

    let c = try RawConnection(path)
    _ = try exchange(c, handshakeLine)
    let mine = try #require(try exchange(c, requestLine("desktop.create", id: "dc_mine", params: #"{"name":"mine"}"#))["data"]?["desktopId"]?.stringValue)
    let list = try exchange(c, requestLine("desktop.list", id: "dl_1"))
    let ids = list["data"]?["desktops"]?.arrayValue?.compactMap { $0["desktopId"]?.stringValue } ?? []
    #expect(ids == [mine], "only its own Desktop: \(ids)")
    #expect(!String(decoding: list.encodedData(), as: UTF8.self).contains("Notes"))

    let before = platform.calls
    func refused(_ method: String, _ params: String = "{}", context: String? = nil) throws -> String? {
        var line = requestLine(method, id: "x_" + UUID().uuidString.prefix(8), params: params)
        if let context { line = String(line.dropLast()) + #","context":"# + context + "}" }
        return try exchange(c, line)["error"]?["code"]?.stringValue
    }
    let onHost = #"{"desktopId":"\#(hostDesk)"}"#
    #expect(try refused("desktop.show", onHost) == "not_found")
    #expect(try refused("session.open", onHost) == "not_found")
    #expect(try refused("window.unbind", onHost) == "not_found")
    #expect(try refused("desktop.destroy", onHost) == "not_found")
    #expect(try refused("window.bind", #"{"desktopId":"\#(hostDesk)","pid":\#(pid)}"#) == "not_found")
    #expect(try refused("observe", context: onHost) == "not_found")
    #expect(try refused("observe", context: #"{"sessionId":"\#(hostSession)"}"#) == "not_found")
    #expect(try refused("act", #"{"snapshotId":"obs_x","action":{"kind":"key","key":"escape"}}"#,
                        context: #"{"sessionId":"\#(hostSession)"}"#) == "not_found")
    #expect(try refused("request.show", #"{"requestId":"host-launch"}"#) == "not_found")
    #expect(try refused("run.show", #"{"runId":"\#(hostRun)"}"#) == "not_found")
    #expect(try refused("run.events", #"{"runId":"\#(hostRun)"}"#) == "not_found")
    #expect(try refused("run.cancel", #"{"runId":"\#(hostRun)"}"#) == "not_found")
    #expect(s.runs.find(hostRun)?.isEnded == false, "the host's run keeps running")
    #expect(platform.calls == before, "nothing of the host's was touched: \(platform.calls.dropFirst(before.count))")
    #expect(s.desktops.find(hostDesk)?.binding != nil, "the host's binding stays")
}

@Test func aBindRefusalDoesNotTellWhetherAPidExists() throws {
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_seal", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: NoSuchProcessBackend(), platform: platform)
    let c = handshaken(s)
    let d = try created(s, c)
    let r = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":99999}"#)
    #expect(failure(r)?.details?["reason"]?.stringValue == "bind_requires_grant")
}

/// A backend in which no process exists.
struct NoSuchProcessBackend: RuntimeBackend {
    var base = FixedBackend()
    var platform: Platform { base.platform }
    func permissions() -> BackendPermissions { base.permissions() }
    func features() -> [String] { base.features() }
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: nil) }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] { [] }
}

// b9's second review: AI configuration, global stop, Desktop names.
@Test func aSocketClientCannotChangeTheAIConfigurationButReadsIt() throws {
    let platform = FakePlatform()
    let (s, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    final class Count: @unchecked Sendable { let lock = NSLock(); var methods: [String] = [] }
    let reached = Count()
    let handler: ExtensionMethod = { call in
        reached.lock.withLock { reached.methods.append(call.method) }
        return .success(.obj([("connections", .array([]))]))
    }
    let writes = ["ai.connections.update", "ai.connections.create", "ai.modelProfiles.update", "ai.profiles.setDefault",
                  "ai.credentials.rotate", "ai.tests.start", "ai.operations.cancel"]
    s.registerExtensions(Dictionary(uniqueKeysWithValues: (writes + ["ai.connections.list"]).map { ($0, handler) }))
    let c = try RawConnection(path)
    _ = try exchange(c, handshakeLine)
    for (i, method) in writes.enumerated() {
        let r = try exchange(c, requestLine(method, id: "ai_\(i)", params: #"{"connectionId":"c_1","baseUrl":"https://elsewhere.example"}"#))
        #expect(r["error"]?["code"]?.stringValue == "permission_denied", "\(method)")
        #expect(r["error"]?["details"]?["reason"]?.stringValue == "ai_config_requires_grant", "\(method)")
        #expect(try s.ledger.record(caller: ~getuid(), requestId: "ai_\(i)") == nil)
    }
    #expect(reached.lock.withLock { reached.methods }.isEmpty, "no AI service write was reached")
    _ = try exchange(c, requestLine("ai.connections.list", id: "ai_list"))
    #expect(reached.lock.withLock { reached.methods } == ["ai.connections.list"], "reading stays open")
}

@Test func aSocketClientMayStopAllInputButNotTurnItBackOn() throws {
    let platform = FakePlatform()
    let (_, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let c = try RawConnection(path)
    _ = try exchange(c, handshakeLine)
    let stop = try exchange(c, requestLine("runtime.stopAll", id: "sa_1", params: #"{"scope":"all_platform_runs"}"#))
    #expect(stop["ok"]?.boolValue == true, "\(stop)")
    let enable = try exchange(c, requestLine("runtime.enableInput", id: "ei_1"))
    #expect(enable["error"]?["code"]?.stringValue == "permission_denied")
}

@Test func desktopNamesAreUniquePerOriginSoTheHostsCannotBeProbedOrTaken() throws {
    let platform = FakePlatform()
    let (s, server, path, dir) = try sealedServer(platform)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let host = handshaken(s)
    _ = try created(s, host, name: "客户资料")
    let c = try RawConnection(path)
    _ = try exchange(c, handshakeLine)
    let first = try exchange(c, requestLine("desktop.create", id: "n_1", params: #"{"name":"客户资料"}"#))
    #expect(first["ok"]?.boolValue == true, "the host's name neither shows nor blocks: \(first)")
    let second = try exchange(c, requestLine("desktop.create", id: "n_2", params: #"{"name":"客户资料"}"#))
    #expect(second["error"]?["code"]?.stringValue == "conflict", "unique among socket clients' Desktops")
    // The host still makes Desktops with its own names.
    #expect(code(call(s, host, "desktop.create", params: #"{"name":"客户资料"}"#)) == "conflict")
    #expect(data(call(s, host, "desktop.create", params: #"{"name":"另一个"}"#)) != nil)
}
