import AgentDesktopAIUI
import AgentDesktopUI
import AppKit
import Combine
import SwiftUI

/// The one main window (docs/plan/06 §6.1). Closing it only hides it: the
/// host, its Runtime, every Desktop and Run keep going (ADR-02); the Dock
/// icon and the menu bar bring it back. The Store it shows belongs to the
/// host and keeps its connection when the window closes.
@MainActor
final class MainWindowController: NSObject, NSWindowDelegate {
    let store: ShellStore
    let navigation = ShellNavigation()
    let previews = PreviewWindowRegistry()
    private(set) var previewWindows: PreviewWindows!
    private var pruning: AnyCancellable?
    private var aiSettings: AISettingsModel?
    private(set) var window: NSWindow?
    /// Times the window was closed; tests read it.
    private(set) var closeCount = 0

    init(store: ShellStore) {
        self.store = store
        super.init()
        previewWindows = PreviewWindows(store: store, registry: previews)
        // A preview of a Desktop that is gone closes by itself.
        pruning = store.$desktops.sink { [weak self] list in
            guard let self, self.store.desktopsState == .loaded || self.store.desktopsState == .empty else { return }
            self.previews.prune(existing: Set(list.compactMap { $0["desktopId"]?.stringValue }))
        }
        previewWindows.openDetail = { [weak self] id in
            guard let self else { return }
            self.navigation.showDesktop(id)
            if self.previewWindows.testDisplay != nil { self.showInBackground(onDisplay: self.previewWindows.testDisplay) } else { self.show() }
        }
    }

    /// The AI/GUI pages for Settings, once the AI service is up.
    func attachAISettings(_ model: AISettingsModel) {
        aiSettings = model
        // Rebuild the content so Settings picks the pages up.
        if let window { window.contentView = hosting() }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show and bring forward (the product, on the user's request).
    func show() {
        let w = ensureWindow()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Show without activating the app or taking key focus: a test copy's
    /// window, placed on the given display (one of its own virtual
    /// Desktops) so the user's screens are not touched.
    func showInBackground(onDisplay displayID: CGDirectDisplayID?) {
        previewWindows.testDisplay = displayID
        let w = ensureWindow()
        if let displayID, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) {
            let f = screen.frame
            w.setFrame(NSRect(x: f.minX, y: f.maxY - min(w.frame.height, f.height),
                              width: min(w.frame.width, f.width), height: min(w.frame.height, f.height)), display: false)
        }
        w.orderFrontRegardless()
    }

    func close() {
        window?.close()
    }

    func ensureWindow() -> NSWindow {
        if let window { return window }
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: ADLayout.designSize),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = HostRole.productName
        w.minSize = NSSize(width: 1100, height: 720)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = hosting()
        w.center()
        w.setFrameAutosaveName("AgentDesktopMainWindow")
        window = w
        return w
    }

    private func hosting() -> NSView {
        let ai = aiSettings
        let nav = navigation
        return NSHostingView(rootView: MainWindowView(store: store, navigation: nav, previews: previews, settings: { page in
            ai?.view(for: page, navigation: nav)
        }))
    }

    /// Hide, never quit, never stop anything.
    func windowWillClose(_ notification: Notification) {
        closeCount += 1
    }
}
