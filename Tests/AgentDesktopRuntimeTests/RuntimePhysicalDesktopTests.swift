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
    let s = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: backend, platform: platform); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    s.physicalDesktopsEnabled = true
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
    s.physicalDesktopsEnabled = true
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
    // Sizes are the display's: the contract refuses a size with physical.
    #expect(code(call(s, c, "desktop.create", params: #"{"name":"y","physical":{},"width":800,"height":600}"#)) == "schema_invalid")
    #expect(!platform.calls.contains { $0.hasPrefix("create") })
    // A virtual Desktop still says what it is.
    let v = try #require(data(call(s, c, "desktop.create", params: #"{"name":"virtual"}"#)))
    #expect(v["kind"]?.stringValue == "virtual")
}

@Test func bindingOnAPhysicalDesktopNeverMovesTheWindow() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    s.physicalDesktopsEnabled = true
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
    s.physicalDesktopsEnabled = true
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
    s.physicalDesktopsEnabled = true
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
    typealias D = DisplayOrigin.Display
    let builtin = D(id: 1, builtin: true, vendor: 0x610, model: 0xa05e)
    // The built-in panel uses up its own framebuffer: an external display copying Apple's vendor has none left.
    let copycat = D(id: 7, builtin: false, vendor: 0x610, model: 0x1234)
    var o = DisplayOrigin.classify([builtin, copycat], framebufferVendors: [0x610])
    #expect(o[1] == .physical)
    if case .unconfirmed = o[7] {} else { Issue.record("a vendor copied from the built-in panel was trusted") }
    // A real external display has its own framebuffer.
    let external = D(id: 3, builtin: false, vendor: 0x10ac, model: 0x4321)
    o = DisplayOrigin.classify([builtin, external], framebufferVendors: [0x610, 0x10ac])
    #expect(o[3] == .physical)
    // Two externals of one vendor need two framebuffers.
    let second = D(id: 4, builtin: false, vendor: 0x10ac, model: 0x4321)
    o = DisplayOrigin.classify([builtin, external, second], framebufferVendors: [0x610, 0x10ac])
    #expect(o[3] == .physical)
    if case .unconfirmed = o[4] {} else { Issue.record("one framebuffer vouched for two displays") }
    // Any engine virtual display, even one claiming to be built in, and a vendorless display.
    o = DisplayOrigin.classify([D(id: 9, builtin: true, vendor: 0x3256, model: 2), D(id: 10, builtin: false, vendor: 0, model: 0)],
                               framebufferVendors: [0x3256, 0])
    if case .virtual = o[9] {} else { Issue.record("engine virtual display trusted") }
    if case .unconfirmed = o[10] {} else { Issue.record("vendorless display trusted") }
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

@Test func physicalDesktopsAreRefusedToEveryCallerUntilGrantsExist() throws {
    let platform = FakePlatform()
    platform.onScreen[11] = "physical-1"
    let s = platformService(platform)
    let c = handshaken(s)
    let r = call(s, c, "desktop.create", params: #"{"name":"main","physical":{}}"#)
    #expect(code(r) == "permission_denied")
    #expect(failure(r)?.notSent == true)
    #expect(failure(r)?.details?["reason"]?.stringValue == "physical_desktop_requires_grant")
    #expect(platform.calls.isEmpty, "the display is not even looked up")
    #expect(data(call(s, c, "desktop.list"))?["desktops"]?.arrayValue?.isEmpty == true)
    // Virtual Desktops are unchanged.
    #expect(data(call(s, c, "desktop.create", params: #"{"name":"virtual"}"#))?["kind"]?.stringValue == "virtual")
}

// MARK: - #143: independent review fixes, on top of window grants (#205)

@Test func onAPhysicalDesktopANotificationOverTheWindowCoversIt() throws {
    let sc = try physicalScene()
    sc.platform.overlayWindows["physical-1"] = [PlatformWindow(windowId: 501, pid: 600, appName: "NotificationCenter", title: "新消息",
                                                               frame: Rect(x: 50, y: 30, width: 350, height: 80))]
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(o)?.details?["reason"]?.stringValue == "occluded")
    #expect(failure(o)?.details?["coveringWindowId"]?.intValue == 501)
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    #expect(sc.platform.performed.isEmpty)
    // The bound app's own sheet or popover covers it too: input to the process may land on it.
    sc.platform.overlayWindows["physical-1"] = [PlatformWindow(windowId: 502, pid: 101, appName: "Calculator", title: "",
                                                               frame: Rect(x: 50, y: 30, width: 150, height: 200))]
    #expect(failure(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?.details?["reason"]?.stringValue == "occluded")
    // Nothing over it: usable again.
    sc.platform.overlayWindows["physical-1"] = []
    #expect(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
    // Refusals name the covering window by number only, never its app.
    sc.platform.overlayWindows["physical-1"] = [PlatformWindow(windowId: 503, pid: 600, appName: "SecretApp", title: "机密",
                                                               frame: Rect(x: 50, y: 30, width: 150, height: 200))]
    let named = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(!(failure(named)?.message.contains("SecretApp") ?? true))
    #expect(!(failure(named)?.message.contains("机密") ?? true))
    #expect(failure(named)?.details?["coveringPid"] == nil)
}

