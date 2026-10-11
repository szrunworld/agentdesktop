import AgentDesktopProtocol
import SwiftUI

/// Desktops › 总览 (P01, P03): what desktop.list and the active Runs say,
/// with creation (P04/P05), the side-by-side view (P07) and a preview window
/// per Desktop (P08). Each card stops its own Desktop (desktop.stop).
public struct DesktopsOverviewView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    let openPreview: ((String) -> Void)?
    @State private var filter: Filter = .all
    @State private var query = ""
    @State private var layout: Layout = .grid
    @State private var creating: CreateDesktopFlow?
    @State private var attaching: AttachDisplayFlow?
    @StateObject private var stops: DesktopStops

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
        _stops = StateObject(wrappedValue: DesktopStops(store: store))
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
                    Button { startAttach() } label: { Label("开放我的显示器", systemImage: "display.and.arrow.down") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(!connected)
                        .help("把你的一块显示器作为物理 Desktop 开放给一个已配对的程序；每个窗口仍要你单独授权")
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
                            let info = DesktopControlInfo.make(desktop: d, activeRuns: store.activeRuns)
                            DesktopCard(desktop: d, control: info.presentation,
                                        openPreview: openPreview.map { f in { f(id) } },
                                        stop: connected && stops.canStop(id, info: info, methods: methods) ? { Task { await stops.stop(id) } } : nil,
                                        openDetail: { navigation.showDesktop(id) },
                                        picture: AnyView(CardPicture(store: store, desktopId: id).id(id)),
                                        stopUnavailable: stopWhy(info), stopNote: stops.note(id))
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
        .task(id: store.tick) { await stops.refresh() }
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
            } else if let flow = attaching {
                ZStack {
                    Color.black.opacity(0.18).ignoresSafeArea()
                        .accessibilityHidden(true)
                    AttachDisplaySheet(flow: flow, cancel: { attaching = nil }, finished: { id in
                        attaching = nil
                        Task { await store.refreshDesktops() }
                        if !id.isEmpty { navigation.showDesktop(id) }
                    })
                    .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
                    .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
                }
            }
        }
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }
    var methods: DesktopControlMethods { DesktopControlMethods(capabilities: store.capabilities) }

    func stopWhy(_ info: DesktopControlInfo) -> String? {
        DesktopInspectorView.stopBlocked(info, methods: methods, connected: connected)
    }

    func startCreate() { creating = CreateDesktopFlow(runtime: store.runtime) }
    func startAttach() { attaching = AttachDisplayFlow(runtime: store.runtime) }

    func listRow(_ d: JSONValue) -> some View {
        let id = d["desktopId"]?.stringValue ?? ""
        let info = DesktopControlInfo.make(desktop: d, activeRuns: store.activeRuns)
        let control = info.presentation
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
            Button { Task { await stops.stop(id) } } label: { Label("停止", systemImage: "stop.fill") }
                .buttonStyle(ADButtonStyle(.secondary))
                .disabled(!connected || !stops.canStop(id, info: info, methods: methods))
                .help(stopWhy(info) ?? (stops.note(id) ?? "只停止这个 Desktop 的输入"))
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

/// Desktops › 详情 (P06, P12–P18): live picture, Desktop.control, the
/// owner's stop / takeover / handback / close, connection panel, apps and
/// size, recent actions. Every control state is the Runtime's answer.
public struct DesktopInspectorView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var activity: DesktopActivityLoader
    @StateObject private var frame: DesktopFrameLease
    @StateObject private var access: PhysicalDesktopAccess
    @StateObject private var control: DesktopControlFlow
    @State private var zoom: PreviewZoom = .fit
    @State private var review: UnknownResultReview?
    @State private var reviewProblem: RuntimeProblem?
    /// Hiding the picture releases the live frame; it never touches
    /// control or Runs (UC14).
    @State private var showPicture = true
    let desktopId: String
    let openPreview: ((String) -> Void)?

    public init(store: ShellStore, navigation: ShellNavigation, desktopId: String, openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.desktopId = desktopId
        self.openPreview = openPreview
        _activity = StateObject(wrappedValue: DesktopActivityLoader(runtime: store.runtime, desktopId: desktopId))
        _frame = StateObject(wrappedValue: DesktopFrameLease())
        _access = StateObject(wrappedValue: PhysicalDesktopAccess(runtime: store.runtime, desktopId: desktopId))
        _control = StateObject(wrappedValue: DesktopControlFlow(runtime: store.runtime, desktopId: desktopId))
    }

    /// With activity, picture and control already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, activity: DesktopActivityLoader, frame: DesktopFrameLease? = nil,
         control: DesktopControlFlow? = nil, review: UnknownResultReview? = nil, openPreview: ((String) -> Void)? = nil) {
        self.store = store
        self.navigation = navigation
        self.desktopId = activity.desktopId
        self.openPreview = openPreview
        _activity = StateObject(wrappedValue: activity)
        _frame = StateObject(wrappedValue: frame ?? DesktopFrameLease())
        _access = StateObject(wrappedValue: PhysicalDesktopAccess(runtime: store.runtime, desktopId: activity.desktopId))
        _control = StateObject(wrappedValue: control ?? DesktopControlFlow(runtime: store.runtime, desktopId: activity.desktopId))
        _review = State(initialValue: review)
    }

    var desktop: JSONValue? { store.desktops.first { $0["desktopId"]?.stringValue == desktopId } }
    var isPhysical: Bool { desktop?["kind"]?.stringValue == "physical" }
    var methods: DesktopControlMethods { DesktopControlMethods(capabilities: store.capabilities) }
    var connected: Bool { if case .connected = store.connection { return true }; return false }

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

    /// Why the header's stop is off, or nil when it is on.
    static func stopBlocked(_ info: DesktopControlInfo, methods: DesktopControlMethods, connected: Bool) -> String? {
        if !connected { return "Runtime 未连接" }
        if !methods.has("desktop.stop") { return DesktopControlMethods.missing("desktop.stop") }
        if info.state == "unknown" { return "先核对上一个动作的结果" }
        if !info.canStop { return info.state == "stopping" ? "停止已受理，正在等待静止" : "输入已停止" }
        return nil
    }

    static func takeoverBlocked(_ info: DesktopControlInfo, methods: DesktopControlMethods, connected: Bool) -> String? {
        if !connected { return "Runtime 未连接" }
        if !methods.has("desktop.takeover") { return DesktopControlMethods.missing("desktop.takeover") }
        if info.state == "unknown" { return "先核对上一个动作的结果" }
        if !info.canTakeover { return "你已在控制这个 Desktop" }
        return nil
    }

    /// The newest unknown action of the Run named by Desktop.control.
    /// Opens P17 for the Run Desktop.control names, read by its runId
    /// (not from the Store's truncated Run snapshot; Codex P2 on acd2591).
    func openReview(_ info: DesktopControlInfo) async {
        guard let runId = info.controllerRunId else { return }
        reviewProblem = nil
        do {
            guard let e = try await Self.unknownEntry(runtime: store.runtime, runId: runId) else {
                reviewProblem = RuntimeProblem(code: "not_found", title: "找不到结果未知的动作",
                                               advice: "运行 \(runId) 的事件里没有结果未知的动作；请在 Runs 中查看这个运行。")
                return
            }
            review = UnknownResultReview(runtime: store.runtime, desktopId: desktopId, entry: e)
            control.dialog = .unknown(requestId: e.requestId)
        } catch {
            reviewProblem = RuntimeProblem(error)
        }
    }

    /// The newest unknown action of one Run, from its own events.
    static func unknownEntry(runtime: RuntimePort, runId: String) async throws -> ActionEntry? {
        let reader = RunEventReader(runId: runId)
        _ = try await reader.pull(runtime)
        return await reader.actions(runtime).first { $0.presentation.level == .unknown }
    }

    /// Why closing is off, or nil (an unknown result is reviewed first;
    /// Codex P1 on acd2591).
    static func closeBlocked(_ info: DesktopControlInfo?, methods: DesktopControlMethods, connected: Bool) -> String? {
        if !connected { return "Runtime 未连接" }
        if !methods.has("desktop.closePlan") { return DesktopControlMethods.missing("desktop.closePlan") }
        if info?.state == "unknown" { return "先核对上一个动作的结果" }
        return nil
    }

    public var body: some View {
        let info = desktop.map { DesktopControlInfo.make(desktop: $0, activeRuns: store.activeRuns) }
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
                    Button { showPicture.toggle() } label: {
                        Label(showPicture ? "隐藏预览" : "显示预览", systemImage: showPicture ? "eye.slash" : "eye")
                    }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(desktop == nil)
                    .help("只隐藏画面；Desktop、控制者和运行不受影响")
                    // U7: a GUI diagnostic on this Desktop (P27 preselected);
                    // the Explorer page itself decides whether it can start.
                    Button { navigation.startExplorer(desktopId: desktopId) } label: { Label("GUI Explorer", systemImage: "wand.and.stars") }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(desktop == nil)
                        .help("在 GUI Explorer 中对这个 Desktop 发起一次诊断")
                    let stopWhy = info.flatMap { Self.stopBlocked($0, methods: methods, connected: connected) } ?? "Desktop 不在列表中"
                    Button { Task { await control.stop() } } label: { Label("停止输入", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger))
                        .disabled(info.flatMap { Self.stopBlocked($0, methods: methods, connected: connected) } != nil || info == nil
                                  || control.working != nil)
                        .help(info.flatMap { Self.stopBlocked($0, methods: methods, connected: connected) } == nil
                              ? "只停止这个 Desktop 的输入；先受理，静止后才显示已停止" : stopWhy)
                    Button { Task { await control.openClose() } } label: { Label("关闭", systemImage: "xmark.circle") }
                        .buttonStyle(ADButtonStyle(.secondary))
                        .disabled(Self.closeBlocked(info, methods: methods, connected: connected) != nil || desktop == nil
                                  || control.working != nil)
                        .help(Self.closeBlocked(info, methods: methods, connected: connected) ?? "先列出将结束与将保留的资源")
                }
            }
        }) {
            if let desktop, let info {
                HStack(alignment: .top, spacing: ADSpace.xl) {
                    VStack(alignment: .leading, spacing: ADSpace.l) {
                        if let banner = DesktopControlBannerText.make(info) {
                            ControlNotice(title: banner.title, detail: banner.detail, tone: banner.tone,
                                          actionTitle: banner.actionTitle, action: bannerAction(banner, info))
                        }
                        if let p = reviewProblem { ProblemView(p) }
                        DesktopControlAnswers(flow: control, takeoverAgain: takeoverBlocked(info) == nil ? {
                            Task { await control.takeover() }
                        } : nil)
                        ControllerBanner(control: info.presentation)
                        if showPicture {
                            DesktopFrameView(lease: frame, zoom: $zoom, height: 460, desktop: desktop)
                                .liveFrame(frame, displayId: DesktopFrameHub.displayId(of: desktop))
                        } else {
                            Text("预览已隐藏：画面不再捕获；Desktop、控制者和运行照常继续。")
                                .font(ADFont.note).foregroundStyle(ADColor.muted)
                                .frame(maxWidth: .infinity, minHeight: 80).adPanel()
                        }
                        if isPhysical {
                            PhysicalDesktopAccessView(access: access, gone: {
                                Task { await store.refreshDesktops() }
                                navigation.back()
                            })
                            .task(id: store.tick) { await access.load() }
                        }
                        recent
                    }
                    .frame(maxWidth: .infinity)
                    VStack(spacing: ADSpace.l) {
                        ConnectionPanel(desktop: desktop, control: info.presentation,
                                        takeover: takeoverBlocked(info) == nil ? { control.dialog = .takeover } : nil,
                                        info: info,
                                        handback: connected && methods.has("desktop.handback") && control.working == nil
                                            ? { Task { await control.handback() } } : nil,
                                        takeoverUnavailable: takeoverBlocked(info))
                        DesktopManagePanel(flow: control, desktop: desktop, methods: methods)
                    }
                    .frame(width: 294)
                }
            }
        }
        .overlay { dialogs(info) }
        .task(id: store.tick) {
            await activity.load(runs: store.runs)
            await control.refresh()
            control.settle(state: desktop.flatMap { DesktopControlInfo.effectiveState(desktop: $0, activeRuns: store.activeRuns) })
        }
        .task {
            control.changed = { [weak store] in
                await store?.refreshDesktops()
                await store?.refreshRuns()
            }
            if methods.has("desktop.closePlan"), control.closePlan == nil { await control.loadClosePlan() }
        }
        .onChange(of: control.closed) { _, closed in
            if closed != nil { navigation.back() }
        }
    }

    /// Ending applies only to the Run the dialog reviews: a newer unknown
    /// Run on the same Desktop is not cleared with old evidence (Codex P2
    /// on 11595f9).
    static func canEnd(info: DesktopControlInfo, review: ActionEntry, methods: DesktopControlMethods) -> Bool {
        info.state == "unknown" && info.controllerRunId == review.runId && methods.has("desktop.handback")
    }

    func takeoverBlocked(_ info: DesktopControlInfo) -> String? {
        if control.working != nil { return "正在处理上一个请求" }
        return Self.takeoverBlocked(info, methods: methods, connected: connected)
    }

    func bannerAction(_ banner: DesktopControlBannerText, _ info: DesktopControlInfo) -> (() -> Void)? {
        switch banner.action {
        case .handback:
            guard connected, methods.has("desktop.handback"), control.working == nil else { return nil }
            return { Task { await control.handback() } }
        case .review:
            guard info.controllerRunId != nil else { return nil }
            return { Task { await openReview(info) } }
        case nil:
            return nil
        }
    }

    @ViewBuilder func dialogs(_ info: DesktopControlInfo?) -> some View {
        if let info, let dialog = control.dialog {
            let name = desktop?["name"]?.stringValue ?? desktopId
            DesktopModal {
                switch dialog {
                case .takeover: TakeoverDialog(flow: control, name: name, info: info)
                case .close: CloseDesktopDialog(flow: control, name: name, info: info, methods: methods)
                case .unknown:
                    if let review {
                        UnknownResultDialog(review: review, flow: control, name: name,
                                            canEndHere: Self.canEnd(info: info, review: review.entry, methods: methods))
                    }
                }
            }
        }
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
                if DesktopFrameView.scopeNotice(desktop) != nil {
                    Text("整个显示器").font(ADFont.identifier).foregroundStyle(ADColor.ink)
                        .padding(.horizontal, ADSpace.s).padding(.vertical, 2)
                        .background(ADColor.panel.opacity(0.9), in: RoundedRectangle(cornerRadius: 4))
                        .padding(ADSpace.s)
                }
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
