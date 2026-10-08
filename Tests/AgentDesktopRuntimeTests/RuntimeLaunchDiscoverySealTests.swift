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
    #expect(reached.lock.withLock { reached.methods }.isEmpty, "no GUI run was created")
    #expect(platform.calls == before, "nothing observed")
    // Reading stays open.
    _ = try exchange(c, requestLine("gui.runs.get", id: "gg_1", params: #"{"runId":"gr_x"}"#))
    #expect(reached.lock.withLock { reached.methods } == ["gui.runs.get"])
}
