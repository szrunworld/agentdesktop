import AgentDesktopProtocol
import SwiftUI

/// Desktops › 总览 (P01, P03): what desktop.list and the active Runs say,
/// with creation (P04/P05), the side-by-side view (P07) and a preview window
/// per Desktop (P08). Stopping waits for desktop.stop (A5).
public struct DesktopsOverviewView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    let openPreview: ((String) -> Void)?
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var layout: Layout = .grid
    @State private var creating: CreateDesktopFlow?

    public enum Layout: String, CaseIterable, Identifiable {
        case grid = "网格", list = "列表"
        public var id: String { rawValue }
    }

    public enum Filter: String, CaseIterable, Identifiable {
        case all = "全部", running = "操作中", idle = "空闲"
        public var id: String { rawValue }
    }

    public init(store: ShellStore, navigation: ShellNavigation, openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.openPreview = openPreview
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
                      emptyDetail: "Desktop 是 Agent 的独立桌面，你继续使用自己的电脑。",
                      emptyAction: connected ? ("创建 Desktop", { startCreate() }) : nil,
                      syncedAt: store.desktopsSyncedAt, retry: { Task { await store.start() } },
                      header: {
            PageHeader(eyebrow: "Agent Desktop", title: "Desktops", subtitle: "每个 Agent 一个独立桌面，你继续使用自己的电脑。") {
                HStack(spacing: ADSpace.s) {
                    Button { navigation.sideBySide = true } label: { Label("并排预览", systemImage: "square.grid.2x2") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(store.desktops.isEmpty)
                    Button { startCreate() } label: { Label("创建 Desktop", systemImage: "plus") }
                        .buttonStyle(ADButtonStyle(.primary)).disabled(!connected)
                }
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
                    Picker("显示方式", selection: $layout) { ForEach(Layout.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 120)
                }
                if shown.isEmpty {
                    EmptyState(title: "没有符合条件的 Desktop", detail: "换一个筛选条件或清除搜索。",
                               action: ("清除筛选", { filter = .all; query = "" })).adPanel()
                } else if layout == .grid {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: ADSpace.l, alignment: .top), count: 3),
                              spacing: ADSpace.l) {
                        ForEach(shown.indices, id: \.self) { i in
                            let d = shown[i]
                            let id = d["desktopId"]?.stringValue ?? ""
                            DesktopCard(desktop: d, control: DesktopControlPresentation.make(desktop: d, activeRuns: store.activeRuns),
                                        openPreview: openPreview.map { f in { f(id) } }, stop: nil,
                                        openDetail: { navigation.showDesktop(id) },
                                        picture: AnyView(CardPicture(store: store, desktopId: id).id(id)),
                                        stopUnavailable: "停止单个 Desktop：\(WaitingFor.a5)")
                        }
                    }
                } else {
                    VStack(spacing: 0) {
                        ForEach(shown.indices, id: \.self) { i in listRow(shown[i]) }
                    }
                    .adPanel()
                }
            }
        }
        // P04 is a modal inside the main window (not a separate sheet
        // window), so the page stays one window for the user and for
        // accessibility.
        .overlay {
            if let flow = creating {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .accessibilityHidden(true)
                    CreateDesktopSheet(flow: flow, cancel: { creating = nil }, finished: { id in
                        creating = nil
                        Task { await store.refreshDesktops() }
                        navigation.showDesktop(id)
                    })
                    .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }
            }
        }
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    func startCreate() { creating = CreateDesktopFlow(runtime: store.runtime) }

    func listRow(_ d: JSONValue) -> some View {
        let id = d["desktopId"]?.stringValue ?? ""
        let control = DesktopControlPresentation.make(desktop: d, activeRuns: store.activeRuns)
        return HStack(spacing: ADSpace.m) {
            VStack(alignment: .leading, spacing: 2) {
                Text(d["name"]?.stringValue ?? "—").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text(id).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }
            .frame(width: 260, alignment: .leading)
            Text(d["binding"]?["appName"]?.stringValue ?? "没有绑定窗口").font(ADFont.note).foregroundStyle(ADColor.ink)
                .frame(width: 180, alignment: .leading)
            Text(DesktopControlPresentation.sizeText(d)).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                .frame(width: 110, alignment: .leading)
            StateBadge(control.status)
            Text(control.controller).font(ADFont.note).foregroundStyle(ADColor.muted)
            Spacer()
            if let openPreview {
                Button { openPreview(id) } label: { Label("预览", systemImage: "eye") }.buttonStyle(ADButtonStyle(.secondary))
            }
            Button { navigation.showDesktop(id) } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).accessibilityLabel("打开 \(d["name"]?.stringValue ?? "Desktop") 的详情")
        }
        .padding(.horizontal, ADSpace.l).frame(minHeight: 60)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }

    func count(_ f: Filter) -> Int {
        Self.visible(store.desktops, activeRuns: store.activeRuns, filter: f, query: "").count
    }
}

