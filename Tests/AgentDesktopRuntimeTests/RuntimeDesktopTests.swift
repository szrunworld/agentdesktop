import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// PR2-1: Desktop lifecycle, placement, binding, sessions, observation and
// the request ledger, against a scripted platform.

func call(_ s: RuntimeService, _ c: ConnectionState, _ method: String, id: String = RuntimeRequest.newId(),
          params: String = "{}", context: String? = nil) -> RuntimeResponse {
    let ctx = context.map { #","context":\#($0)"# } ?? ""
    return answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(id)","method":"\#(method)"\#(ctx),"params":\#(params)}"#, c)
}

func created(_ s: RuntimeService, _ c: ConnectionState, name: String? = nil) throws -> String {
    let p = name.map { #"{"name":"\#($0)"}"# } ?? "{}"
    return try #require(data(call(s, c, "desktop.create", params: p))?["desktopId"]?.stringValue)
}

@Test func createListShowAndCount() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"name":"工作区","width":1280,"height":800}"#)))
    #expect(contract.validate(d, "Desktop").isEmpty, "\(d.encoded())")
    #expect(d["name"]?.stringValue == "工作区")
    #expect(d["binding"] == .null)
    let id = try #require(d["desktopId"]?.stringValue)
    #expect(platform.calls == ["create \(id)"])
    #expect(data(call(s, c, "desktop.list"))?["desktops"]?.arrayValue?.count == 1)
    #expect(data(call(s, c, "desktop.show", params: #"{"desktopId":"\#(id)"}"#))?["desktopId"]?.stringValue == id)
    #expect(data(call(s, c, "runtime.status"))?["desktops"]?.intValue == 1)
    #expect(code(call(s, c, "desktop.create", params: #"{"name":"工作区"}"#)) == "conflict")
}

@Test func theSameRequestIdRunsOnceAndOtherContentIsAConflict() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let first = try #require(data(call(s, c, "desktop.create", id: "create-1", params: #"{"name":"a"}"#)))
    // A retry, e.g. after a lost reply, from another connection.
    let again = try #require(data(call(s, handshaken(s), "desktop.create", id: "create-1", params: #"{"name":"a"}"#)))
    #expect(again == first)
    #expect(platform.calls.filter { $0.hasPrefix("create") }.count == 1)
    #expect(code(call(s, c, "desktop.create", id: "create-1", params: #"{"name":"b"}"#)) == "idempotency_conflict")
    let record = try #require(data(call(s, c, "request.show", params: #"{"requestId":"create-1"}"#)))
    #expect(contract.validate(record, "RequestRecord").isEmpty)
    #expect(record["state"]?.stringValue == "completed")
    #expect(record["outcome"]?["data"]?["desktopId"] == first["desktopId"])
    // A failed write is recorded as failed and replays its error.
    #expect(code(call(s, c, "desktop.destroy", id: "destroy-x", params: #"{"desktopId":"d_nope"}"#)) == "not_found")
    #expect(code(call(s, c, "desktop.destroy", id: "destroy-x", params: #"{"desktopId":"d_nope"}"#)) == "not_found")
    #expect(data(call(s, c, "request.show", params: #"{"requestId":"destroy-x"}"#))?["state"]?.stringValue == "failed")
    #expect(code(call(s, c, "request.show", params: #"{"requestId":"never"}"#)) == "not_found")
}

