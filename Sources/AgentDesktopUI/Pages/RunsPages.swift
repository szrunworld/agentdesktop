import AgentDesktopProtocol
import SwiftUI

/// Runs entry (U5): 全部运行 and 动作记录 as two tabs, a Run's detail when
/// one is selected. Lane UI-A keeps the tab here so the shared navigation
/// does not change.
public struct RunsPage: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @State private var tab: RunsTab

    public enum RunsTab: String, CaseIterable, Identifiable, Sendable {
        case runs = "全部运行", records = "动作记录"
        public var id: String { rawValue }
    }

    public init(store: ShellStore, navigation: ShellNavigation, tab: RunsTab = .runs) {
        self.store = store
        self.navigation = navigation
        _tab = State(initialValue: tab)
    }

    public var body: some View {
        if let id = navigation.runId {
            RunInspectorView(store: store, navigation: navigation, runId: id).id(id)
        } else {
            switch tab {
            case .runs: RunsListView(store: store, navigation: navigation, tab: $tab)
            case .records: ActionRecordsView(store: store, navigation: navigation, tab: $tab)
            }
        }
    }
}

/// The tab switch under a Runs page header.
struct RunsTabBar: View {
    @Binding var tab: RunsPage.RunsTab

    var body: some View {
        Picker("Runs", selection: $tab) { ForEach(RunsPage.RunsTab.allCases) { Text($0.rawValue).tag($0) } }
            .pickerStyle(.segmented).labelsHidden().frame(width: 240)
    }
}

/// A menu of choices with a visible label, for the filter rows.
struct RunsFilterMenu: View {
    let title: String
    let options: [(String?, String)]
    @Binding var selection: String?

    var body: some View {
        Menu {
            ForEach(options.indices, id: \.self) { i in
                Button(options[i].1) { selection = options[i].0 }
            }
        } label: {
            HStack(spacing: ADSpace.s) {
                Text(options.first { $0.0 == selection }?.1 ?? title).font(ADFont.note).foregroundStyle(ADColor.ink)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ADColor.muted)
            }
            .padding(.horizontal, ADSpace.m).frame(height: 34)
            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.panel))
            .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .accessibilityLabel(title)
    }
}

