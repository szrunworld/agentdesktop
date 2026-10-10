import AgentDesktopProtocol
import AppKit
import CoreGraphics
import Darwin
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
    /// The host's report of every active display with its proved origin
    /// (PhysicalDisplays.report): the engine itself holds only the physical
    /// ones it was given as host screens.
    private let displayReport: @Sendable () -> [PlatformDisplay]

    public init(engine: AgentRuntime, displays: @escaping @Sendable () -> [PlatformDisplay] = { [] }) {
        self.engine = engine
        self.displayReport = displays
        ClipboardProbe.prepareKeyboardLayout()
    }

    /// Owner only (hub.displays.list). The attachable ones are exactly
    /// the host screens attachDisplay accepts: the same classification
    /// decides both, so the list never offers what attach would refuse.
    public func displays() -> [PlatformDisplay] {
        let host = Set(((try? check(handle(ControlRequest(command: .screenList))))?.screens ?? []).filter { $0.kind == .primary }.map(\.displayID))
        return displayReport().map { d in
            var d = d
            // Proved physical by the host but not registered with the engine
            // (a display that appeared after the report): not attachable yet.
            if d.origin == .physical, !host.contains(d.displayId) {
                d.origin = .unconfirmed
                d.originDetail = "the display is not registered with the engine yet; try again in a moment"
            }
            return d
        }
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
            // Which displays exist is not told to a caller that has no grant.
            throw PlatformError(.notFound, "display \(wanted) is not a confirmed physical display")
        }
        return ScreenHandle(name: s.name, displayId: s.displayID, frame: Self.rect(s.frame), hiDPI: s.hiDPI)
    }

    public func destroyScreen(name: String) throws {
        var r = ControlRequest(command: .screenDestroy)
        r.screen = name
        _ = try check(handle(r))
    }

    public func resizeScreen(name: String, width: Int, height: Int) throws -> ScreenHandle {
        var r = ControlRequest(command: .screenResize)
        r.screen = name
        r.width = width
        r.height = height
        let response = try check(handle(r))
        guard let s = response.screen else { throw PlatformError(.refused, "the engine resized no screen") }
        return ScreenHandle(name: s.name, displayId: s.displayID, frame: Self.rect(s.frame), hiDPI: s.hiDPI)
    }

    public func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws
        -> (pid: Int32, windows: [PlatformWindow]) {
        var r = ControlRequest(command: .appLaunch)
        r.screen = screen.name
        r.bundleID = bundleId
        r.path = path
        r.newInstance = newInstance
        let answer = handle(r)
        // Refused before anything was opened: say so, with the reason, so a
        // client can tell "not allowed" from a launch that failed.
        if !answer.ok, let reason = answer.reason {
            switch reason {
            case "no_launch_apps_configured", "launch_not_verified", "launch_unprovable", "app_already_running":
                throw RuntimeError("permission_denied", answer.error ?? "the app was not opened", phase: .handler, notSent: true,
                                   details: .obj([("reason", .string(reason))]))
            case "launch_failed":
                // The open call failed: the app may or may not have started.
                throw RuntimeError("execution_failed", answer.error ?? "the launch call failed", phase: .handler,
                                   details: .obj([("reason", .string(reason))]))
            case "launch_refused_after_open":
                // Opened, then refused: nothing moved or bound, but not "not sent".
                throw RuntimeError("execution_failed", answer.error ?? "the app was opened, then refused", phase: .handler,
                                   details: .obj([("reason", .string(reason))]))
            default:
                break
            }
        }
        let response = try check(answer)
        guard let pid = response.pid else { throw PlatformError(.refused, "the engine reported no process") }
        // The engine refuses a launch that returns an already-running
        // process before it moves or binds anything (AgentScreens.launch).
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

    /// The one display-wide high-layer window that is known OS furniture:
    /// the system Dock keeps a transparent layer over the whole display.
    /// Only that layer is left out; the Dock's menus, folder stacks and
    /// other panels count like any overlay (Codex on 1994bca). The Dock is
    /// told by its process (bundle com.apple.dock at the system path), never
    /// by the window's owner name, which any app can take (Codex on
    /// 4c2536b). Everything else above the normal layer counts.
    static func isSystemDock(pid: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return app.bundleIdentifier == "com.apple.dock"
            && app.bundleURL?.standardizedFileURL.path == "/System/Library/CoreServices/Dock.app"
    }

    /// The system cursor is a rendered pointer, not an input destination.
    /// Window names alone never establish that identity.
    static func isSystemCursor(pid: Int32, layer: Int, title: String) -> Bool {
        guard layer == Int(CGWindowLevelForKey(.cursorWindow)), title == "Cursor" else { return false }
        var path = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &path, UInt32(path.count)) > 0 else { return false }
        return cursorIdentity(layer: layer, title: title, executable: String(cString: path))
    }

    static func cursorIdentity(layer: Int, title: String, executable: String) -> Bool {
        layer == Int(CGWindowLevelForKey(.cursorWindow)) && title == "Cursor"
            && executable == "/System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer"
    }

    public func overlays(on screen: ScreenHandle, boundPid: Int32) -> [PlatformWindow] {
        let bounds = CGRect(x: screen.frame.x, y: screen.frame.y, width: screen.frame.width, height: screen.frame.height)
        let menuBar = CGFloat(NSStatusBar.system.thickness)
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { entry in
            // Transparent windows count too: input routing does not look at
            // alpha, so an invisible panel can still take a click (Codex on 23ea538).
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer > 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let b = entry[kCGWindowBounds as String] as? NSDictionary,
                  let f = CGRect(dictionaryRepresentation: b), f.intersects(bounds)
            else { return nil }
            let owner = entry[kCGWindowOwnerName as String] as? String ?? ""
            let title = entry[kCGWindowName as String] as? String ?? ""
            if Self.isSystemCursor(pid: pid, layer: layer, title: title) { return nil }
            let frame = Rect(x: f.minX, y: f.minY, width: f.width, height: f.height)
            guard Self.isCoveringOverlay(frame: frame, systemDock: Self.isSystemDock(pid: pid), boundProcess: pid == boundPid,
                                         screen: screen.frame, menuBar: Double(menuBar)) else { return nil }
            return PlatformWindow(windowId: number, pid: pid, appName: owner,
                                  title: entry[kCGWindowName as String] as? String ?? "", frame: frame)
        }
    }

    /// Whether a window above the normal layer counts as covering what is
    /// under it: fail closed. Only three things are left out: the Dock's
    /// display-wide layer, anything confined to the menu bar strip (status
    /// items, the menu bar itself), and windows input routing never picks
    /// (2 points or less on a side).
    /// An unknown layer spanning the whole display (a gesture utility's
    /// transparent overlay looks exactly like an opaque one in the window
    /// list) counts: what the user sees may not be what is acted on.
    static func isCoveringOverlay(frame f: Rect, systemDock: Bool, boundProcess: Bool = false, screen s: Rect, menuBar: Double) -> Bool {
        let spansDisplay = f.x <= s.x + 1 && f.y <= s.y + 1
            && f.x + f.width >= s.x + s.width - 1 && f.y + f.height >= s.y + s.height - 1
        if systemDock && spansDisplay { return false }
        // Another process's item in the menu bar strip cannot take input
        // posted to the bound process; the bound process's own can (input
        // routing picks any of its windows), so those count (Codex on 536bb4d).
        if !boundProcess && f.y <= s.y + 1 && f.y + f.height <= s.y + menuBar + 1 { return false }
        // Left out only what input routing can never pick: BackgroundInput's
        // topWindow takes any window larger than 2 points both ways, so the
        // same cutoff applies here (Codex on 4952c9e, 8c1ebc1).
        if f.width <= 2 || f.height <= 2 { return false }
        return true
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

    /// Whether an engine failure proves the action performed nothing (#170
    /// not_performed). Only the engine's structured record says so (#173):
    /// `delivery` == "notPerformed", set by the execution path itself before
    /// anything was submitted. "submitted", "unknown" or no record at all
    /// (an engine that does not say) is never not performed.
    static func notPerformed(delivery: String?) -> Bool {
        delivery == "notPerformed"
    }

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
            let before = Self.notPerformed(delivery: response.delivery)
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
