import AgentDesktopProtocol
import SwiftUI

/// The one main window's content (docs/plan/06 §6.1): frame, six entries,
/// and per entry its page or a clear "not yet" state. Desktops and Runs
/// read the Runtime through the Store; Settings shows what the host gives
/// it for each second-level entry; Inbox is not enabled before U9; Agents
/// and GUI Explorer wait for U4 / U7. Nothing here keeps execution state.
public struct MainWindowView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    /// Settings content the host supplies (the AI/GUI pages until U6);
    /// nil for an entry shows that it is pending.
    let settings: (SettingsPage) -> AnyView?
    /// Preview windows (P08), when the host can open them.
    let previews: PreviewWindowRegistry?
    @State private var confirmStop = false

    public init(store: ShellStore, navigation: ShellNavigation, previews: PreviewWindowRegistry? = nil,
                settings: @escaping (SettingsPage) -> AnyView? = { _ in nil }) {
        self.store = store
        self.navigation = navigation
        self.previews = previews
        self.settings = settings
    }

    /// Convenience for previews and renders: a fresh navigation.
    public init(store: ShellStore, initial: MainSection = .desktops) {
        self.init(store: store, navigation: ShellNavigation(section: initial))
    }

    public var body: some View {
        MainFrame(selection: Binding(get: { navigation.section }, set: { navigation.open($0) }),
                  runtime: runtimeText, stopAll: connected ? { confirmStop = true } : nil,
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]?.stringValue ?? "", name: d["name"]?.stringValue ?? "—",
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: connected ? [.desktops: store.desktops.count, .runs: store.activeRuns.count] : [:],
                  statusLeft: statusLeft, statusRight: statusRight, isSample: store.isSample,
                  inputStopped: store.inputAdmission == "stopped",
                  enableInput: connected ? { Task { await store.enableInput() } } : nil,
                  openDesktop: { navigation.showDesktop($0) }) {
            page(navigation.section)
        }
        .confirmationDialog("停止所有输入？", isPresented: $confirmStop) {
            Button("停止所有输入", role: .destructive) { Task { await store.stopAllInput() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("所有平台运行立即不再接受新输入，并进入停止流程；已经开始的动作要等执行端确认静止。外部 Agent 应用本身不会被结束。")
        }
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    var runtimeText: StatusText {
        switch store.connection {
        case .connecting: return StatusText("正在连接本机服务", .idle)
        case .connected:
            switch store.inputAdmission {
            case "stopped": return StatusText("输入已停止", .attention)
            case "stopping": return StatusText("正在停止输入", .attention)
            default: return StatusText("本机服务就绪", .running)
            }
        case .disconnected: return StatusText("Runtime 未连接", .danger)
        }
    }

    var statusLeft: String {
        guard connected else { return "Runtime 未连接" }
        return "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中"
    }

    /// The bar names the data's freshness, not how it travels.
    var statusRight: String {
        guard let t = store.runsSyncedAt ?? store.desktopsSyncedAt else { return "尚未同步" }
        return "同步于 \(PageContainer<EmptyView, EmptyView>.time(t))"
    }

    var connectionState: PageState {
        switch store.connection {
        case .connecting: return .loading
        case .connected: return .loaded
        case .disconnected(let p): return .disconnected(p)
        }
    }

    var sectionContext: SectionContext {
        SectionContext(store: store, navigation: navigation, connectionState: connectionState,
                       retry: { [store] in Task { await store.start() } })
    }

    @ViewBuilder
    func page(_ section: MainSection) -> some View {
        switch section {
        case .desktops: DesktopsPage(store: store, navigation: navigation, openPreview: previews.map { r in { r.show($0) } })
        case .runs: RunsPage(store: store, navigation: navigation)
        // Each entry below lives in its own file under Pages/Sections, so
        // the UI lanes (docs/plan/11-parallel-lanes.md) never edit this one.
        case .inbox: InboxSection(context: sectionContext)
        case .settings: SettingsSection(context: sectionContext, content: settings)
        case .agents: AgentsSection(context: sectionContext)
        case .explorer: ExplorerSection(context: sectionContext)
        }
    }
}

/// A first-level entry whose pages come with a later delivery.
public struct PendingSection: View {
    let delivery: String
    public init(delivery: String) { self.delivery = delivery }
    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            StateBadge("页面待接入（\(delivery)）", tone: .idle)
            Text("这个入口的页面在 \(delivery) 交付。导航位置已固定，内容只会来自 Runtime。")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adPanel()
    }
}
