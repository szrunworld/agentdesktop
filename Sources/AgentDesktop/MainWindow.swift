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
    let previews: PreviewWindowRegistry
    /// Live pictures for this window and the preview windows: one capture
    /// stream per Desktop display, only while a visible view shows it.
    let frames: DesktopFrameHub
    private(set) var previewWindows: PreviewWindows!
    private var pruning: AnyCancellable?
    private(set) var window: NSWindow?
    /// Times the window was closed; tests read it.
    private(set) var closeCount = 0

    /// `frames` is explicit: the app passes ScreenCaptureKit, tests a fake.
    init(store: ShellStore, frames: DesktopFrameHub) {
        self.store = store
        self.frames = frames
        self.previews = PreviewWindowRegistry(frames: frames)
        super.init()
        // Nothing streams for the main window until it is shown.
        frames.setScopeVisible(DesktopFrameHub.mainScope, false)
        previewWindows = PreviewWindows(store: store, registry: previews)
        // A preview of a Desktop that is gone closes by itself. The list and
        // its state are watched together: after a disconnection the Store
        // publishes the new list before the state turns loaded again.
        pruning = store.$desktops.combineLatest(store.$desktopsState).sink { [weak self] list, state in
            guard let self, state == .loaded || state == .empty else { return }
            self.previews.sync(desktops: list)
        }
        previewWindows.openDetail = { [weak self] id in
            guard let self else { return }
            self.navigation.showDesktop(id)
            if self.previewWindows.testDisplay != nil { self.showInBackground(onDisplay: self.previewWindows.testDisplay) } else { self.show() }
        }
    }

    var isVisible: Bool { window?.isVisible ?? false }

    /// Show and bring forward (the product, on the user's request).
    func show() {
        let w = ensureWindow()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
        frames.setScopeVisible(DesktopFrameHub.mainScope, true)
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
        frames.setScopeVisible(DesktopFrameHub.mainScope, true)
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
        // Settings (U6) draws its own pages over this window's Runtime port:
        // the AI/GUI entries call ai.* on runtime/1 and appear once
        // runtime.capabilities lists them, so the host supplies no pages.
        NSHostingView(rootView: MainWindowView(store: store, navigation: navigation, previews: previews)
            .environment(\.desktopFrames, frames))
    }

    /// Hide, never quit, never stop anything.
    func windowWillClose(_ notification: Notification) {
        closeCount += 1
        frames.setScopeVisible(DesktopFrameHub.mainScope, false)
    }

    /// Hidden behind other windows, minimised or on another Space: the
    /// main window's pictures pause and resume when it can be seen again.
    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        frames.setScopeVisible(DesktopFrameHub.mainScope, w.isVisible && w.occlusionState.contains(.visible))
    }
}
