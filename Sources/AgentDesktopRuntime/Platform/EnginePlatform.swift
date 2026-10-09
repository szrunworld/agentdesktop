import AgentDesktopProtocol
import AppKit
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
        ClipboardProbe.prepareKeyboardLayout()
    }

    // G2 probes: accessibility and keyboard-layout reads only.

    public func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit? {
        ClipboardProbe.hit(at: CGPoint(x: point.x, y: point.y), pid: pid).map {
            PlatformHit(role: $0.role, texts: $0.texts, shortcut: $0.shortcut, windowId: $0.windowID, inMenu: $0.inMenu,
                        ancestorTexts: $0.ancestorTexts, focused: $0.focused, editable: $0.editable)
        }
    }

    /// A menu bar, read again at most every few seconds per app: every
    /// modified key asks for it.
    private let menuCache = NSLock()
    private var menus: [Int32: (items: [PlatformMenuItem], at: Date)] = [:]

    public func menuItems(pid: Int32) -> [PlatformMenuItem]? {
        if let cached = menuCache.withLock({ menus[pid] }), Date().timeIntervalSince(cached.at) < ClipboardProbe.menuCacheSeconds {
            return cached.items
        }
        guard let items = ClipboardProbe.menuItems(pid: pid)?.map({ PlatformMenuItem(texts: $0.texts, shortcut: $0.shortcut) })
        else { return nil }
        menuCache.withLock { menus[pid] = (items, Date()) }
        return items
    }

    public func menuOpen(pid: Int32) -> Bool? { ClipboardProbe.menuOpen(pid: pid) }

    public func focusedControl(pid: Int32) -> PlatformHit? {
        ClipboardProbe.focused(pid: pid).map {
            PlatformHit(role: $0.role, texts: $0.texts, shortcut: $0.shortcut, windowId: $0.windowID, inMenu: $0.inMenu,
                        ancestorTexts: $0.ancestorTexts, focused: true, editable: $0.editable,
                        defaultButtonTexts: $0.defaultButtonTexts)
        }
    }

    public func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter {
        switch ClipboardProbe.character(forKey: key, modifiers: modifiers) {
        case .named: return .named
        case let .character(c): return .character(c)
        case .unknown: return .unknown
        }
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

    /// The host registers the user's physical displays with the engine
    /// (`AgentRuntime.hostScreens`, kind primary); this only looks one up.
    /// The engine refuses to destroy or resize a host screen.
    public func attachDisplay(_ displayId: UInt32?) throws -> ScreenHandle {
        let response = try check(handle(ControlRequest(command: .screenList)))
        let host = (response.screens ?? []).filter { $0.kind == .primary }
        let wanted = displayId ?? UInt32(CGMainDisplayID())
        guard let s = host.first(where: { $0.displayID == wanted }) else {
            let known = host.map { String($0.displayID) }.joined(separator: ", ")
            throw PlatformError(.notFound, "display \(wanted) is not one of the user's physical displays (\(known.isEmpty ? "none" : known))")
        }
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

    public func screenshot(_ screen: ScreenHandle, cropTo frame: Rect, to path: String) throws -> (width: Int, height: Int) {
        let full = path + ".screen.png"
        defer { try? FileManager.default.removeItem(atPath: full) }
        let size = try screenshot(screen, to: full)
        let scale = Double(size.width) / max(1, screen.frame.width)
        let x0 = max(0, ((frame.x - screen.frame.x) * scale).rounded(.down))
        let y0 = max(0, ((frame.y - screen.frame.y) * scale).rounded(.down))
        let x1 = min(Double(size.width), ((frame.x + frame.width - screen.frame.x) * scale).rounded(.up))
        let y1 = min(Double(size.height), ((frame.y + frame.height - screen.frame.y) * scale).rounded(.up))
        guard x1 > x0, y1 > y0,
              let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: full) as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil),
              let cropped = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)),
              let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { throw PlatformError(.refused, "cannot cut the window out of the screenshot") }
        CGImageDestinationAddImage(dest, cropped, nil)
        guard CGImageDestinationFinalize(dest) else { throw PlatformError(.refused, "cannot write \(path)") }
        return (cropped.width, cropped.height)
    }

    public func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int) {
        var r = ControlRequest(command: .screenshot)
        r.screen = screen.name
        r.output = path
        r.windowsOnly = true
        r.windowID = windowId
        r.pid = pid
        _ = try check(handle(r))
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { throw PlatformError(.refused, "the window capture at \(path) is unreadable") }
        return (w, h)
    }

    public func stack(on screen: ScreenHandle) -> [PlatformWindow] {
        let bounds = CGRect(x: screen.frame.x, y: screen.frame.y, width: screen.frame.width, height: screen.frame.height)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { entry in
            // Normal windows only; a fully transparent one shows nothing.
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowAlpha as String] as? Double ?? 1) > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let b = entry[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: b), f.intersects(bounds)
            else { return nil }
            return PlatformWindow(windowId: number, pid: pid, appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                                  title: entry[kCGWindowName as String] as? String ?? "",
                                  frame: Rect(x: f.minX, y: f.minY, width: f.width, height: f.height))
        }
    }

    /// Runs on the calling thread (one of the Runtime's AX threads), straight
    /// into the engine's input engine: not through `handle`, whose detached
    /// task would put the uninterruptible AX calls on the cooperative pool.
    public func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws
        -> ElementRead {
        let bounds = CGRect(x: screen.frame.x, y: screen.frame.y, width: screen.frame.width, height: screen.frame.height)
        guard let window = WindowMover.windows(ofPID: pid).first(where: { $0.windowID == windowId }),
              bounds.contains(CGPoint(x: window.frame.midX, y: window.frame.midY))
        else { throw PlatformError(.notFound, "window \(windowId) of pid \(pid) is not on screen \(screen.name)") }
        let response: ControlResponse
        do {
            response = try engine.input.state(window, query: query, deadline: deadline)
        } catch {
            throw Self.classify(error.localizedDescription)
        }
        guard let w = response.window else { throw PlatformError(.notFound, "the window is gone") }
        let elements = (response.elements ?? []).map {
            PlatformElement(index: $0.index, role: $0.role, label: $0.label, value: $0.value,
                            actions: $0.actions ?? [], frame: $0.frame.map(Self.rect))
        }
        return ElementRead(window: Self.window(w), elements: elements, truncated: response.elementsTruncated)
    }

    /// Engine refusals that happen before any event is posted: target
    /// lookups and argument checks in InputEngine.perform.
    static let preDispatchFailures = [
        "has no window", "has no on-screen window", "is not on screen", "is outside the window",
        "no element", "give --index", "needs --value", "needs the field named", "permission",
        "has no frame to click", "does not take its text", "unknown key", "no screen named",
    ]

    public func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String {
        var input = InputAction(InputAction.Kind(rawValue: action.kind.rawValue)!)
        input.index = action.elementIndex
        input.x = action.point?.x
        input.y = action.point?.y
        input.value = action.text
        input.key = action.key
        input.modifiers = action.modifiers.isEmpty ? nil : action.modifiers
        input.button = action.button
        input.count = action.count
        input.direction = action.direction
        input.amount = action.amount
        var r = ControlRequest(command: .input)
        r.screen = screen.name
        r.pid = pid
        r.windowID = windowId
        r.input = input
        let response = handle(r)
        guard response.ok else {
            let message = response.error ?? "the engine refused the action"
            let before = Self.preDispatchFailures.contains { message.lowercased().contains($0.lowercased()) }
            var e = Self.classify(message)
            e.beforeDispatch = before
            throw e
        }
        return response.route ?? "unknown"
    }

    public func quit(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.terminate()
    }
}
