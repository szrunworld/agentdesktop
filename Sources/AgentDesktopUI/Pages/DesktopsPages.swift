import AgentDesktopContracts
import SwiftUI

/// Desktops › 总览 (P01, P03), read-only: what desktop.list and the active
/// Runs say. Creating, previewing and stopping arrive with U2 / U3, so
/// those buttons are present but off.
public struct DesktopsOverviewView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @State private var filter: Filter = .all
    @State private var query = ""

    public enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", running = "操作中", idle = "空闲"
        public var id: String { rawValue }
    }

    public init(store: ShellStore, navigation: ShellNavigation) {
        self.store = store
        self.navigation = navigation
    }

    /// Desktops after the filter and the name / ID search.
    public static func visible(_ desktops: [JSONValue], activeRuns: [JSONValue], filter: Filter, query: String) -> [JSONValue] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return desktops.filter { d in
            let running = activeRuns.contains { $0["desktopId"] == d["desktopId"] }
            switch filter {
            case .all: break
            case .running: if !running { return false }
            case .idle: if running { return false }
            }
            guard !q.isEmpty else { return true }
            return [d["name"]?.stringValue, d["desktopId"]?.stringValue, d["binding"]?["appName"]?.stringValue]
                .compactMap { $0?.lowercased() }.contains { $0.contains(q) }
        }
    }

    public var body: some View {
        PageContainer(state: store.desktopsState, emptyTitle: "还没有 Desktop",
                      emptyDetail: "Desktop 是 Agent 的独立桌面，你继续使用自己的电脑。可以用 agentdesktop desktop create 创建；界面里的创建入口随 U2 提供。",
                      syncedAt: store.desktopsSyncedAt, retry: { Task { await store.start() } },
                      header: {
            PageHeader(eyebrow: "Agent Desktop", title: "Desktops", subtitle: "每个 Agent 一个独立桌面，你继续使用自己的电脑。") {
                HStack(spacing: ADSpace.s) {
                    Button {} label: { Label("并排预览", systemImage: "square.grid.2x2") }.buttonStyle(ADButtonStyle(.secondary))
                    Button {} label: { Label("创建 Desktop", systemImage: "plus") }.buttonStyle(ADButtonStyle(.primary))
                }
                .disabled(true)
                .help("创建与并排预览随 Desktops 页面（U2）提供")
            }
        }) {
            let shown = Self.visible(store.desktops, activeRuns: store.activeRuns, filter: filter, query: query)
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack(spacing: ADSpace.m) {
                    Picker("筛选", selection: $filter) {
                        ForEach(Filter.allCases) { f in Text("\(f.rawValue) \(count(f))").tag(f) }
                    }
                    .pickerStyle(.segmented).labelsHidden().frame(width: 300)
                    Spacer()
                    TextField("搜索 Desktop 名称、ID 或应用", text: $query).textFieldStyle(.roundedBorder).frame(width: 260)
                }
                if shown.isEmpty {
                    EmptyState(title: "没有符合条件的 Desktop", detail: "换一个筛选条件或清除搜索。",
                               action: ("清除筛选", { filter = .all; query = "" })).adPanel()
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ADSpace.l, alignment: .top), count: 3),
                              spacing: ADSpace.l) {
                        ForEach(shown.indices, id: \.self) { i in
                            let d = shown[i]
                            DesktopCard(desktop: d, control: DesktopControlPresentation.make(desktop: d, activeRuns: store.activeRuns),
                                        openDetail: { navigation.showDesktop(d["desktopId"]?.stringValue ?? "") })
                        }
                    }
                }
            }
        }
    }

    func count(_ f: Filter) -> Int {
        Self.visible(store.desktops, activeRuns: store.activeRuns, filter: f, query: "").count
    }
}

