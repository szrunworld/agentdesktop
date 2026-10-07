import Foundation

/// Sample data for building the UI before C03 answers for real: one task
/// per state, each with the operations the contract allows there. Control
/// requests move the sample the way the service would: a cancel is accepted
/// first ("stopping"), and the executor is reported stopped a moment later.
final class SampleTaskClient: TaskClient {
    let scope = ClientScope(clientId: "com.agentdesktop.app", agentIds: nil)
    private var tasks: [String: TaskView]
    private let queue = DispatchQueue(label: "sample-task-client")

    init() {
        tasks = Dictionary(uniqueKeysWithValues: Self.samples.map { ($0.id, $0) })
    }

    static let identity = ServiceIdentity(
        product: "Agent Desktop", bundleId: "com.agentdesktop.app", pid: 0,
        protocolVersion: ServiceIdentity.supportedProtocolVersion, runtimeVersion: "sample",
        engineRevision: "sample", capabilities: ["task.view", "task.control", "task.artifacts", "agent.host"])

    func service() async throws -> ServiceIdentity { Self.identity }

    func views() async throws -> [TaskView] {
        queue.sync { tasks.values.sorted { $0.updatedAt > $1.updatedAt } }
    }

    func view(_ taskId: String) async throws -> TaskView {
        guard let task = queue.sync(execute: { tasks[taskId] }) else { throw TaskClientError.notFound("no task \(taskId)") }
        return task
    }

    func control(_ request: ControlRequest) async throws -> ControlReceipt {
        guard var task = queue.sync(execute: { tasks[request.taskId] }) else { throw TaskClientError.notFound("no task \(request.taskId)") }
        guard task.allowed.contains(request.operation) else {
            return ControlReceipt(requestId: request.requestId, taskId: task.id, operation: request.operation, accepted: false,
                                  acceptedAt: nil, reason: .init(code: "conflict", message: "\(request.operation.rawValue) is not allowed while \(task.state.rawValue)"),
                                  executorStopped: task.executor?.stopped ?? true, settlesTo: [])
        }
        let now = Self.stamp(Date())
        var settles: [TaskUiState] = []
        switch request.operation {
        case .cancel:
            task.state = .stopping
            task.executor = .init(ownerPid: task.executor?.ownerPid, epoch: task.executor?.epoch, stopped: false)
            task.allowed = []
            settles = [.cancelled]
            settleLater(task.id, to: .cancelled, allowed: [.resubmit])
        case .pause:
            task.state = .pausing
            task.executor = .init(ownerPid: task.executor?.ownerPid, epoch: task.executor?.epoch, stopped: false)
            task.allowed = [.cancel]
            settles = [.paused]
            settleLater(task.id, to: .paused, allowed: [.resume, .cancel])
        case .resume:
            task.state = .running
            task.executor = .init(ownerPid: 4242, epoch: UUID().uuidString, stopped: false)
            task.allowed = [.pause, .cancel]
            task.heartbeat = .init(at: now, stale: false)
            settles = [.running]
        case .approve, .answer, .bindAccount:
            task.state = .running
            task.waiting = nil
            task.allowed = [.pause, .cancel]
            task.executor = .init(ownerPid: 4242, epoch: UUID().uuidString, stopped: false)
            task.heartbeat = .init(at: now, stale: false)
            settles = [.running]
        case .deny:
            task.state = .cancelled
            task.waiting = nil
            task.allowed = [.resubmit]
            task.executor = .init(ownerPid: nil, epoch: nil, stopped: true)
            settles = [.cancelled]
        case .openOutput, .resubmit:
            settles = [task.state]
        }
        task.updatedAt = now
        queue.sync { tasks[task.id] = task }
        return ControlReceipt(requestId: request.requestId, taskId: task.id, operation: request.operation, accepted: true,
                              acceptedAt: now, reason: nil, executorStopped: task.executor?.stopped ?? false, settlesTo: settles)
    }

