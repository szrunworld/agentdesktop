import AppKit
import SwiftUI

/// The product's main window: a sidebar with the four entries of the
/// roadmap's interface table (任务主页, Agent, 待处理, 设置). Closing it
/// keeps the host, its screens and its tasks running; the menu bar and the
/// Dock reopen it.
@MainActor
final class MainWindowController: NSWindowController, NSWindowDelegate {
    let model: AppModel

    init(model: AppModel) {
        self.model = model
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = HostRole.productName
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 820, height: 520)
        window.setFrameAutosaveName("MainWindow")
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: MainView().environmentObject(model))
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        model.start()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the window is not quitting: tasks and the host go on.
        model.stop()
    }
}

enum SidebarSection: String, CaseIterable, Identifiable {
    case tasks, agents, inbox, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tasks: return "任务主页"
        case .agents: return "Agent"
        case .inbox: return "待处理"
        case .settings: return "设置"
        }
    }
    var symbol: String {
        switch self {
        case .tasks: return "list.bullet.rectangle"
        case .agents: return "cpu"
        case .inbox: return "tray"
        case .settings: return "gearshape"
        }
    }
}

struct MainView: View {
    @EnvironmentObject var model: AppModel
    @State private var section: SidebarSection = .tasks

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $section) { s in
                Label(s.title, systemImage: s.symbol).tag(s)
                    .badge(s == .inbox ? model.pending.count : 0)
            }
            .navigationSplitViewColumnWidth(min: 160, ideal: 180)
        } detail: {
            VStack(spacing: 0) {
                ServiceBanner()
                Divider()
                switch section {
                case .tasks: TasksView()
                case .agents: AgentsView()
                case .inbox: InboxView()
                case .settings: SettingsView()
                }
            }
        }
        .frame(minWidth: 820, minHeight: 520)
    }
}

/// The service's state, and what to do about it when it is not ready.
struct ServiceBanner: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        switch model.serviceState {
        case .ready(let s):
            HStack {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("\(s.host.product) · runtime \(s.task.runtimeVersion) · 契约 \(s.task.protocolVersion) · 控制协议 \(s.host.controlProtocolVersion)")
                if model.mode == .sample { Text("样例数据").font(.caption).padding(4).background(.yellow.opacity(0.3)).cornerRadius(4) }
                Spacer()
                if let at = model.lastRefresh { Text(at.formatted(date: .omitted, time: .standard)).font(.caption).foregroundStyle(.secondary) }
            }.padding(8)
        case .checking:
            HStack { ProgressView().controlSize(.small); Text("正在连接服务…"); Spacer() }.padding(8)
        default:
            ServiceProblemView(state: model.serviceState)
        }
    }
}

/// Each exceptional state with its explanation and next step (roadmap F04/F10).
struct ServiceProblemView: View {
    @EnvironmentObject var model: AppModel
    let state: ServiceState

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.title2)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(explanation).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("重新检测") { Task { await model.refresh() } }
                    if case .runtimeMissing = state {
                        Button("用样例数据查看界面") { model.setMode(.sample) }
                    }
                    if case .capabilityMissing = state {
                        Button("用样例数据查看界面") { model.setMode(.sample) }
                    }
                    if case .offline = state {
                        Button("打开产品宿主") { NSWorkspace.shared.open(Bundle.main.bundleURL) }
                    }
                }
            }
            Spacer()
        }
        .padding(10)
        .background(.orange.opacity(0.08))
    }

    var title: String {
        switch state {
        case .runtimeMissing: return "未安装 Runtime"
        case .offline: return "服务离线"
        case .connectionFailed: return "连接失败"
        case .versionMismatch: return "版本不兼容"
        case .capabilityMissing: return "服务缺少这项能力"
        case .error: return "服务返回错误"
        case .checking, .ready: return ""
        }
    }

    var explanation: String {
        switch state {
        case .runtimeMissing(let m):
            return "\(m)。任务功能要等引擎发布不带业务 skills 的 task runtime 后随产品包提供（路线 C01）。"
        case .offline(let m):
            return "没有宿主在产品 endpoint 上监听，或命令行报告应用未运行：\(m)"
        case .connectionFailed(let m):
            return "命令行没有给出可读的回答：\(m)"
        case .versionMismatch(let f, let s):
            return "服务的契约版本是 \(f)，本产品支持 \(s)。请升级产品或等待 Runtime 更新。"
        case .capabilityMissing(let m):
            return "当前 Runtime 还没有任务视图接口（路线 C03）：\(m)"
        case .error(let m):
            return m
        case .checking, .ready:
            return ""
        }
    }
}
