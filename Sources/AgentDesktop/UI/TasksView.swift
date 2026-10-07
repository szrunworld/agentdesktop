import SwiftUI

/// 任务主页: current tasks, the queue, history; a task's detail beside.
struct TasksView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?

    var body: some View {
        HSplitView {
            List(selection: $selected) {
                Section("当前") {
                    if model.current.isEmpty { Text("没有正在进行的任务").foregroundStyle(.secondary) }
                    ForEach(model.current) { TaskRow(task: $0).tag($0.id) }
                }
                Section("历史") {
                    if model.history.isEmpty { Text("还没有完成的任务").foregroundStyle(.secondary) }
                    ForEach(model.history) { TaskRow(task: $0).tag($0.id) }
                }
            }
            .frame(minWidth: 300, idealWidth: 340)
            .toolbar {
                ToolbarItem { Button { } label: { Label("新建任务", systemImage: "plus") }.disabled(true).help("新建任务随 F03 的中性参考 Agent 接入") }
            }
            Group {
                if let id = selected, let task = model.tasks.first(where: { $0.id == id }) {
                    TaskDetailView(task: task)
                } else {
                    VStack { Spacer(); Text("选择一个任务查看详情").foregroundStyle(.secondary); Spacer() }
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(minWidth: 420)
        }
    }
}

struct TaskRow: View {
    let task: TaskView
    var body: some View {
        HStack {
            StateDot(task: task)
            VStack(alignment: .leading) {
                Text(task.taskType).font(.body)
                Text("\(TaskStateDisplay.label(task)) · \(task.agentId)").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if task.state == .waiting { Image(systemName: "hand.raised.fill").foregroundStyle(.orange) }
        }
    }
}

struct StateDot: View {
    let task: TaskView
    var color: Color {
        switch task.state {
        case .running: return task.heartbeat?.stale == true ? .gray : .green
        case .queued, .pausing, .stopping: return .yellow
        case .waiting, .interrupted, .unknown: return .orange
        case .paused: return .blue
        case .succeeded: return .green
        case .partial: return .teal
        case .failed, .cancelled: return .red
        }
    }
    var body: some View { Circle().fill(color).frame(width: 9, height: 9) }
}

/// 详情: current step, why it waits, the course, result, usage and the
/// operations the service allows right now. Nothing else is a button.
struct TaskDetailView: View {
    @EnvironmentObject var model: AppModel
    let task: TaskView
    @State private var answer = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading) {
                        Text(task.taskType).font(.title2)
                        Text("\(task.id) · \(task.kind.rawValue) · \(task.agentId)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text(TaskStateDisplay.label(task)).font(.headline)
                }
                Divider()
                field("当前步骤", task.progress?.current ?? (task.state == .queued ? "等待执行者" : "—"))
                if let w = task.waiting {
                    field("等待原因", "\(w.reason)（由\(w.resolvedBy == .user ? "你" : w.resolvedBy == .approval ? "审批" : "外部") 解除），自 \(w.since)")
                }
                if let hb = task.heartbeat {
                    field("心跳", hb.stale ? "过期：\(hb.at)，不再视为执行中" : hb.at)
                }
                if let ex = task.executor {
                    field("执行者", ex.stopped ? "已停止" : "进程 \(ex.ownerPid.map(String.init) ?? "?") 仍在")
                }
                if let counts = task.progress?.counts, !counts.isEmpty {
                    field("计数", counts.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: " · "))
                }
                if let e = task.error { field("错误", "\(e.code): \(e.message)") }
                if let r = task.result {
                    GroupBox("结果") {
                        VStack(alignment: .leading, spacing: 4) {
                            if let s = r.summary { Text(s) }
                            if let p = r.outputPath { Text(p).font(.caption.monospaced()) }
                            Text("平台验证 \(verdict(r.verification.platform)) · 业务验收 \(verdict(r.verification.business))").font(.caption)
                            ForEach(r.verification.notes ?? [], id: \.self) { Text("· \($0)").font(.caption).foregroundStyle(.secondary) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !task.artifacts.isEmpty {
                    GroupBox("产物") {
                        VStack(alignment: .leading) {
                            ForEach(task.artifacts) { a in
                                HStack { Image(systemName: a.verified ? "checkmark.seal" : "questionmark.circle"); Text(a.path); Text(a.kind).foregroundStyle(.secondary) }.font(.caption)
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if let u = task.usage {
                    field("用量", "模型调用 \(u.modelCalls.text) · 输入 \(u.inputTokens.text) · 输出 \(u.outputTokens.text) · 费用 \(u.cost?.text ?? "未知")")
                }
                field("更新", task.updatedAt)
                Divider()
                if task.allowed.isEmpty {
                    Text(task.state == .stopping || task.state == .pausing ? "等待执行者停止…" : "此刻没有可执行的操作").foregroundStyle(.secondary)
                } else {
                    if task.allowed.contains(.answer) {
                        TextField("回答或核对说明", text: $answer).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        ForEach(task.allowed, id: \.self) { op in
                            Button(TaskStateDisplay.label(op)) {
                                Task { _ = await model.send(op, to: task, payload: op == .answer ? ["answer": answer] : nil) }
                            }
                        }
                    }
                }
                if let receipt = model.receipts.first(where: { $0.taskId == task.id }) {
                    Text(receiptLine(receipt)).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(name).frame(width: 72, alignment: .trailing).foregroundStyle(.secondary)
            Text(value).textSelection(.enabled)
        }.font(.callout)
    }

    func verdict(_ v: TaskView.Verdict) -> String {
        switch v { case .passed: return "通过"; case .failed: return "未通过"; case .none: return "无" }
    }

    func receiptLine(_ r: ControlReceipt) -> String {
        if !r.accepted { return "\(TaskStateDisplay.label(r.operation)) 未受理：\(r.reason?.message ?? "")" }
        return "\(TaskStateDisplay.label(r.operation)) 已受理" + (r.executorStopped ? "，执行者已停止" : "，等待执行者停止…")
    }
}
