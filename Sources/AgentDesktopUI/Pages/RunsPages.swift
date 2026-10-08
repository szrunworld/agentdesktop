import AgentDesktopContracts
import SwiftUI

/// Runs › 全部运行 (Hub W04): every Run the Runtime lists, with its three
/// axes as the Runtime reports them. Read-only.
public struct RunsListView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @State private var scope: Scope = .all

    public enum Scope: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", ended = "已结束"
        public var id: String { rawValue }
    }

    public init(store: ShellStore, navigation: ShellNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public static func visible(_ runs: [JSONValue], scope: Scope) -> [JSONValue] {
        let sorted = runs.sorted { ($0["createdAt"]?.stringValue ?? "") > ($1["createdAt"]?.stringValue ?? "") }
        switch scope {
        case .all: return sorted
        case .active: return sorted.filter { $0["phase"]?.stringValue != "ended" }
        case .ended: return sorted.filter { $0["phase"]?.stringValue == "ended" }
        }
    }

    static let columns: [(String, CGFloat)] = [("开始", 100), ("运行", 220), ("Desktop", 170), ("来源 / 调用者", 190),
                                               ("状态", 130), ("动作", 70)]

    public var body: some View {
        PageContainer(state: store.runsState, emptyTitle: "还没有运行",
                      emptyDetail: "外部 Agent 经 CLI、MCP 或 SDK 发起的执行，以及 GUI Explorer 的运行，都会出现在这里。",
                      syncedAt: store.runsSyncedAt, retry: { Task { await store.start() } },
                      header: {
            PageHeader(eyebrow: "Activity / Runs", title: "全部运行",
                       subtitle: "平台执行的权威记录。状态来自 Runtime；停止中的运行要等执行端确认静止后才显示已停止。")
        }) {
            let shown = Self.visible(store.runs, scope: scope)
            VStack(alignment: .leading, spacing: ADSpace.m) {
                Picker("范围", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 260)
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        ForEach(Self.columns, id: \.0) { c in
                            Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                        }
                        Spacer()
                    }
                    .padding(.horizontal, ADSpace.l).frame(height: 40)
                    .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
                    if shown.isEmpty {
                        Text("这个范围里没有运行。").font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
                    }
                    ForEach(shown.indices, id: \.self) { i in row(shown[i]) }
                }
                .adPanel()
            }
        }
    }

    func row(_ r: JSONValue) -> some View {
        let id = r["runId"]?.stringValue ?? "—"
        let desk = store.desktops.first { $0["desktopId"] == r["desktopId"] }?["name"]?.stringValue
        return HStack(spacing: 0) {
            Text(TimeText.clock(r["createdAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(id).font(ADFont.code).foregroundStyle(ADColor.ink).lineLimit(1).truncationMode(.middle)
                Text("kind \(r["kind"]?.stringValue ?? "—")").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(desk ?? "已关闭的 Desktop").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text(r["desktopId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(RunStatusPresentation.originText(r["origin"]?.stringValue)).font(ADFont.note).foregroundStyle(ADColor.ink)
                Text(r["clientId"]?.stringValue ?? "平台").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 190, alignment: .leading)
            StateBadge(RunStatusPresentation.make(run: r)).frame(width: 130, alignment: .leading)
            Text("\(r["receipts"]?.arrayValue?.count ?? 0)").font(ADFont.note).foregroundStyle(ADColor.ink)
                .frame(width: 70, alignment: .leading)
            Spacer()
            if (r["unknownActions"]?.intValue ?? 0) > 0 {
                StateBadge("\(r["unknownActions"]!.intValue!) 个结果未知", tone: .attention).padding(.trailing, ADSpace.s)
            }
            Button { navigation.showRun(id) } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).accessibilityLabel("打开运行 \(id)")
        }
        .padding(.horizontal, ADSpace.l).frame(minHeight: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// Runs › 运行详情 (Hub W05): the Run's fields, its events and its actions
/// with receipts (06 §6.4). Read-only: stopping a Run is U3 / U5.
public struct RunInspectorView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var loader: RunDetailLoader

    public init(store: ShellStore, navigation: ShellNavigation, runId: String) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: RunDetailLoader(runtime: store.runtime, runId: runId))
    }

    /// With a loader that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, loader: RunDetailLoader) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: loader)
    }

    public var body: some View {
        PageContainer(state: loader.state, emptyTitle: "没有这个运行", syncedAt: loader.syncedAt,
                      retry: { Task { await loader.load() } }, header: {
            PageHeader(eyebrow: "Activity / Run", title: "运行详情", subtitle: loader.runId) {
                Button { navigation.back() } label: { Label("全部运行", systemImage: "chevron.left") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
        }) {
            if let run = loader.run { content(run) }
        }
        .task(id: store.tick) { await loader.load() }
    }

    func content(_ run: JSONValue) -> some View {
        HStack(alignment: .top, spacing: ADSpace.xl) {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                VStack(alignment: .leading, spacing: ADSpace.m) {
                    Text("动作与回执").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    if loader.actions.isEmpty {
                        Text("这个运行还没有动作。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    ForEach(loader.actions, id: \.requestId) { a in
                        ActionReceiptView(receipt: a.receipt, requestId: a.requestId, errorCode: a.errorCode)
                    }
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text("事件").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink).padding(ADSpace.l)
                    ForEach(loader.events.indices.reversed(), id: \.self) { i in
                        let e = loader.events[i]
                        HStack(spacing: ADSpace.m) {
                            Text("#\(e["sequence"]?.intValue ?? 0)").font(ADFont.code).foregroundStyle(ADColor.muted)
                                .frame(width: 44, alignment: .leading)
                            Text(TimeText.clock(e["at"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                            Text(e["type"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink)
                            Spacer()
                        }
                        .padding(.horizontal, ADSpace.l).frame(minHeight: 34)
                        .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
                    }
                }
                .adPanel()
            }
            .frame(maxWidth: .infinity)
            facts(run).frame(width: 330)
        }
    }

    func facts(_ r: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            StateBadge(RunStatusPresentation.make(run: r))
            Text("三项状态分开显示，均来自 Runtime").font(ADFont.note).foregroundStyle(ADColor.muted).padding(.bottom, ADSpace.xs)
            LabeledValue(label: "阶段 phase", value: r["phase"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "结果 outcome", value: r["outcome"]?.stringValue ?? "尚无", monospaced: true, labelWidth: 110)
            LabeledValue(label: "静止 quiescence", value: r["quiescence"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "结束原因", value: r["closingReason"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            Divider().overlay(ADColor.line)
            LabeledValue(label: "kind", value: r["kind"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "来源", value: RunStatusPresentation.originText(r["origin"]?.stringValue), labelWidth: 110)
            LabeledValue(label: "所有权", value: r["ownership"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "生命周期", value: r["lifetime"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "clientId", value: r["clientId"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "connectionId", value: r["connectionId"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "desktopId", value: r["desktopId"]?.stringValue ?? "—", monospaced: true, labelWidth: 110)
            LabeledValue(label: "开始", value: TimeText.clock(r["createdAt"]?.stringValue), monospaced: true, labelWidth: 110)
            LabeledValue(label: "结束", value: TimeText.clock(r["endedAt"]?.stringValue), monospaced: true, labelWidth: 110)
            LabeledValue(label: "回执数", value: "\(r["receipts"]?.arrayValue?.count ?? 0)", labelWidth: 110)
            LabeledValue(label: "结果未知", value: "\(r["unknownActions"]?.intValue ?? 0)", labelWidth: 110)
            LabeledValue(label: "修订", value: "\(r["revision"]?.intValue ?? 0)", monospaced: true, labelWidth: 110)
            if let d = r["desktopId"]?.stringValue, store.desktops.contains(where: { $0["desktopId"]?.stringValue == d }) {
                Button { navigation.showDesktop(d) } label: { Label("打开 Desktop", systemImage: "display").frame(maxWidth: .infinity) }
                    .buttonStyle(ADButtonStyle(.secondary)).padding(.top, ADSpace.s)
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }
}

/// Runs entry: list or the selected Run's detail.
public struct RunsPage: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation

    public init(store: ShellStore, navigation: ShellNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        if let id = navigation.runId {
            RunInspectorView(store: store, navigation: navigation, runId: id).id(id)
        } else {
            RunsListView(store: store, navigation: navigation)
        }
    }
}
