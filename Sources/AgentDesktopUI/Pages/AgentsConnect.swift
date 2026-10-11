import AgentDesktopProtocol
import SwiftUI

// Lane UI-C (U4 Agents; docs/plan/11-parallel-lanes.md): Agents › 接入应用
// (P09 CLI, P10 MCP, P11 ACP) and the pairing requests (Hub W02). The page
// only shows commands and what the Runtime reports; it runs nothing, and it
// never approves or denies a pairing: the user does that in the host's
// trusted window with Touch ID or the login password.

/// The commands and configurations of P09–P11, bound to one desktopId.
/// Only commands the shipped CLI has are shown as such; what is not
/// released yet is marked 拟议.
public enum AgentsConnectExamples {
    public static let binary = "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop"

    /// A Desktop id as the contract allows it (`Id`); anything else becomes a placeholder.
    public static func safe(_ desktopId: String?) -> String {
        guard let d = desktopId, !d.isEmpty, d.count <= 128,
              d.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil else { return "<desktopId>" }
        return d
    }

    public static func cli(desktopId: String?) -> String {
        let d = safe(desktopId)
        return """
        # 1. 配对这个 CLI：Agent Desktop 弹出确认窗口，由你用 Touch ID 批准
        agentdesktop agents pair --name "我的脚本" --capabilities observe,act --desktops \(d) --duration 8h

        # 2. 读取这个 Desktop
        agentdesktop desktop show \(d) --format json

        # 3. 在这个 Desktop 上打开会话并观察
        S=$(agentdesktop session open --desktop \(d) --format json | jq -r .data.sessionId)
        agentdesktop observe --session $S --format json

        # 4. 按快照点击；快照过期或目标变化时 Runtime 不发送输入
        agentdesktop act click --session $S --snapshot <snapshotId> --element <elementId>
        """
    }

    public static func mcpPair(desktopId: String?) -> String {
        "agentdesktop agents pair --name \"MCP 宿主\" --profile mcp --capabilities observe,act --desktops \(safe(desktopId)) --duration 8h"
    }

    /// The MCP server entry; one valid JSON object (UC23). The Desktop is
    /// bound by the pairing above until `mcp --desktop-id` ships (A7).
    public static func mcpConfig() -> String {
        """
        {
          "mcpServers": {
            "agentdesktop": {
              "command": "\(binary)",
              "args": ["mcp", "--profile", "mcp"]
            }
          }
        }
        """
    }

    public static func acpPair(desktopId: String?) -> String {
        "agentdesktop agents pair --name ACP --profile acp --capabilities observe,act,run --desktops \(safe(desktopId)) --duration 8h"
    }

    /// Proposed: `agentdesktop acp` is not in the CLI yet (docs/acp).
    public static func acpConfig() -> String {
        """
        {
          "agent_servers": {
            "AgentDesktop": {
              "command": "\(binary)",
              "args": ["acp"]
            }
          }
        }
        """
    }
}

struct AgentsConnectView: View {
    @ObservedObject var model: AgentsModel
    @ObservedObject var store: ShellStore
    let openDesktop: (String) -> Void

    var desktopId: String? {
        if let d = model.targetDesktopId, store.desktops.contains(where: { $0["desktopId"]?.stringValue == d }) { return d }
        return store.desktops.first?["desktopId"]?.stringValue
    }

