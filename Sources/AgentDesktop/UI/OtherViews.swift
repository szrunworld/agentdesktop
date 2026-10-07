import AppKit
import SwiftUI

/// Agent: installed packages, the official sample, each one's state. Only
/// structure now: F09 brings import, versions and compatibility checks.
struct AgentsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        List {
            Section("官方") {
                HStack {
                    Image(systemName: "sparkles")
                    VStack(alignment: .leading) {
                        Text("桌面助手（参考 Agent）")
                        Text("随路线 C06 以公开 process 协议提供；目前未安装").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("未安装").foregroundStyle(.secondary)
                }
            }
            Section("已导入") {
                Text("没有导入的 Agent 包。导入、版本与兼容检查随 F09 提供。").foregroundStyle(.secondary)
            }
            Section("本 runtime 托管") {
                let ids = Set(model.tasks.map(\.agentId)).sorted()
                if ids.isEmpty { Text("没有任务记录").foregroundStyle(.secondary) }
                ForEach(ids, id: \.self) { id in
                    HStack { Text(id); Spacer(); Text("\(model.tasks.filter { $0.agentId == id }.count) 个任务").foregroundStyle(.secondary) }
                }
            }
        }
    }
}

/// 待处理: approvals, questions, logins and checks, each tied to its task.
/// The decision is made through the task's allowed operations; a business
/// process never approves its own request.
struct InboxView: View {
    @EnvironmentObject var model: AppModel
    @State private var selected: String?
    var body: some View {
        HSplitView {
            List(selection: $selected) {
                if model.pending.isEmpty { Text("没有等待你的事项").foregroundStyle(.secondary) }
                ForEach(model.pending) { task in
                    VStack(alignment: .leading) {
                        Text(pendingTitle(task))
                        Text("\(task.taskType) · \(task.id)").font(.caption).foregroundStyle(.secondary)
                    }.tag(task.id)
                }
            }.frame(minWidth: 300)
            Group {
                if let id = selected, let task = model.pending.first(where: { $0.id == id }) {
                    TaskDetailView(task: task)
                } else {
                    VStack { Spacer(); Text("选择一项查看目标与动作").foregroundStyle(.secondary); Spacer() }.frame(maxWidth: .infinity)
                }
            }.frame(minWidth: 420)
        }
    }

    func pendingTitle(_ t: TaskView) -> String {
        switch t.state {
        case .interrupted: return "中断后需要核对"
        case .unknown: return "结果不明，需要人工核对"
        default:
            switch t.waiting?.reason {
            case "approval": return "动作需要批准"
            case "question": return "Agent 有问题要问你"
            case "login_required": return "需要登录"
            case "account_changed": return "需要绑定账号"
            case let r?: return "等待：\(r)"
            case nil: return "等待处理"
            }
        }
    }
}

/// 设置: the permission wizard with real checks, the client mode, and the
/// build's provenance. Model, budget and data settings come with F07/F10.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var build: String = SettingsView.readBuild()

    var body: some View {
        Form {
            Section("权限与 Runtime") {
                PermissionRow(name: "屏幕录制", granted: model.permissions.screenRecording,
                              detail: "预览与截图。拒绝后可在系统设置里重新开启，再点「重新检测」。",
                              request: { PermissionStatus.requestScreenRecording() })
                PermissionRow(name: "辅助功能", granted: model.permissions.accessibility,
                              detail: "把应用窗口放到工作屏、交还与搬回。",
                              request: { PermissionStatus.requestAccessibility() })
                PermissionRow(name: "Task runtime", granted: model.permissions.runtimeInstalled,
                              detail: model.permissions.runtimeInstalled ? model.permissions.runtimePath : "产品包内没有 task runtime；等引擎发布不带业务 skills 的版本（路线 C01）",
                              request: nil)
                HStack {
                    Text("服务")
                    Spacer()
                    Text(serviceText).foregroundStyle(.secondary).lineLimit(2)
                }
                Button("重新检测") { Task { await model.refresh() } }
            }
            Section("开发") {
                Picker("任务数据来源", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                    Text("产品命令行（bin/agentdesktop）").tag(TaskClientMode.cli)
                    Text("样例数据").tag(TaskClientMode.sample)
                }
                Text("样例数据只用于界面开发，覆盖契约里的全部状态；不代表任何真实任务。").font(.caption).foregroundStyle(.secondary)
            }
            Section("版本与来源") {
                Text(build).font(.caption.monospaced()).textSelection(.enabled)
            }
            Section("后续") {
                Text("模型与预算（F07）、数据保留与删除、脱敏诊断、更新提示（F10）随对应核心能力接入。").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    var serviceText: String {
        switch model.serviceState {
        case .ready(let s): return "\(s.product) pid \(s.pid)，协议 \(s.protocolVersion)，能力 \(s.capabilities.joined(separator: " "))"
        case .checking: return "检测中"
        case .runtimeMissing(let m), .offline(let m), .connectionFailed(let m), .capabilityMissing(let m), .error(let m): return m
        case .versionMismatch(let f, let s): return "协议 \(f)，本产品支持 \(s)"
        }
    }

    static func readBuild() -> String {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/build.json")
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            return "不在产品包里运行：没有 build.json"
        }
        return text
    }
}

struct PermissionRow: View {
    let name: String
    let granted: Bool
    let detail: String
    let request: (() -> Void)?
    var body: some View {
        HStack(alignment: .top) {
            Image(systemName: granted ? "checkmark.circle.fill" : "xmark.circle").foregroundStyle(granted ? .green : .red)
            VStack(alignment: .leading) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted, let request { Button("申请 / 打开系统设置", action: request) }
        }
    }
}
