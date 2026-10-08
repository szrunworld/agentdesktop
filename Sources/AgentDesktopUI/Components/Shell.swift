import SwiftUI

/// The six first-level entries of the one main window (docs/plan/06 §6.1).
/// The information architecture does not change with delivery batches;
/// entries whose pages come later say so instead of showing fake data.
public enum MainSection: String, CaseIterable, Identifiable, Sendable {
    case desktops, agents, runs, explorer, inbox, settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .desktops: return "Desktops"
        case .agents: return "Agents"
        case .runs: return "Runs"
        case .explorer: return "GUI Explorer"
        case .inbox: return "Inbox"
        case .settings: return "设置"
        }
    }

    public var symbol: String {
        switch self {
        case .desktops: return "display"
        case .agents: return "point.3.connected.trianglepath.dotted"
        case .runs: return "clock.arrow.circlepath"
        case .explorer: return "scope"
        case .inbox: return "tray"
        case .settings: return "gearshape"
        }
    }

    /// Second-level views (06 §6.1), shown as the page's sub-navigation.
    public var subviews: [String] {
        switch self {
        case .desktops: return ["总览", "Desktop 详情", "并排", "独立预览窗口"]
        case .agents: return ["总览", "接入应用", "Agent 详情与授权"]
        case .runs: return ["全部运行", "运行详情", "动作记录", "动作回执"]
        case .explorer: return ["运行历史"]
        case .inbox: return ["平台审批与问题"]
        case .settings: return ["通用", "权限", "AI 连接", "GUI 配置", "能力测试", "核实", "诊断与用量"]
        }
    }

    public var eyebrow: String {
        switch self {
        case .desktops: return "Agent Desktop"
        case .agents: return "Agents / Connections"
        case .runs: return "Activity / Runs"
        case .explorer: return "GUI Explorer"
        case .inbox: return "Inbox"
        case .settings: return "Agent Desktop"
        }
    }

    /// Delivery that fills the section (02 file); shown while it is pending.
    public var delivery: String {
        switch self {
        case .desktops: return "U2"
        case .agents: return "U4"
        case .runs: return "U5"
        case .explorer: return "U7"
        case .inbox: return "U9"
        case .settings: return "U6"
        }
    }
}

/// Left navigation, 206 pt wide.
public struct SideNav: View {
    @Binding var selection: MainSection
    let desktopNames: [(id: String, name: String, active: Bool)]
    let counts: [MainSection: Int]

