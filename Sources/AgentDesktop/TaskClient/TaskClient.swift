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
/// A pause or cancel counts as settled only on the executor's own evidence:
/// `executor.stopped == true`. Without an executor record there is no
/// evidence, and the task stays "停止中"/"暂停中".
enum TaskStateDisplay {
    static let noExecutorEvidence = "缺少执行端停止证据"

    static func label(_ task: TaskView) -> String {
        switch task.state {
        case .queued: return "排队中"
        case .running: return task.heartbeat?.stale == true ? "失联" : "执行中"
        case .waiting: return "等待处理"
        case .pausing: return "暂停中"
        case .paused: return isSettledStop(task) ? "已暂停" : "暂停中"
        case .stopping: return "停止中"
        case .cancelled: return isSettledStop(task) ? "已停止" : "停止中"
        case .succeeded: return "已完成"
        case .partial: return "部分完成"
        case .failed: return "失败"
        case .interrupted: return "已中断，待核对"
        case .unknown: return "结果不明"
        }
    }

    /// A note beside the label when a stop is shown as unsettled because the
    /// service gave no executor record, as opposed to one that is still running.
    static func note(_ task: TaskView) -> String? {
        switch task.state {
        case .pausing, .paused, .stopping, .cancelled:
            return task.executor == nil ? noExecutorEvidence : nil
        default:
            return nil
        }
    }

    /// True once a pause or cancel is settled: the executor is reported stopped.
    static func isSettledStop(_ task: TaskView) -> Bool {
        switch task.state {
        case .paused, .cancelled: return task.executor?.stopped == true
        default: return false
        }
    }

    static func label(_ operation: TaskOperation) -> String {
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

    /// What a receipt means, by operation: a pause or cancel waits for the
    /// executor to stop; the others report where the task settles.
    static func receiptLine(_ r: ControlReceipt) -> String {
        let op = label(r.operation)
        guard r.accepted else { return "\(op) 未受理：\(r.reason?.message ?? r.reason?.code ?? "")" }
        switch r.operation {
        case .pause, .cancel:
            return r.executorStopped ? "\(op) 已受理，执行者已停止" : "\(op) 已受理，等待执行者停止…"
        case .resume, .answer, .approve, .deny, .bindAccount, .resubmit, .openOutput:
            let to = r.settlesTo.map(label).joined(separator: " / ")
            return to.isEmpty ? "\(op) 已受理" : "\(op) 已受理，任务将进入\(to)"
        }
    }
}
