import AgentDesktopContracts
import SwiftUI

/// The main window's content: frame, navigation and one page container per
/// first-level entry, fed by a ShellStore. Pages arrive with U2–U9; until
/// then each entry shows the Runtime state it depends on and which delivery
/// fills it, never sample content presented as real.
public struct MainWindowView: View {
    @ObservedObject var store: ShellStore
    @State private var selection: MainSection
    let stopAll: (() -> Void)?

    public init(store: ShellStore, initial: MainSection = .desktops, stopAll: (() -> Void)? = nil) {
        self.store = store
        _selection = State(initialValue: initial)
        self.stopAll = stopAll
    }

    public var body: some View {
        MainFrame(selection: $selection, runtime: runtimeText, stopAll: connected ? stopAll : nil,
                  desktopNames: store.desktops.map { d in
                      (id: d["desktopId"]?.stringValue ?? "", name: d["name"]?.stringValue ?? "—",
                       active: store.activeRuns.contains { $0["desktopId"] == d["desktopId"] })
                  },
                  counts: connected ? [.desktops: store.desktops.count] : [:],
                  statusLeft: statusLeft, statusRight: statusRight, isSample: store.isSample) {
            page(selection)
        }
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    var runtimeText: StatusText {
        switch store.connection {
        case .connecting: return StatusText("正在连接本机服务", .idle)
        case .connected: return store.inputAdmission == "stopped" ? StatusText("输入已停止", .attention)
            : StatusText("本机服务就绪", .running)
        case .disconnected: return StatusText("Runtime 未连接", .danger)
        }
    }

    var statusLeft: String {
        guard connected else { return "Runtime 未连接" }
        return "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中"
    }

    var statusRight: String {
        let mode: String
        switch store.runUpdates {
        case .subscription: mode = "运行状态：事件订阅"
        case .polling: mode = "运行状态：轮询"
        case .none: mode = "运行状态：未更新"
        }
        return mode
    }

    /// Connection-level state for entries that read no list yet.
    var connectionState: PageState {
        switch store.connection {
        case .connecting: return .loading
        case .connected: return .loaded
        case .disconnected(let p): return .disconnected(p)
        }
    }

    @ViewBuilder
    func page(_ section: MainSection) -> some View {
        switch section {
        case .inbox:
            InboxNotEnabledView()
        case .desktops:
            PageContainer(state: store.desktopsState, emptyTitle: "还没有 Desktop",
                          emptyDetail: "Desktop 是 Agent 的独立桌面；创建入口随 Desktops 页面（U2）提供。",
                          syncedAt: store.desktopsSyncedAt, retry: { Task { await store.refreshDesktops() } },
                          header: { header(section) }) { pending(section) }
        case .runs:
            PageContainer(state: store.runsState, emptyTitle: "还没有运行",
                          emptyDetail: "外部 Agent 或 GUI Explorer 发起的执行会出现在这里。",
                          syncedAt: store.runsSyncedAt, retry: { Task { await store.refreshRuns() } },
                          header: { header(section) }) { pending(section) }
        default:
            PageContainer(state: connectionState, retry: { Task { await store.start() } },
                          header: { header(section) }) { pending(section) }
        }
    }

    func header(_ section: MainSection) -> some View {
        PageHeader(eyebrow: section.eyebrow, title: section.title, subtitle: section.subviews.joined(separator: " · "))
    }

    func pending(_ section: MainSection) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            StateBadge("页面待接入（\(section.delivery)）", tone: .idle)
            Text("这个入口的页面在 \(section.delivery) 交付。导航位置已固定，内容只会来自 Runtime。")
                .font(ADFont.note).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.xl)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adPanel()
    }
}
