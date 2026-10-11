import AgentDesktopProtocol
import SwiftUI

// Lane UI-C (U4 Agents; docs/plan/11-parallel-lanes.md): Hub W01 总览,
// W03 Agent 详情与授权, and the confirmations of every change. The "接入应用"
// view (P09–P11, W02) is in AgentsConnect.swift.

/// A change the user asked for, waiting for the second confirmation.
public enum AgentsConfirmation: Equatable, Sendable {
    case revokeClient(String)
    case revokeGrant(String)
    case narrowGrant(String, GrantNarrowing.Intent)
    case revokeWindowGrant(JSONValue)
}

/// The words of each confirmation: what will happen, what will not.
public struct AgentsConfirmationText: Equatable, Sendable {
    public let title: String
    public let message: String
    public let consequences: [String]
    public let preserved: [String]
    public let confirmTitle: String

    @MainActor
    public static func make(_ c: AgentsConfirmation, model: AgentsModel) -> AgentsConfirmationText {
        switch c {
        case let .revokeClient(id):
            let n = model.activeRuns(of: id)
            return .init(title: "移除 \(model.name(of: id))？", message: "移除后它的凭据立即失效，要再次使用必须重新配对（会得到新的 clientId）。",
                         consequences: ["新的请求和握手一律被拒绝", "它的所有连接被切断", "应用授权和全部窗口授权一起结束",
                                        n > 0 ? "\(n) 个未结束的平台运行进入停止流程，要等执行端确认静止" : "Runtime 目前没有报告它未结束的平台运行"],
                         preserved: ["外部应用本身继续运行：Hub 不结束它的进程", "已发生的动作回执和审计记录保留"],
                         confirmTitle: "移除")
        case let .revokeGrant(id):
            let n = model.activeRuns(of: id)
            return .init(title: "撤销 \(model.name(of: id)) 的全部授权？", message: "应用仍保持登记，但不再能做任何受保护的操作；恢复需要重新配对。",
                         consequences: ["新的受保护请求立即被拒绝", "它的连接被切断，窗口授权一起结束",
                                        n > 0 ? "\(n) 个未结束的平台运行进入停止流程，要等执行端确认静止" : "Runtime 目前没有报告它未结束的平台运行"],
                         preserved: ["外部应用本身继续运行：Hub 不结束它的进程", "登记记录保留，状态如实显示为已撤销"],
                         confirmTitle: "撤销授权")
        case let .narrowGrant(id, intent):
            let removed = model.grant(of: id).flatMap { g in
                GrantNarrowing.params(clientId: id, grant: g, intent: intent, now: model.currentNow)
                    .map { GrantNarrowing.removed(grant: g, params: $0, now: model.currentNow) }
            } ?? []
            return .init(title: "收紧 \(model.name(of: id)) 的授权？", message: "只能去掉已有的项目或缩短期限，不会扩大或延长授权。",
                         consequences: removed + ["本次提交也会略微缩短期限，以保证不会延长授权；所有既有窗口授权（含已关闭窗口）将永久撤销，旧截图不再可读，恢复能力或续期也不会恢复；使用窗口需重新申请授权", "新范围从下一个请求、下一个动作起生效", "新范围之外的平台运行由 Runtime 停止；它的连接被切断，需要重连"],
                         preserved: ["保留的能力、Desktop 和 App 不变", "外部应用本身继续运行"],
                         confirmTitle: "收紧授权")
        case let .revokeWindowGrant(w):
            let win = w["window"]
            return .init(title: "撤销这个窗口授权？",
                         message: "\(win?["appName"]?.stringValue ?? "—") · 窗口 \(win?["windowId"]?.intValue.map(String.init) ?? "—") · \(w["desktopId"]?.stringValue ?? "—")",
                         consequences: ["这个应用不再能查看、操作或保存这个窗口", "只为它短暂保留的截图被删除", "它的连接被切断，需要重连"],
                         preserved: ["窗口本身和其中的内容不受影响", "这个应用的其他授权不变"],
                         confirmTitle: "撤销窗口授权")
        }
    }
}

