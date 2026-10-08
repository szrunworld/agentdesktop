import AppKit
import ScreenCaptureKit
import SecondScreenCore
import UniformTypeIdentifiers

extension AgentScreens {
    /// Capture one window on its own (desktopIndependentWindow), so nothing
    /// lying over it shows. `screenshot --windows-only` with a window ID.
    /// The response names the window and the frame it had at the capture;
    /// a window that moved or resized during the capture is refused rather
    /// than returned with a frame it no longer has.
    public func windowScreenshot(windowID: CGWindowID, pid: pid_t?, of screen: ScreenInfo,
                                 to output: String) async -> ControlResponse {
        guard CGPreflightScreenCaptureAccess() else {
            return .failure("Agent Desktop needs the Screen Recording permission to take screenshots")
        }
        let bounds = CGRect(screen.frame)
        func current() -> WindowInfo? {
            WindowMover.allWindows().first { $0.windowID == windowID && (pid == nil || $0.pid == pid) }
        }
        guard let before = current() else {
            return .failure("window \(windowID) is not on screen" + (pid.map { " for pid \($0)" } ?? ""))
        }
        guard bounds.contains(CGPoint(x: before.frame.midX, y: before.frame.midY)) else {
            return .failure("window \(windowID) is not on screen \"\(screen.name)\"")
        }
        let scale = CGFloat(screen.hiDPI ? 2 : 1)
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return .failure("window \(windowID) cannot be captured")
            }
            let config = SCStreamConfiguration()
            config.width = max(Int(before.frame.width * scale), 1)
            config.height = max(Int(before.frame.height * scale), 1)
            config.showsCursor = false
            config.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: window), configuration: config)
            guard let after = current(), after.frame == before.frame else {
                return .failure("window \(windowID) moved, resized or closed during the capture")
            }
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
            else { return .failure("cannot write \(url.path)") }
            CGImageDestinationAddImage(destination, image, nil)
            guard CGImageDestinationFinalize(destination) else { return .failure("cannot write \(url.path)") }
        } catch {
            return .failure("screenshot of window \(windowID) failed: \(error.localizedDescription)")
        }
        var response = ControlResponse()
        response.output = url.path
        response.pid = before.pid
        response.window = WindowSummary(before)
        return response
    }
}