/// Desktops › 详情 (P06), read-only part: picture placeholder, controller,
/// connection panel and recent actions. Preview, takeover and stop come
/// with U2 / U3.
public struct DesktopInspectorView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var activity: DesktopActivityLoader
    let desktopId: String

    public init(store: ShellStore, navigation: ShellNavigation, desktopId: String) {
        self.store = store
        self.navigation = navigation
        self.desktopId = desktopId
        _activity = StateObject(wrappedValue: DesktopActivityLoader(runtime: store.runtime, desktopId: desktopId))
    }

    /// With activity already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, activity: DesktopActivityLoader) {
        self.store = store
        self.navigation = navigation
        self.desktopId = activity.desktopId
        _activity = StateObject(wrappedValue: activity)
    }

    var desktop: JSONValue? { store.desktops.first { $0["desktopId"]?.stringValue == desktopId } }

    var state: PageState { Self.state(list: store.desktopsState, found: desktop != nil) }

    /// Detail state from the list's state: a Desktop missing from a good
    /// list is gone (its own empty state); failures and disconnection show
    /// as such, over the last known data when there is any.
    public static func state(list: PageState, found: Bool) -> PageState {
        switch list {
        case .loaded, .empty: return found ? .loaded : .empty
        case .loading: return found ? .loaded : .loading
        case .failed, .disconnected: return list
        }
    }

    public var body: some View {
        PageContainer(state: state, emptyTitle: "这个 Desktop 已不存在",
                      emptyDetail: "\(desktopId) 已关闭或被销毁；它的运行与动作记录仍在 Runs 中。",
                      emptyAction: ("返回总览", { navigation.back() }),
                      syncedAt: store.desktopsSyncedAt, retry: { Task { await store.start() } },
                      header: {
            PageHeader(eyebrow: "Desktop / Detail", title: desktop?["name"]?.stringValue ?? desktopId,
                       subtitle: "\(desktopId) · \(desktop?["binding"]?["appName"]?.stringValue ?? "没有绑定窗口")") {
                HStack(spacing: ADSpace.s) {
                    Button { navigation.back() } label: { Label("总览", systemImage: "chevron.left") }
                        .buttonStyle(ADButtonStyle(.secondary))
                    Button {} label: { Label("独立预览", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(true).help("独立预览随 U2 提供")
                    Button {} label: { Label("停止输入", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger)).disabled(true).help("停止单个 Desktop 需要 desktop.stop（A5，U3）")
                }
            }
        }) {
            if let desktop {
                let control = DesktopControlPresentation.make(desktop: desktop, activeRuns: store.activeRuns)
                HStack(alignment: .top, spacing: ADSpace.xl) {
                    VStack(alignment: .leading, spacing: ADSpace.l) {
                        ControllerBanner(control: control)
                        DesktopViewport(desktop: desktop).frame(height: 420).adPanel()
                            .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
                        recent
                    }
                    .frame(maxWidth: .infinity)
                    ConnectionPanel(desktop: desktop, control: control).frame(width: 294)
                }
            }
        }
        .task(id: store.tick) { await activity.load(runs: store.runs) }
    }

    var recent: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近动作").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                Button("全部运行") { navigation.open(.runs) }.buttonStyle(ADButtonStyle(.quiet))
            }
            .padding(ADSpace.l)
            if let p = activity.problem { ProblemView(p).padding(ADSpace.l) }
            if activity.actions.isEmpty {
                Text("还没有动作。外部 Agent 经 CLI、MCP 或 SDK 发出的输入会出现在这里。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
            }
            ForEach(activity.actions.prefix(8), id: \.requestId) { a in
                HStack(spacing: ADSpace.m) {
                    Text(TimeText.clock(a.at)).font(ADFont.code).foregroundStyle(ADColor.ink)
                    Text(a.requestId).font(ADFont.code).foregroundStyle(ADColor.muted)
                    if let reason = a.presentation.reasonText {
                        Text(reason).font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    Spacer()
                    StateBadge(a.presentation.status)
                    Button { navigation.showRun(a.runId) } label: { Image(systemName: "chevron.right") }
                        .buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("打开运行 \(a.runId)")
                }
                .padding(.horizontal, ADSpace.l).frame(minHeight: 44)
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
            }
        }
        .adPanel()
    }
}

/// Desktops entry: overview or the selected Desktop's detail.
public struct DesktopsPage: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation

    public init(store: ShellStore, navigation: ShellNavigation) {
        self.store = store
        self.navigation = navigation
    }

    public var body: some View {
        if let id = navigation.desktopId {
            DesktopInspectorView(store: store, navigation: navigation, desktopId: id).id(id)
        } else {
            DesktopsOverviewView(store: store, navigation: navigation)
        }
    }
}
