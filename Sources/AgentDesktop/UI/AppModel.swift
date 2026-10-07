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
    /// Bumped on every client switch; a result that comes back with an older
    /// generation belongs to a client that is gone and is dropped.
    private(set) var generation = 0
    private var timer: Timer?
    /// Windows that asked for polling; the one timer runs while any is open.
    private var pollers = 0

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
        switchClient(Self.makeClient(mode))
    }

    /// Replaces the client: a new generation, nothing of the old one kept.
    func switchClient(_ next: TaskClient) {
        generation += 1
        client = next
        tasks = []
        receipts = []
        serviceState = .checking
        lastRefresh = nil
        Task { await refresh() }
    }

    /// Idempotent: the first caller starts the one timer, later callers
    /// only count; `stop` from each of them ends it with the last.
    func start() {
        pollers += 1
        Task { await refresh() }
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
    }

    func stop() {
        pollers = max(0, pollers - 1)
        guard pollers == 0 else { return }
        timer?.invalidate()
        timer = nil
    }

    var isPolling: Bool { timer != nil }

    func refresh() async {
        permissions = PermissionStatus.check()
        let client = self.client
        let gen = generation
        do {
            let service = try await client.service()
            let views = try await client.views()
            guard gen == generation else { return }  // answered by a client that was switched away
            serviceState = .ready(service)
            tasks = views
        } catch {
            guard gen == generation else { return }
            if client is MissingRuntimeClient {
                serviceState = .runtimeMissing("产品包里还没有 task runtime（Contents/Resources/task-runtime）")
            } else {
                serviceState = ServiceState.from(error)
            }
            tasks = []
        }
        lastRefresh = Date()
    }

    /// Why an operation cannot be sent right now, or nil when it can. Checked
    /// again at the click, against the service and the task as they are now,
    /// not the cached button list.
    enum Refusal: Equatable {
        case serviceNotReady
        case capabilityMissing(String)
        case notAllowedNow(TaskUiState)
        case inputMissing([String])
    }

    func refusal(for operation: TaskOperation, on taskId: String, payload: JSONValue?) async -> Refusal? {
        guard case .ready(let service) = serviceState else { return .serviceNotReady }
        if !service.task.capabilities.contains("task.control") { return .capabilityMissing("task.control") }
        let client = self.client
        let gen = generation
        guard let latest = try? await client.view(taskId), gen == generation else { return .serviceNotReady }
        guard latest.allowed.contains(operation) else { return .notAllowedNow(latest.state) }
        let missing = operation.inputFields.filter { payload?[$0] == nil }
        return missing.isEmpty ? nil : .inputMissing(missing)
    }

    func send(_ operation: TaskOperation, to task: TaskView, payload: JSONValue? = nil) async -> ControlReceipt? {
        if let why = await refusal(for: operation, on: task.id, payload: payload) {
            let reason: ControlReceipt.Reason
            switch why {
            case .serviceNotReady: reason = .init(code: "offline", message: "服务未就绪，操作未发送")
            case .capabilityMissing(let c): reason = .init(code: "capability_missing", message: "服务没有 \(c) 能力")
            case .notAllowedNow(let s): reason = .init(code: "conflict", message: "任务现在是\(TaskStateDisplay.label(s))，不再允许\(TaskStateDisplay.label(operation))")
            case .inputMissing(let f): reason = .init(code: "invalid_input", message: "缺少输入 \(f.joined(separator: ", "))")
            }
            let refused = ControlReceipt(requestId: "", taskId: task.id, operation: operation, accepted: false, acceptedAt: nil,
                                         reason: reason, executorStopped: task.executor?.stopped ?? false, settlesTo: [])
            receipts.insert(refused, at: 0)
            await refresh()
            return refused
        }
        let request = ControlRequest(taskId: task.id, operation: operation, payload: payload, requestId: UUID().uuidString)
        let client = self.client
        let gen = generation
        do {
            let receipt = try await client.control(request)
            guard gen == generation else { return nil }
            receipts.insert(receipt, at: 0)
            await refresh()
            return receipt
        } catch {
            guard gen == generation else { return nil }
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