/// The Agents entry (U4): 总览 and 接入应用 as tabs, a client's detail on top.
public struct AgentsPageView: View {
    let context: SectionContext
    @ObservedObject var model: AgentsModel
    @ObservedObject var store: ShellStore
    @State private var confirming: AgentsConfirmation?
    /// False for off-screen renders of a model the test filled itself.
    let autoload: Bool

    public init(context: SectionContext, model: AgentsModel) {
        self.context = context
        self.model = model
        self.store = context.store
        self.autoload = true
    }

    /// Renders and tests open a confirmation directly and keep the model as given.
    init(context: SectionContext, model: AgentsModel, confirming: AgentsConfirmation?, autoload: Bool) {
        self.context = context
        self.model = model
        self.store = context.store
        self.autoload = autoload
        _confirming = State(initialValue: confirming)
    }

    var pageState: PageState {
        if case let .disconnected(p) = context.connectionState { return .disconnected(p) }
        if case .loading = context.connectionState { return .loading }
        if model.clientId == nil, model.tab == .connect { return .loaded }
        return model.state
    }

    public var body: some View {
        ZStack {
            PageContainer(state: pageState, emptyTitle: "还没有配对的外部应用",
                          emptyDetail: "外部 Agent 用 CLI、MCP 或 ACP 申请配对，你在系统弹出的确认窗口里用 Touch ID 批准后，它会出现在这里。",
                          emptyAction: ("查看接入方式", { model.tab = .connect }), syncedAt: model.syncedAt,
                          retry: { Task { await model.load() } }, header: { header }) {
                if let id = model.clientId {
                    AgentDetailView(model: model, clientId: id, confirm: { confirming = $0 },
                                    openRun: { context.navigation.showRun($0) })
                } else if model.tab == .overview {
                    AgentsOverviewView(model: model)
                } else {
                    AgentsConnectView(model: model, store: store, openDesktop: { context.navigation.showDesktop($0) })
                }
            }
            if let c = confirming {
                Color.black.opacity(0.18).ignoresSafeArea()
                let t = AgentsConfirmationText.make(c, model: model)
                ConfirmationDialog(title: t.title, message: t.message, consequences: t.consequences, preserved: t.preserved,
                                   confirmTitle: t.confirmTitle, destructive: true, cancel: { confirming = nil },
                                   confirm: model.connected ? { confirming = nil; Task { await run(c) } } : nil)
            }
        }
        .task { if autoload { await model.load() } }
        .onChange(of: store.tick) { _, _ in if autoload { Task { await model.load() } } }
    }

    func run(_ c: AgentsConfirmation) async {
        switch c {
        case let .revokeClient(id): await model.revokeClient(id)
        case let .revokeGrant(id): await model.revokeGrant(id)
        case let .narrowGrant(id, intent): await model.narrowGrant(id, intent: intent)
        case let .revokeWindowGrant(w):
            if let id = w["windowGrantId"]?.stringValue { await model.revokeWindowGrant(id) }
        }
    }

