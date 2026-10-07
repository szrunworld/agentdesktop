import Foundation

/// The thin client the UI talks to. It reads structured views and sends
/// control requests; it keeps no state machine, scheduler or budget of its
/// own (contract §0).
protocol TaskClient: AnyObject {
    var scope: ClientScope { get }
    func service() async throws -> ServiceIdentity
    func views() async throws -> [TaskView]
    func view(_ taskId: String) async throws -> TaskView
    func control(_ request: ControlRequest) async throws -> ControlReceipt
}

/// Which client the app uses: the bundled CLI, or sample data for UI work.
enum TaskClientMode: String {
    case cli, sample

    /// `AGENTDESKTOP_TASK_CLIENT=sample|cli` wins; then the `taskClient`
    /// default; the product uses the CLI.
    static var current: TaskClientMode {
        if let env = ProcessInfo.processInfo.environment["AGENTDESKTOP_TASK_CLIENT"], let mode = TaskClientMode(rawValue: env) {
            return mode
        }
        if let stored = UserDefaults.standard.string(forKey: "taskClient"), let mode = TaskClientMode(rawValue: stored) {
            return mode
        }
        return .cli
    }
}

/// What the UI says about a task's state, and whether a stop is settled.
enum TaskStateDisplay {
    /// The word for the state. "停止中" and "暂停中" are shown until the
    /// executor is proven stopped; only then "已停止" / "已暂停".
    static func label(_ task: TaskView) -> String {
        switch task.state {
        case .queued: return "排队中"
        case .running: return task.heartbeat?.stale == true ? "失联" : "执行中"
        case .waiting: return "等待处理"
        case .pausing: return "暂停中"
        case .paused: return task.executor?.stopped == false ? "暂停中" : "已暂停"
        case .stopping: return "停止中"
        case .cancelled: return task.executor?.stopped == false ? "停止中" : "已停止"
        case .succeeded: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        case .interrupted: return "已中断，待核对"
        case .unknown: return "结果不明"
        }
    }

    /// True once a pause or cancel is settled: the executor has stopped.
    static func isSettledStop(_ task: TaskView) -> Bool {
        switch task.state {
        case .paused, .cancelled: return task.executor?.stopped ?? true
        default: return false
        }
    }

    static func label(_ operation: Operation) -> String {
        switch operation {
        case .pause: return "暂停"
        case .resume: return "继续"
        case .cancel: return "取消"
        case .approve: return "批准"
        case .deny: return "拒绝"
        case .answer: return "回答"
        case .bindAccount: return "绑定账号"
        case .openOutput: return "打开结果"
        case .resubmit: return "重新提交"
        }
    }

    static func label(_ state: TaskUiState) -> String {
        switch state {
        case .queued: return "排队中"
        case .running: return "执行中"
        case .waiting: return "等待处理"
        case .pausing: return "暂停中"
        case .paused: return "已暂停"
        case .stopping: return "停止中"
        case .cancelled: return "已停止"
        case .succeeded: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        case .interrupted: return "已中断"
        case .unknown: return "结果不明"
        }
    }
}
