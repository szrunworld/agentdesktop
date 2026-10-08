import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A4-SEC-01 / A4-SEC-02: anything that keeps running for a caller stays
// bound by its access. A wait or run.wait in progress, and an open event
// stream, stop at the revocation; after the owner's revoke (or narrowing)
// returns, nothing more is sent on the app's connections. Expiry has no
// owner action: it is checked at every poll, every pushed frame and before
// every answer.

/// A result filled in on another thread.
private final class Box: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RuntimeResponse?
    var response: RuntimeResponse? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

/// Send one request on a plain thread (never on the cooperative pool).
private func callOnThread(_ s: RuntimeService, _ c: ConnectionState, _ method: String, params: String, context: String? = nil)
    -> (Box, DispatchSemaphore) {
    let box = Box(), done = DispatchSemaphore(value: 0)
    let ctx = context.map { #","context":\#($0)"# } ?? ""
    let line = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(RuntimeRequest.newId())","method":"\#(method)"\#(ctx),"params":\#(params)}"#
    Thread {
        box.response = s.respond(to: Data(line.utf8), on: c)
        done.signal()
    }.start()
    return (box, done)
}

private func until(_ seconds: Double = 5, _ condition: () -> Bool) -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() > end { return false }
        Thread.sleep(forTimeInterval: 0.01)
    }
    return true
}

private func reads(_ p: FakePlatform) -> Int { p.lock.withLock { p.calls.filter { $0.hasPrefix("elements") }.count } }

// MARK: A4-SEC-01: wait

@Test func secWaitPollingStopsAtTheRevocation() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    let before = reads(platform)
    let (box, done) = callOnThread(s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"never"},"timeoutMs":10000}"#,
                                   context: #"{"sessionId":"\#(sc.session)"}"#)
    // It is polling.
    #expect(until { reads(platform) >= before + 2 })
    #expect(box.response == nil)
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    let revokedAt = Date()
    #expect(done.wait(timeout: .now() + 2) == .success, "the wait ends at the revocation, not at its 10 s timeout")
    #expect(Date().timeIntervalSince(revokedAt) < 1)
    #expect(box.response.flatMap(code) == "client_revoked")
    // And it polls no more.
    let after = reads(platform)
    Thread.sleep(forTimeInterval: 0.6)
    #expect(reads(platform) == after)
}

@Test func secAWaitWhoseReadSucceedsAfterTheRevocationAnswersNothingProtected() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    // The read is in progress when the owner revokes; it then finds a match.
    let gate = DispatchSemaphore(value: 0)
    platform.lock.withLock { platform.axGate = gate }
    let (box, done) = callOnThread(s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"继续"},"timeoutMs":5000}"#,
                                   context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(until { platform.lock.withLock { platform.axRunning } == 1 })
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    platform.lock.withLock { platform.axGate = nil }
    gate.signal()
    #expect(done.wait(timeout: .now() + 3) == .success)
    let r = try #require(box.response)
    #expect(code(r) == "client_revoked", "no matches, no snapshot after the revocation: \(r.json.encoded())")
    #expect(r.json.encoded().contains("继续") == false)
    #expect(s.hub.auditEvents().contains { $0["decision"]?.stringValue == "withheld" && $0["method"]?.stringValue == "wait" })
}

@Test func secAWaitStopsWhenTheGrantExpiresOrLosesTheDesktop() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let (sc, id, _) = try pairedScene(s, platform)
    var g = try #require(s.hub.grant(id))
    g.expiresAt = Timestamp.string(Date().addingTimeInterval(0.5))
    try s.hub.putGrant(g)
    let started = Date()
    let (box, done) = callOnThread(s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"never"},"timeoutMs":10000}"#,
                                   context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(done.wait(timeout: .now() + 3) == .success)
    #expect(box.response.flatMap(code) == "grant_expired")
    #expect(Date().timeIntervalSince(started) < 2)
}

@Test func secRunWaitAnswersNothingAfterTheRevocation() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let (box, done) = callOnThread(s, sc.c, "run.wait", params: #"{"runId":"\#(runId)","timeoutMs":10000}"#)
    Thread.sleep(forTimeInterval: 0.2)
    #expect(box.response == nil)
    // The revocation ends the Run, which would end the wait with the Run's
    // record; the app gets the revocation instead.
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    #expect(done.wait(timeout: .now() + 3) == .success)
    #expect(box.response.flatMap(code) == "client_revoked")
    #expect(data(call(s, owner, "run.show", params: #"{"runId":"\#(runId)"}"#))?["closingReason"]?.stringValue == "client_revoked")
}