    @ViewBuilder
    var header: some View {
        if let id = model.clientId {
            PageHeader(eyebrow: "Agents / 详情与授权", title: model.name(of: id),
                       subtitle: "App 身份、在线连接和资源授权分开管理。状态以 Runtime 的回答为准。") {
                Button { model.closeDetail() } label: { Label("返回列表", systemImage: "chevron.left") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
        } else {
            PageHeader(eyebrow: MainSection.agents.eyebrow, title: model.tab == .overview ? "Agents" : "连接你正在使用的 Agent",
                       subtitle: model.tab == .overview
                           ? "已配对的外部应用：登记、连接、授权三组状态分开显示。Hub 不托管、不启动外部 Agent。"
                           : "复用已有的模型与工作流，只把桌面观察和输入接到 AgentDesktop。") {
                Picker("视图", selection: $model.tab) { ForEach(AgentsModel.Tab.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            }
        }
    }
}

// MARK: - W01 总览

struct AgentsOverviewView: View {
    @ObservedObject var model: AgentsModel

    static let columns: [(String, CGFloat)] = [("外部应用", 220), ("代码身份", 210), ("登记", 110), ("连接", 150),
                                               ("授权", 170), ("允许范围", 190)]

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            HStack(spacing: ADSpace.m) {
                AgentsStat(label: "登记有效的应用", value: model.clients.filter { $0["state"]?.stringValue == "active" }.count,
                           foot: "已配对，未被移除")
                AgentsStat(label: "当前连接", value: model.connections.filter { $0["role"]?.stringValue == "paired" }.count,
                           foot: "传输在线，不等于有操作权限")
                AgentsStat(label: "外部应用的平台运行", value: model.store.activeRuns.filter { $0["origin"]?.stringValue == "agent_hub" }.count,
                           foot: "Runtime 报告未结束的运行")
                AgentsStat(label: "待确认的配对", value: model.openPairings.count, foot: "只在系统确认窗口里处理")
            }
            if !model.pairings.isEmpty { AgentsPairingsPanel(model: model) }
            ForEach(model.partProblems.keys.sorted(), id: \.self) { m in
                if let p = model.partProblems[m] { ProblemView(p) }
            }
            VStack(spacing: 0) {
                HStack {
                    Text("外部应用").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    Spacer()
                    Text("\(model.clients.count) 个").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                .padding(.horizontal, ADSpace.l).frame(height: 50)
                HStack(spacing: 0) {
                    ForEach(Self.columns, id: \.0) { c in
                        Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                    }
                    Spacer()
                }
                .padding(.horizontal, ADSpace.l).frame(height: 34)
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
                .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
                if model.clients.isEmpty {
                    Text("还没有配对的外部应用。").font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(model.clients.indices, id: \.self) { i in row(model.clients[i]) }
                HStack {
                    Text("登记、连接、授权是三组独立状态。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    Spacer()
                    Text("列表来自 Runtime 的登记表，不从运行历史反推。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                .padding(.horizontal, ADSpace.l).frame(height: 40)
            }
            .adPanel()
            AgentsNote(title: "独立应用接入",
                       text: "外部应用自己管理业务循环、任务和进程。这里只管理它与 AgentDesktop 的配对、连接和授权；移除或撤销授权都不会结束它的进程。")
        }
    }

    func row(_ c: JSONValue) -> some View {
        let id = c["clientId"]?.stringValue ?? "—"
        let conns = model.connections(of: id)
        let grant = model.grant(of: id)
        let latest = conns.compactMap { $0["since"]?.stringValue }.max()
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(c["agentName"]?.stringValue ?? "—").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink).lineLimit(1)
                Text(id).font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(1)
                Text("名称为应用自报").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 220, alignment: .leading)
            StateBadge(AgentsText.codeIdentity(c["codeIdentity"])).frame(width: 210, alignment: .leading)
            StateBadge(AgentsText.clientState(c)).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                StateBadge(AgentsText.connection(conns.count))
                Text(latest.map { "最近连接 \(TimeText.clock($0))" } ?? "没有打开的连接").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 150, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                StateBadge(AgentsText.grantState(grant, now: model.currentNow))
                Text(grant.map { "到期 \(TimeText.clock($0["expiresAt"]?.stringValue)) · 版本 \($0["revision"]?.intValue ?? 0)" } ?? "—")
                    .font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(AgentsText.capabilities(grant?["capabilities"])).font(ADFont.note).foregroundStyle(ADColor.ink).lineLimit(1)
                Text("运行中 \(model.activeRuns(of: id)) · 窗口授权 \(model.windowGrants.filter { $0["clientId"]?.stringValue == id && $0["state"]?.stringValue == "active" }.count)")
                    .font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 190, alignment: .leading)
            Spacer()
            Button { model.open(id) } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).disabled(!model.offers("hub.clients.show"))
                .accessibilityLabel("\(c["agentName"]?.stringValue ?? id) 的详情与授权")
        }
        .padding(.horizontal, ADSpace.l)
        .frame(minHeight: 74)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

struct AgentsStat: View {
    let label: String
    let value: Int
    let foot: String

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted)
            Text("\(value)").font(ADFont.pageTitle).foregroundStyle(ADColor.ink)
            Text(foot).font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
        .accessibilityElement(children: .combine)
    }
}

struct AgentsNote: View {
    let title: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: ADSpace.s) {
            Image(systemName: "info.circle").foregroundStyle(ADColor.muted).accessibilityHidden(true)
            (Text(title).font(ADFont.noteStrong) + Text(" · " + text).font(ADFont.note))
                .foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(ADSpace.m)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.selected.opacity(0.45)))
    }
}

