@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// #139: iPhone Mirroring is refused by the general desktop methods for
// every caller until the iPhone device session is accepted. Fail closed: a
// process whose app cannot be identified is refused too, for that request.

func mirroring(pid: Int32) -> AppSummary {
    AppSummary(process: ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.ScreenContinuity",
               name: "iPhone Mirroring", active: false, hidden: false)
}

func refusedAsMirroring(_ r: RuntimeResponse, identity: String = "iphone_mirroring") -> Bool {
    code(r) == "permission_denied" && failure(r)?.details?["reason"]?.stringValue == "iphone_mirroring_blocked"
        && failure(r)?.details?["identity"]?.stringValue == identity
}

/// A .app on disk with this bundle id (none: an Info.plist without one);
/// removed with its folder when released.
final class TempApp {
    let url: URL
    var executable: String { url.appendingPathComponent("Contents/MacOS/main").path }
    init(_ bundleId: String?, name: String = "App") throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("t139-\(UUID().uuidString)/\(name).app")
        try FileManager.default.createDirectory(at: url.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        var plist: [String: Any] = ["CFBundleExecutable": "main", "CFBundlePackageType": "APPL"]
        if let bundleId { plist["CFBundleIdentifier"] = bundleId }
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: url.appendingPathComponent("Contents/Info.plist"))
        FileManager.default.createFile(atPath: executable, contents: Data())
    }
    deinit { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
}

// MARK: app.launch

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

@Test func iPhoneMirroringIsNotLaunchedByPathAndNeitherIsAnUnreadableApp() throws {
    let app = try TempApp("com.apple.ScreenContinuity", name: "iPhone Mirroring")
    let nameless = try TempApp(nil)
    let platform = FakePlatform()
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try created(s, c)
    // The bundle, and the executable inside it.
    for path in [app.url.path, app.executable] {
        let r = call(s, c, "app.launch", params: JSONValue.obj([("desktopId", .string(d)), ("path", .string(path))]).encoded())
        #expect(refusedAsMirroring(r), "\(path)")
    }
    // An app whose bundle id cannot be read could be it.
    let r = call(s, c, "app.launch", params: JSONValue.obj([("desktopId", .string(d)), ("path", .string(nameless.url.path))]).encoded())
    #expect(refusedAsMirroring(r, identity: "unverified"))
    #expect(failure(r)?.notSent == true)
    #expect(!platform.calls.contains { $0.hasPrefix("launch") })
}

/// A launch of something else whose process is pid 303; `during` runs as it starts.
func launching(failingWith error: Error? = nil, _ during: @escaping (FixedBackend) -> Void) throws
    -> (platform: FakePlatform, s: RuntimeService, d: String, r: RuntimeResponse) {
    let platform = FakePlatform()
    platform.launchError = error
    let backend = FixedBackend()
    platform.onLaunch = { during(backend) }
    let s = platformService(platform, backend: backend)
    let c = handshaken(s)
    let d = try created(s, c)
    return (platform, s, d, call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.example.notes"}"#))
}

@Test func aLaunchThatStartedIPhoneMirroringQuitsOnlyThatProcessAndKeepsNothing() throws {
    // The platform proved pid 303 is this launch's; the user's own instance
    // (404) is running too.
    let t = try launching { $0.opened.apps = [mirroring(pid: 404), mirroring(pid: 303)] }
    #expect(refusedAsMirroring(t.r))
    #expect(failure(t.r)?.notSent == false)
    #expect(failure(t.r)?.details?["quitRequested"]?.boolValue == true)
    #expect(t.platform.quit == [303])
    let desk = try #require(t.s.desktops.find(t.d))
    #expect(desk.launched.isEmpty && desk.binding == nil)
}

@Test func theUserOpeningIPhoneMirroringDuringALaunchIsNotTouched() throws {
    // The user opens it (pid 404) while the launch starts the requested app
    // (303): the launch goes ahead, and nothing of the user's is quit.
    let notes = try TempApp("com.example.notes", name: "Notes")
    let t = try launching {
        $0.opened.apps = [mirroring(pid: 404)]
        $0.opened.paths[303] = notes.executable
    }
    #expect(data(t.r) != nil)
    #expect(t.platform.quit.isEmpty)
    #expect(t.s.desktops.find(t.d)?.launched.map(\.pid) == [303])
}

@Test func aLaunchedProcessThatCannotBeIdentifiedIsRefusedNotKeptButAskedToQuit() throws {
    // Not in the list, no readable executable path. The launch token proved
    // it is this launch's, so it is asked to quit rather than left orphaned.
    let t = try launching { $0.opened.pathsUnreadable = true }
    #expect(refusedAsMirroring(t.r, identity: "unverified"))
    #expect(failure(t.r)?.notSent == false)
    #expect(failure(t.r)?.details?["quitRequested"]?.boolValue == true)
    #expect(t.platform.quit == [303])
    #expect(t.s.desktops.find(t.d)?.launched.isEmpty == true)
}

@Test func aLaunchThatCannotProveItsProcessQuitsNothingAndKeepsNothing() throws {
    // The engine opened something but could not prove it was this launch's
    // (or the open call failed), while an iPhone Mirroring with a new pid
    // appeared. Nothing is quit, nothing kept, and the engine's error stands.
    for reason in ["launch_refused_after_open", "launch_failed"] {
        let engine = RuntimeError("execution_failed", "the app was opened, then refused", phase: .handler,
                                  details: .obj([("reason", .string(reason))]))
        let t = try launching(failingWith: engine) { $0.opened.apps = [mirroring(pid: 505)] }
        #expect(code(t.r) == "execution_failed", "\(reason)")
        #expect(failure(t.r)?.details?["reason"]?.stringValue == reason)
        #expect(t.platform.quit.isEmpty, "\(reason)")
        let desk = try #require(t.s.desktops.find(t.d))
        #expect(desk.launched.isEmpty && desk.binding == nil, "\(reason)")
    }
}

// MARK: window.bind

func bindScene(_ backend: FixedBackend) throws -> (platform: FakePlatform, s: RuntimeService, c: ConnectionState, d: String) {
    let platform = FakePlatform()
    platform.windows[404] = [PlatformWindow(windowId: 44, pid: 404, appName: "iPhone Mirroring", title: "iPhone",
                                            frame: Rect(x: 10, y: 20, width: 300, height: 600))]
    let s = platformService(platform, backend: backend)
    let c = handshaken(s)
    return (platform, s, c, try created(s, c))
}

@Test func iPhoneMirroringIsNotBound() throws {
    let backend = FixedBackend()
    backend.opened.apps = [mirroring(pid: 404)]
    let t = try bindScene(backend)
    let r = call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404,"windowId":44}"#)
    #expect(refusedAsMirroring(r))
    #expect(!t.platform.calls.contains { $0.hasPrefix("move") })
    #expect(t.s.desktops.find(t.d)?.binding == nil)
}

