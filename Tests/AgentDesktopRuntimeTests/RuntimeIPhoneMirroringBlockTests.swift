@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// #139: iPhone Mirroring is refused by the general desktop methods for
// every caller until the iPhone device session is accepted.

func mirroring(pid: Int32) -> AppSummary {
    AppSummary(process: ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.ScreenContinuity",
               name: "iPhone Mirroring", active: false, hidden: false)
}

func refusedAsMirroring(_ r: RuntimeResponse) -> Bool {
    code(r) == "permission_denied" && failure(r)?.details?["reason"]?.stringValue == "iphone_mirroring_blocked"
}

@Test func iPhoneMirroringIsNotLaunchedByBundleId() throws {
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try created(s, c)
    for id in ["com.apple.ScreenContinuity", "COM.APPLE.SCREENCONTINUITY"] {
        let r = call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"\#(id)"}"#)
        #expect(refusedAsMirroring(r))
        #expect(failure(r)?.notSent == true)
    }
    #expect(!platform.calls.contains { $0.hasPrefix("launch") })
}

@Test func iPhoneMirroringIsNotLaunchedByPath() throws {
    let app = FileManager.default.temporaryDirectory.appendingPathComponent("t139-\(UUID().uuidString)/iPhone Mirroring.app")
    try FileManager.default.createDirectory(at: app.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: app.deletingLastPathComponent()) }
    let plist: [String: Any] = ["CFBundleIdentifier": "com.apple.ScreenContinuity", "CFBundleExecutable": "iPhone Mirroring",
                                "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: app.appendingPathComponent("Contents/Info.plist"))
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try created(s, c)
    // The bundle, and the executable inside it.
    for path in [app.path, app.appendingPathComponent("Contents/MacOS/iPhone Mirroring").path] {
        let r = call(s, c, "app.launch", params: JSONValue.obj([("desktopId", .string(d)), ("path", .string(path))]).encoded())
        #expect(refusedAsMirroring(r), "\(path)")
    }
    #expect(!platform.calls.contains { $0.hasPrefix("launch") })
}

/// A launch of something else that comes up as iPhone Mirroring (pid 303).
func launchTurningIntoMirroring(before: Bool = false, startedAt: String?) throws
    -> (platform: FakePlatform, s: RuntimeService, d: String, r: RuntimeResponse) {
    let platform = FakePlatform()
    let backend = FixedBackend()
    if before { backend.opened.apps = [mirroring(pid: 303)] }
    platform.onLaunch = {
        backend.opened.apps = [mirroring(pid: 303)]
        if let startedAt { backend.opened.startedAt[303] = startedAt }
    }
    let s = platformService(platform, backend: backend)
    let c = handshaken(s)
    let d = try created(s, c)
    return (platform, s, d, call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.example.notes"}"#))
}

@Test func aLaunchThatProvablyStartedIPhoneMirroringQuitsItAndKeepsNothing() throws {
    let t = try launchTurningIntoMirroring(startedAt: Timestamp.string(Date().addingTimeInterval(5)))
    #expect(refusedAsMirroring(t.r))
    #expect(failure(t.r)?.notSent == false)
    #expect(failure(t.r)?.details?["quit"]?.boolValue == true)
    #expect(t.platform.quit == [303])
    let desk = try #require(t.s.desktops.find(t.d))
    #expect(desk.launched.isEmpty && desk.binding == nil)
}

@Test func theUsersOwnIPhoneMirroringIsNeverQuit() throws {
    // Already running before the launch: whatever the start time says.
    let mine = try launchTurningIntoMirroring(before: true, startedAt: Timestamp.string(Date().addingTimeInterval(5)))
    #expect(refusedAsMirroring(mine.r))
    #expect(failure(mine.r)?.details?["quit"]?.boolValue == false)
    #expect(mine.platform.quit.isEmpty)
    #expect(mine.s.desktops.find(mine.d)?.launched.isEmpty == true)
    // Not listed before, but started before the launch: not provably ours.
    let older = try launchTurningIntoMirroring(startedAt: "2026-10-08T01:00:00.000Z")
    #expect(refusedAsMirroring(older.r))
    #expect(failure(older.r)?.details?["quit"]?.boolValue == false)
    #expect(older.platform.quit.isEmpty)
    // No start time at all: not provable either.
    let unknown = try launchTurningIntoMirroring(startedAt: nil)
    #expect(unknown.platform.quit.isEmpty)
}

@Test func iPhoneMirroringIsNotBound() throws {
    let platform = FakePlatform()
    let backend = FixedBackend()
    backend.opened.apps = [mirroring(pid: 404)]
    platform.windows[404] = [PlatformWindow(windowId: 44, pid: 404, appName: "iPhone Mirroring", title: "iPhone",
                                            frame: Rect(x: 10, y: 20, width: 300, height: 600))]
    let s = platformService(platform, backend: backend)
    let c = handshaken(s)
    let d = try created(s, c)
    let r = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":404}"#)
    #expect(refusedAsMirroring(r))
    #expect(!platform.calls.contains { $0.hasPrefix("move") })
    #expect(s.desktops.find(d)?.binding == nil)
}

@Test func aBoundWindowThatIsIPhoneMirroringIsNeitherObservedNorTyped() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    // However the binding came about, the bound process is now the phone's.
    backend.opened.apps = [mirroring(pid: 101)]
    let before = sc.platform.calls
    #expect(refusedAsMirroring(call(sc.s, sc.c, "observe", id: "obs-139", context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(refusedAsMirroring(call(sc.s, sc.c, "observe", params: #"{"screenshot":false}"#,
                                    context: #"{"sessionId":"\#(sc.session)"}"#)))
    let a = act(sc, #"{"kind":"type","target":{"elementRef":"el_1"},"text":"Ada"}"#, id: "act-139")
    #expect(refusedAsMirroring(a))
    #expect(failure(a)?.notSent == true)
    #expect(refusedAsMirroring(call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","role":"AXButton","label":"继续"},"timeoutMs":300}"#,
                                    context: #"{"sessionId":"\#(sc.session)"}"#)))
    // Nothing captured, read, sent, moved or quit: the window is as it was.
    #expect(sc.platform.calls == before)
    #expect(sc.platform.performed.isEmpty && sc.platform.quit.isEmpty)
    // The act is recorded as refused, never as a success (observe is not
    // a mutation and is not recorded at all).
    let record = data(call(sc.s, sc.c, "request.show", params: #"{"requestId":"act-139"}"#))
    #expect(record?["state"]?.stringValue == "failed")
    #expect(record?["outcome"]?["error"]?["details"]?["reason"]?.stringValue == "iphone_mirroring_blocked")
    #expect(code(call(sc.s, sc.c, "request.show", params: #"{"requestId":"obs-139"}"#)) == "not_found")
    // Nothing to resume from: the binding gives no way around it.
    #expect(sc.s.desktops.find(sc.desktop)?.binding != nil)
    #expect(refusedAsMirroring(act(sc, clickContinue)))
    #expect(sc.platform.performed.isEmpty)
}
