import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// What #153's interim seal promises socket clients, kept under A4's model
// (Kevin 2026-10-09: the seal does not replace the identity model, and the
// final integration must be regression-tested). Real RuntimeServer, real
// socket, product defaults.

private func offPool(_ body: @escaping @Sendable () throws -> Void) async throws {
    try await withCheckedThrowingContinuation { (k: CheckedContinuation<Void, Error>) in
        Thread { do { try body(); k.resume() } catch { k.resume(throwing: error) } }.start()
    }
}

/// Counts backend reads, to show a refusal reads nothing.
private final class CountingBackend: RuntimeBackend, @unchecked Sendable {
    let inner = FixedBackend()
    let lock = NSLock()
    var reads = 0
    var platform: Platform { inner.platform }
    func permissions() -> BackendPermissions { inner.permissions() }
    func features() -> [String] { inner.features() }
    func applications(includeBackground: Bool) -> [AppSummary] { lock.withLock { reads += 1 }; return inner.applications(includeBackground: includeBackground) }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        lock.withLock { reads += 1 }; return inner.windows(pid: pid, bundleId: bundleId, includeOffscreen: includeOffscreen)
    }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { inner.processIdentity(pid) }
}

private final class Stage {
    let platform = FakePlatform()
    let backend = CountingBackend()
    let s: RuntimeService
    let owner: ConnectionState
    let server: RuntimeServer
    let dir: String
    let path: String
    init() throws {
        dir = try socketDirectory()
        path = dir + "/runtime.sock"
        s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_parity", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: path, buildSource: "unknown"),
                           backend: backend, platform: platform)
        owner = handshaken(s)
        server = RuntimeServer(path: path, service: s)
        try server.start()
    }
    deinit { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    func client(_ cred: ClientCredential?) -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"), timeout: 5, credential: cred)
    }
    func pair(_ caps: [String], desktops: [String] = ["created"], apps: [String] = []) throws -> ClientCredential {
        let (_, id, token) = try pairedClient(s, capabilities: caps, desktops: desktops, apps: apps)
        return ClientCredential(clientId: id, token: token)
    }
}

private struct Outcome { var data: JSONValue?; var error: RuntimeError? }
private func send(_ c: SocketRuntimeClient, _ method: String, _ params: String = "{}", id: String = RuntimeRequest.newId()) -> Outcome {
    do { return Outcome(data: try c.call(RuntimeRequest(requestId: id, method: method, params: try StrictJSON.parse(Data(params.utf8)))), error: nil) }
    catch let e as RuntimeError { return Outcome(data: nil, error: e) } catch { return Outcome(data: nil, error: nil) }
}

/// A refusal names no app, window, title or pid.
private func namesNothing(_ e: RuntimeError?) -> Bool {
    let text = (e?.message ?? "") + (e?.details?.encoded() ?? "")
    return !["Calculator", "calculator", "微信", "xinWeChat", "文件传输助手", "最小化", "101", "202"].contains { text.contains($0) }
}

