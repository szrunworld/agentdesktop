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

@Test func aLaunchThatTurnsOutToBeIPhoneMirroringIsClosedAndNotKept() throws {
    let platform = FakePlatform()
    let backend = FixedBackend()
    // Whatever was asked for, the process that came up is iPhone Mirroring.
    backend.opened.apps = [mirroring(pid: 303)]
    let s = platformService(platform, backend: backend)
    let c = handshaken(s)
    let d = try created(s, c)
    let r = call(s, c, "app.launch", params: #"{"desktopId":"\#(d)","bundleId":"com.example.notes"}"#)
    #expect(refusedAsMirroring(r))
    #expect(failure(r)?.notSent == false)
    #expect(platform.quit == [303])
    #expect(s.desktops.find(d)?.launched.isEmpty == true)
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
    #expect(refusedAsMirroring(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let a = act(sc, #"{"kind":"type","target":{"elementRef":"el_1"},"text":"Ada"}"#)
    #expect(refusedAsMirroring(a))
    #expect(failure(a)?.notSent == true)
    #expect(refusedAsMirroring(call(sc.s, sc.c, "wait", params: #"{"condition":{"kind":"elementPresent","role":"AXButton","label":"继续"},"timeoutMs":300}"#,
                                    context: #"{"sessionId":"\#(sc.session)"}"#)))
    #expect(sc.platform.performed.isEmpty)
}
