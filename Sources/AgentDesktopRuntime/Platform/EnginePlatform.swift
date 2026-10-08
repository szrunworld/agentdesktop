import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO
import SecondScreenCore
import SecondScreenRuntime

/// macOS desktops on the 2ndscreen engine running in this host process:
/// every call goes through `AgentRuntime.handle`, the engine's verified
/// command path, on the main actor. Callers are Runtime connection threads,
/// never the main thread.
public final class EnginePlatform: DesktopPlatform, @unchecked Sendable {
    private let engine: AgentRuntime

    public init(engine: AgentRuntime) {
        self.engine = engine
    }

    private func handle(_ request: ControlRequest) -> ControlResponse {
        precondition(!Thread.isMainThread, "EnginePlatform blocks; call it from a Runtime thread")
        final class Box: @unchecked Sendable { var value = ControlResponse.failure("no reply") }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let engine = engine
        Task { @MainActor in
            box.value = await engine.handle(request)
            done.signal()
        }
        done.wait()
        return box.value
    }

    private func check(_ r: ControlResponse) throws -> ControlResponse {
        guard r.ok else { throw Self.classify(r.error ?? "the engine refused") }
        return r
    }

    static func classify(_ message: String) -> PlatformError {
        let m = message.lowercased()
        if m.contains("permission") { return PlatformError(.permission, message) }
        if m.contains("no screen named") || m.contains("no agent screen") || m.contains("has no matching")
            || m.contains("has no window") || m.contains("has no on-screen window") || m.contains("is not on screen") {
            return PlatformError(.notFound, message)
        }
        return PlatformError(.refused, message)
    }

    static func rect(_ f: Frame) -> Rect { Rect(x: f.x, y: f.y, width: f.width, height: f.height) }

    static func window(_ w: SecondScreenCore.WindowSummary) -> PlatformWindow {
        PlatformWindow(windowId: w.windowID, pid: w.pid, appName: w.app, title: w.title, frame: rect(w.frame))
    }

    public func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle {
        var r = ControlRequest(command: .screenCreate)
        r.screen = name
        r.width = width
        r.height = height
        // The Runtime owns the lifetime: no idle reaping behind its back.
        r.idleTimeout = 0
        let response = try check(handle(r))
        guard let s = response.screen else { throw PlatformError(.refused, "the engine created no screen") }
        return ScreenHandle(name: s.name, displayId: s.displayID, frame: Self.rect(s.frame), hiDPI: s.hiDPI)
    }

    public func destroyScreen(name: String) throws {
        var r = ControlRequest(command: .screenDestroy)
        r.screen = name
        _ = try check(handle(r))
    }

    public func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws
        -> (pid: Int32, windows: [PlatformWindow]) {
        var r = ControlRequest(command: .appLaunch)
        r.screen = screen.name
        r.bundleID = bundleId
        r.path = path
        r.newInstance = newInstance
        let response = try check(handle(r))
        guard let pid = response.pid else { throw PlatformError(.refused, "the engine reported no process") }
        return (pid, (response.windows ?? []).map(Self.window))
    }

    public func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] {
        var r = ControlRequest(command: .windowMove)
        r.screen = screen.name
        r.pid = pid
        r.windowID = windowId
        let response = try check(handle(r))
        return (response.windows ?? []).map(Self.window)
    }

    public func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? {
        let bounds = CGRect(x: screen.frame.x, y: screen.frame.y, width: screen.frame.width, height: screen.frame.height)
        guard let w = WindowMover.windows(ofPID: pid).first(where: { $0.windowID == windowId }),
              bounds.contains(CGPoint(x: w.frame.midX, y: w.frame.midY))
        else { return nil }
        return PlatformWindow(windowId: w.windowID, pid: w.pid, appName: w.appName, title: w.title,
                              frame: Rect(x: w.frame.minX, y: w.frame.minY, width: w.frame.width, height: w.frame.height))
    }

    public func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) {
        var r = ControlRequest(command: .screenshot)
        r.screen = screen.name
        r.output = path
        _ = try check(handle(r))
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw PlatformError(.refused, "the screenshot at \(path) is unreadable") }
        return (w, h)
    }

    public func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?) throws
        -> (window: PlatformWindow, elements: [PlatformElement]) {
        var r = ControlRequest(command: .windowState)
        r.screen = screen.name
        r.pid = pid
        r.windowID = windowId
        r.query = query
        let response = try check(handle(r))
        guard let w = response.window else { throw PlatformError(.notFound, "the window is gone") }
        let elements = (response.elements ?? []).map {
            PlatformElement(index: $0.index, role: $0.role, label: $0.label, value: $0.value,
                            actions: $0.actions ?? [], frame: $0.frame.map(Self.rect))
        }
        return (Self.window(w), elements)
    }
}
