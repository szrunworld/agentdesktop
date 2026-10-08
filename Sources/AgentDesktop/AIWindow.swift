import AgentDesktopAIUI
import AgentDesktopService
import AppKit
import SwiftUI

/// The AI and GUI settings and diagnostics window (W01–W08), opened from
/// the menu bar. It talks to the service the host already composed,
/// in process, as the owner; nothing here takes input or holds a key.
@MainActor
final class AIWindowController {
    private var window: NSWindow?

    func show(service: AgentDesktopService) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let client = InProcessContractClient(router: service.router(callerScope: "uid:\(getuid())", trustedOwner: true))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "AI 与 GUI"
        window.minSize = NSSize(width: 900, height: 600)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: AIGUIRootView(client: client))
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window?.close()
        window = nil
    }
}
