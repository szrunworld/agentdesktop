import AgentDesktopClient
@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// events.subscribe (runtime-api-v1-freeze §4): pushed frames on the same
// connection, cursors to resume, visibility by principal, and a stream that
// is never a control connection.

private func served(_ sc: Scene) throws -> (server: RuntimeServer, path: String, dir: String) {
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let server = RuntimeServer(path: path, service: sc.s)
    try server.start()
    return (server, path, dir)
}

private func client(_ path: String) -> SocketRuntimeClient {
    SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"), timeout: 5)
}

/// Frames until `count` arrived or the stream went quiet for a few seconds.
private func frames(_ c: SocketRuntimeClient, count: Int) throws -> [JSONValue] {
    var got: [JSONValue] = []
    var idle = 0
    while got.count < count, idle < 5 {
        switch try c.nextEvent() {
        case let .frame(f): got.append(f)
        case .idle: idle += 1
        case .closed: return got
        }
    }
    return got
}

@Test func aGlobalSubscriptionPushesEveryRunsEventsInOrderAndRefusesOtherRequests() throws {
    let sc = try scene()
    let (server, path, dir) = try served(sc)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let watcher = client(path)
    defer { watcher.close() }
    let reply = try watcher.subscribe(runId: nil, after: nil)
    #expect(reply["subscribed"]?.boolValue == true)

    let run = try durable(sc)
    _ = sc.s.execution.stop(runId: run.runId, reason: "stopped", endAs: .cancelled)
    let got = try frames(watcher, count: 3)
    #expect(got.count >= 3)
    for f in got { #expect(contract.validate(f, "EventFrame").isEmpty, "\(f.encoded())") }
    #expect(got.first?["event"]?["type"]?.stringValue == "run.started")
    #expect(got.allSatisfy { $0["event"]?["runId"]?.stringValue == run.runId })
    let cursors = got.compactMap { $0["cursor"]?.intValue }
    #expect(cursors == cursors.sorted() && Set(cursors).count == cursors.count)

    // Requests other than events.unsubscribe are refused on a stream.
    #expect(throws: RuntimeError.self) { try watcher.call(RuntimeRequest(.status)) }
    do { _ = try watcher.call(RuntimeRequest(.status)) } catch let e as RuntimeError {
        #expect(e.code == "conflict")
        #expect(e.details?["reason"]?.stringValue == "subscribed")
    }
    // Unsubscribing hands the connection back to requests.
    let off = try watcher.call(RuntimeRequest(.eventsUnsubscribe))
    #expect(off["subscribed"]?.boolValue == false)
    #expect(try watcher.call(RuntimeRequest(.status))["state"]?.stringValue == "running")

    // Resuming from the last cursor misses nothing and repeats nothing.
    let again = client(path)
    defer { again.close() }
    _ = try again.subscribe(runId: nil, after: cursors[0])
    let rest = try frames(again, count: got.count - 1)
    #expect(rest.map { $0["cursor"]?.intValue } == Array(cursors.dropFirst()).map { Optional($0) })
}

@Test func aRunStreamStartsAtTheBeginningAndClosesAfterTheRunEnds() throws {
    let sc = try scene()
    let (server, path, dir) = try served(sc)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let run = try durable(sc)
    let watcher = client(path)
    defer { watcher.close() }
    _ = try watcher.subscribe(runId: run.runId, after: nil)
    let first = try frames(watcher, count: 1)
    #expect(first.first?["event"]?["sequence"]?.intValue == 1)
    #expect(first.first?["cursor"]?.intValue == 1)
    _ = sc.s.execution.stop(runId: run.runId, reason: "stopped", endAs: .cancelled)
    var types: [String] = []
    var closed = false
    for _ in 0..<20 {
        switch try watcher.nextEvent() {
        case let .frame(f): types.append(f["event"]?["type"]?.stringValue ?? "")
        case .idle: continue
        case .closed: closed = true
        }
        if closed { break }
    }
    #expect(closed)
    #expect(types.last == "run.ended")
    // The stream was a view: the Run's record is what the stop made it.
    #expect(sc.s.runs.find(run.runId)?.outcome == .cancelled)
}

@Test func closingAStreamStopsNoRunAndAControlConnectionCannotBecomeOne() throws {
    let sc = try scene()
    let (server, path, dir) = try served(sc)
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    // A Delegated Run owned by a socket connection.
    let controller = client(path)
    defer { controller.close() }
    var start = RuntimeRequest(.runStart)
    start.context = RequestContext(sessionId: sc.session)
    let runId = try #require(try controller.call(start)["run"]?["runId"]?.stringValue)
    do { _ = try controller.subscribe(runId: nil, after: nil) } catch let e as RuntimeError {
        #expect(e.code == "conflict")
        #expect(e.details?["reason"]?.stringValue == "control_connection")
    }
    // A watcher of that Run comes and goes; the Run goes on.
    let watcher = client(path)
    _ = try watcher.subscribe(runId: runId, after: 0)
    #expect(try frames(watcher, count: 1).count == 1)
    watcher.close()
    Thread.sleep(forTimeInterval: 0.5)
    #expect(sc.s.runs.find(runId)?.phase == .running)
}

@Test func aPrincipalSeesOnlyItsOwnRunsAndAStaleCursorIsSaidSo() throws {
    let sc = try scene()
    let other = handshaken(sc.s)
    other.clientId = "app:someone-else"
    #expect(data(call(sc.s, other, "events.subscribe")) != nil)
    let run = try durable(sc)
    _ = sc.s.execution.stop(runId: run.runId, reason: "stopped", endAs: .cancelled)
    #expect(sc.s.pendingEventFrames(other).isEmpty)
    // Someone else's Run cannot be subscribed to either.
    let third = handshaken(sc.s)
    third.clientId = "app:someone-else"
    #expect(code(call(sc.s, third, "events.subscribe", params: #"{"runId":"\#(run.runId)"}"#)) == "not_found")
    // The owner sees it; a cursor from beyond the store is expired.
    let owner = handshaken(sc.s)
    let latest = sc.s.runs.eventCursorRange().latest
    #expect(code(call(sc.s, owner, "events.subscribe", params: #"{"after":\#(latest + 5)}"#)) == "events_cursor_expired")
    #expect(data(call(sc.s, owner, "events.subscribe", params: #"{"after":0}"#)) != nil)
    #expect(sc.s.pendingEventFrames(owner).count >= 3)
}
