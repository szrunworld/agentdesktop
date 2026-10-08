import AgentDesktopUI
import AppKit
import SwiftUI

/// P32: what quitting does. Quit (⌘Q, the Dock, the menu bar panel) asks
/// first: cancel, hide the main window, keep running in the background, or
/// stop all input and quit once every Run is quiet (UC51). Nothing here
/// decides that a Run has stopped; QuitFlow reads it from the Runtime.
@MainActor
final class QuitController: NSObject, NSWindowDelegate {
    let store: ShellStore
    /// A test copy keeps the dialog on its own display and never activates.
    var testDisplay: CGDirectDisplayID?
    var hideMainWindow: () -> Void = {}
    var keepInBackground: () -> Void = {}
    /// NSApp.reply(toApplicationShouldTerminate:), injectable for tests.
    var reply: (Bool) -> Void = { NSApp.reply(toApplicationShouldTerminate: $0) }
    /// Whether showing the dialog may activate the app; a test copy only
    /// orders it front, leaving focus where the user has it.
    var activates = true
    /// NSApp.terminate, injectable for tests.
    var terminate: () -> Void = { NSApp.terminate(nil) }
    var clock: PollClock = SystemPollClock()
    private(set) var flow: QuitFlow?
    /// Reading the active count; tests wait on it.
    private(set) var counting: Task<Void, Never>?
    private(set) var window: NSWindow?
    private(set) var choices: [QuitChoice] = []
    private var answered = true
    /// True once quitting is approved; the next terminate goes through.
    private(set) var approved = false

    init(store: ShellStore) {
        self.store = store
    }

    var isAsking: Bool { !answered }

    /// Every quit request of the host (the menu bar panel, the Dock, the
    /// idle timer) comes here. While the dialog waits for an answer, a
    /// second NSApp.terminate makes AppKit force an immediate termination
    /// ("Unexpected call to terminate: while still determining whether to
    /// terminate"), which skips stopping input and waiting for quiet Runs.
    /// So a request then only brings the dialog forward.
    func requestQuit() {
        guard isAsking else { terminate(); return }
        guard let window else { return }
        bringForward(window)
    }

    private func bringForward(_ w: NSWindow) {
        if testDisplay != nil || !activates {
            w.orderFrontRegardless()
        } else {
            w.makeKeyAndOrderFront(nil)
            NSApp.activate()
        }
    }

    /// Show the dialog; the app waits (terminateLater) for the answer. The
    /// dialog appears at once: the in-process port answers in order, so a
    /// stalled earlier request would otherwise hold it back. The count of
    /// active Runs fills in when the Runtime answers.
    func begin(show: Bool = true) async {
        answered = false
        let flow = QuitFlow(runtime: store.runtime, clock: clock)
        self.flow = flow
        counting = Task { await flow.countActive() }
        guard show else { return }
        let w = window ?? NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 300),
                                   styleMask: [.titled], backing: .buffered, defer: false)
        w.title = "退出 Agent Desktop"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: QuitDialogView(flow: flow) { [weak self] c in
            self?.choose(c)
        })
        window = w
        if let testDisplay, let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == testDisplay
        }) {
            let f = screen.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - 300, y: f.midY - 120))
        } else {
            w.center()
        }
        bringForward(w)
    }

    func choose(_ choice: QuitChoice) {
        choices.append(choice)
        switch choice {
        case .cancel:
            flow?.cancel()
            finish(quit: false)
        case .hideWindow:
            hideMainWindow()
            finish(quit: false)
        case .keepInBackground:
            keepInBackground()
            finish(quit: false)
        case .stopAndQuit:
            guard let flow else { return }
            flow.stopAndWait()
            Task { [weak self] in
                while let self, !Task.isCancelled {
                    switch flow.phase {
                    case .quiet:
                        self.approved = true
                        self.finish(quit: true)
                        return
                    case .cancelled:
                        return
                    default:
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }
    }

    private func finish(quit: Bool) {
        guard !answered else { return }
        answered = true
        window?.orderOut(nil)
        reply(quit)
    }
}

/// P31 in the menu bar: a popover with MenuBarPanelView. A test copy has no
/// menu bar entry; it can show the same panel in a window on its own
/// display (AGENTDESKTOP_MENU_PANEL=1) for acceptance.
@MainActor
final class MenuBarPanel: NSObject {
    let store: ShellStore
    let actions: MenuBarActions
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()
    private(set) var testWindow: NSWindow?

    init(store: ShellStore, actions: MenuBarActions) {
        self.store = store
        self.actions = actions
        super.init()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarPanelView(store: store, actions: wrapped))
    }

    /// Actions close the popover first.
    private var wrapped: MenuBarActions {
        let a = actions
        return MenuBarActions(openMain: { [weak self] in self?.popover.close(); a.openMain() },
                              openPreview: { [weak self] in self?.popover.close(); a.openPreview($0) },
                              openSettings: { [weak self] in self?.popover.close(); a.openSettings() },
                              quit: { [weak self] in self?.popover.close(); a.quit() })
    }

    func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: HostRole.productName)
        item.button?.target = self
        item.button?.action = #selector(toggle(_:))
        statusItem = item
    }

    @objc private func toggle(_ sender: NSStatusBarButton) {
        if popover.isShown { popover.close(); return }
        popover.show(relativeTo: sender.bounds, of: sender, preferredEdge: .minY)
    }

    func showTestWindow(onDisplay displayID: CGDirectDisplayID) {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 520), styleMask: [.titled],
                         backing: .buffered, defer: false)
        w.title = "菜单栏弹层（测试副本）"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: MenuBarPanelView(store: store, actions: actions))
        if let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID
        }) {
            let f = screen.visibleFrame
            w.setFrameTopLeftPoint(NSPoint(x: f.maxX - 360, y: f.maxY - 10))
        }
        w.orderFrontRegardless()
        testWindow = w
    }
}
