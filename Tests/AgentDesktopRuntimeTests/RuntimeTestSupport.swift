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
    /// Windows a test opens later, in front of every other (a reference, so
    /// a test can change it after the Runtime took its copy of the backend).
    final class Opened: @unchecked Sendable { var windows: [WindowSummary] = [] }
    var opened = Opened()
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        (opened.windows + wins).filter { (pid == nil || $0.process.pid == pid) && (bundleId == nil || $0.bundleId == bundleId)
            && (includeOffscreen || $0.onScreen) }
    }
}

func makeService(backend: RuntimeBackend = FixedBackend(), endpoint: String = "/tmp/t.sock",
                 desktops: DesktopRegistry = DesktopRegistry()) -> RuntimeService {
    { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(),
                                             startedAt: Timestamp.string(Date()), endpoint: endpoint,
                                             buildSource: "unknown"),
                   backend: backend, desktops: desktops); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; s.socketLaunchRequiresGrant = false; s.socketDiscoveryRequiresGrant = false; s.socketGuiRunRequiresGrant = false; s.socketsSeeOnlyTheirOwn = false; s.socketExtensionsAreReadOnly = false; return s }()
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
    // G2 probes. By default: the element of `elements` under the point
    // (else the window itself) in the pid's first window, a QWERTY layout
    // (`layout` maps keys the other way), and an empty menu bar.
    var hitAt: (((x: Double, y: Double), Int32) -> PlatformHit?)?
    var menu: [PlatformMenuItem]? = []
    var layout: [String: String] = [:]
    var layoutKnown = true
    func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit? {
        if let hitAt { return hitAt(point, pid) }
        let (els, wins) = lock.withLock { (elements, windows[pid] ?? []) }
        let e = els.last { $0.frame.map { point.x >= $0.x && point.x < $0.x + $0.width && point.y >= $0.y && point.y < $0.y + $0.height } ?? false }
        return PlatformHit(role: e?.role ?? "AXWindow", texts: [e?.label, e?.value].compactMap { $0 }, windowId: wins.first?.windowId)
    }
    func menuItems(pid: Int32) -> [PlatformMenuItem]? { menu }
    /// What has focus; by default nothing.
    var focusedHit: PlatformHit? = PlatformHit(role: "AXNone", texts: [], windowId: nil)
    /// Whether the app shows a menu; nil when that cannot be told.
    var menuShown: Bool? = false
    func menuOpen(pid: Int32) -> Bool? { menuShown }
    /// Reads of the focus that fail before `focusedHit` is answered.
    var focusFailures = 0
    var focusReads = 0
    func focusedControl(pid: Int32) -> PlatformHit? {
        focusReads += 1
        if focusFailures > 0 { focusFailures -= 1; return nil }
        return focusedHit
    }
    func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter {
        guard layoutKnown else { return .unknown }
        return key.count == 1 ? .character(layout[key] ?? key) : .named
    }

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
    /// Write decodable PNGs (the GUI ports crop them).
    var realImages = false
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

    /// The user's own displays a physical Desktop may attach, by ID.
    var physicalDisplays: [UInt32: ScreenHandle] = [
        1: ScreenHandle(name: "physical-1", displayId: 1, frame: Rect(x: 0, y: 0, width: 1512, height: 982), hiDPI: true),
    ]

    func attachDisplay(_ displayId: UInt32?) throws -> ScreenHandle {
        let id = displayId ?? 1
        note("attach \(id)")
        guard let h = lock.withLock({ physicalDisplays[id] }) else {
            throw PlatformError(.notFound, "display \(id) is not one of the user's physical displays")
        }
        return h
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
            // Placed inside the screen, like the engine does.
            var placed: [PlatformWindow] = []
            for var w in ws {
                w.frame = Rect(x: screen.frame.x + 100, y: 100, width: 400, height: 300)
                onScreen[w.windowId] = screen.name
                placed.append(w)
            }
            windows[pid] = (windows[pid] ?? []).map { w in placed.first { $0.windowId == w.windowId } ?? w }
            return placed
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
        let w = Int(screen.frame.width) * 2, h = Int(screen.frame.height) * 2
        if realImages {
            try pngData(width: w, height: h).write(to: URL(fileURLWithPath: path))
        } else {
            try Data("PNG".utf8).write(to: URL(fileURLWithPath: path))
        }
        lock.withLock { lastScreenshot = path }
        return (Int(screen.frame.width) * 2, Int(screen.frame.height) * 2)
    }

    /// Windows the test puts in front of everything on a screen, front first.
    var inFront: [String: [PlatformWindow]] = [:]
    /// Runs right after an input is "sent" or a window is captured.
    var onPerform: (() -> Void)?
    var onCapture: (() -> Void)?

    func stack(on screen: ScreenHandle) -> [PlatformWindow] {
        lock.withLock {
            (inFront[screen.name] ?? [])
                + windows.values.flatMap { $0 }.filter { onScreen[$0.windowId] == screen.name }.sorted { $0.windowId < $1.windowId }
        }
    }

    /// Test double: the window alone, as the window's crop of this double's screen.
    func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int) {
        if lock.withLock({ failScreenshot }) { throw PlatformError(.refused, "capture failed") }
        guard let w = window(on: screen, pid: pid, windowId: windowId) else { throw PlatformError(.notFound, "window \(windowId) is not on screen") }
        return try screenshot(screen, cropTo: w.frame, to: path)
    }

    func screenshot(_ screen: ScreenHandle, cropTo frame: AgentDesktopProtocol.Rect, to path: String) throws -> (width: Int, height: Int) {
        note("screenshot \(screen.name) window")
        defer { lock.withLock { onCapture }?() }
        guard screenRecordingGranted else {
            throw PlatformError(.permission, "needs the Screen Recording permission to take screenshots")
        }
        let w = Int(frame.width) * 2, h = Int(frame.height) * 2
        if realImages {
            try pngData(width: w, height: h).write(to: URL(fileURLWithPath: path))
        } else {
            try Data("PNG".utf8).write(to: URL(fileURLWithPath: path))
        }
        lock.withLock { lastScreenshot = path }
        return (w, h)
    }

    /// Makes an element read hang until signalled (a stuck app), or end
    /// truncated like a walk out of time.
    var axGate: DispatchSemaphore?
    var axTruncated: String?
    var axFailure: PlatformError?
    /// Element reads running now, and the most at once.
    var axRunning = 0, axPeak = 0
    var axThreads: Set<String> = []

    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws -> ElementRead {
        note("elements \(pid)/\(windowId)")
        lock.withLock {
            axRunning += 1; axPeak = max(axPeak, axRunning)
            axThreads.insert(Thread.isMainThread ? "main" : (Thread.current.name ?? "?"))
        }
        defer { lock.withLock { axRunning -= 1 } }
        lock.withLock { axGate }?.wait()
        if let f = lock.withLock({ axFailure }) { throw f }
        guard let w = window(on: screen, pid: pid, windowId: windowId) else { throw PlatformError(.notFound, "the window is gone") }
        return ElementRead(window: w, elements: elements, truncated: lock.withLock { axTruncated })
    }

    var quit: [Int32] = []
    func quit(pid: Int32) -> Bool { lock.withLock { quit.append(pid) }; return true }
    var performed: [PlatformAction] = []
    /// Fail the next action: before or after dispatch.
    var failNext: PlatformError?
    /// Window captures fail (G2/#144 tests).
    var failScreenshot = false
    /// Hold actions until signalled (cancel-in-flight tests).
    var gate: DispatchSemaphore?
    var entered = DispatchSemaphore(value: 0)

    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String {
        note("perform \(action.kind.rawValue)")
        entered.signal()
        gate?.wait()
        if let f = lock.withLock({ () -> PlatformError? in defer { failNext = nil }; return failNext }) { throw f }
        lock.withLock { performed.append(action) }
        lock.withLock { onPerform }?()
        return action.elementIndex != nil ? "ax.press" : "event.click"
    }

    /// The user moves the window.
    func moveWindow(_ id: UInt32, by dx: Double) {
        lock.withLock {
            for (pid, ws) in windows { windows[pid] = ws.map { var w = $0; if w.windowId == id { w.frame.x += dx }; return w } }
        }
    }

    /// The window leaves the screen (closed or moved away by the user).
    func dropWindow(_ id: UInt32) { lock.withLock { onScreen[id] = nil } }
}

func platformService(_ platform: FakePlatform = FakePlatform(), backend: FixedBackend = FixedBackend(),
                     ledger: RequestLedger? = nil) -> RuntimeService {
    { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_test", pid: getpid(), startedAt: Timestamp.string(Date()),
                                             endpoint: "/tmp/t.sock", buildSource: "unknown"),
                   backend: backend, platform: platform, ledger: ledger); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; s.socketLaunchRequiresGrant = false; s.socketDiscoveryRequiresGrant = false; s.socketGuiRunRequiresGrant = false; s.socketsSeeOnlyTheirOwn = false; s.socketExtensionsAreReadOnly = false; return s }()
}

import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// A solid PNG of the given size.
func pngData(width: Int, height: Int) throws -> Data {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    return data as Data
}

func pngSize(_ data: Data) -> (Int, Int)? {
    guard let src = CGImageSourceCreateWithData(data as CFData, nil),
          let p = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
          let w = p[kCGImagePropertyPixelWidth] as? Int, let h = p[kCGImagePropertyPixelHeight] as? Int else { return nil }
    return (w, h)
}
