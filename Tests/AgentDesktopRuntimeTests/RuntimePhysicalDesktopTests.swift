@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// Physical Window Desktop: a Desktop that attaches one of the user's own
// displays and binds a window already there. Nothing is created, moved,
// launched, quit or destroyed; observation and input keep G0's rule that
// they reach the bound window or nothing.

/// A physical Desktop on display 1 with Calculator's window (pid 101,
/// window 11) bound where the user left it.
func physicalScene(_ platform: FakePlatform = FakePlatform(), backend: FixedBackend = FixedBackend()) throws -> Scene {
    platform.onScreen[11] = "physical-1"
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: backend, platform: platform)
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"name":"main","physical":{}}"#))?["desktopId"]?.stringValue)
    let bound = try #require(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)))
    #expect(bound["binding"]?["windowId"]?.intValue == 11)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let snap = try #require(data(call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#))?["snapshotId"]?.stringValue)
    return Scene(platform: platform, s: s, c: c, desktop: d, session: sid, snapshot: snap)
}

@Test func aPhysicalDesktopAttachesTheUsersDisplayAndCreatesNothing() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"name":"main","physical":{"displayId":1}}"#)))
    #expect(contract.validate(d, "Desktop").isEmpty, "\(d.encoded())")
    #expect(d["kind"]?.stringValue == "physical")
    #expect(d["screen"]?["displayId"]?.intValue == 1)
    #expect(platform.calls == ["attach 1"], "no virtual display is created")
    // The same display backs one Desktop only.
    #expect(code(call(s, c, "desktop.create", params: #"{"name":"again","physical":{"displayId":1}}"#)) == "conflict")
    // A display that is not one of the user's is not found; sizes are the display's.
    #expect(code(call(s, c, "desktop.create", params: #"{"name":"x","physical":{"displayId":42}}"#)) == "not_found")
    #expect(code(call(s, c, "desktop.create", params: #"{"name":"y","physical":{},"width":800,"height":600}"#)) == "invalid_argument")
    #expect(!platform.calls.contains { $0.hasPrefix("create") })
    // A virtual Desktop still says what it is.
    let v = try #require(data(call(s, c, "desktop.create", params: #"{"name":"virtual"}"#)))
    #expect(v["kind"]?.stringValue == "virtual")
}

@Test func bindingOnAPhysicalDesktopNeverMovesTheWindow() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"physical":{}}"#))?["desktopId"]?.stringValue)
    // Not on this display: refused, not moved over.
    #expect(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)) == "invalid_target")
    // Which window must be named: the window stays where the user put it.
    platform.onScreen[11] = "physical-1"
    #expect(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)) == "invalid_argument")
    let bound = try #require(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)))
    #expect(bound["binding"]?["generation"]?.intValue == 1)
    #expect(!platform.calls.contains { $0.hasPrefix("move") })
    #expect(platform.windows[101]?.first?.frame == Rect(x: 10, y: 20, width: 230, height: 400), "the frame is untouched")
}

@Test func aPhysicalDesktopWithoutABindingShowsNothingAndLaunchesNothing() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"physical":{}}"#))?["desktopId"]?.stringValue)
    let sid = try #require(data(call(s, c, "session.open", params: #"{"desktopId":"\#(d)"}"#))?["sessionId"]?.stringValue)
    let o = call(s, c, "observe", context: #"{"sessionId":"\#(sid)"}"#)
    #expect(code(o) == "invalid_target")
    #expect(!platform.calls.contains { $0.hasPrefix("screenshot") }, "the user's whole screen is never captured")
    let l = call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.apple.calculator"}"#)
    #expect(code(l) == "invalid_target")
    #expect(failure(l)?.notSent == true)
    #expect(!platform.calls.contains { $0.hasPrefix("launch") })
}

