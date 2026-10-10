import AgentDesktopProtocol
import AgentDesktopClient
import Foundation
import Testing
@testable import AgentDesktopRuntime

@Test func observationSubscriptionIsThrottledAndDoesNotReplaceActionSnapshots() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let viewer = handshaken(sc.s)
    let start = ContinuousClock().now
    sc.s.observationStreamNow = { start }
    let reply = try #require(data(call(sc.s, viewer, "observe.subscribe", params: #"{"fps":2,"maxWidth":200}"#,
                                     context: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(contract.validate(reply, "ObservationSubscription").isEmpty)
    let old = try #require(sc.s.observations.find(sc.snapshot))
    let frames = sc.s.pendingEventFrames(viewer)
    let frame = try #require(frames.first)
    #expect(contract.validate(frame, "ObservationFrame").isEmpty)
    #expect(frame["status"]?.stringValue == "ready")
    #expect(frame["frame"]?["snapshotId"] == nil)
    #expect(frame["frame"]?["image"]?["width"]?.intValue == 200)
    #expect(frame["frame"]?["image"]?["transient"]?.boolValue == true)
    #expect(sc.s.pendingEventFrames(viewer).isEmpty)
    #expect(sc.s.observations.find(sc.snapshot)?.capturedAt == old.capturedAt)
    #expect(sc.s.observations.isLatestElementRead(sc.snapshot, desktopId: sc.desktop))
    sc.s.observationStreamNow = { start.advanced(by: .milliseconds(500)) }
    #expect(sc.s.pendingEventFrames(viewer).first?["sequence"]?.intValue == 2)
    #expect(data(call(sc.s, viewer, "observe.unsubscribe"))?["subscribed"]?.boolValue == false)
    #expect(!viewer.isSubscribed && sc.s.pendingEventFrames(viewer).isEmpty)
}

@Test func watchingDoesNotTakeOrReleaseTheExecutingRunsLease() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let control = handshaken(sc.s)
    let started = try #require(data(call(sc.s, control, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let run = try #require(started["run"]?["runId"]?.stringValue)
    let before = try #require(sc.s.runs.find(run))
    let viewer = handshaken(sc.s)
    #expect(data(call(sc.s, viewer, "observe.subscribe", context: #"{"desktopId":"\#(sc.desktop)"}"#)) != nil)
    #expect(sc.s.pendingEventFrames(viewer).first?["status"]?.stringValue == "ready")
    #expect(sc.s.execution.holder(of: sc.desktop) == run)
    #expect(sc.s.runs.find(run)?.quiescence == before.quiescence)
    #expect(data(act(sc, clickContinue, runId: run, on: control)) != nil)
    sc.s.connectionClosed(viewer)
    #expect(sc.s.execution.holder(of: sc.desktop) == run)
    #expect(sc.s.runs.find(run)?.phase == .running)
}

@Test func aControlConnectionCannotBecomeAnObservationStream() throws {
    let sc = try scene()
    let control = handshaken(sc.s)
    #expect(data(call(sc.s, control, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
    let r = call(sc.s, control, "observe.subscribe", context: #"{"desktopId":"\#(sc.desktop)"}"#)
    #expect(code(r) == "conflict")
    #expect(!control.isSubscribed)
}

@Test func anOccludedLiveFrameIsExplicitlyPausedWithNoInput() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let viewer = handshaken(sc.s)
    #expect(data(call(sc.s, viewer, "observe.subscribe", context: #"{"desktopId":"\#(sc.desktop)"}"#)) != nil)
    sc.platform.inFront[sc.s.desktops.find(sc.desktop)!.screen.name] = [coveringWindow]
    let frame = try #require(sc.s.pendingEventFrames(viewer).first)
    #expect(frame["status"]?.stringValue == "paused")
    #expect(frame["error"]?["code"]?.stringValue == "stale_observation")
    #expect(frame["frame"] == nil)
    #expect(sc.platform.performed.isEmpty)
}

@Test func observationFramesTravelOverTheSocketAndUnsubscribeRestoresRequests() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let dir = try socketDirectory()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/view.sock"
    let server = RuntimeServer(path: path, service: sc.s)
    try server.start()
    defer { server.stop() }
    let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option),
                                     info: ClientInfo(name: "view", version: "1"), timeout: 5, credential: testOwner)
    defer { client.close() }
    let request = RuntimeRequest(requestId: "view-start", method: "observe.subscribe",
                                 context: RequestContext(desktopId: sc.desktop), params: .obj([("maxWidth", .int(200))]))
    #expect(try client.call(request)["subscribed"]?.boolValue == true)
    guard case let .frame(frame) = try client.nextEvent() else { Issue.record("missing pushed image frame"); return }
    #expect(frame["status"]?.stringValue == "ready")
    #expect(contract.validate(frame, "ObservationFrame").isEmpty)
    #expect(try client.call(RuntimeRequest(.observeUnsubscribe))["subscribed"]?.boolValue == false)
    #expect(try client.call(RuntimeRequest(.status))["state"]?.stringValue == "running")
}

@Test func frameSubscriptionRequiresObserveAndRechecksDesktopGrant() throws {
    let sc = try scene()
    sc.platform.realImages = true
    let (denied, _, _) = try pairedClient(sc.s, capabilities: ["run"], desktops: [sc.desktop], apps: ["com.apple.calculator"])
    #expect(code(call(sc.s, denied, "observe.subscribe", context: #"{"desktopId":"\#(sc.desktop)"}"#)) == "grant_missing")
    let (viewer, id, _) = try pairedClient(sc.s, capabilities: ["observe"], desktops: [sc.desktop], apps: ["com.apple.calculator"])
    #expect(data(call(sc.s, viewer, "observe.subscribe", context: #"{"desktopId":"\#(sc.desktop)"}"#)) != nil)
    _ = call(sc.s, sc.c, "hub.clients.revoke", params: #"{"clientId":"\#(id)"}"#)
    #expect(sc.s.subscriptionRevoked(viewer))
    #expect(!viewer.isSubscribed && sc.s.pendingEventFrames(viewer).isEmpty)
}