@Test func withTheAppListUnreadableTheExecutableStillIdentifiesIPhoneMirroring() throws {
    let app = try TempApp("com.apple.ScreenContinuity", name: "iPhone Mirroring")
    let backend = FixedBackend()
    backend.opened.appListUnreadable = true
    backend.opened.paths[404] = app.executable
    let t = try bindScene(backend)
    #expect(refusedAsMirroring(call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404}"#)))
    // The executable is checked even when the list names another app.
    backend.opened.appListUnreadable = false
    backend.opened.apps = [AppSummary(process: ProcessIdentity(pid: 404, startedAt: nil), bundleId: "com.example.notes",
                                      name: "Notes", active: false, hidden: false)]
    #expect(refusedAsMirroring(call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404}"#)))
    #expect(!t.platform.calls.contains { $0.hasPrefix("move") })
}

@Test func anAppThatCannotBeIdentifiedIsNotBoundUntilItCanBe() throws {
    let backend = FixedBackend()
    backend.opened.appListUnreadable = true
    backend.opened.pathsUnreadable = true
    let t = try bindScene(backend)
    // Neither the list nor the executable says what pid 404 is.
    let r = call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404}"#)
    #expect(refusedAsMirroring(r, identity: "unverified"))
    #expect(failure(r)?.notSent == true)
    // An app bundle that cannot be read is no better.
    let nameless = try TempApp(nil)
    backend.opened.paths[404] = nameless.executable
    #expect(refusedAsMirroring(call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404}"#), identity: "unverified"))
    #expect(!t.platform.calls.contains { $0.hasPrefix("move") })
    // Not a lasting refusal: once it is known to be another app, it binds.
    let notes = try TempApp("com.example.notes", name: "Notes")
    backend.opened.paths[404] = notes.executable
    #expect(data(call(t.s, t.c, "window.bind", params: #"{"desktopId":"\#(t.d)","pid":404}"#)) != nil)
}

// MARK: observe, act, wait on an existing binding

@Test func aBoundWindowThatIsIPhoneMirroringIsNeitherObservedNorTyped() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    // However the binding came about, the bound process is now the phone's.
    backend.opened.apps = [mirroring(pid: 101)]
    let before = sc.platform.calls
    let o = call(sc.s, sc.c, "observe", id: "obs-139", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(refusedAsMirroring(o))
    // Refused before any capture or read: nothing was done.
    #expect(failure(o)?.notSent == true)
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
    // The binding is still there, and gives no way around it.
    #expect(sc.s.desktops.find(sc.desktop)?.binding != nil)
    #expect(refusedAsMirroring(act(sc, clickContinue)))
    #expect(sc.platform.performed.isEmpty)
}

@Test func aBoundAppThatCannotBeIdentifiedNowIsRefusedForThatRequestOnly() throws {
    let backend = FixedBackend()
    let sc = try scene(backend: backend)
    backend.opened.appListUnreadable = true
    backend.opened.pathsUnreadable = true
    let before = sc.platform.calls
    let o = call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
    #expect(refusedAsMirroring(o, identity: "unverified"))
    #expect(failure(o)?.notSent == true)
    #expect(refusedAsMirroring(act(sc, clickContinue), identity: "unverified"))
    #expect(refusedAsMirroring(call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","role":"AXButton","label":"继续"},"timeoutMs":300}"#,
                                    context: #"{"sessionId":"\#(sc.session)"}"#), identity: "unverified"))
    #expect(sc.platform.calls == before)
    #expect(sc.platform.performed.isEmpty)
    // Readable again: checked anew, and the same binding works.
    backend.opened.appListUnreadable = false
    backend.opened.pathsUnreadable = false
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, clickContinue, snapshot: snap)) != nil)
    #expect(sc.platform.performed.count == 1)
}

@Test func theMacBackendReadsAProcessesExecutable() throws {
    let own = try #require(MacBackend().executablePath(getpid()))
    #expect(FileManager.default.fileExists(atPath: own))
    #expect(MacBackend().executablePath(-1) == nil)
}