@Test func onAPhysicalDesktopTheImageAndTheInputAreTheBoundWindow() throws {
    let sc = try physicalScene()
    let o = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(contract.validate(o, "Observation").isEmpty, "\(o.encoded())")
    #expect(o["target"]?["windowId"]?.intValue == 11)
    // The capture is cut to the window's frame, never the whole display.
    #expect(sc.platform.calls.contains("screenshot physical-1 window"))
    #expect(!sc.platform.calls.contains("screenshot physical-1"))
    #expect(o["image"]?["transform"]?["originX"]?.doubleValue == 10)
    let a = act(sc, #"{"kind":"key","key":"return"}"#)
    #expect(data(a)?["delivery"]?.stringValue == "dispatched", "\(a)")
    #expect(sc.platform.performed.count == 1)
}

@Test func onAPhysicalDesktopACoveringWindowStopsObservationAndInput() throws {
    let sc = try physicalScene()
    // One of the user's windows slides over the bound one.
    sc.platform.inFront["physical-1"] = [PlatformWindow(windowId: 88, pid: 555, appName: "Safari", title: "用户的窗口",
                                                        frame: Rect(x: 100, y: 100, width: 600, height: 400))]
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(failure(o)?.details?["reason"]?.stringValue == "occluded")
    let a = act(sc, #"{"kind":"key","key":"return"}"#)
    #expect(code(a) == "stale_observation")
    #expect(failure(a)?.notSent == true)
    #expect(sc.platform.performed.isEmpty, "fail closed: nothing reaches any window")
}

@Test func onAPhysicalDesktopAClosedWindowFailsClosed() throws {
    let sc = try physicalScene()
    sc.platform.dropWindow(11)
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(failure(o)?.details?["reason"]?.stringValue == "window_gone")
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
}

@Test func destroyingAPhysicalDesktopLeavesTheDisplayAndTheAppsAlone() throws {
    let sc = try physicalScene()
    #expect(data(call(sc.s, sc.c, "session.close", params: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
    let unbound = try #require(data(call(sc.s, sc.c, "window.unbind", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(unbound["binding"] == .null)
    let gone = try #require(data(call(sc.s, sc.c, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)))
    #expect(gone["destroyed"]?.boolValue == true)
    #expect(gone["quitApps"]?.arrayValue?.isEmpty == true)
    #expect(!sc.platform.calls.contains { $0.hasPrefix("destroy") }, "the user's display is never destroyed")
    #expect(sc.platform.quit.isEmpty, "no app is quit")
    // The display can be attached again.
    #expect(data(call(sc.s, sc.c, "desktop.create", params: #"{"physical":{"displayId":1}}"#)) != nil)
}

@Test func oversizedPhysicalDisplayIDsAreRefusedBeforeThePlatform() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    #expect(code(call(s, c, "desktop.create", params: #"{"physical":{"displayId":4294967296}}"#)) == "schema_invalid")
    #expect(platform.calls.isEmpty)
    // The handler also refuses out-of-range values when called internally.
    let result = s.createDesktop(.obj([("physical", .obj([("displayId", .int(Int.max))]))]), c)
    if case let .failure(error) = result {
        #expect(error.code == "invalid_argument")
    } else {
        Issue.record("oversized physical display ID was accepted")
    }
    #expect(platform.calls.isEmpty)
}

// MARK: - Review round 1 (Kevin 2026-10-08): target loss, identity, display origin

@Test func displayOriginTrustsOnlyWhatTheHardwareVouchesFor() {
    // The built-in panel.
    #expect(DisplayOrigin.classify(builtin: true, vendor: 0x610, model: 0xa05e, hardwareVendors: []) == .physical)
    // An external display the I/O registry has a framebuffer for.
    #expect(DisplayOrigin.classify(builtin: false, vendor: 0x10ac, model: 0x4321, hardwareVendors: [0x10ac]) == .physical)
    // Any engine virtual display, whoever created it — even if it claims to be built in.
    if case .virtual = DisplayOrigin.classify(builtin: true, vendor: 0x3256, model: 2, hardwareVendors: [0x3256]) {} else { Issue.record("engine virtual display trusted") }
    // Unknown origin is refused, not assumed physical.
    if case .unconfirmed = DisplayOrigin.classify(builtin: false, vendor: 0x1234, model: 1, hardwareVendors: [0x10ac]) {} else { Issue.record("display without a framebuffer trusted") }
    if case .unconfirmed = DisplayOrigin.classify(builtin: false, vendor: 0, model: 0, hardwareVendors: [0]) {} else { Issue.record("vendorless display trusted") }
}

@Test func whenTheTargetIsLostTheRunStaysButEveryActIsRefusedAndRecorded() throws {
    let sc = try physicalScene()
    let run = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    sc.platform.dropWindow(11)
    let a = act(sc, #"{"kind":"key","key":"return"}"#, runId: run)
    #expect(code(a) == "stale_observation")
    #expect(failure(a)?.notSent == true)
    #expect(sc.platform.performed.isEmpty)
    // The Run is not ended by the loss; ADR v2.2 ends it (finish, cancel, connection loss).
    #expect(data(call(sc.s, sc.c, "run.show", params: #"{"runId":"\#(run)"}"#))?["phase"]?.stringValue == "running")
    // The existing catalog already says what happened: action.refused with the reason code.
    let events = try #require(data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(run)"}"#))?["events"]?.arrayValue)
    let refused = events.first { $0["type"]?.stringValue == "action.refused" }
    #expect(refused?["data"]?["reason"]?["code"]?.stringValue == "stale_observation")
    // A second attempt is refused the same way: nothing retries on its own.
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#, runId: run)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
    #expect(data(call(sc.s, sc.c, "run.finish", params: #"{"runId":"\#(run)","exitCode":1}"#)) != nil)
}

@Test func aReopenedWindowWithANewIdInheritsNothing() throws {
    let sc = try physicalScene()
    // The user closes the window and the app opens a new one in its place.
    sc.platform.windows[101] = [PlatformWindow(windowId: 19, pid: 101, appName: "Calculator", title: "Calculator",
                                               frame: Rect(x: 10, y: 20, width: 230, height: 400))]
    sc.platform.onScreen[11] = nil
    sc.platform.onScreen[19] = "physical-1"
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(o)?.details?["reason"]?.stringValue == "window_gone")
    // The old snapshot and the old binding do not reach the new window.
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
    // Only an explicit bind of the new window makes it the target (a new generation).
    let rebound = try #require(data(call(sc.s, sc.c, "window.bind", params: #"{"desktopId":"\#(sc.desktop)","pid":101,"windowId":19}"#)))
    #expect(rebound["binding"]?["generation"]?.intValue == 2)
}

@Test func aRecycledWindowIdOfAnotherProcessIsNotTheTarget() throws {
    let sc = try physicalScene()
    // Window 11 now belongs to another process (same number, other owner).
    sc.platform.windows[101] = []
    sc.platform.windows[555] = [PlatformWindow(windowId: 11, pid: 555, appName: "Other", title: "别的应用",
                                               frame: Rect(x: 10, y: 20, width: 230, height: 400))]
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
}

@Test func aWindowMovedToAnotherDisplayStopsObservationAndInput() throws {
    let sc = try physicalScene()
    sc.platform.onScreen[11] = "physical-2"
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(o)?.details?["reason"]?.stringValue == "window_gone")
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
}