struct AgentsChip: View {
    let text: String
    var body: some View {
        Text(text).font(ADFont.identifier).foregroundStyle(ADColor.ink)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(ADColor.canvas))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(ADColor.line))
    }
}

/// The answer of the last change: accepted with the Runtime's facts, or refused.
struct AgentsResultBanner: View {
    let result: AgentsActionResult

    var body: some View {
        if let p = result.problem {
            ProblemView(p)
        } else {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                HStack(spacing: ADSpace.s) {
                    StateBadge("已受理", tone: .running)
                    Text(result.title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                }
                ForEach(result.facts, id: \.self) { Text("· " + $0).font(ADFont.note).foregroundStyle(ADColor.ink) }
            }
            .padding(ADSpace.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(StatusTone.running.background))
            .accessibilityElement(children: .combine)
        }
    }
}

// MARK: - W03 Agent 详情与授权

struct AgentDetailView: View {
    @ObservedObject var model: AgentsModel
    let clientId: String
    let confirm: (AgentsConfirmation) -> Void
    let openRun: (String) -> Void

    @State private var editing = false
    @State private var keepCaps: Set<String> = []
    @State private var keepDesks: Set<String> = []
    @State private var keepApps: Set<String> = []
    @State private var period: Int?
    @State private var noChange = false