@Test func overlaysOnlyCountOnAPhysicalDesktop() throws {
    // A virtual Desktop is the agent's own screen: high-layer windows of the
    // user's display are not over it, and the platform is not asked.
    let sc = try scene()
    sc.platform.overlayWindows[sc.platform.screens.keys.first ?? ""] = [PlatformWindow(windowId: 501, pid: 600, appName: "X", title: "",
                                                                                       frame: Rect(x: 0, y: 0, width: 5000, height: 5000))]
    #expect(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)) != nil)
}

@Test func whenTheUserChangesTheDisplayAPhysicalDesktopStops() throws {
    let sc = try physicalScene()
    // "More space": the same display, a different logical size.
    sc.platform.physicalDisplays[1] = ScreenHandle(name: "physical-1", displayId: 1, frame: Rect(x: 0, y: 0, width: 1800, height: 1169), hiDPI: true)
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(o)?.details?["reason"]?.stringValue == "display_changed")
    #expect(code(act(sc, #"{"kind":"key","key":"return"}"#)) == "stale_observation")
    // Unplugged.
    sc.platform.physicalDisplays[1] = nil
    #expect(failure(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?.details?["reason"]?.stringValue == "display_changed")
    #expect(sc.platform.performed.isEmpty)
}

@Test func onAPhysicalDesktopAnExitedProcessFailsClosed() throws {
    let backend = FixedBackend()
    let sc = try physicalScene(backend: backend)
    backend.opened.lock.withLock { _ = backend.opened.restarted.insert(101) }
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(code(o) == "stale_observation")
    #expect(failure(o)?.details?["reason"]?.stringValue == "process_exited")
    let a = act(sc, #"{"kind":"key","key":"return"}"#)
    #expect(code(a) == "stale_observation")
    #expect(failure(a)?.details?["reason"]?.stringValue == "process_exited")
    #expect(failure(a)?.notSent == true)
    #expect(sc.platform.performed.isEmpty)
}

@Test func idsOutsideTheirRangeAreRefusedNotACrash() throws {
    let platform = FakePlatform()
    platform.onScreen[11] = "physical-1"
    let s = platformService(platform)
    s.physicalDesktopsEnabled = true
    let c = handshaken(s)
    let d = try #require(data(call(s, c, "desktop.create", params: #"{"physical":{}}"#))?["desktopId"]?.stringValue)
    #expect(["invalid_argument", "schema_invalid"].contains(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":4294967296}"#))))
    #expect(["invalid_argument", "schema_invalid"].contains(code(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":2147483648,"windowId":11}"#))))
    #expect(data(call(s, c, "desktop.show", params: #"{"desktopId":"\#(d)"}"#))?["binding"] == .null)
}

@Test func twoConnectionsAttachingOneDisplayAtOnceGetOneDesktop() throws {
    let s = platformService(FakePlatform())
    s.physicalDesktopsEnabled = true
    let results = LockedStrings()
    DispatchQueue.concurrentPerform(iterations: 8) { i in
        let c = handshaken(s)
        results.append(code(call(s, c, "desktop.create", params: #"{"name":"race-\#(i)","physical":{"displayId":1}}"#)) ?? "ok")
    }
    #expect(results.values.filter { $0 == "ok" }.count == 1)
    #expect(results.values.filter { $0 == "conflict" }.count == 7)
}

final class LockedStrings: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func append(_ s: String) { lock.withLock { items.append(s) } }
    var values: [String] { lock.withLock { items } }
}

@Test func whatCountsAsAnOverlayOverTheUsersWindow() {
    let screen = Rect(x: 0, y: 0, width: 1512, height: 982)
    func covers(_ f: Rect, _ owner: String = "App") -> Bool {
        EnginePlatform.isCoveringOverlay(frame: f, owner: owner, screen: screen, menuBar: 37)
    }
    #expect(covers(Rect(x: 1150, y: 40, width: 350, height: 80), "NotificationCenter"), "a banner")
    #expect(covers(Rect(x: 200, y: 300, width: 220, height: 180), "Other"), "another app's menu")
    #expect(covers(Rect(x: 0, y: 0, width: 1512, height: 982), "WGestures"), "an unknown layer over the whole display: fail closed")
    #expect(covers(Rect(x: 0, y: 0, width: 1512, height: 982), "Window Server"), "a display-wide Window Server layer counts")
    #expect(!covers(Rect(x: 0, y: 0, width: 1512, height: 37), "Window Server"), "the menu bar")
    #expect(!covers(Rect(x: 1010, y: 0, width: 38, height: 37), "WeChat"), "a status item")
    #expect(!covers(Rect(x: 0, y: 0, width: 1512, height: 982), "Dock"), "the Dock's display-wide layer")
    #expect(covers(Rect(x: 600, y: 500, width: 240, height: 300), "Dock"), "a Dock menu or folder stack counts (Codex on 1994bca)")
    #expect(!covers(Rect(x: 0, y: 38, width: 1, height: 1), "Typeless"), "a 1×1 anchor")
    #expect(covers(Rect(x: 300, y: 200, width: 3, height: 400)), "a thin but long panel counts (Codex on 4952c9e)")
    #expect(covers(Rect(x: 300, y: 200, width: 400, height: 3)), "and lying down")
}

@Test func noPathCapturesTheUsersScreenOnAPhysicalDesktop() throws {
    // Every observation on a physical Desktop: window capture only, across a whole session.
    let sc = try physicalScene()
    sc.s.refusesScreenCaptureWithoutBinding = false   // even with the virtual-Desktop seal off
    for _ in 0..<3 { _ = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#) }
    _ = call(sc.s, sc.c, "observe", params: #"{"screenshot":false}"#, context: #"{"sessionId":"\#(sc.session)"}"#)
    sc.platform.dropWindow(11)
    _ = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    _ = call(sc.s, sc.c, "window.unbind", params: #"{"desktopId":"\#(sc.desktop)"}"#)
    _ = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(!sc.platform.calls.contains("screenshot physical-1"), "\(sc.platform.calls)")
    #expect(sc.platform.calls.filter { $0 == "screenshot physical-1 window" }.count == 4, "\(sc.platform.calls)")
}

@Test func theSealsStayAsTheProductShipsThem() {
    // As constructed, before any test helper flips a switch.
    let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                     endpoint: "/tmp/t.sock", buildSource: "unknown"),
                           backend: FixedBackend(), platform: FakePlatform())
    #expect(s.physicalDesktopsEnabled == false)
    #expect(s.bindsOnlyLaunchedProcesses == true)
    #expect(s.refusesScreenCaptureWithoutBinding == true)
}

@Test func aWaitOnAPhysicalDesktopStopsWhenTheDisplayChanges() throws {
    // Codex on 1994bca: every wait poll checks the display, not only observe and act.
    let sc = try physicalScene()
    sc.platform.physicalDisplays[1] = ScreenHandle(name: "physical-1", displayId: 1, frame: Rect(x: 0, y: 0, width: 1800, height: 1169), hiDPI: true)
    let w = call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"x"},"timeoutMs":300}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(w)?.details?["reason"]?.stringValue == "display_changed", "\(w.json.encoded())")
    // A display that changes between the read and the store is refused too.
    sc.platform.physicalDisplays[1] = ScreenHandle(name: "physical-1", displayId: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), hiDPI: true)
    let reads = sc.platform.calls.filter { $0.hasPrefix("elements") }.count
    sc.platform.onElements = { sc.platform.physicalDisplays[1] = nil }
    let w2 = call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"x"},"timeoutMs":300}"#,
                  context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(w2)?.details?["reason"]?.stringValue == "display_changed", "\(w2.json.encoded())")
    #expect(sc.platform.calls.filter { $0.hasPrefix("elements") }.count > reads, "the read happened; the store was refused")
}