@Test func secARequestQueuedBehindTheRevocationIsCheckedWhenItRuns() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, token) = try pairedScene(s, platform)
    // Two requests pipelined on one socket: the first holds the connection
    // (a gated read), the owner revokes, the second runs only afterwards.
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let server = RuntimeServer(path: path, service: s)
    try server.start()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let gate = DispatchSemaphore(value: 0)
    platform.lock.withLock { platform.axGate = gate }
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    defer { close(fd) }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in _ = path.utf8CString.withUnsafeBytes { buf.copyMemory(from: $0) } }
    let len = socklen_t(MemoryLayout<sockaddr_un>.size)
    #expect(withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, len) } } == 0)
    var tv = timeval(tv_sec: 5, tv_usec: 0)
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    let lines = [
        #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"},"credential":{"clientId":"\#(id)","token":"\#(token)"}}}"#,
        #"{"apiVersion":"agentdesktop.runtime/1","requestId":"q-observe","method":"observe","context":{"sessionId":"\#(sc.session)"},"params":{"screenshot":false}}"#,
        #"{"apiVersion":"agentdesktop.runtime/1","requestId":"q-click","method":"act","context":{"sessionId":"\#(sc.session)"},"params":{"snapshotId":"\#(sc.snapshot)","action":{"kind":"click","target":{"elementRef":"el_0"}}}}"#,
    ].joined(separator: "\n") + "\n"
    _ = lines.withCString { write(fd, $0, strlen($0)) }
    #expect(until { platform.lock.withLock { platform.axRunning } == 1 })
    #expect(data(call(s, owner, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)) != nil)
    platform.lock.withLock { platform.axGate = nil }
    gate.signal()
    // Whatever reached the socket before the cut, the click never ran.
    var got = Data()
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
        let n = read(fd, &buf, buf.count)
        if n <= 0 { break }
        got.append(contentsOf: buf[0..<n])
    }
    #expect(platform.performed.isEmpty)
    #expect(String(decoding: got, as: UTF8.self).contains("q-click\",\"ok\":true") == false)
    #expect(String(decoding: got, as: UTF8.self).contains("q-observe\",\"ok\":true") == false)
}

// MARK: A4-SEC-02: event streams

private func streamClient(_ path: String, _ id: String, _ token: String) -> SocketRuntimeClient {
    SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"),
                        timeout: 1, credential: ClientCredential(clientId: id, token: token))
}

private func served(_ s: RuntimeService) throws -> (RuntimeServer, String, String) {
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let server = RuntimeServer(path: path, service: s)
    try server.start()
    return (server, path, dir)
}

/// Read frames until the stream closes (or `seconds` pass); their cursors.
private func drain(_ c: SocketRuntimeClient, seconds: Double = 5) throws -> (cursors: [Int], closed: Bool) {
    var cursors: [Int] = []
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        switch try c.nextEvent() {
        case let .frame(f): cursors.append(f["cursor"]?.intValue ?? -1)
        case .idle: continue
        case .closed: return (cursors, true)
        }
    }
    return (cursors, false)
}