/// Runs › 全部运行 (Hub W04): every Run the Runtime lists, filtered by the
/// Runtime (`run.list`), with phase, outcome and quiescence each in its
/// own column. Read-only.
public struct RunsListView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @Binding var tab: RunsPage.RunsTab
    @StateObject private var loader: RunListLoader
    @State private var scope: String? = nil
    @State private var origin: String? = nil
    @State private var desktop: String? = nil
    @State private var client: String? = nil

    public enum Scope: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", ended = "已结束"
        public var id: String { rawValue }
    }

    public init(store: ShellStore, navigation: ShellNavigation, tab: Binding<RunsPage.RunsTab> = .constant(.runs)) {
        self.store = store
        self.navigation = navigation
        _tab = tab
        _loader = StateObject(wrappedValue: RunListLoader(runtime: store.runtime))
    }

    /// With a loader that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, loader: RunListLoader) {
        self.store = store
        self.navigation = navigation
        _tab = .constant(.runs)
        _loader = StateObject(wrappedValue: loader)
    }

    /// Client-side scope over the Store's Runs (kept for the shell's tests).
    public static func visible(_ runs: [JSONValue], scope: Scope) -> [JSONValue] {
        let sorted = runs.sorted { ($0["createdAt"]?.stringValue ?? "") > ($1["createdAt"]?.stringValue ?? "") }
        switch scope {
        case .all: return sorted
        case .active: return sorted.filter { $0["phase"]?.stringValue != "ended" }
        case .ended: return sorted.filter { $0["phase"]?.stringValue == "ended" }
        }
    }

    var filter: RunListLoader.Filter {
        RunListLoader.Filter(active: scope == "active" ? true : scope == "ended" ? false : nil, origin: origin,
                             desktopId: desktop, clientId: client, unknownOnly: scope == "unknown")
    }

    static let columns: [(String, CGFloat)] = [("开始", 84), ("平台 Run", 190), ("Desktop / 调用方", 196),
                                               ("执行阶段", 104), ("最终结果", 150), ("输入静止", 116), ("验证", 104)]

    public var body: some View {
        PageContainer(state: pageState, emptyTitle: "还没有运行",
                      emptyDetail: "外部 Agent 经 CLI、MCP 或 SDK 发起的执行，以及 GUI Explorer 的运行，都会出现在这里。",
                      syncedAt: loader.syncedAt, retry: { Task { await loader.reload() } },
                      header: {
            PageHeader(eyebrow: "Activity / Runs", title: "全部运行",
                       subtitle: "平台执行的权威记录。执行阶段、最终结果、输入静止三项分开显示，都来自 Runtime；停止中的运行要等执行端确认静止后才显示已结束。") {
                RunsTabBar(tab: $tab)
            }
        }) {
            content
        }
        .task(id: store.tick) { await loader.reload() }
        .onChange(of: filter) { f in Task { await loader.apply(f) } }
    }

    /// The filter row stays usable while a filtered list is empty.
    var pageState: PageState {
        if case .empty = loader.state, filter != RunListLoader.Filter() { return .loaded }
        return loader.state
    }

    var content: some View {
        let shown = loader.shown
        return VStack(alignment: .leading, spacing: ADSpace.m) {
            filters(count: shown.count)
            VStack(spacing: 0) {
                header
                if shown.isEmpty {
                    HStack {
                        Text("没有符合条件的运行。").font(ADFont.note).foregroundStyle(ADColor.muted)
                        Button("清除筛选") { scope = nil; origin = nil; desktop = nil; client = nil }
                            .buttonStyle(ADButtonStyle(.secondary))
                        Spacer()
                    }.padding(ADSpace.l)
                }
                ForEach(shown.indices, id: \.self) { i in row(shown[i]) }
                if loader.next != nil {
                    Button(loader.loadingMore ? "正在读取…" : "加载更多") { Task { await loader.loadMore() } }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(loader.loadingMore).padding(ADSpace.m)
                }
            }
            .adPanel()
            HStack(alignment: .top, spacing: ADSpace.l) {
                note("何时结束", "只有执行端确认输入静止（quiescence = confirmed）后，阶段才会变成已结束。停止请求被受理不会让列表立刻显示已结束。")
                note("已结束仍可能结果未知", "已结束、结果未知、已确认静止可以同时成立；停止输入不会补出历史动作的结果。单次动作的运行成功只表示已投递。")
            }
        }
    }

    func note(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(title).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            Text(text).font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    func filters(count: Int) -> some View {
        let clients = Array(Set(store.runs.compactMap { $0["clientId"]?.stringValue })).sorted()
        return HStack(spacing: ADSpace.s) {
            RunsFilterMenu(title: "运行范围", options: [(nil, "所有运行"), ("active", "尚未结束"), ("ended", "已结束"),
                                                    ("unknown", "结果未知")], selection: $scope)
            RunsFilterMenu(title: "来源", options: [(nil, "所有来源"), ("agent_hub", "外部 Agent"), ("gui_explorer", "GUI Explorer"),
                                                  ("workflow_replay", "流程回放"), ("user", "人工")], selection: $origin)
            RunsFilterMenu(title: "Desktop", options: [(nil, "所有 Desktop")] + store.desktops.map {
                ($0["desktopId"]?.stringValue, $0["name"]?.stringValue ?? "—")
            }, selection: $desktop)
            RunsFilterMenu(title: "调用主体", options: [(nil, "所有调用主体")] + clients.map { ($0, $0) }, selection: $client)
            Spacer()
            Text("\(count) 条\(loader.next != nil ? "，还有更多" : "")").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
    }

    var header: some View {
        HStack(spacing: 0) {
            ForEach(Self.columns, id: \.0) { c in
                Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
            }
            Spacer()
        }
        .padding(.horizontal, ADSpace.l).frame(height: 40)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }

    func row(_ r: JSONValue) -> some View {
        let id = r["runId"]?.stringValue ?? "—"
        let desk = store.desktops.first { $0["desktopId"] == r["desktopId"] }?["name"]?.stringValue
        let unknown = r["unknownActions"]?.intValue ?? 0
        return HStack(spacing: 0) {
            Text(TimeText.clock(r["createdAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                .frame(width: 84, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(id).font(ADFont.code).foregroundStyle(ADColor.ink).lineLimit(1).truncationMode(.middle)
                Text("\(RunsText.kindText(r["kind"]?.stringValue)) · \(RunStatusPresentation.originText(r["origin"]?.stringValue))")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }.frame(width: 190, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(desk ?? "已关闭的 Desktop").font(ADFont.noteStrong).foregroundStyle(ADColor.ink).lineLimit(1)
                Text(r["clientId"]?.stringValue ?? "平台").font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(1)
            }.frame(width: 196, alignment: .leading)
            StateBadge(RunsText.phase(r)).frame(width: 104, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                StateBadge(RunsText.outcome(r))
                if unknown > 0 && r["outcome"]?.stringValue != "unknown" {
                    Text("\(unknown) 个动作结果未知").font(ADFont.note).foregroundStyle(StatusTone.attention.foreground)
                }
            }.frame(width: 150, alignment: .leading)
            StateBadge(RunsText.quiescence(r)).frame(width: 116, alignment: .leading)
            Group {
                if let v = RunsText.verification(r) { StateBadge(v) } else { Text("—").font(ADFont.note).foregroundStyle(ADColor.muted) }
            }.frame(width: 104, alignment: .leading)
            Spacer(minLength: 0)
            Button { navigation.showRun(id) } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).accessibilityLabel("打开运行 \(id)")
        }
        .padding(.horizontal, ADSpace.l).frame(minHeight: 62)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// Runs › 运行详情 (Hub W05): the three axes, the stop evidence, the GUI
/// unit's facts, the events and every action with its three result levels
/// (06 §6.4). Stopping a Run asks `run.cancel` and shows what the Runtime
/// answers; it never marks the Run stopped itself.
public struct RunInspectorView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var loader: RunDetailLoader
    @State private var confirmStop = false
    @State private var receipt: String?

    public init(store: ShellStore, navigation: ShellNavigation, runId: String) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: RunDetailLoader(runtime: store.runtime, runId: runId))
    }

    /// With a loader that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, loader: RunDetailLoader, receipt: String? = nil) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: loader)
        _receipt = State(initialValue: receipt)
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    public var body: some View {
        PageContainer(state: loader.state, emptyTitle: "没有这个运行", syncedAt: loader.syncedAt,
                      retry: { Task { await loader.load() } }, header: {
            PageHeader(eyebrow: "Activity / Run", title: "运行详情", subtitle: loader.runId) {
                HStack(spacing: ADSpace.s) {
                    Button { navigation.back() } label: { Label("全部运行", systemImage: "chevron.left") }
                        .buttonStyle(ADButtonStyle(.secondary))
                    Button { confirmStop = true } label: { Label("停止此运行", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger)).disabled(!canStop)
                }
            }
        }) {
            if let run = loader.run { content(run) }
        }
        .task(id: store.tick) { await loader.load() }
        .confirmationDialog("停止这个运行？", isPresented: $confirmStop) {
            Button("停止此运行", role: .destructive) { Task { await loader.stop() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行不再接受新输入并进入停止流程；已经开始的动作要等执行端确认静止后才显示已结束。外部 Agent 应用本身不会被结束。")
        }
        .overlay {
            if let id = receipt {
                ReceiptDetailView(runtime: store.runtime, requestId: id, desktopName: desktopName(loader.run),
                                  close: { receipt = nil })
            }
        }
    }

    var canStop: Bool {
        guard connected, let p = loader.run?["phase"]?.stringValue else { return false }
        return p != "ended" && p != "stopping" && !loader.stopping
    }

    func desktopName(_ run: JSONValue?) -> String? {
        store.desktops.first { $0["desktopId"] == run?["desktopId"] }?["name"]?.stringValue
    }

    func content(_ run: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            axes(run)
            banners(run)
            HStack(alignment: .top, spacing: ADSpace.xl) {
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    if run["kind"]?.stringValue == "unit" { unitPanel(run) }
                    actionsPanel
                    timeline
                }
                .frame(maxWidth: .infinity)
                facts(run).frame(width: 320)
            }
        }
    }

    func axes(_ r: JSONValue) -> some View {
        HStack(spacing: ADSpace.m) {
            axis("执行阶段 · phase", RunsText.phase(r), r["phase"]?.stringValue ?? "—")
            axis("最终结果 · outcome", RunsText.outcome(r), r["outcome"]?.stringValue ?? "null")
            axis("输入静止 · quiescence", RunsText.quiescence(r), r["quiescence"]?.stringValue ?? "—")
            if let v = RunsText.verification(r) {
                axis("验证 · verification", v, r["unit"]?["verification"]?["status"]?.stringValue ?? "not_requested")
            }
        }
    }

    func axis(_ label: String, _ status: StatusText, _ code: String) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted)
            StateBadge(status)
            Text(code).font(ADFont.identifier).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    @ViewBuilder
    func banners(_ r: JSONValue) -> some View {
        if r["phase"]?.stringValue == "stopping" {
            banner(r["closingReason"]?.stringValue == "finished" ? "正在完成：等待平台输入静止证据" : "停止请求已受理，等待平台输入静止证据",
                   "现在仍是 phase=stopping / quiescence=\(r["quiescence"]?.stringValue ?? "—")。不会因为连接断开或收到受理回执就显示已结束。")
        }
        if let p = loader.stopProblem {
            banner("停止请求没有被受理：\(p.title)（\(p.code)）", p.advice, tone: .danger)
        }
        let unknown = r["unknownActions"]?.intValue ?? 0
        if r["outcome"]?.stringValue == "unknown" || unknown > 0 {
            banner(r["phase"]?.stringValue == "ended" ? "平台输入已静止；\(unknown) 个动作结果仍需核实" : "\(unknown) 个动作结果未知，需要核实",
                   "停止完成与历史动作结果未知是两件事。结果未知的动作不会重发；运行结束、输入静止后可在 Inbox 记录核实结论，运行的最终结果仍保持未知。")
            if store.offers("inbox.list") {
                Button { navigation.open(.inbox) } label: { Label("去 Inbox 核实", systemImage: "tray") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
        }
    }

    func banner(_ title: String, _ text: String, tone: StatusTone = .attention) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(title).font(ADFont.bodyStrong).foregroundStyle(tone.foreground)
            Text(text).font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(tone.background))
    }

    func unitPanel(_ r: JSONValue) -> some View {
        let u = r["unit"]
        let v = u?["verification"]
        return VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack {
                Text("GUI 单元").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                StateBadge(RunsText.unitVerification(v?["status"]?.stringValue))
            }
            LabeledValue(label: "模式", value: RunsText.modeText(u?["mode"]?.stringValue), labelWidth: 110)
            LabeledValue(label: "目标摘要", value: u?["goalHash"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "GUI 配置", value: u?["guiProfileId"]?.stringValue.map { "\($0) · r\(u?["guiProfileRevision"]?.intValue ?? 0)" } ?? "—",
                         monospaced: true, labelWidth: 110)
            LabeledValue(label: "验证观察", value: v?["observationId"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "验证时间", value: TimeText.clock(v?["checkedAt"]?.stringValue), monospaced: true, labelWidth: 110)
            Text(Self.verificationNote(v?["status"]?.stringValue)).font(ADFont.note).foregroundStyle(ADColor.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.l).adPanel()
    }

    static func verificationNote(_ status: String?) -> String {
        switch status {
        case "matched": return "在新的观察上，验证条件全部成立。"
        case "contradicted": return "在新的观察上，验证条件不成立。"
        case "inconclusive": return "无法判定：新的观察不足以判断验证条件是否成立。不要把它当成成功或失败。"
        case "not_run": return "没有运行验证；单元结束只说明执行结束，不说明目标已达到。"
        default: return "验证结果尚未产生。"
        }
    }

    var actionsPanel: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            Text("动作与回执").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            if loader.actions.isEmpty {
                Text("这个运行还没有动作。").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            ForEach(loader.actions, id: \.requestId) { a in
                RunsReceiptCard(entry: a, open: { receipt = a.requestId })
            }
        }
    }

    var timeline: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("平台事件").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink).padding(ADSpace.l)
            ForEach(loader.events.indices.reversed(), id: \.self) { i in
                let e = loader.events[i]
                HStack(alignment: .firstTextBaseline, spacing: ADSpace.m) {
                    Text("#\(e["sequence"]?.intValue ?? 0)").font(ADFont.code).foregroundStyle(ADColor.muted)
                        .frame(width: 40, alignment: .leading)
                    Text(TimeText.clock(e["at"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(RunsText.eventTitle(e["type"]?.stringValue)).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                        Text([e["type"]?.stringValue ?? "—", RunsText.eventDetail(e)].filter { !$0.isEmpty }.joined(separator: " · "))
                            .font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(2)
                    }
                    Spacer()
                }
                .padding(.horizontal, ADSpace.l).padding(.vertical, ADSpace.s)
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
            }
        }
        .adPanel()
    }

    func facts(_ r: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text("资源与归属").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink).padding(.bottom, ADSpace.xs)
            LabeledValue(label: "类型", value: RunsText.kindText(r["kind"]?.stringValue), labelWidth: 100)
            LabeledValue(label: "来源", value: RunStatusPresentation.originText(r["origin"]?.stringValue), labelWidth: 100)
            LabeledValue(label: "所有权", value: r["ownership"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "生命周期", value: r["lifetime"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "调用主体", value: r["clientId"]?.stringValue ?? "平台", monospaced: true, labelWidth: 100)
            LabeledValue(label: "connectionId", value: r["connectionId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "Desktop", value: desktopName(r) ?? "已关闭的 Desktop", labelWidth: 100)
            LabeledValue(label: "desktopId", value: r["desktopId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "sessionId", value: r["sessionId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            Divider().overlay(ADColor.line)
            LabeledValue(label: "开始", value: TimeText.clock(r["createdAt"]?.stringValue), monospaced: true, labelWidth: 100)
            LabeledValue(label: "结束", value: TimeText.clock(r["endedAt"]?.stringValue), monospaced: true, labelWidth: 100)
            LabeledValue(label: "结束原因", value: r["closingReason"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "回执数", value: "\(r["receipts"]?.arrayValue?.count ?? 0)", labelWidth: 100)
            LabeledValue(label: "结果未知", value: "\(r["unknownActions"]?.intValue ?? 0)", labelWidth: 100)
            LabeledValue(label: "修订", value: "\(r["revision"]?.intValue ?? 0)", monospaced: true, labelWidth: 100)
            if let s = loader.stopAnswer {
                Divider().overlay(ADColor.line)
                LabeledValue(label: "停止请求", value: s, labelWidth: 100)
            }
            if let d = r["desktopId"]?.stringValue, store.desktops.contains(where: { $0["desktopId"]?.stringValue == d }) {
                Button { navigation.showDesktop(d) } label: { Label("打开 Desktop", systemImage: "display").frame(maxWidth: .infinity) }
                    .buttonStyle(ADButtonStyle(.secondary)).padding(.top, ADSpace.s)
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }
}
