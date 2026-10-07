import AppKit
import Combine
import Foundation

/// What the service answered last: the UI shows one of these at the top.
enum ServiceState: Equatable {
    case checking
    case ready(ServiceIdentity)
    case runtimeMissing(String)
    case offline(String)
    case connectionFailed(String)
    case versionMismatch(found: String, supported: String)
    case capabilityMissing(String)
    case error(String)

    static func from(_ error: Error) -> ServiceState {
        guard let e = error as? TaskClientError else { return .error(error.localizedDescription) }
        switch e {
        case .offline(let m): return .offline(m)
        case .capabilityMissing(let m): return .capabilityMissing(m)
        case .versionMismatch(let f, let s): return .versionMismatch(found: f, supported: s)
        case .connectionFailed(let m): return .connectionFailed(m)
        case .notFound(let m), .conflict(let m), .invalidInput(let m), .leaseHeld(let m): return .error(m)
        case .other(let c, let m): return .error("\(c): \(m)")
        }
    }
}

/// The main window's data: the client, the service's state and the task
/// views, refreshed on a timer. No state of its own beyond what was read.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var serviceState: ServiceState = .checking
    @Published private(set) var tasks: [TaskView] = []
    @Published private(set) var lastRefresh: Date?
    @Published var mode: TaskClientMode
    @Published var permissions = PermissionStatus.check()
    /// Receipts of the controls sent from this window, newest first.
    @Published private(set) var receipts: [ControlReceipt] = []

    let role: HostRole
    private(set) var client: TaskClient
    private var timer: Timer?

    init(role: HostRole, mode: TaskClientMode = .current) {
        self.role = role
        self.mode = mode
        self.client = Self.makeClient(mode)
    }

    static func makeClient(_ mode: TaskClientMode) -> TaskClient {
        switch mode {
        case .sample: return SampleTaskClient()
        case .cli:
            if let cli = CLITaskClient.bundled() { return CLITaskClient(executable: cli) }
            return MissingRuntimeClient()
        }
    }

    func setMode(_ mode: TaskClientMode) {
        guard mode != self.mode else { return }
        self.mode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "taskClient")
        client = Self.makeClient(mode)
        tasks = []
        serviceState = .checking
        Task { await refresh() }
    }

    func start() {
        Task { await refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    func refresh() async {
        permissions = PermissionStatus.check()
        do {
            let service = try await client.service()
            serviceState = .ready(service)
            tasks = try await client.views()
        } catch {
            if client is MissingRuntimeClient {
                serviceState = .runtimeMissing("产品包里还没有 task runtime（Contents/Resources/task-runtime）")
            } else {
                serviceState = ServiceState.from(error)
            }
            if case .ready = serviceState {} else if !(client is SampleTaskClient) { tasks = [] }
        }
        lastRefresh = Date()
    }

    func send(_ operation: Operation, to task: TaskView, payload: [String: String]? = nil) async -> ControlReceipt? {
        let request = ControlRequest(taskId: task.id, operation: operation, payload: payload, requestId: UUID().uuidString)
        do {
            let receipt = try await client.control(request)
            receipts.insert(receipt, at: 0)
            await refresh()
            return receipt
        } catch {
            serviceState = ServiceState.from(error)
            return nil
        }
    }

    var current: [TaskView] { tasks.filter { !$0.state.isTerminal } }
    var history: [TaskView] { tasks.filter { $0.state.isTerminal } }
    var pending: [TaskView] { tasks.filter { $0.state == .waiting || $0.state == .interrupted || $0.state == .unknown } }
}

/// Stands in for the CLI when the bundle has no command line (a `swift run`
/// outside the bundle): every call is a missing capability.
final class MissingRuntimeClient: TaskClient {
    let scope = ClientScope(clientId: HostRole.bundleID, agentIds: nil)
    private func missing() -> TaskClientError { .capabilityMissing("this build has no bundled command line or task runtime") }
    func service() async throws -> ServiceIdentity { throw missing() }
    func views() async throws -> [TaskView] { throw missing() }
    func view(_ taskId: String) async throws -> TaskView { throw missing() }
    func control(_ request: ControlRequest) async throws -> ControlReceipt { throw missing() }
}

/// The real grants and the runtime, as the wizard checks them.
struct PermissionStatus: Equatable {
    var screenRecording: Bool
    var accessibility: Bool
    /// Contents/Resources/task-runtime exists in this bundle.
    var runtimeInstalled: Bool
    var runtimePath: String

    static func check() -> PermissionStatus {
        let runtime = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/task-runtime")
        var isDir: ObjCBool = false
        let installed = FileManager.default.fileExists(atPath: runtime.path, isDirectory: &isDir) && isDir.boolValue
        return PermissionStatus(screenRecording: CGPreflightScreenCaptureAccess(), accessibility: AXIsProcessTrusted(),
                                runtimeInstalled: installed, runtimePath: runtime.path)
    }

    static func requestScreenRecording() {
        CGRequestScreenCaptureAccess()
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ url: String) {
        if let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
