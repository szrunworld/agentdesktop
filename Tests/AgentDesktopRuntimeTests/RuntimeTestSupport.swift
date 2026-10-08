import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
@testable import AgentDesktopRuntime

struct FixedBackend: RuntimeBackend {
    var perms = BackendPermissions(screenRecording: .granted, accessibility: .granted)
    var apps: [AppSummary] = [
        AppSummary(process: ProcessIdentity(pid: 101, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.calculator",
                   name: "Calculator", active: false, hidden: false),
    ]
    var wins: [WindowSummary] = [
        WindowSummary(windowId: 11, process: ProcessIdentity(pid: 101, startedAt: "2026-10-08T01:00:00.000Z"),
                      appName: "Calculator", bundleId: "com.apple.calculator", title: "Calculator",
                      frame: Rect(x: 10, y: 20, width: 230, height: 400), onScreen: true),
        WindowSummary(windowId: 12, process: ProcessIdentity(pid: 202, startedAt: nil), appName: "微信",
                      bundleId: "com.tencent.xinWeChat", title: "文件传输助手 \"草稿\"\n第二行",
                      frame: Rect(x: -1440, y: 0, width: 800, height: 600), onScreen: true),
        WindowSummary(windowId: 13, process: ProcessIdentity(pid: 202, startedAt: nil), appName: "微信",
                      bundleId: "com.tencent.xinWeChat", title: "最小化的窗口",
                      frame: Rect(x: 0, y: 0, width: 400, height: 300), onScreen: false),
    ]

    var platform: Platform { Platform(os: "macos", osVersion: "15.1.0", arch: "arm64") }
    func permissions() -> BackendPermissions { perms }
    func features() -> [String] { ["apps.list", "windows.list"] }
    func applications(includeBackground: Bool) -> [AppSummary] { apps }
    /// Processes the test has "restarted": same pid, other start time.
    var restarted: Set<Int32> = []
    func processIdentity(_ pid: Int32) -> ProcessIdentity {
        ProcessIdentity(pid: pid, startedAt: restarted.contains(pid) ? "2026-10-08T09:00:00.000Z" : "2026-10-08T01:00:00.000Z")
    }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        wins.filter { (pid == nil || $0.process.pid == pid) && (bundleId == nil || $0.bundleId == bundleId)
            && (includeOffscreen || $0.onScreen) }
    }
}

func makeService(backend: RuntimeBackend = FixedBackend(), endpoint: String = "/tmp/t.sock",
                 desktops: DesktopRegistry = DesktopRegistry()) -> RuntimeService {
    RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(),
                                             startedAt: Timestamp.string(Date()), endpoint: endpoint,
                                             buildSource: "unknown"),
                   backend: backend, desktops: desktops)
}

/// A short private directory for sockets (sun_path holds 104 bytes).
func socketDirectory() throws -> String {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    guard let p = mkdtemp(&template) else { throw POSIXError(.EIO) }
    return String(cString: p)
}

/// A raw connection that speaks lines, for tests below the client.
final class RawConnection {
    let fd: Int32
    let channel: LineChannel

    init(_ path: String) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        _ = SocketOptions.noSigPipe(fd)
        var addr = SocketOptions.address(path)!
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.fd = fd
        SocketOptions.receiveTimeout(fd, seconds: 5)
        channel = LineChannel(fd: fd, limit: 4 * RuntimeAPI.maxFrameBytes)
    }

    func send(_ text: String) { _ = Array(text.utf8).withUnsafeBytes { write(fd, $0.baseAddress, $0.count) } }

    func read() throws -> JSONValue {
        guard case let .line(d) = channel.readLine() else { throw POSIXError(.ECONNRESET) }
        return try StrictJSON.parse(d)
    }

    deinit { close(fd) }
}

let handshakeLine = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"hs_1","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}}"#

func requestLine(_ method: String, id: String = "req_1", params: String = "{}") -> String {
    #"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(id)","method":"\#(method)","params":\#(params)}"#
}

let testScreen = ScreenHandle(name: "d_test", displayId: 77, frame: Rect(x: 2000, y: 0, width: 1280, height: 800), hiDPI: true)