    var body: some View {
        HStack(alignment: .top, spacing: ADSpace.xl) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                ForEach(AgentsModel.Channel.allCases) { c in
                    let on = model.channel == c
                    Button { model.channel = c } label: {
                        HStack(spacing: ADSpace.m) {
                            Image(systemName: c.symbol).frame(width: 18).foregroundStyle(on ? ADColor.primary : ADColor.muted)
                            Text(c.rawValue).font(on ? ADFont.bodyStrong : ADFont.body).foregroundStyle(ADColor.ink)
                            Spacer()
                        }
                        .padding(.horizontal, ADSpace.m).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(on ? ADColor.selected : .clear))
                        .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(on ? ADColor.line : .clear))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
                Text("这些是连接方式，不是 Agent 市场。\n无需在这里注册 Agent。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    .padding(.top, ADSpace.l).padding(.horizontal, ADSpace.xs)
            }
            .frame(width: 220)
            VStack(alignment: .leading, spacing: ADSpace.l) {
                target
                if model.channel == .acp {
                    AgentsNote(title: "ACP 是可选连接器",
                               text: "它连接外部 Agent 的会话，不替代截图、点击、输入工具；产品命令 agentdesktop acp 尚未发布，下面的配置是拟议格式。此处不安装或下载任何 Agent。")
                }
                step(1, title: stepOneTitle, detail: "以下是 agentdesktop 的命令与配置；界面只展示，不会替你运行。agentdesktop 位于 Agent Desktop.app/Contents/Resources/bin/。")
                examples
                step(2, title: "在确认窗口里批准配对", detail: "配对请求出现时，Agent Desktop 会弹出系统确认窗口：核对申请方、代码身份和配对码后，用 Touch ID 或登录密码批准。主窗口不能代替你批准。")
                AgentsPairingsPanel(model: model)
                step(3, title: "检查连接与目标", detail: "查看这个 Desktop、它的控制者，以及授权列出它的应用。只读检查，不接管正在运行的 Agent。")
                HStack(spacing: ADSpace.s) {
                    Button { if let d = desktopId { Task { await model.checkConnection(desktopId: d) } } } label: {
                        Label("检查连接", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(desktopId == nil || !model.connected || !model.offers("hub.clients.list"))
                    Button { if let d = desktopId { openDesktop(d) } } label: { Label("打开目标 Desktop", systemImage: "eye") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(desktopId == nil)
                }
                .padding(.leading, 40)
                if let c = model.check { AgentsCheckResult(check: c).padding(.leading, 40) }
            }
        }
    }

    var stepOneTitle: String {
        switch model.channel {
        case .cli: return "在终端或 Agent 工具中调用"
        case .mcp: return "把配置加入调用方的 MCP 设置"
        case .acp: return "配置已安装的 ACP Agent"
        }
    }

    var target: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("连接到指定 Desktop").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                .padding(.horizontal, ADSpace.l).frame(height: 54)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: ADSpace.s) {
                Text("Desktop").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                if store.desktops.isEmpty {
                    Text("还没有 Desktop。先在 Desktops 中创建一个，命令里的 desktopId 才有值。").font(ADFont.note).foregroundStyle(ADColor.muted)
                } else {
                    Picker("Desktop", selection: Binding(get: { desktopId ?? "" }, set: { model.targetDesktopId = $0; model.clearCheck() })) {
                        ForEach(store.desktops.indices, id: \.self) { i in
                            let d = store.desktops[i]
                            Text("\(d["name"]?.stringValue ?? "—") · \(d["desktopId"]?.stringValue ?? "")").tag(d["desktopId"]?.stringValue ?? "")
                        }
                    }
                    .labelsHidden().frame(maxWidth: 440, alignment: .leading)
                }
                Text("配置限定到所选 desktopId；所有动作仍显式携带它。现有控制者不会被静默替换。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .padding(ADSpace.l)
        }
        .adPanel()
    }

    func step(_ n: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            Text("\(n)").font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
                .frame(width: 26, height: 26).overlay(Circle().stroke(ADColor.line))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(detail).font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    var examples: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            switch model.channel {
            case .cli:
                CodeBox(title: "终端 · Shell", code: AgentsConnectExamples.cli(desktopId: desktopId))
            case .mcp:
                CodeBox(title: "先配对 MCP 宿主（限定到这个 Desktop）", code: AgentsConnectExamples.mcpPair(desktopId: desktopId))
                CodeBox(title: "MCP 配置 · JSON", code: AgentsConnectExamples.mcpConfig(), json: true)
                Text("Desktop 范围由上面的配对授权限定；`agentdesktop mcp --desktop-id` 尚未发布（A7）。无需添加 AI 连接，也不会改变外部 Agent 的模型或提示词。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            case .acp:
                CodeBox(title: "ACP 桥自己配对（限定到这个 Desktop）", code: AgentsConnectExamples.acpPair(desktopId: desktopId))
                CodeBox(title: "Zed 配置 · JSON（拟议，agentdesktop acp 尚未发布）", code: AgentsConnectExamples.acpConfig(), json: true)
                Text("ACP 发起的运行随编辑器连接结束而停止（connection_scoped）。桌面观察与输入仍走 Runtime，ACP 只负责指令、消息与取消。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ADSpace.l).adPanel()
    }
}

/// The result of the read-only check (UC24): what the Runtime said, when.
struct AgentsCheckResult: View {
    let check: AgentsConnectionCheck

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack(spacing: ADSpace.s) {
                StateBadge(check.problem == nil ? StatusText("检查完成", .running) : StatusText("检查未完成", .attention))
                Text("\(check.desktopId) · \(PageContainer<EmptyView, EmptyView>.time(check.checkedAt))")
                    .font(ADFont.code).foregroundStyle(ADColor.muted)
            }
            if let p = check.problem { ProblemView(p) }
            if let d = check.desktop {
                LabeledValue(label: "Desktop", value: "\(d["name"]?.stringValue ?? "—") · 状态 \(d["state"]?.stringValue ?? "—")", labelWidth: 120)
                let control = d["control"]
                LabeledValue(label: "控制者", value: control.map { c in
                    "\(c["state"]?.stringValue ?? "—")" + (c["clientName"]?.stringValue ?? c["clientId"]?.stringValue).map { " · \($0)" }.agentsOrEmpty
                } ?? "Runtime 没有报告控制状态", labelWidth: 120)
            }
            LabeledValue(label: "授权列出它的应用", value: check.clients.isEmpty ? "没有"
                         : check.clients.map { "\($0.name)（\($0.connections) 条连接）" }.joined(separator: "、"), labelWidth: 120)
            Text("只读检查：没有开始运行，没有接管或替换控制者。").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
        .accessibilityElement(children: .combine)
    }
}

extension Optional where Wrapped == String {
    var agentsOrEmpty: String { self ?? "" }
}

/// Pairing requests as the Runtime lists them (hub.clients.list `pairings`),
/// with hub.pairing.status on demand. No approve or deny here.
struct AgentsPairingsPanel: View {
    @ObservedObject var model: AgentsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("配对请求").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                StateBadge("批准与拒绝只在确认窗口中进行", tone: .idle)
            }
            .padding(.horizontal, ADSpace.l).frame(height: 50)
            Rectangle().fill(ADColor.line).frame(height: 1)
            if model.pairings.isEmpty {
                Text("目前没有配对请求。外部应用发起配对后，这里显示它的状态。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(model.pairings.indices, id: \.self) { i in row(model.pairings[i]) }
            Text("配对码只用于和申请方显示的码核对，不是长期凭据。界面不显示任何凭据或 token。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).padding(.horizontal, ADSpace.l).frame(height: 38)
        }
        .adPanel()
    }

    func row(_ p: JSONValue) -> some View {
        let id = p["pairingId"]?.stringValue ?? "—"
        let checked = model.pairingChecks[id]
        let state = checked?["state"]?.stringValue ?? p["state"]?.stringValue
        let requested = p["requested"]
        let code = p["shortCode"]?.stringValue ?? ""
        return HStack(alignment: .center, spacing: ADSpace.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(p["agentName"]?.stringValue ?? "—").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text("名称为应用自报 · \(id)").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 170, alignment: .leading)
            StateBadge(AgentsText.codeIdentity(p["codeIdentity"])).frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(code.count == 6 ? "\(code.prefix(3)) \(code.suffix(3))" : code).font(.system(size: 17, weight: .semibold, design: .monospaced))
                    .foregroundStyle(ADColor.ink)
                Text("配对码").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text("申请：" + AgentsText.capabilities(requested?["capabilities"])).font(ADFont.note).foregroundStyle(ADColor.ink).lineLimit(1)
                Text("Desktop：" + (GrantNarrowing.strings(requested?["desktops"]).map(AgentsText.desktop).joined(separator: "、").nilIfEmpty ?? "无")
                     + " · 到期 \(TimeText.clock(checked?["expiresAt"]?.stringValue ?? p["expiresAt"]?.stringValue))")
                    .font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(1)
            }.frame(maxWidth: .infinity, alignment: .leading)
            VStack(alignment: .trailing, spacing: ADSpace.xs) {
                StateBadge(AgentsText.pairingState(state))
                if let c = checked?["clientId"]?.stringValue { Text(c).font(ADFont.identifier).foregroundStyle(ADColor.muted) }
                if let e = model.pairingCheckProblems[id] { Text(e.title).font(ADFont.identifier).foregroundStyle(StatusTone.attention.foreground) }
            }
            Button("刷新状态") { Task { await model.checkPairing(id) } }.buttonStyle(ADButtonStyle(.secondary)).fixedSize()
                .disabled(!model.connected || !model.offers("hub.pairing.status"))
                .accessibilityLabel("刷新 \(p["agentName"]?.stringValue ?? id) 的配对状态")
        }
        .padding(.horizontal, ADSpace.l).frame(minHeight: 66)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}