@Test func aTargetLostWhileInputIsSentIsUnknownAndNeverRetried() throws {
    let sc = try physicalScene()
    let run = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    sc.platform.onPerform = { sc.platform.dropWindow(11) }
    let a = act(sc, #"{"kind":"key","key":"return"}"#, runId: run)
    #expect(code(a) == "action_delivery_unknown")
    #expect(failure(a)?.details?["receipt"]?["delivery"]?.stringValue == "unknown")
    sc.platform.onPerform = nil
    // The next input is stopped before dispatch; the unknown one is not repeated.
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#, runId: run)) == "stale_observation")
    #expect(sc.platform.performed.count == 1)
    let shown = try #require(data(call(sc.s, sc.c, "run.show", params: #"{"runId":"\#(run)"}"#)))
    #expect(shown["unknownActions"]?.intValue == 1)
}

@Test func destroyingAPhysicalDesktopLeavesOtherDesktopsAlone() throws {
    let sc = try physicalScene()
    let other = try #require(data(call(sc.s, sc.c, "desktop.create", params: #"{"name":"isolated"}"#))?["desktopId"]?.stringValue)
    _ = call(sc.s, sc.c, "session.close", params: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(data(call(sc.s, sc.c, "desktop.destroy", params: #"{"desktopId":"\#(sc.desktop)"}"#)) != nil)
    let left = data(call(sc.s, sc.c, "desktop.list"))?["desktops"]?.arrayValue ?? []
    #expect(left.map { $0["desktopId"]?.stringValue } == [other])
    #expect(!sc.platform.calls.contains { $0.hasPrefix("destroy") })
    #expect(sc.platform.quit.isEmpty)
}