    private func settleLater(_ id: String, to state: TaskUiState, allowed: [Operation]) {
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, var task = self.tasks[id] else { return }
            task.state = state
            task.executor = .init(ownerPid: nil, epoch: task.executor?.epoch, stopped: true)
            task.allowed = allowed
            task.updatedAt = Self.stamp(Date())
            self.tasks[id] = task
        }
    }

    static func stamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    // MARK: Samples

    /// One task per state, with the operations the contract allows there.
    static var samples: [TaskView] {
        let t0 = Date(timeIntervalSince1970: 1_791_400_000)
        func at(_ minutes: Double) -> String { stamp(t0.addingTimeInterval(minutes * 60)) }
        func task(_ n: Int, _ state: TaskUiState, _ kind: TaskKind, _ type: String, allowed: [Operation],
                  raw: String, _ edit: (inout TaskView) -> Void = { _ in }) -> TaskView {
            var v = TaskView(
                id: "sample-\(n)", kind: kind, agentId: kind == .skill ? "builtin:\(type)" : "assistant",
                taskType: type, scope: .init(clientId: "com.agentdesktop.app", agentId: kind == .skill ? "builtin:\(type)" : "assistant"),
                state: state, raw: .init(status: raw, phase: nil, lifecycle: nil), waiting: nil,
                updatedAt: at(Double(n)), heartbeat: nil, progress: nil, allowed: allowed, executor: nil,
                error: nil, result: nil, artifacts: [], usage: nil, submittedAt: at(Double(n) - 10), startedAt: nil, endedAt: nil)
            edit(&v)
            return v
        }
        return [
            task(1, .queued, .agent, "extract-page", allowed: [.cancel], raw: "queued"),
            task(2, .running, .agent, "extract-page", allowed: [.pause, .cancel], raw: "running") {
                $0.heartbeat = .init(at: at(2), stale: false)
                $0.progress = .init(current: "读取第 3 页", counts: ["pages": 3, "items": 12])
                $0.executor = .init(ownerPid: 4242, epoch: "e1", stopped: false)
                $0.usage = .init(modelCalls: .known(2), inputTokens: .known(1_800), outputTokens: .known(240), cost: .unknown)
            },
            task(3, .running, .agent, "extract-page", allowed: [.cancel], raw: "running") {
                $0.heartbeat = .init(at: at(-30), stale: true)
                $0.executor = .init(ownerPid: 4243, epoch: "e2", stopped: false)
            },
            task(4, .waiting, .agent, "fill-form", allowed: [.approve, .deny, .cancel], raw: "running") {
                $0.waiting = .init(reason: "approval", since: at(4), resolvedBy: .approval, inboxId: "inbox-1")
                $0.progress = .init(current: "提交表单前需要批准", counts: nil)
            },
            task(5, .waiting, .skill, "boss.collect-resumes", allowed: [.bindAccount, .cancel], raw: "waiting_user") {
                $0.waiting = .init(reason: "account_changed", since: at(5), resolvedBy: .user, inboxId: nil)
            },
            task(6, .waiting, .agent, "extract-page", allowed: [.answer, .cancel], raw: "running") {
                $0.waiting = .init(reason: "question", since: at(6), resolvedBy: .user, inboxId: "inbox-2")
            },
            task(7, .pausing, .agent, "extract-page", allowed: [.cancel], raw: "running") {
                $0.executor = .init(ownerPid: 4244, epoch: "e3", stopped: false)
            },
            task(8, .paused, .agent, "extract-page", allowed: [.resume, .cancel], raw: "paused") {
                $0.executor = .init(ownerPid: nil, epoch: "e4", stopped: true)
            },
            task(9, .stopping, .agent, "extract-page", allowed: [], raw: "cancelling") {
                $0.executor = .init(ownerPid: 4245, epoch: "e5", stopped: false)
            },
            task(10, .cancelled, .agent, "extract-page", allowed: [.resubmit], raw: "cancelled") {
                $0.executor = .init(ownerPid: nil, epoch: "e6", stopped: true)
                $0.endedAt = at(10)
            },
            task(11, .succeeded, .agent, "extract-page", allowed: [.openOutput, .resubmit], raw: "succeeded") {
                $0.result = .init(summary: "提取 12 条，来源截图 3 张", outputPath: "~/Agent Desktop/extract-page/2026-10-07",
                                  verification: .init(platform: .passed, business: .passed, notes: nil))
                $0.artifacts = [.init(id: "a1", path: "result.json", kind: "json", sha256: "0ab3", verified: true),
                                .init(id: "a2", path: "page-1.png", kind: "screenshot", sha256: "9f1c", verified: true)]
                $0.usage = .init(modelCalls: .known(4), inputTokens: .known(5_100), outputTokens: .known(900), cost: .known(0))
                $0.endedAt = at(11)
            },
            task(12, .partial, .agent, "extract-page", allowed: [.openOutput, .resubmit], raw: "partial") {
                $0.result = .init(summary: "12 条中完成 9 条；3 条页面未加载", outputPath: "~/Agent Desktop/extract-page/2026-10-07b",
                                  verification: .init(platform: .passed, business: .failed, notes: ["3 条缺少来源截图"]))
                $0.artifacts = [.init(id: "a3", path: "result.json", kind: "json", sha256: nil, verified: true)]
                $0.endedAt = at(12)
            },
            task(13, .failed, .skill, "boss.collect-resumes", allowed: [.resubmit], raw: "failed") {
                $0.error = .init(code: "lease_held", message: "the app is in use by another task")
                $0.endedAt = at(13)
            },
            task(14, .interrupted, .agent, "fill-form", allowed: [.answer, .cancel], raw: "running") {
                $0.raw.lifecycle = "exited"
                $0.error = .init(code: "interrupted", message: "the worker running this task stopped without finishing it")
                $0.executor = .init(ownerPid: nil, epoch: "e7", stopped: true)
            },
            task(15, .unknown, .agent, "fill-form", allowed: [.answer], raw: "running") {
                $0.error = .init(code: "unknown", message: "a submit was sent; whether it took effect is not known")
                $0.executor = .init(ownerPid: nil, epoch: "e8", stopped: false)
            },
        ]
    }
}