/// A scripted desktop platform that records every call.
final class FakePlatform: DesktopPlatform, @unchecked Sendable {
    let lock = NSLock()
    var calls: [String] = []
    var screens: [String: ScreenHandle] = [:]
    /// Windows by pid; a bind moves them onto the named screen.
    var windows: [Int32: [PlatformWindow]] = [
        101: [PlatformWindow(windowId: 11, pid: 101, appName: "Calculator", title: "Calculator",
                             frame: Rect(x: 10, y: 20, width: 230, height: 400))],
    ]
    var onScreen: [UInt32: String] = [:]
    var elements: [PlatformElement] = [
        PlatformElement(index: 0, role: "AXButton", label: "继续", value: nil, actions: ["AXPress"],
                        frame: Rect(x: 2100, y: 100, width: 80, height: 30)),
        PlatformElement(index: 1, role: "AXTextField", label: "名字", value: "Ada \"Q\"", actions: [],
                        frame: Rect(x: 2100, y: 150, width: 200, height: 24)),
    ]
    var screenRecordingGranted = true
    var nextDisplay: UInt32 = 900
    var lastScreenshot: String?

    private func note(_ s: String) { lock.withLock { calls.append(s) } }

    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle {
        note("create \(name)")
        return lock.withLock {
            nextDisplay += 1
            let h = ScreenHandle(name: name, displayId: nextDisplay,
                                 frame: Rect(x: 2000 + Double(screens.count) * 1400, y: 0,
                                             width: Double(width ?? 1280), height: Double(height ?? 800)), hiDPI: true)
            screens[name] = h
            return h
        }
    }

    func destroyScreen(name: String) throws {
        note("destroy \(name)")
        try lock.withLock {
            guard screens.removeValue(forKey: name) != nil else { throw PlatformError(.notFound, "no agent screen named \(name)") }
        }
    }

    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws -> (pid: Int32, windows: [PlatformWindow]) {
        note("launch \(bundleId ?? path ?? "?") on \(screen.name)")
        guard bundleId != "com.example.missing" else { throw PlatformError(.refused, "give a bundle ID of an installed app") }
        let w = PlatformWindow(windowId: 31, pid: 303, appName: "Notes", title: "备忘录",
                               frame: Rect(x: screen.frame.x + 10, y: 10, width: 500, height: 400))
        lock.withLock { windows[303] = [w]; onScreen[31] = screen.name }
        return (303, [w])
    }

    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] {
        note("move \(pid)/\(windowId.map(String.init) ?? "*") to \(screen.name)")
        return try lock.withLock {
            let ws = (windows[pid] ?? []).filter { windowId == nil || $0.windowId == windowId }
            guard !ws.isEmpty else { throw PlatformError(.notFound, "pid \(pid) has no matching on-screen window") }
            for w in ws { onScreen[w.windowId] = screen.name }
            return ws
        }
    }

    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? {
        lock.withLock {
            guard onScreen[windowId] == screen.name else { return nil }
            return windows[pid]?.first { $0.windowId == windowId }
        }
    }

    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) {
        note("screenshot \(screen.name)")
        guard screenRecordingGranted else {
            throw PlatformError(.permission, "needs the Screen Recording permission to take screenshots")
        }
        try Data("PNG".utf8).write(to: URL(fileURLWithPath: path))
        lock.withLock { lastScreenshot = path }
        return (Int(screen.frame.width) * 2, Int(screen.frame.height) * 2)
    }

    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?) throws -> (window: PlatformWindow, elements: [PlatformElement]) {
        note("elements \(pid)/\(windowId)")
        guard let w = window(on: screen, pid: pid, windowId: windowId) else { throw PlatformError(.notFound, "the window is gone") }
        return (w, elements)
    }

    /// The window leaves the screen (closed or moved away by the user).
    func dropWindow(_ id: UInt32) { lock.withLock { onScreen[id] = nil } }
}

func platformService(_ platform: FakePlatform = FakePlatform(), backend: FixedBackend = FixedBackend(),
                     ledger: RequestLedger? = nil) -> RuntimeService {
    RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                             endpoint: "/tmp/t.sock", buildSource: "unknown"),
                   backend: backend, platform: platform, ledger: ledger)
}
