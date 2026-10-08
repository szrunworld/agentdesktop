import AgentDesktopUI
import AppKit
import SwiftUI

/// One window per previewed Desktop (P08), keyed by desktopId. Closing a
/// preview closes only the window: the Desktop, its input and its Runs are
/// untouched (UC14). The picture is the live capture of the Desktop's
/// display, shared through the registry's DesktopFrameHub; closing the
/// window lets go of it, and it pauses while the window cannot be seen.
@MainActor
final class PreviewWindows: NSObject, NSWindowDelegate {
    let store: ShellStore
    let registry: PreviewWindowRegistry
    /// A test copy keeps its windows on this display and never activates.
    var testDisplay: CGDirectDisplayID?
    /// Opens the main window on a Desktop's detail.
    var openDetail: ((String) -> Void)?
    private(set) var windows: [String: NSWindow] = [:]

    init(store: ShellStore, registry: PreviewWindowRegistry) {
        self.store = store
        self.registry = registry
        super.init()
        registry.present = { [weak self] id in self?.show(id) }
        registry.dismiss = { [weak self] id in self?.windows[id]?.close() }
    }

    func window(for desktopId: String) -> NSWindow {
        if let w = windows[desktopId] { return w }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 640),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        let name = store.desktops.first { $0["desktopId"]?.stringValue == desktopId }?["name"]?.stringValue ?? desktopId
        w.title = "\(name) 预览"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.identifier = NSUserInterfaceItemIdentifier(desktopId)
        w.contentView = NSHostingView(rootView: DesktopPreviewView(
            store: store, desktopId: desktopId,
            hide: { [weak self] in self?.registry.hide(desktopId) },
            openDetail: { [weak self] in self?.openDetail?(desktopId) })
            .environment(\.desktopFrames, registry.frames))
        w.cascadeTopLeft(from: NSPoint(x: 80 + 24 * CGFloat(windows.count), y: 700 - 24 * CGFloat(windows.count)))
        windows[desktopId] = w
        return w
    }

    func show(_ desktopId: String) {
        let w = window(for: desktopId)
        if let testDisplay {
            if let screen = NSScreen.screens.first(where: {
                ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == testDisplay
            }) {
                let f = screen.visibleFrame
                w.setFrame(NSRect(x: f.maxX - min(900, f.width), y: f.minY, width: min(900, f.width),
                                  height: min(640, f.height)), display: false)
            }
            w.orderFrontRegardless()
        } else {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
        windows.removeValue(forKey: id)
        registry.closed(id)
        // Drop the hosted views now rather than whenever the window is freed.
        w.contentView = nil
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue, windows[id] === w else { return }
        registry.setVisible(id, w.isVisible && w.occlusionState.contains(.visible))
    }
}