/// The owner's withdrawal races a stream of new events: after the call
/// returns, no event created after it may arrive. Repeated to give the race
/// many chances.
@Test(arguments: ["revoke", "revokeGrant", "narrow"])
func secNoEventCreatedAfterTheWithdrawalIsSent(_ how: String) throws {
    for _ in 0..<15 {
        let platform = FakePlatform()
        let s = platformService(platform)
        let owner = handshaken(s)
        let (sc, id, token) = try pairedScene(s, platform)
        let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
        let (server, path, dir) = try served(s)
        defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
        let watcher = streamClient(path, id, token)
        defer { watcher.close() }
        _ = try watcher.subscribe(runId: nil, after: nil)
        // A steady stream of the app's own events.
        let stop = Box()
        Thread {
            var i = 0
            while stop.response == nil {
                _ = s.runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string("burst-\(i)"))]))
                i += 1
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }.start()
        Thread.sleep(forTimeInterval: 0.05)
        let params: String
        switch how {
        case "revoke": params = #"{"clientId":"\#(id)"}"#
        case "revokeGrant": params = #"{"clientId":"\#(id)"}"#
        default: params = #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":["created"]}"#
        }
        let method = how == "revoke" ? "hub.clients.revoke" : how == "revokeGrant" ? "hub.grants.revoke" : "hub.grants.set"
        #expect(data(call(s, owner, method, params: params)) != nil)
        // Every event from here on was created after the withdrawal.
        let boundary = s.runs.eventCursorRange().latest
        Thread.sleep(forTimeInterval: 0.05)
        stop.response = .success("x", .null)
        let (cursors, closed) = try drain(watcher)
        #expect(closed, "\(how): the stream closes")
        #expect(cursors.allSatisfy { $0 <= boundary }, "\(how): an event after the withdrawal was sent (boundary \(boundary), got \(cursors.max() ?? 0))")
    }
}

/// The exact race, held open: the stream passed its access check, then the
/// owner revokes and the Run's stop writes new events, then the stream
/// fetches them. None of them may be sent.
@Test(arguments: ["revoke", "revokeGrant", "narrow"])
func secTheCheckThenSendRaceSendsNothingAfterTheWithdrawal(_ how: String) throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, token) = try pairedScene(s, platform)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let (server, path, dir) = try served(s)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    let armed = Box()
    s.pushCheckpoint = { c in
        guard c.clientId == id, armed.response != nil else { return }
        armed.response = nil
        held.signal()
        release.wait()
    }
    let watcher = streamClient(path, id, token)
    defer { watcher.close() }
    _ = try watcher.subscribe(runId: nil, after: nil)
    armed.response = .success("x", .null)
    #expect(held.wait(timeout: .now() + 3) == .success, "the stream reached its checkpoint")
    let boundary = s.runs.eventCursorRange().latest
    let method = how == "revoke" ? "hub.clients.revoke" : how == "revokeGrant" ? "hub.grants.revoke" : "hub.grants.set"
    let params = how == "narrow" ? #"{"clientId":"\#(id)","capabilities":["observe"],"desktops":["created"]}"# : #"{"clientId":"\#(id)"}"#
    #expect(data(call(s, owner, method, params: params)) != nil)
    _ = s.runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string("after-withdrawal"))]))
    #expect(s.runs.eventCursorRange().latest > boundary)
    release.signal()
    let (cursors, closed) = try drain(watcher)
    #expect(closed)
    #expect(cursors.allSatisfy { $0 <= boundary }, "\(how): sent \(cursors), boundary \(boundary)")
}

@Test func secAStreamEndsWhenTheGrantExpires() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let (sc, id, token) = try pairedScene(s, platform)
    let runId = try #require(data(call(s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let (server, path, dir) = try served(s)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    var g = try #require(s.hub.grant(id))
    let expiry = Date().addingTimeInterval(0.6)
    g.expiresAt = Timestamp.string(expiry)
    try s.hub.putGrant(g)
    let watcher = streamClient(path, id, token)
    defer { watcher.close() }
    _ = try watcher.subscribe(runId: nil, after: nil)
    _ = s.runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string("before"))]))
    Thread.sleep(forTimeInterval: 0.8)
    let boundary = s.runs.eventCursorRange().latest
    _ = s.runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string("after"))]))
    let (cursors, closed) = try drain(watcher)
    #expect(closed)
    #expect(cursors.allSatisfy { $0 <= boundary }, "an event created after the expiry was sent")
    #expect(s.hub.auditEvents().contains { $0["method"]?.stringValue == "events.subscribe" && $0["reason"]?.stringValue == "grant_expired" })
}

@Test func aWidenedGrantKeepsTheConnections() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let owner = handshaken(s)
    let (sc, id, _) = try pairedScene(s, platform)
    #expect(data(call(s, owner, "hub.grants.set", params: #"{"clientId":"\#(id)","capabilities":["observe","act","desktop.manage","run","unit.run"],"desktops":["created"],"apps":["com.apple.calculator"],"durationSeconds":7200}"#)) != nil)
    #expect(sc.c.cutReason == nil)
    #expect(data(act(sc, clickContinue)) != nil)
}