    var client: JSONValue? { model.detail?["clientId"]?.stringValue == clientId ? model.detail : model.client(clientId) }
    var grant: JSONValue? { model.grant(of: clientId) }
    var revoked: Bool { client?["state"]?.stringValue == "revoked" }
    var grantActive: Bool { grant?["state"]?.stringValue == "active" }

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            if let p = model.detailProblem { ProblemView(p, retry: { Task { await model.loadDetail(clientId) } }) }
            HStack(spacing: ADSpace.m) {
                axis("登记 registration", AgentsText.clientState(client), client?["state"]?.stringValue ?? "—",
                     client?["revokedAt"]?.stringValue.map { "移除于 \(TimeText.clock($0))" } ?? "登记于 \(TimeText.clock(client?["registeredAt"]?.stringValue))")
                axis("连接 transport", AgentsText.connection(connectionIds.count), "\(connectionIds.count) connections",
                     "传输在线不等于有操作权限")
                axis("应用授权 grant", AgentsText.grantState(grant, now: model.currentNow), grant?["state"]?.stringValue ?? "none",
                     grant.map { "版本 \($0["revision"]?.intValue ?? 0) · 到期 \(TimeText.clock($0["expiresAt"]?.stringValue))" } ?? "—")
            }
            if let r = model.lastResult { AgentsResultBanner(result: r) }
            if revoked || grant?["state"]?.stringValue == "revoked" { revokedBanner }
            HStack(alignment: .top, spacing: ADSpace.l) {
                grantPanel.frame(maxWidth: .infinity)
                identityPanel.frame(width: 400)
            }
            windowsPanel
            runsPanel
        }
    }

    var connectionIds: [String] {
        if let fromShow = client?["connections"]?.arrayValue { return fromShow.compactMap(\.stringValue) }
        return model.connections(of: clientId).compactMap { $0["connectionId"]?.stringValue }
    }

    func axis(_ label: String, _ status: StatusText, _ raw: String, _ foot: String) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted)
            StateBadge(status)
            Text(raw).font(ADFont.code).foregroundStyle(ADColor.ink)
            Text(foot).font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    /// HB-UI-04: the app may still be running; its access is gone; its Runs stop.
    var revokedBanner: some View {
        let stopping = model.stoppingRuns(of: clientId)
        return VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(revoked ? "已移除 · 外部应用本身可能仍在运行" : "授权已撤销 · 外部应用本身可能仍在运行")
                .font(ADFont.bodyStrong).foregroundStyle(StatusTone.attention.foreground)
            Text("后续受保护的请求一律被拒绝。" + (stopping > 0 ? "\(stopping) 个平台运行停止中，等待执行端确认静止。" : "Runtime 没有报告这个应用停止中的运行。")
                 + "Hub 没有结束它的进程；当前连接 \(connectionIds.count) 条。")
                .font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(StatusTone.attention.background))
    }

    // MARK: App-level grant

    var grantPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("应用级授权").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                Text("hub.grants.list").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }
            .padding(.horizontal, ADSpace.l).frame(height: 50)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: ADSpace.m) {
                if let g = grant {
                    if editing { editor(g) } else { grantRows(g) }
                } else {
                    Text("Runtime 没有这个应用的授权记录。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            }
            .padding(ADSpace.l)
        }
        .adPanel()
    }

    func grantRows(_ g: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            itemRow("能力", GrantNarrowing.strings(g["capabilities"]).map(AgentsText.capability))
            itemRow("Desktop", GrantNarrowing.strings(g["desktops"]).map(AgentsText.desktop))
            itemRow("App", GrantNarrowing.strings(g["apps"]))
            LabeledValue(label: "到期", value: "\(g["expiresAt"]?.stringValue ?? "—")"
                         + (GrantNarrowing.remaining(g, now: model.currentNow).map { "（还剩 \(AgentsText.duration($0))）" } ?? ""),
                         labelWidth: 90)
            LabeledValue(label: "版本", value: g["revision"]?.intValue.map(String.init) ?? "—", labelWidth: 90)
            Text("App 授权不等于这个 App 所有窗口的授权：别人的窗口还要逐个经你确认窗口授权。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: ADSpace.s) {
                Spacer()
                Button("收紧授权…") { startEditing(g) }.buttonStyle(ADButtonStyle(.secondary))
                    .disabled(!model.canChange("hub.grants.set") || !model.offers("hub.grants.list") || GrantNarrowing.remaining(g, now: model.currentNow) == nil || revoked)
                    .help(!model.offers("hub.grants.set") ? "Runtime 未提供 hub.grants.set" : !model.offers("hub.grants.list") ? "Runtime 未提供 hub.grants.list，无法核对当前授权" : "只能去掉已有项目或缩短期限")
                Button("撤销授权…") { confirm(.revokeGrant(clientId)) }.buttonStyle(ADButtonStyle(.danger))
                    .disabled(!model.canChange("hub.grants.revoke") || !grantActive)
            }
        }
    }

    func itemRow(_ label: String, _ items: [String]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: ADSpace.s) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 82, alignment: .leading)
            if items.isEmpty {
                Text("无").font(ADFont.note).foregroundStyle(ADColor.muted)
            } else {
                HStack(spacing: ADSpace.xs) { ForEach(items, id: \.self) { AgentsChip(text: $0) } }
            }
            Spacer(minLength: 0)
        }
    }

    func startEditing(_ g: JSONValue) {
        keepCaps = Set(GrantNarrowing.strings(g["capabilities"]))
        keepDesks = Set(GrantNarrowing.strings(g["desktops"]))
        keepApps = Set(GrantNarrowing.strings(g["apps"]))
        period = nil
        noChange = false
        editing = true
    }

    func editor(_ g: JSONValue) -> some View {
        let left = GrantNarrowing.remaining(g, now: model.currentNow) ?? 0
        return VStack(alignment: .leading, spacing: ADSpace.m) {
            Text("只能去掉已有的项目或缩短期限。取消勾选的项目在确认后从授权中去掉。")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
            checks("能力", GrantNarrowing.strings(g["capabilities"]), $keepCaps, label: AgentsText.capability)
            checks("Desktop", GrantNarrowing.strings(g["desktops"]), $keepDesks, label: AgentsText.desktop)
            checks("App", GrantNarrowing.strings(g["apps"]), $keepApps, label: { $0 })
            HStack(spacing: ADSpace.s) {
                Text("期限").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 82, alignment: .leading)
                Picker("期限", selection: $period) {
                    Text("保持当前到期时间（还剩 \(AgentsText.duration(left))）").tag(Int?.none)
                    ForEach(GrantNarrowing.periods.filter { $0.1 < left }, id: \.1) { Text("缩短为 \($0.0)").tag(Int?.some($0.1)) }
                }
                .labelsHidden().frame(width: 300)
            }
            if noChange { Text("没有任何变化：至少去掉一项，或选一个更短的期限。").font(ADFont.note).foregroundStyle(StatusTone.attention.foreground) }
            HStack(spacing: ADSpace.s) {
                Spacer()
                Button("取消") { editing = false }.buttonStyle(ADButtonStyle(.secondary))
                Button("检查并确认…") {
                    let intent = GrantNarrowing.Intent(keepCapabilities: keepCaps, keepDesktops: keepDesks, keepApps: keepApps,
                                                       period: period, revision: g["revision"]?.intValue ?? -1)
                    if GrantNarrowing.params(clientId: clientId, grant: g, intent: intent, now: model.currentNow) != nil {
                        editing = false
                        confirm(.narrowGrant(clientId, intent))
                    } else {
                        noChange = true
                    }
                }
                .buttonStyle(ADButtonStyle(.primary)).disabled(!model.canChange("hub.grants.set"))
            }
        }
    }

    func checks(_ title: String, _ items: [String], _ keep: Binding<Set<String>>, label: @escaping (String) -> String) -> some View {
        HStack(alignment: .top, spacing: ADSpace.s) {
            Text(title).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 82, alignment: .leading)
            if items.isEmpty { Text("无").font(ADFont.note).foregroundStyle(ADColor.muted) }
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                ForEach(items, id: \.self) { item in
                    Toggle(label(item), isOn: Binding(get: { keep.wrappedValue.contains(item) },
                                                      set: { on in if on { keep.wrappedValue.insert(item) } else { keep.wrappedValue.remove(item) } }))
                        .toggleStyle(.checkbox).font(ADFont.note)
                }
            }
        }
    }

    // MARK: Identity and connections

    var identityPanel: some View {
        let ci = client?["codeIdentity"]
        let facts = client?["callerFacts"]
        return VStack(alignment: .leading, spacing: 0) {
            Text("身份与连接").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                .padding(.horizontal, ADSpace.l).frame(height: 50)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: ADSpace.s) {
                HStack { Text("代码身份").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 90, alignment: .leading)
                    StateBadge(AgentsText.codeIdentity(ci)) }
                LabeledValue(label: "签名标识", value: ci?["identifier"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                LabeledValue(label: "Team ID", value: ci?["teamId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                LabeledValue(label: "Hardened", value: ci?["hardenedRuntime"]?.boolValue == true ? "是" : "否", labelWidth: 90)
                LabeledValue(label: "clientId", value: clientId, monospaced: true, labelWidth: 90)
                LabeledValue(label: "发布者", value: client?["publisher"]?.stringValue.map { "\($0)（自报）" } ?? "—", labelWidth: 90)
                if let pid = facts?["pid"]?.intValue {
                    LabeledValue(label: "进程", value: "pid \(pid)（仅展示，不参与认证）", labelWidth: 90)
                }
                Text("代码身份由 Runtime 从内核读出，名称和发布者是应用自报。界面不显示凭据。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                Rectangle().fill(ADColor.line).frame(height: 1).padding(.vertical, ADSpace.xs)
                Text("打开的连接").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                let conns = model.connections(of: clientId)
                if conns.isEmpty {
                    Text(model.partProblems["hub.connections.list"] != nil ? "Runtime 没有回答连接列表。" : "当前没有打开的连接。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                ForEach(conns.indices, id: \.self) { i in
                    let c = conns[i]
                    HStack {
                        Text(c["connectionId"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink)
                        Spacer()
                        Text("\(c["role"]?.stringValue ?? "—") · 自 \(TimeText.clock(c["since"]?.stringValue))"
                             + (c["callerFacts"]?["pid"]?.intValue.map { " · pid \($0)" } ?? ""))
                            .font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
                HStack {
                    Spacer()
                    Button("移除此应用…") { confirm(.revokeClient(clientId)) }.buttonStyle(ADButtonStyle(.danger))
                        .disabled(!model.canChange("hub.clients.revoke") || revoked)
                }
                .padding(.top, ADSpace.s)
            }
            .padding(ADSpace.l)
        }
        .adPanel()
    }

    // MARK: Window grants

    static let windowColumns: [(String, CGFloat)] = [("窗口", 230), ("Desktop", 110), ("Observe", 80), ("Act", 70), ("Persist", 80),
                                                     ("状态", 200), ("到期", 90)]

    var windowsPanel: some View {
        let list = model.windowGrants(of: clientId)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("窗口级授权").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text("查看 / 操作 / 保存截图分开授权，每一个都经你确认").font(ADFont.note).foregroundStyle(ADColor.muted)
                Spacer()
                Toggle("显示已结束的", isOn: $model.showEndedWindowGrants).toggleStyle(.checkbox).font(ADFont.note)
            }
            .padding(.horizontal, ADSpace.l).frame(height: 50)
            HStack(spacing: 0) {
                ForEach(Self.windowColumns, id: \.0) { c in
                    Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, ADSpace.l).frame(height: 34)
            .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
            .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
            if let p = model.partProblems["hub.windows.list"] {
                ProblemView(p).padding(ADSpace.l)
            } else if list.isEmpty {
                Text("没有窗口授权。它只能用自己在 Desktop 上启动的窗口。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading)
            }
            ForEach(list.indices, id: \.self) { i in windowRow(list[i]) }
        }
        .adPanel()
    }

    func windowRow(_ w: JSONValue) -> some View {
        let win = w["window"]
        let perms = GrantNarrowing.strings(w["permissions"])
        let state = w["state"]?.stringValue
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(win?["appName"]?.stringValue ?? "—") · 窗口 \(win?["windowId"]?.intValue.map(String.init) ?? "—")")
                    .font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text("\(win?["bundleId"]?.stringValue ?? "—") · pid \(win?["process"]?["pid"]?.intValue.map(String.init) ?? "—")")
                    .font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 230, alignment: .leading)
            Text(w["desktopId"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink).frame(width: 110, alignment: .leading)
            ForEach([("observe", 80.0), ("act", 70.0), ("persist", 80.0)], id: \.0) { p in
                permission(perms.contains(p.0), name: AgentsText.windowPermission(p.0)).frame(width: p.1, alignment: .leading)
            }
            HStack(spacing: ADSpace.xs) {
                StateBadge(AgentsText.windowState(w))
                if let r = w["endedReason"]?.stringValue {
                    Text(AgentsText.endedReason(r)).font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(1)
                }
            }.frame(width: 200, alignment: .leading)
            Text(TimeText.clock(w["expiresAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink).frame(width: 90, alignment: .leading)
            Spacer()
            Button("撤销…") { confirm(.revokeWindowGrant(w)) }.buttonStyle(ADButtonStyle(.secondary))
                .disabled(!model.canChange("hub.windows.revoke") || state == "revoked")
                .accessibilityLabel("撤销 \(w["windowGrantId"]?.stringValue ?? "") 窗口授权")
        }
        .padding(.horizontal, ADSpace.l)
        .frame(minHeight: 58)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }

    func permission(_ on: Bool, name: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: on ? "checkmark.circle.fill" : "minus").font(.system(size: 11))
                .foregroundStyle(on ? StatusTone.running.foreground : ADColor.muted).accessibilityHidden(true)
            Text(on ? "允许" : "无").font(ADFont.note).foregroundStyle(on ? ADColor.ink : ADColor.muted)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name)：\(on ? "允许" : "无")")
    }

    // MARK: Runs

    var runsPanel: some View {
        let runs = model.runs(of: clientId)
        return VStack(alignment: .leading, spacing: ADSpace.s) {
            Text("这个应用的平台运行").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            if runs.isEmpty {
                Text("没有运行。配对不会自动开始任何业务任务。").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            ForEach(runs.indices, id: \.self) { i in
                let r = runs[i]
                HStack(spacing: ADSpace.m) {
                    Text(r["runId"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink).frame(width: 110, alignment: .leading)
                    Text(r["desktopId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted).frame(width: 90, alignment: .leading)
                    StateBadge(RunStatusPresentation.make(run: r))
                    Spacer()
                    Button { openRun(r["runId"]?.stringValue ?? "") } label: { Label("查看", systemImage: "chevron.right") }
                        .buttonStyle(ADButtonStyle(.quiet))
                }
            }
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }
}