@Test func parityUnpairedSocketClientsLaunchAndListNothingAndLeaveNoTrace() async throws {
    try await offPool {
        let st = try Stage()
        let anon = st.client(nil)
        defer { anon.close() }
        let reads = st.backend.lock.withLock { st.backend.reads }
        for (m, p) in [("app.launch", #"{"desktopId":"d_x","bundleId":"com.apple.calculator"}"#), ("app.list", #"{"includeBackground":true}"#),
                       ("window.list", #"{"pid":202}"#), ("window.list", #"{"bundleId":"com.tencent.xinWeChat"}"#),
                       ("window.bind", #"{"desktopId":"d_x","pid":202}"#), ("gui.runs.start", "{}")] {
            let r = send(anon, m, p, id: "seal-\(m)")
            #expect(r.error?.code == "pairing_required" && r.error?.notSent == true, "\(m)")
            #expect(namesNothing(r.error), "\(m)")
        }
        #expect(st.backend.lock.withLock { st.backend.reads } == reads, "a refusal reads no backend")
        #expect(st.platform.lock.withLock { st.platform.calls.isEmpty })
    }
}

@Test func parityRefusalsOfPairedClientsUseTheSealsReasonsAndNameNothing() async throws {
    try await offPool {
        let st = try Stage()
        let viewerCred = try st.pair(["act"])
        let viewer = st.client(viewerCred)
        defer { viewer.close() }
        for (m, p) in [("app.list", "{}"), ("window.list", #"{"pid":202}"#)] {
            let r = send(viewer, m, p)
            #expect(r.error?.details?["reason"]?.stringValue == "window_discovery_requires_grant" && namesNothing(r.error), "\(m)")
        }
        let launcher = st.client(try st.pair(["observe", "desktop.manage"], apps: []))
        defer { launcher.close() }
        let desk = try #require(send(launcher, "desktop.create").data?["desktopId"]?.stringValue)
        let l = send(launcher, "app.launch", #"{"desktopId":"\#(desk)","bundleId":"com.apple.calculator"}"#)
        #expect(l.error?.details?["reason"]?.stringValue == "launch_requires_grant" && namesNothing(l.error))
        // A pid that is WeChat's, and one that exists nowhere: the same answer.
        let existing = send(launcher, "window.bind", #"{"desktopId":"\#(desk)","pid":202}"#)
        let missing = send(launcher, "window.bind", #"{"desktopId":"\#(desk)","pid":99999}"#)
        #expect(existing.error?.details?["reason"]?.stringValue == "bind_requires_grant")
        #expect(existing.error?.message == missing.error?.message && existing.error?.details == missing.error?.details)
        #expect(namesNothing(existing.error))
        for m in ["gui.runs.start", "gui.runs.get"] {
            #expect(send(launcher, m, "{}").error?.details?["reason"]?.stringValue == "gui_run_requires_grant", "\(m)")
        }
    }
}

@Test func parityTheHostsOwnWindowStillLaunchesAndLists() throws {
    let st = try Stage()
    let d = try created(st.s, st.owner)
    #expect(data(call(st.s, st.owner, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.calculator"}"#)) != nil)
    #expect(data(call(st.s, st.owner, "window.list", params: #"{"includeOffscreen":true}"#))?["windows"]?.arrayValue?.isEmpty == false)
}

@Test func parityAPairedClientDoesNotSeeTheHostsDesktopsSessionsRequestsOrRuns() async throws {
    try await offPool {
        let st = try Stage()
        let d = try created(st.s, st.owner, name: "工作区")
        let sid = try #require(data(call(st.s, st.owner, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
        let run = try #require(data(call(st.s, st.owner, "run.start", context: #"{"sessionId":"\#(sid)"}"#))?["run"]?["runId"]?.stringValue)
        _ = call(st.s, st.owner, "desktop.create", id: "host-req-1", params: #"{"name":"另一个"}"#)
        let c = st.client(try st.pair(["observe", "act", "desktop.manage", "run"]))
        defer { c.close() }
        #expect(send(c, "desktop.list").data?["desktops"]?.arrayValue?.isEmpty == true)
        #expect(send(c, "desktop.show", #"{"desktopId":"\#(d)"}"#).error?.code == "not_found")
        #expect(send(c, "session.show", #"{"sessionId":"\#(sid)"}"#).error?.code == "not_found")
        #expect(send(c, "run.show", #"{"runId":"\#(run)"}"#).error?.code == "not_found")
        #expect(send(c, "request.show", #"{"requestId":"host-req-1"}"#).error?.code == "not_found")
        // Desktop names are per creator: the host's cannot be probed or taken.
        let mine = send(c, "desktop.create", #"{"name":"工作区"}"#)
        #expect(mine.data?["desktopId"]?.stringValue != nil && mine.data?["desktopId"]?.stringValue != d)
        #expect(data(call(st.s, st.owner, "desktop.create", params: #"{"name":"第三个"}"#)) != nil)
    }
}

@Test func parityStopAllByAPairedClientTellsItOnlyOfItsOwnRuns() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    s.confirmer = FakeConfirmer()
    let owner = handshaken(s)
    let hostDesk = try created(s, owner)
    _ = call(s, owner, "window.bind", params: #"{"desktopId":"\#(hostDesk)","pid":101}"#)
    let hostSession = try #require(data(call(s, owner, "session.open", params: #"{"desktopId":"\#(hostDesk)"}"#))?["sessionId"]?.stringValue)
    let hostRun = try #require(data(call(s, owner, "run.start", context: #"{"sessionId":"\#(hostSession)"}"#))?["run"]?["runId"]?.stringValue)
    let (sc, _, _) = try pairedScene(s, platform)
    let mine = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let r = try #require(data(call(s, sc.c, "runtime.stopAll", params: #"{"scope":"all_platform_runs"}"#)))
    let ids = (r["runs"]?.arrayValue ?? []).compactMap { $0["runId"]?.stringValue }
    #expect(ids == [mine], "only its own run is reported")
    #expect(data(call(s, owner, "run.show", params: #"{"runId":"\#(hostRun)"}"#))?["phase"]?.stringValue != "running", "but every run stopped")
}

@Test func theOriginInterfaceAgreedWith153() {
    #expect(ConnectionState(peerUID: getuid()).origin == .host)
    #expect(ConnectionState(socketPeer: getuid()).origin == .socket)
    #expect(ConnectionState(socketPeer: getuid(), pid: 1, executable: "/x").origin == .socket)
}