    public init(selection: Binding<MainSection>, desktopNames: [(id: String, name: String, active: Bool)] = [],
                counts: [MainSection: Int] = [:]) {
        _selection = selection
        self.desktopNames = desktopNames
        self.counts = counts
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text("本机 / LOCAL").font(ADFont.eyebrow).kerning(1.2).foregroundStyle(ADColor.muted)
                .padding(.horizontal, ADSpace.m).padding(.bottom, ADSpace.s)
            ForEach(MainSection.allCases) { section in
                entry(section)
                if section == .desktops, selection == .desktops {
                    ForEach(desktopNames.prefix(6), id: \.id) { d in
                        HStack(spacing: ADSpace.s) {
                            Circle().fill(d.active ? StatusTone.running.foreground : StatusTone.idle.foreground.opacity(0.5))
                                .frame(width: 5, height: 5)
                            Text(d.name).font(ADFont.note).foregroundStyle(ADColor.ink).lineLimit(1)
                        }
                        .padding(.leading, 34).frame(height: 30)
                    }
                }
            }
            Spacer()
            Divider().overlay(ADColor.line)
            VStack(alignment: .leading, spacing: 2) {
                Text("AgentDesktop").font(ADFont.note).foregroundStyle(ADColor.muted)
                Text("本机桌面执行工具").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .padding(.horizontal, ADSpace.m).padding(.top, ADSpace.s)
        }
        .padding(.vertical, ADSpace.xl)
        .padding(.horizontal, ADSpace.m)
        .frame(width: ADLayout.sidebarWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(ADColor.canvas)
        .overlay(alignment: .trailing) { Rectangle().fill(ADColor.line).frame(width: 1) }
    }

    private func entry(_ section: MainSection) -> some View {
        let on = selection == section
        return Button { selection = section } label: {
            HStack(spacing: ADSpace.m) {
                Image(systemName: section.symbol).frame(width: 18).foregroundStyle(on ? ADColor.primary : ADColor.muted)
                Text(section.title).font(on ? ADFont.bodyStrong : ADFont.body).foregroundStyle(on ? ADColor.ink : ADColor.ink.opacity(0.85))
                Spacer()
                if let n = counts[section] {
                    Text("\(n)").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(ADColor.panel))
                }
            }
            .padding(.horizontal, ADSpace.m)
            .frame(height: 40)
            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(on ? ADColor.selected : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// Top bar, 54 pt: product name, Runtime state, global stop.
public struct TitleBar: View {
    let runtime: StatusText
    let platform: String
    let stopAll: (() -> Void)?

    public init(runtime: StatusText, platform: String = "macOS", stopAll: (() -> Void)?) {
        self.runtime = runtime
        self.platform = platform
        self.stopAll = stopAll
    }

    public var body: some View {
        HStack(spacing: ADSpace.l) {
            Image(systemName: "display").font(.system(size: 18)).foregroundStyle(ADColor.ink)
            Text("AgentDesktop").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Spacer()
            StateBadge(runtime)
            Text(platform).font(ADFont.note).foregroundStyle(ADColor.muted)
            Button {
                stopAll?()
            } label: {
                Label("停止所有输入", systemImage: "stop.fill")
            }
            .buttonStyle(ADButtonStyle(.danger))
            .disabled(stopAll == nil)
            .help(stopAll == nil ? "Runtime 未连接或此入口尚未接入" : "停止所有平台运行的输入")
        }
        .padding(.horizontal, ADSpace.xl)
        .frame(height: ADLayout.titleBarHeight)
        .background(ADColor.panel)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// Bottom bar, 28 pt: counts, sync time, sample mark.
public struct StatusBar: View {
    let left: String
    let right: String
    let isSample: Bool

    public init(left: String, right: String, isSample: Bool) {
        self.left = left
        self.right = right
        self.isSample = isSample
    }

    public var body: some View {
        HStack(spacing: ADSpace.m) {
            Image(systemName: "display").font(.system(size: 11)).foregroundStyle(ADColor.muted)
            Text(left).font(ADFont.note).foregroundStyle(ADColor.muted)
            Spacer()
            if isSample { SampleMark().scaleEffect(0.85) }
            Text(right).font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(.horizontal, ADSpace.l)
        .frame(height: ADLayout.statusBarHeight)
        .background(ADColor.canvas)
        .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// A page body in one of the four states, or its content. Header and
/// padding (32) are shared; the content area scrolls on its own.
public struct PageContainer<Content: View, Header: View>: View {
    let state: PageState
    let emptyTitle: String
    let emptyDetail: String
    let emptyAction: (String, () -> Void)?
    let syncedAt: Date?
    let retry: (() -> Void)?
    let header: Header
    let content: Content

    public init(state: PageState, emptyTitle: String = "这里还没有内容", emptyDetail: String = "",
                emptyAction: (String, () -> Void)? = nil, syncedAt: Date? = nil, retry: (() -> Void)? = nil,
                @ViewBuilder header: () -> Header, @ViewBuilder content: () -> Content) {
        self.state = state
        self.emptyTitle = emptyTitle
        self.emptyDetail = emptyDetail
        self.emptyAction = emptyAction
        self.syncedAt = syncedAt
        self.retry = retry
        self.header = header()
        self.content = content()
    }

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: ADSpace.xl) {
                header
                switch state {
                case .loading:
                    VStack(spacing: ADSpace.m) {
                        ProgressView().controlSize(.regular)
                        Text("正在读取 Runtime 状态…").font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 240)
                    .accessibilityLabel("正在加载")
                case .empty:
                    EmptyState(title: emptyTitle, detail: emptyDetail, action: emptyAction).adPanel()
                case .loaded:
                    content
                case .failed(let p):
                    ProblemView(title: p.title, advice: p.advice, code: p.code,
                                extra: syncedAt.map { ["显示的是 \(Self.time($0)) 同步的数据"] } ?? [], retry: retry)
                    if syncedAt != nil { content.opacity(0.6) }
                case .disconnected(let p):
                    DisconnectedView(problem: p, syncedAt: syncedAt, retry: retry)
                    if syncedAt != nil { content.opacity(0.5).disabled(true) }
                }
            }
            .padding(ADLayout.contentPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(ADColor.canvas)
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.timeZone = TimeText.shanghai
        f.dateFormat = "HH:mm:ss"
        return f.string(from: d)
    }
}

extension PageContainer where Header == EmptyView {
    public init(state: PageState, emptyTitle: String = "这里还没有内容", emptyDetail: String = "",
                emptyAction: (String, () -> Void)? = nil, syncedAt: Date? = nil, retry: (() -> Void)? = nil,
                @ViewBuilder content: () -> Content) {
        self.init(state: state, emptyTitle: emptyTitle, emptyDetail: emptyDetail, emptyAction: emptyAction,
                  syncedAt: syncedAt, retry: retry, header: { EmptyView() }, content: content)
    }
}

/// Runtime unreachable: say so, keep last data read-only, offer re-check.
/// Never replaces the data with samples.
public struct DisconnectedView: View {
    let problem: RuntimeProblem
    let syncedAt: Date?
    let retry: (() -> Void)?

    public init(problem: RuntimeProblem, syncedAt: Date?, retry: (() -> Void)?) {
        self.problem = problem
        self.syncedAt = syncedAt
        self.retry = retry
    }

    public var body: some View {
        VStack(spacing: ADSpace.m) {
            Image(systemName: "bolt.horizontal.circle").font(.system(size: 28)).foregroundStyle(StatusTone.danger.foreground)
            StateBadge("Runtime 未连接", tone: .danger)
            Text(problem.title).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text(problem.advice).font(ADFont.note).foregroundStyle(ADColor.muted).multilineTextAlignment(.center)
            Text(syncedAt.map { "下方为 \(PageContainer<EmptyView, EmptyView>.time($0)) 的缓存，只读，不能修改" } ?? "没有可显示的缓存数据")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
            Text(problem.code).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            if let retry { Button("重新检测", action: retry).buttonStyle(ADButtonStyle(.primary)) }
        }
        .padding(ADSpace.xxl)
        .frame(maxWidth: .infinity)
        .adPanel()
    }
}

/// Inbox before U9: the place exists, the feature does not (06 §6.1).
public struct InboxNotEnabledView: View {
    public init() {}
    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xl) {
            PageHeader(eyebrow: "Inbox", title: "Inbox", subtitle: "平台审批与问题。")
            VStack(alignment: .leading, spacing: ADSpace.m) {
                StateBadge("尚未启用", tone: .idle)
                Text("尚未启用：平台审批将在后续版本提供").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                Text("启用后，外部 Agent 请求的平台动作审批会集中出现在这里。业务审批（是否发消息、联系谁）仍由各自的应用处理。现在这里没有任何待处理项，也不会显示示例。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(ADSpace.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .adPanel()
        }
        .padding(ADLayout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ADColor.canvas)
    }
}

/// The main window's frame: title bar, side navigation, page, status bar.
public struct MainFrame<Page: View>: View {
    @Binding var selection: MainSection
    let runtime: StatusText
    let stopAll: (() -> Void)?
    let desktopNames: [(id: String, name: String, active: Bool)]
    let counts: [MainSection: Int]
    let statusLeft: String
    let statusRight: String
    let isSample: Bool
    let page: Page

    public init(selection: Binding<MainSection>, runtime: StatusText, stopAll: (() -> Void)?,
                desktopNames: [(id: String, name: String, active: Bool)] = [], counts: [MainSection: Int] = [:],
                statusLeft: String, statusRight: String, isSample: Bool, @ViewBuilder page: () -> Page) {
        _selection = selection
        self.runtime = runtime
        self.stopAll = stopAll
        self.desktopNames = desktopNames
        self.counts = counts
        self.statusLeft = statusLeft
        self.statusRight = statusRight
        self.isSample = isSample
        self.page = page()
    }

    public var body: some View {
        VStack(spacing: 0) {
            TitleBar(runtime: runtime, stopAll: stopAll)
            HStack(spacing: 0) {
                SideNav(selection: $selection, desktopNames: desktopNames, counts: counts)
                page.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            StatusBar(left: statusLeft, right: statusRight, isSample: isSample)
        }
        .background(ADColor.canvas)
        .environment(\.colorScheme, .light)
    }
}
