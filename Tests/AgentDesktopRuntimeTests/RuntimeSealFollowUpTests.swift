@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Follow-ups of the #145 review (2ndscreen-b9): a window reaching past the
// screen edge, and a launch that returns a process that was already running.

@Test func aWindowPastTheScreenEdgeKeepsItsOwnOriginAndScale() throws {
    let sc = try scene()
    let screen = try #require(sc.s.desktops.find(sc.desktop)?.screen)
    // The user drags the bound window half past the left edge.
    sc.platform.lock.withLock {
        sc.platform.windows[101] = sc.platform.windows[101]!.map { w in
            var w = w
            w.frame = AgentDesktopProtocol.Rect(x: screen.frame.x - 100, y: 100, width: 400, height: 300)
            return w
        }
    }
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let image = try #require(o["image"])
    // The engine renders the whole window: the image is 800x600 at scale 2
    // with the window's own origin, not a frame cut at the edge.
    #expect(image["width"]?.intValue == 800)
    #expect(image["transform"]?["originX"]?.doubleValue == screen.frame.x - 100)
    #expect(image["transform"]?["scale"]?.doubleValue == 2)
    let snap = try #require(o["snapshotId"]?.stringValue)
    // A point of the part past the edge is refused, nothing sent.
    let off = act(sc, #"{"kind":"click","target":{"imagePoint":{"x":100,"y":100}}}"#, snapshot: snap)
    #expect(code(off) == "invalid_target")
    #expect(failure(off)?.notSent == true)
    #expect(sc.platform.lock.withLock { sc.platform.performed.isEmpty })
    // A point on the screen lands where the image shows it.
    #expect(data(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":400,"y":100}}}"#, snapshot: snap)) != nil)
    let sent = try #require(sc.platform.lock.withLock { sc.platform.performed.last?.point })
    #expect(sent.x == screen.frame.x + 100 && sent.y == 150)
}

@Test func aNegativeImagePointIsRefused() throws {
    let sc = try scene()
    // The schema refuses it first; the Runtime's own check stays behind it.
    let r = act(sc, #"{"kind":"click","target":{"imagePoint":{"x":-1,"y":5}}}"#)
    #expect(code(r) == "schema_invalid")
    #expect(sc.platform.lock.withLock { sc.platform.performed.isEmpty })
}

@Test func aRefusedLaunchOwnsNothingAndMovesNothing() throws {
    let platform = FakePlatform()
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: platform)
    let c = handshaken(s)
    let d = try created(s, c)
    // The engine found the "new instance" was the user's running app (pid 101).
    let r = call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.example.single-instance","newInstance":true}"#)
    #expect(code(r) != nil, "refused")
    #expect(try #require(s.desktops.find(d)).launched.isEmpty, "nothing is recorded as launched here")
    #expect(!platform.calls.contains { $0.hasPrefix("move") }, "no window moved")
    // So the user's app stays unbindable.
    let bind = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    #expect(failure(bind)?.details?["reason"]?.stringValue == "bind_requires_grant")
    #expect(!platform.calls.contains { $0.hasPrefix("move") })
}