@Test func reorderedKeysAreTheSameRequest() throws {
    let s = platformService()
    let c = handshaken(s)
    let a = data(call(s, c, "desktop.create", id: "k1", params: #"{"name":"x","width":1280,"height":800}"#))
    let b = data(call(s, c, "desktop.create", id: "k1", params: #"{"height":800,"width":1280,"name":"x"}"#))
    #expect(a != nil && a == b)
}

@Test func aWriteInFlightWhenTheHostStoppedIsUnknownAfterRestart() throws {
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/requests.sqlite"
    do {
        let ledger = try RequestLedger(path: path)
        let r = RuntimeRequest(requestId: "act-9", method: "desktop.create", params: .obj([]))
        #expect(try ledger.begin(caller: getuid(), r) == .fresh)
        // The host dies here: no finish.
    }
    var st = stat()
    #expect(stat(path, &st) == 0 && st.st_mode & 0o777 == 0o600)
    let reopened = try RequestLedger(path: path)
    let s = platformService(ledger: reopened)
    let c = handshaken(s)
    #expect(data(call(s, c, "request.show", params: #"{"requestId":"act-9"}"#))?["state"]?.stringValue == "unknown")
    // Retrying never runs it: the outcome stays unknown.
    #expect(code(call(s, c, "desktop.create", id: "act-9")) == "request_acceptance_unknown")
    #expect(s.desktops.count == 0)
}

@Test func destroyWaitsForSessionsToClose() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let id = try created(s, c)
    let session = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(id)"}"#)))
    #expect(contract.validate(session, "Session").isEmpty)
    let sid = try #require(session["sessionId"]?.stringValue)
    #expect(code(call(s, c, "desktop.destroy", params: #"{"desktopId":"\#(id)"}"#)) == "conflict")
    #expect(data(call(s, c, "session.close", params: #"{"sessionId":"\#(sid)"}"#))?["state"]?.stringValue == "closed")
    let gone = try #require(data(call(s, c, "desktop.destroy", params: #"{"desktopId":"\#(id)"}"#)))
    #expect(contract.validate(gone, "DestroyResult").isEmpty)
    #expect(platform.calls.last == "destroy \(id)")
    #expect(code(call(s, c, "desktop.show", params: #"{"desktopId":"\#(id)"}"#)) == "not_found")
    #expect(code(call(s, c, "observe", context: #"{"desktopId":"\#(id)"}"#)) == "not_found")
}

@Test func launchPlacesTheAppAndReportsItsProcess() throws {
    let s = platformService()
    let c = handshaken(s)
    let id = try created(s, c)
    let r = try #require(data(call(s, c, "app.launch", params: #"{"desktopId":"\#(id)","bundleId":"com.apple.Notes"}"#)))
    #expect(contract.validate(r, "LaunchResult").isEmpty, "\(r.encoded())")
    #expect(r["process"]?["pid"]?.intValue == 303)
    #expect(r["process"]?["startedAt"]?.stringValue != nil)
    #expect(code(call(s, c, "app.launch", params: #"{"desktopId":"\#(id)","bundleId":"com.example.missing"}"#)) == "execution_failed")
    #expect(code(call(s, c, "app.launch", params: #"{"desktopId":"\#(id)","bundleId":"a","path":"/b"}"#)) == "schema_invalid")
    // Destroying the Desktop quits what was launched there, not bound apps.
    let platform = s.platform as! FakePlatform
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(id)","pid":101}"#)
    let gone = try #require(data(call(s, c, "desktop.destroy", params: #"{"desktopId":"\#(id)"}"#)))
    #expect(gone["quitApps"]?.arrayValue?.compactMap { $0["pid"]?.intValue } == [303])
    #expect(platform.quit == [303])
}

@Test func bindObserveAndTheGenerationsThatMakeSnapshotsStale() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let id = try created(s, c)
    let screen = try #require(s.desktops.find(id)?.screen)

    // Unbound: a screenshot, no target, no elements.
    let bare = try #require(data(call(s, c, "observe", context: #"{"desktopId":"\#(id)"}"#)))
    #expect(contract.validate(bare, "Observation").isEmpty, "\(bare.encoded())")
    #expect(bare["target"] == .null)
    #expect(bare["elements"] == .array([]))

    let bound = try #require(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(id)","pid":101}"#)))
    #expect(bound["binding"]?["generation"]?.intValue == 1)
    #expect(bound["binding"]?["windowId"]?.intValue == 11)
    #expect(platform.calls.contains("move 101/* to \(id)"))

    let o = try #require(data(call(s, c, "observe", context: #"{"desktopId":"\#(id)"}"#)))
    #expect(contract.validate(o, "Observation").isEmpty, "\(o.encoded())")
    #expect(o["target"]?["generation"]?.intValue == 1)
    let els = o["elements"]?.arrayValue ?? []
    #expect(els.compactMap { $0["id"]?.stringValue } == ["el_0", "el_1"])
    #expect(els.first?["label"]?.stringValue == "继续")
    let image = try #require(o["image"])
    #expect(image["width"]?.intValue == 2560)
    #expect(image["transform"]?["scale"]?.doubleValue == 2)
    #expect(image["transform"]?["originX"]?.doubleValue == screen.frame.x)
    #expect(s.artifacts.file(of: try #require(image["artifactId"]?.stringValue)) != nil)
    let snap = try #require(o["snapshotId"]?.stringValue)
    #expect(s.observations.isLatestElementRead(snap, desktopId: id))

    // Rebinding moves the generation on; unbinding too.
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(id)","pid":101,"windowId":11}"#))?["binding"]?["generation"]?.intValue == 2)
    let unbound = try #require(data(call(s, c, "window.unbind", params: #"{"desktopId":"\#(id)"}"#)))
    #expect(unbound["binding"] == .null)
    #expect(s.desktops.find(id)?.generation == 3)
    #expect(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(id)","pid":999}"#)) == "not_found")
}

@Test func aBoundWindowThatLeftOrAProcessThatRestartedIsStale() throws {
    let platform = FakePlatform()
    var backend = FixedBackend()
    let s1 = platformService(platform, backend: backend)
    let c1 = handshaken(s1)
    let id = try created(s1, c1)
    _ = call(s1, c1, "window.bind", params: #"{"desktopId":"\#(id)","pid":101}"#)
    platform.dropWindow(11)
    #expect(code(call(s1, c1, "observe", context: #"{"desktopId":"\#(id)"}"#)) == "stale_observation")

    let platform2 = FakePlatform()
    backend.restarted = []
    let s2 = platformService(platform2, backend: backend)
    let c2 = handshaken(s2)
    let id2 = try created(s2, c2)
    _ = call(s2, c2, "window.bind", params: #"{"desktopId":"\#(id2)","pid":101}"#)
    // Same service, but the process behind pid 101 is now another launch.
    let restartedService = RuntimeService(identity: s2.identity, backend: {
        var b = backend; b.restarted = [101]; return b }(), platform: platform2, desktops: s2.desktops)
    let c3 = handshaken(restartedService)
    #expect(code(call(restartedService, c3, "observe", context: #"{"desktopId":"\#(id2)"}"#)) == "stale_observation")
}

@Test func observeNeedsATargetAndPermissions() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    #expect(code(call(s, c, "observe")) == "schema_invalid")
    let id = try created(s, c)
    platform.screenRecordingGranted = false
    #expect(code(call(s, c, "observe", context: #"{"desktopId":"\#(id)"}"#)) == "permission_denied")
    // Without the screenshot the observation still works.
    #expect(data(call(s, c, "observe", params: #"{"screenshot":false}"#, context: #"{"desktopId":"\#(id)"}"#))?["image"] == .null)
}

@Test func sessionsBelongToTheirCaller() throws {
    let s = platformService()
    let c = handshaken(s)
    let id = try created(s, c)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(id)"}"#))?["sessionId"]?.stringValue)
    let o = data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#))
    #expect(o?["sessionId"]?.stringValue == sid)
    #expect(o?["desktopId"]?.stringValue == id)
    let stranger = ConnectionState(peerUID: getuid() + 1)
    _ = answer(s, handshakeLine, stranger)
    #expect(code(call(s, stranger, "session.show", params: #"{"sessionId":"\#(sid)"}"#)) == "not_found")
    #expect(code(call(s, stranger, "observe", context: #"{"sessionId":"\#(sid)"}"#)) == "not_found")
    #expect(code(call(s, c, "observe", context: #"{"sessionId":"\#(sid)","desktopId":"d_other"}"#)) == "schema_invalid")
    _ = call(s, c, "session.close", params: #"{"sessionId":"\#(sid)"}"#)
    #expect(code(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)) == "conflict")
}

@Test func withAPlatformEveryMethodIsOffered() throws {
    let s = platformService()
    let d = try #require(data(call(s, handshaken(s), "runtime.capabilities")))
    let methods = d["interface"]?["methods"]?.arrayValue?.compactMap { $0["method"]?.stringValue } ?? []
    #expect(Set(methods) == Set(RuntimeMethod.allCases.map(\.rawValue)))
}

@Test func twoDesktopsWorkInParallel() async throws {
    let s = platformService()
    let c = handshaken(s)
    let a = try created(s, c)
    let b = try created(s, c)
    let results = await withTaskGroup(of: Bool.self) { g in
        for i in 0..<20 {
            let d = i % 2 == 0 ? a : b
            g.addTask { data(call(s, handshaken(s), "observe", context: #"{"desktopId":"\#(d)"}"#)) != nil }
        }
        var all: [Bool] = []
        for await r in g { all.append(r) }
        return all
    }
    #expect(results.count == 20 && results.allSatisfy { $0 })
}
