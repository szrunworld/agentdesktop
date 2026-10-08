// The product host: the Runtime, the AI/GUI service, the main window and
// a small menu bar entry. Engine logic (displays, input, agent screens)
// comes from SecondScreenCore and SecondScreenRuntime and is driven only
// through the Runtime. The old engine menu (primary virtual display,
// resolution, HiDPI, window moving and its ⌃⌥⌘M hot key, per-screen
// previews) is not part of the product (decision D35); its implementation
// stays in engine/ as history.

import AppKit
import SecondScreenCore
import SecondScreenRuntime
import AgentDesktopAI
import AgentDesktopAIUI
import AgentDesktopContracts
import AgentDesktopGUI
import AgentDesktopProtocol
import AgentDesktopRuntime
import AgentDesktopService
import AgentDesktopUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private static let displayName = HostRole.productName

    private let role: HostRole
    private var statusItem: NSStatusItem?
    /// Agent screens and input into them, driven by the Runtime in process.
    private let runtime: AgentRuntime
    private var agentScreens: AgentScreens { runtime.screens }
    /// The Runtime API endpoint every external entry uses.
    private var runtimeServer: RuntimeServer?
    private var runtimeService: RuntimeService?
    /// The AI/GUI service and its endpoint.
    private var aiService: AgentDesktopService?
    /// The main window and the Store it shows; the Store lives as long as
    /// the host, so closing the window changes nothing in the Runtime.
    private(set) var store: ShellStore!
    private(set) var mainWindow: MainWindowController!

    init(role: HostRole) {
        self.role = role
        self.runtime = AgentRuntime(serialBase: role.agentSerialBase)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if role.isSideInstance {
            // A test copy keeps to the background; it quits once its agent
            // has left it idle.
            quitWhenIdle()
        } else {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.image = NSImage(systemSymbolName: "display.2", accessibilityDescription: Self.displayName)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }

        runtime.fallback = { request in
            // Everything the engine leaves to the host is a phone command,
            // which the product does not carry (roadmap decision 4).
            .failure("\(request.command.rawValue) is not supported by \(Self.displayName)")
        }
        // The engine serves this process only (A0): the Runtime below drives
        // it in-process and is the one way in; the engine's own control
        // socket is not opened.
        runtime.startInProcess()
        startRuntimeServer()

        // In process, polling for now (U1b-1); event push is U1b-2.
        let port: RuntimePort = runtimeService.map(InProcessRuntimePort.init(service:))
            ?? UnavailableRuntimePort(reason: "the Runtime did not start in this host")
        store = ShellStore(runtime: port, allowSubscription: false)
        mainWindow = MainWindowController(store: store)
        Task { await store.start() }

        if !role.isSideInstance {
            mainWindow.show()
        } else if let request = role.mainWindowForTest {
            mainWindow.showInBackground(onDisplay: request.displayID)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.stop()
        runtimeServer?.stop()
        runtime.stop()
    }

    /// Closing the main window keeps the app, its Desktops and its Runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon reopens the main window whenever it is not visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !role.isSideInstance, !mainWindow.isVisible { mainWindow.show() }
        return true
    }

    /// Model connections, profiles, capability tests and GUI runs. GUI runs
    /// get the Runtime's ports only when real GUI input is switched on;
    /// otherwise gui.runs.start answers CAPABILITY_MISMATCH.
    private func startAIService(runtime: RuntimeService, records: String) {
        let enabled = role.guiExecutionEnabled
        let credentialBackend = role.credentialBackend
        let ports = RuntimeGuiPorts(service: runtime)
        Task {
            do {
                let backend = enabled ? GuiExecutionBackend(
                    ports: GuiExplorerPorts(observation: ports, execution: ports, audit: NoGuiAudit()),
                    sessions: ports,
                    features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"],
                                                 independentDesktopConcurrency: true)) : nil
                let credentials: CredentialStore
                switch credentialBackend {
                case .keychain: credentials = KeychainCredentialStore()
                case .files(let directory): credentials = try FileCredentialStore(directory: directory.path)
                }
                let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
                    databasePath: records + "/ai.sqlite", credentials: credentials, executionBackend: backend))
                // A2: one endpoint. The AI service answers ai.* through the
                // Runtime's server; there is no ai.sock any more.
                let served = runtime.contract.methods.filter { $0.servedBy == "ai-service" }.map(\.method)
                runtime.registerExtensions(RuntimeBridge.handlers(service, methods: served))
                runtime.registerCapabilitySection("gui") { RuntimeBridge.guiCapabilities(service) }
                await MainActor.run {
                    self.aiService = service
                    // The AI/GUI pages live in Settings and keep their
                    // contract v1 client until U6.
                    let client = InProcessContractClient(router: service.router(callerScope: "uid:\(getuid())", trustedOwner: true))
                    self.mainWindow.attachAISettings(AISettingsModel(client: client))
                }
            } catch {
                FileHandle.standardError.write(Data("AI service unavailable: \(error)\n".utf8))
            }
        }
    }

    private func startRuntimeServer() {
        let path = role.runtimeEndpoint.path
        let build = Bundle.main.resourceURL.map(BuildInfo.load(resourcesDirectory:)) ?? .unknown
        let identity = RuntimeIdentity(instanceId: RuntimeRequest.newId(prefix: "rt"), pid: getpid(),
                                       startedAt: Timestamp.string(Date()), endpoint: path,
                                       buildSource: build.source, builtAt: build.builtAt)
        do {
            // Records beside the endpoint: <dir>/runtime (product) or
            // <dir>/<name>.runtime (side instance), owner-only.
            let records = role.runtimeRecordsDirectory.path
            let service = try RuntimeService.persistent(
                identity: identity, backend: MacBackend(), platform: EnginePlatform(engine: runtime), records: records)
            let server = RuntimeServer(path: path, service: service)
            try server.start()
            runtimeServer = server
            runtimeService = service
            startAIService(runtime: service, records: records)
        } catch {
            let message = "The agentdesktop command cannot reach \(Self.displayName): \(error)"
            if role.isSideInstance {
                FileHandle.standardError.write(Data((message + "\n").utf8))
            } else {
                presentError(message)
            }
        }
    }

    // MARK: Test copies

    /// A side instance quits after this long without requests, unless it
    /// still has an agent screen.
    private static let sideInstanceIdleQuit: TimeInterval = 30 * 60

    private func quitWhenIdle() {
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, Date().timeIntervalSince(self.runtime.lastRequest) > Self.sideInstanceIdleQuit,
                      self.agentScreens.screens.isEmpty else { return }
                NSApp.terminate(nil)
            }
        }
    }

    /// Side instances run to test builds of the product, which keep off the
    /// menu bar; each can be quit from here.
    private func testCopiesItem() -> NSMenuItem? {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let copies = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .filter { $0.processIdentifier != ownPID }
        guard !copies.isEmpty else { return nil }
        let parent = NSMenuItem(title: "测试副本（\(copies.count)）", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for copy in copies {
            var title = "退出 " + Self.copyName(copy.bundleURL)
            if let launched = copy.launchDate {
                title += "（\(launched.formatted(date: .omitted, time: .shortened)) 起）"
            }
            let entry = item(title, #selector(quitTestCopy(_:)))
            entry.representedObject = copy.processIdentifier
            entry.toolTip = copy.bundleURL?.path
            submenu.addItem(entry)
        }
        parent.submenu = submenu
        return parent
    }

    /// "agentdesktop-feature" for …/agentdesktop-feature/build/Agent Desktop.app,
    /// the folder it was built in; otherwise its folder and name.
    static func copyName(_ url: URL?) -> String {
        guard let url else { return "unknown" }
        let folder = url.deletingLastPathComponent()
        if folder.lastPathComponent == "build" {
            return folder.deletingLastPathComponent().lastPathComponent
        }
        return folder.lastPathComponent + "/" + url.deletingPathExtension().lastPathComponent
    }

    @objc private func quitTestCopy(_ sender: NSMenuItem) {
        guard let pid = sender.representedObject as? pid_t else { return }
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    // MARK: Menu bar (P31: status, open the main window, stop all input)

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        for line in Self.statusLines(store) {
            let status = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())
        let open = item("打开 \(Self.displayName)", #selector(openMainWindow))
        open.keyEquivalent = "o"
        menu.addItem(open)
        menu.addItem(.separator())
        let connected: Bool = { if case .connected = store.connection { return true }; return false }()
        if store.inputAdmission == "stopped" {
            let resume = item("恢复输入", #selector(enableInput))
            resume.isEnabled = connected
            menu.addItem(resume)
        } else {
            let stop = item("停止所有输入…", #selector(stopAllInput))
            stop.isEnabled = connected
            menu.addItem(stop)
        }
        menu.addItem(.separator())
        if let copies = testCopiesItem() {
            menu.addItem(copies)
            menu.addItem(.separator())
        }
        menu.addItem(NSMenuItem(title: "退出 \(Self.displayName)", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
    }

    /// What the menu says about the Runtime: only what the Store last read.
    static func statusLines(_ store: ShellStore?) -> [String] {
        guard let store else { return ["正在启动"] }
        switch store.connection {
        case .connecting: return ["正在连接本机服务"]
        case .disconnected(let p): return ["Runtime 未连接：\(p.title)"]
        case .connected:
            var lines = ["\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中"]
            switch store.inputAdmission {
            case "stopped": lines.append("输入已停止")
            case "stopping": lines.append("正在停止输入")
            default: break
            }
            return lines
        }
    }

    private func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openMainWindow() {
        mainWindow.show()
    }

    /// Global stop is explicit (P31): confirm, then runtime.stopAll.
    @objc private func stopAllInput() {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "停止所有输入？"
        alert.informativeText = "所有平台运行立即不再接受新输入并进入停止流程；已经开始的动作要等执行端确认静止。外部 Agent 应用不会被结束。"
        alert.addButton(withTitle: "停止所有输入")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { await store.stopAllInput() }
    }

    @objc private func enableInput() {
        Task { await store.enableInput() }
    }

    private func presentError(_ message: String) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = Self.displayName
        alert.informativeText = message
        alert.runModal()
    }
}

/// Placeholder audit for the backend: AgentDesktopService replaces it with
/// its durable audit (durableAudit, the default).
private struct NoGuiAudit: GuiAuditPort {
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) {}
    func reserveAction(_ proposal: GuiProposal) -> String { "act_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "") }
    func recordAction(_ receipt: GuiActionReceipt) {}
}