@Test func aWaitOnAPhysicalDesktopStopsWhenSomethingCoversTheWindow() throws {
    // Codex on 4952c9e: wait polls check exposure like observe and act.
    let sc = try physicalScene()
    sc.platform.overlayWindows["physical-1"] = [PlatformWindow(windowId: 501, pid: 600, appName: "NotificationCenter", title: "",
                                                               frame: Rect(x: 50, y: 30, width: 350, height: 80))]
    let reads = sc.platform.calls.filter { $0.hasPrefix("elements") }.count
    let w = call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"x"},"timeoutMs":300}"#,
                 context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(w)?.details?["reason"]?.stringValue == "occluded", "\(w.json.encoded())")
    #expect(sc.platform.calls.filter { $0.hasPrefix("elements") }.count == reads, "nothing was read")
    // Something that appears during the read: the poll's result is not stored or answered.
    sc.platform.overlayWindows["physical-1"] = []
    sc.platform.onElements = {
        sc.platform.overlayWindows["physical-1"] = [PlatformWindow(windowId: 502, pid: 600, appName: "X", title: "",
                                                                   frame: Rect(x: 50, y: 30, width: 350, height: 80))]
    }
    let w2 = call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","label":"x"},"timeoutMs":300}"#,
                  context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(failure(w2)?.details?["reason"]?.stringValue == "occluded", "\(w2.json.encoded())")
}