/// Desktops › 详情 (P06): live picture, controller, connection panel and
/// recent actions. Takeover and stop wait for A5.
public struct DesktopInspectorView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var activity: DesktopActivityLoader
    @StateObject private var frame: DesktopFrameLease
    @State private var zoom: PreviewZoom = .fit
    let desktopId: String
    let openPreview: ((String) -> Void)?

    public init(store: ShellStore, navigation: ShellNavigation, desktopId: String, openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.desktopId = desktopId
        self.openPreview = openPreview
        _activity = StateObject(wrappedValue: DesktopActivityLoader(runtime: store.runtime, desktopId: desktopId))
        _frame = StateObject(wrappedValue: DesktopFrameLease())
    }

    /// With activity and picture already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, activity: DesktopActivityLoader, frame: DesktopFrameLease? = nil,
         openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.desktopId = activity.desktopId
        self.openPreview = openPreview
        _activity = StateObject(wrappedValue: activity)
        _frame = StateObject(wrappedValue: frame ?? DesktopFrameLease())
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
                    Button { openPreview?(desktopId) } label: { Label("独立预览", systemImage: "rectangle.on.rectangle") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(openPreview == nil || desktop == nil)
                    Button {} label: { Label("停止输入", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger)).disabled(true).help("停止单个 Desktop 需要 desktop.stop：\(WaitingFor.a5)")
                    Button {} label: { Label("关闭", systemImage: "xmark.circle") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(true).help("关闭前要列出将结束的资源（desktop.closePlan）：\(WaitingFor.a5)")
                }
            }
        }) {
            if let desktop {
                let control = DesktopControlPresentation.make(desktop: desktop, activeRuns: store.activeRuns)
                HStack(alignment: .top, spacing: ADSpace.xl) {
                    VStack(alignment: .leading, spacing: ADSpace.l) {
                        ControllerBanner(control: control)
                        DesktopFrameView(lease: frame, zoom: $zoom, height: 460)
                            .liveFrame(frame, displayId: DesktopFrameHub.displayId(of: desktop))
                        Text("停止、接管、关闭：\(WaitingFor.a5)（desktop.stop / takeover / closePlan 尚未上线）")
                            .font(ADFont.note).foregroundStyle(ADColor.muted)
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
    let openPreview: ((String) -> Void)?

    public init(store: ShellStore, navigation: ShellNavigation, openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.openPreview = openPreview
    }

    public var body: some View {
        if let id = navigation.desktopId {
            DesktopInspectorView(store: store, navigation: navigation, desktopId: id, openPreview: openPreview).id(id)
        } else if navigation.sideBySide {
            SideBySideView(store: store, navigation: navigation, openPreview: openPreview)
        } else {
            DesktopsOverviewView(store: store, navigation: navigation, openPreview: openPreview)
        }
    }
}

/// A card's picture: the Desktop's live picture, shared with any other
/// view of the same Desktop; the placeholder until the first frame.
struct CardPicture: View {
    @ObservedObject var store: ShellStore
    @StateObject private var lease = DesktopFrameLease()
    let desktopId: String

    init(store: ShellStore, desktopId: String) {
        self.store = store
        self.desktopId = desktopId
    }

    var desktop: JSONValue? { store.desktops.first { $0["desktopId"]?.stringValue == desktopId } }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            if let frame = lease.frame {
                Rectangle().fill(ADColor.canvas)
                Image(decorative: frame.image, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(ADSpace.xs)
            } else if let d = desktop {
                DesktopViewport(sizeText: DesktopControlPresentation.sizeText(d), appName: d["binding"]?["appName"]?.stringValue,
                                note: Self.note(lease.status))
            }
        }
        .liveFrame(lease, displayId: DesktopFrameHub.displayId(of: desktop))
    }

    static func note(_ status: DesktopFrameStatus) -> String {
        switch status {
        case .starting: return "正在连接实时画面…"
        case .permissionDenied: return "需要屏幕录制权限"
        case .paused: return "画面已暂停"
        case .live, .unavailable: return "画面暂不可用"
        }
    }
}
