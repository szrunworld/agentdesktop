// The product host: the Runtime, the AI/GUI service, the main window and
// a small menu bar entry. Engine logic (displays, input, agent screens)
// comes from SecondScreenCore and SecondScreenRuntime and is driven only
// through the Runtime. The old engine menu (primary virtual display,
// resolution, HiDPI, window moving and its ⌃⌥⌘M hot key, per-screen
// previews) is not part of the product (decision D35); its implementation
// stays in engine/ as history.

import AppKit
import Combine
import SecondScreenCore
import SecondScreenRuntime
import AgentDesktopAI
import AgentDesktopAIUI
import AgentDesktopProtocol
import AgentDesktopGUI
import AgentDesktopRuntime
import AgentDesktopService
import AgentDesktopUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate {
    private static let displayName = HostRole.productName

    private let role: HostRole
    private(set) var menuPanel: MenuBarPanel?
    private(set) var quit: QuitController!
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
    private var showOnFirstDesktop: AnyCancellable?

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
        }

        runtime.fallback = { request in
            // Everything the engine leaves to the host is a phone command,
            // which the product does not carry (roadmap decision 4).
            .failure("\(request.command.rawValue) is not supported by \(Self.displayName)")
        }
        // The engine serves this process only (A0): the Runtime below drives
        // it in-process and is the one way in; the engine's own control
        // socket is not opened.
        // The user's own displays, so a physical Desktop can attach one
        // instead of creating a virtual display.
        runtime.hostScreens = { PhysicalDisplays.screens() }
        runtime.startInProcess()
        startRuntimeServer()

        // In process, polling for now (U1b-1); event push is U1b-2.
        let port: RuntimePort = TestFaultRuntimePort.wrap(
            runtimeService.map(InProcessRuntimePort.init(service:))
                ?? UnavailableRuntimePort(reason: "the Runtime did not start in this host"), role: role)
        store = ShellStore(runtime: port, allowSubscription: false)
        mainWindow = MainWindowController(store: store, frames: ScreenCaptureFrameSource.hub())
        Task { await store.start() }

        quit = QuitController(store: store)
        // A test copy never takes focus from the app the user is in.
        quit.activates = !role.isSideInstance
        handleQuitEvents()
        quit.hideMainWindow = { [weak self] in self?.mainWindow.close() }
        quit.keepInBackground = { [weak self] in self?.enterBackground() }
        let panel = MenuBarPanel(store: store, actions: MenuBarActions(
            openMain: { [weak self] in self?.openMain(section: nil) },
            openPreview: { [weak self] id in self?.mainWindow.previews.show(id) },
            openSettings: { [weak self] in self?.openMain(section: .settings) },
            quit: { [weak self] in self?.quit.requestQuit() }))
        menuPanel = panel

        if !role.isSideInstance {
            panel.installStatusItem()
            mainWindow.show()
        } else if let request = role.mainWindowForTest {
            quit.testDisplay = request.displayID
            if request.onFirstDesktop {
                showOnFirstDesktop = store.$desktops.sink { [weak self] list in
                    guard let self, let id = list.first.flatMap(DesktopFrameHub.displayId(of:)) else { return }
                    self.showOnFirstDesktop = nil
                    DispatchQueue.main.async {
                        self.quit.testDisplay = id
                        self.mainWindow.showInBackground(onDisplay: id)
                    }
                }
            } else {
                mainWindow.showInBackground(onDisplay: request.displayID)
            }
            if let d = request.displayID, ProcessInfo.processInfo.environment["AGENTDESKTOP_MENU_PANEL"] == "1" {
                panel.showTestWindow(onDisplay: d)
            }
        }
    }

    /// Main window back (and the Dock icon, if the app was in the
    /// background), optionally on one entry.
    func openMain(section: MainSection?) {
        if let section { mainWindow.navigation.open(section) }
        if role.isSideInstance {
            mainWindow.showInBackground(onDisplay: quit.testDisplay)
        } else {
            if NSApp.activationPolicy() != .regular { NSApp.setActivationPolicy(.regular) }
            mainWindow.show()
        }
    }

    /// P32 "保留后台": every window closes, the Dock icon goes; the menu bar
    /// entry, the Runtime, every Desktop and Run stay.
    func enterBackground() {
        mainWindow.close()
        for id in mainWindow.previews.open { mainWindow.previews.hide(id) }
        if !role.isSideInstance { NSApp.setActivationPolicy(.accessory) }
    }

    /// Quit asks first (P32). An idle test copy without windows quits
    /// straight away.
    /// The Dock's Quit and other quit Apple events: AppKit's own handler
    /// calls terminate directly, which forces termination while the quit
    /// dialog is open; this one goes through the same gate as the panel.
    private func handleQuitEvents() {
        NSAppleEventManager.shared().setEventHandler(self, andSelector: #selector(quitEvent(_:withReply:)),
                                                     forEventClass: AEEventClass(kCoreEventClass),
                                                     andEventID: AEEventID(kAEQuitApplication))
    }

    @objc private func quitEvent(_ event: NSAppleEventDescriptor, withReply reply: NSAppleEventDescriptor) {
        guard let quit else { return }
        quit.holdQuitEvent()
        quit.requestQuit()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quit == nil || quit.approved { return .terminateNow }
        if role.isSideInstance, role.mainWindowForTest == nil, !role.quitDialogForTest { return .terminateNow }
        if quit.isAsking { return .terminateLater }
        quit.markAsking()
        quit.markAsking()
        Task { await quit.begin() }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        mainWindow?.frames.stopAll()
        store?.stop()
        runtimeServer?.stop()
        runtime.stop()
    }

    /// Closing the main window keeps the app, its Desktops and its Runs.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon reopens the main window whenever it is not visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !role.isSideInstance, !mainWindow.isVisible { openMain(section: nil) }
        return true
    }

    /// Model connections, profiles, capability tests and GUI runs. GUI runs
    /// get the Runtime's ports only when real GUI input is switched on;
    /// otherwise there is no unit.run executor and unit.run answers unsupported_backend.
    private func startAIService(runtime: RuntimeService, records: String) {
        let enabled = role.guiExecutionEnabled
        let credentialBackend = role.credentialBackend
        let ports = RuntimeGuiPorts(service: runtime)
        Task {
            do {
                let backend = enabled ? GuiExecutionBackend(
                    ports: GuiExplorerPorts(observation: ports, execution: ports, audit: NoGuiAudit()),
                    features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"],
                                                 independentDesktopConcurrency: true)) : nil
                let credentials: CredentialStore
                switch credentialBackend {
                case .keychain: credentials = KeychainCredentialStore()
                case .files(let directory): credentials = try FileCredentialStore(directory: directory.path)
                }
                let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
                    databasePath: records + "/ai.sqlite", credentials: credentials, executionBackend: backend,
                    actionOutcomes: { runIds, from, to in try runtime.actionOutcomes(runIds: runIds, from: from, to: to) }))
                // A2: one endpoint. The AI service answers ai.* through the
                // Runtime's server; it has no socket of its own.
                let served = runtime.contract.methods.filter { $0.servedBy == "ai-service" }.map(\.method)
                runtime.registerExtensions(RuntimeBridge.handlers(service, methods: served))
                runtime.registerCapabilitySection("gui") { RuntimeBridge.guiCapabilities(service) }
                // A6: unit.run, only while real GUI input is switched on.
                if let units = service.units { runtime.registerUnitExecutor(units, ports: ports) }
                // A4 R4: a revoked client's AI operations stop.
                runtime.onAccessWithdrawn { clientId in Task { await service.accessWithdrawn(clientId: clientId) } }
                await MainActor.run {
                    self.aiService = service
                    // The AI/GUI pages live in Settings and keep their
                    // contract v1 client until U6.
                    let client = InProcessContractClient(router: service.router(callerScope: "uid:\(getuid())"),
                                                         guiCapabilities: { service.guiCapabilities() },
                                                         runs: Self.runtimeRuns(runtime))
                    self.mainWindow.attachAISettings(AISettingsModel(client: client))
                }
            } catch {
                FileHandle.standardError.write(Data("AI service unavailable: \(error)\n".utf8))
            }
        }
    }

    /// The main window's way to its Runs (A6): unit Runs it starts are
    /// Durable (in-process, never on the wire); reading and stopping go
    /// through the Runtime as the owner. Off the cooperative pool: the
    /// Runtime answers synchronously.
    nonisolated static func runtimeRuns(_ runtime: RuntimeService) -> RuntimeRunsPort {
        let owner = ConnectionState(peerUID: getuid())
        _ = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"w05-handshake","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"agentdesktop-window","version":"1"}}}"#.utf8),
                            on: owner)
        @Sendable func offPool<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
            await withCheckedContinuation { cont in DispatchQueue.global().async { cont.resume(returning: body()) } }
        }
        return RuntimeRunsPort(
            start: { params in await offPool { runtime.startDurableUnitRun(params: params) } },
            call: { method, params, requestId in
                await offPool {
                    let line = JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)),
                                              ("requestId", .string(requestId ?? RuntimeRequest.newId(prefix: "w06"))),
                                              ("method", .string(method)), ("params", params)]).encodedData()
                    return runtime.respond(to: line, on: owner).result
                }
            })
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
                identity: identity, backend: MacBackend(),
                platform: EnginePlatform(engine: runtime, displays: { PhysicalDisplays.report() }), records: records)
            // A4: pairings and owner-only calls from socket clients are
            // decided by the user in this app's trusted window.
            service.confirmer = TrustedConfirmationWindow()
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
                      self.agentScreens.screens.isEmpty, self.quit?.isAsking != true else { return }
                self.quit.requestQuit()
            }
        }
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
