import AgentDesktopProtocol
import SwiftUI

/// What the user picks when quitting (P32).
public enum QuitChoice: String, CaseIterable, Sendable {
    /// Keep everything; quit is called off.
    case cancel
    /// Close the main window; the app stays in the Dock and the menu bar.
    case hideWindow
    /// Close every window and leave the Dock; the menu bar entry stays and
    /// every Desktop and Run goes on.
    case keepInBackground
    /// Stop all input, wait until every Run is quiet, then quit.
    case stopAndQuit
}

/// Quitting after the Runtime says everything is quiet (UC51). It asks
/// runtime.stopAll, then reads run.list {active:true} and each Run the stop
/// named until none is active and every one is `ended` with quiescence
/// `confirmed`. An accepted stop alone is never enough. It never forces:
/// while something is still stopping the user can only wait or call the
/// quit off (input stays stopped).
@MainActor
public final class QuitFlow: ObservableObject {
    public enum Phase: Equatable, Sendable {
        case choosing
        case stopping
        /// Every Run is quiet: the host may terminate.
        case quiet
        case failed(RuntimeProblem)
        case cancelled
    }

    @Published public private(set) var phase: Phase = .choosing
    /// Runs still not quiet, as last read (Run objects).
    @Published public private(set) var remaining: [JSONValue] = []
    /// Runs the stop named, for the record.
    @Published public private(set) var stoppedIds: [String] = []
    @Published public private(set) var checks = 0
    /// Active Runs when the dialog opened; nil until the Runtime answers
    /// (or when it could not), so the dialog never waits on it.
    @Published public private(set) var activeCount: Int?

    private let runtime: RuntimePort
    private let clock: PollClock
    private let pollMs: Int
    private var task: Task<Void, Never>?

    public init(runtime: RuntimePort, clock: PollClock = SystemPollClock(), pollMs: Int = 500) {
        self.runtime = runtime
        self.clock = clock
        self.pollMs = pollMs
    }

    /// Active Runs right now (for the dialog's first line).
    public func activeNow() async -> [JSONValue] {
        ((try? await runtime.call("run.list", .obj([("active", .bool(true)), ("limit", .int(200))])))?["runs"]?.arrayValue) ?? []
    }

    /// Reads the count for the dialog's first line; a failure leaves it
    /// unknown rather than zero.
    public func countActive() async {
        let r = try? await runtime.call("run.list", .obj([("active", .bool(true)), ("limit", .int(200))]))
        activeCount = r?["runs"]?.arrayValue?.count
    }

    public func stopAndWait() {
        guard phase == .choosing || { if case .failed = phase { return true }; return false }() else { return }
        phase = .stopping
        task = Task { [weak self] in await self?.run() }
    }

    /// Call the quit off; input stays as it is (stopped if it was).
    public func cancel() {
        task?.cancel()
        task = nil
        phase = .cancelled
    }

    func run() async {
        do {
            let r = try await runtime.call("runtime.stopAll", .obj([("scope", .string("all_platform_runs"))]))
            stoppedIds = (r["runs"]?.arrayValue ?? []).compactMap { $0["runId"]?.stringValue }
            while !Task.isCancelled {
                checks += 1
                let active = try await runtime.call("run.list", .obj([("active", .bool(true)), ("limit", .int(200))]))["runs"]?.arrayValue ?? []
                var notQuiet = active
                for id in stoppedIds where !active.contains(where: { $0["runId"]?.stringValue == id }) {
                    let run = try await runtime.call("run.show", .obj([("runId", .string(id))]))
                    if !Self.isQuiet(run) { notQuiet.append(run) }
                }
                remaining = notQuiet
                if notQuiet.isEmpty {
                    phase = .quiet
                    return
                }
                try await clock.pause(milliseconds: pollMs)
            }
        } catch is CancellationError {
            return
        } catch {
            if !Task.isCancelled { phase = .failed(RuntimeProblem(error)) }
        }
    }

    /// Ended and confirmed quiet: the only state that allows quitting.
    public static func isQuiet(_ run: JSONValue) -> Bool {
        run["phase"]?.stringValue == "ended" && run["quiescence"]?.stringValue == "confirmed"
    }
}

/// P32: the quit dialog.
public struct QuitDialogView: View {
    @ObservedObject var flow: QuitFlow
    let choose: (QuitChoice) -> Void

    public init(flow: QuitFlow, choose: @escaping (QuitChoice) -> Void) {
        self.flow = flow
        self.choose = choose
    }

    public static func activeLine(_ count: Int?) -> String {
        switch count {
        case nil: return "正在读取进行中的运行。关闭界面不会结束运行；只有「停止输入并退出」会先停止全部输入，等它们静止后再退出。"
        case 0?: return "现在没有进行中的运行。"
        case let n?: return "现在有 \(n) 个运行进行中。关闭界面不会结束它们；只有「停止输入并退出」会先停止全部输入，等它们静止后再退出。"
        }
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            Text("退出 Agent Desktop？").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            switch flow.phase {
            case .choosing, .cancelled:
                Text(Self.activeLine(flow.activeCount))
                    .font(ADFont.body).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("· 隐藏主窗口：只关窗口，Dock 和菜单栏入口保留").font(ADFont.note)
                    Text("· 保留后台：关闭所有窗口并离开 Dock，只留菜单栏；Desktop 与运行继续").font(ADFont.note)
                    Text("· 停止输入并退出：调用全局停止，确认所有运行静止后才退出").font(ADFont.note)
                }
                .foregroundStyle(ADColor.muted)
                HStack {
                    Button("取消") { choose(.cancel) }.buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                    Spacer()
                    Button("隐藏主窗口") { choose(.hideWindow) }.buttonStyle(ADButtonStyle(.secondary))
                    Button("保留后台") { choose(.keepInBackground) }.buttonStyle(ADButtonStyle(.secondary))
                    Button("停止输入并退出") { choose(.stopAndQuit) }.buttonStyle(ADButtonStyle(.danger))
                }
            case .stopping:
                HStack(spacing: ADSpace.m) {
                    ProgressView().controlSize(.small)
                    Text("已请求停止所有输入，正在等待运行静止（第 \(flow.checks) 次核对）").font(ADFont.body).foregroundStyle(ADColor.ink)
                }
                ForEach(flow.remaining.indices, id: \.self) { i in
                    let r = flow.remaining[i]
                    HStack {
                        Text(r["runId"]?.stringValue ?? "—").font(ADFont.code).foregroundStyle(ADColor.ink)
                        StateBadge(RunStatusPresentation.make(run: r))
                        Text("quiescence \(r["quiescence"]?.stringValue ?? "—")").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
                Text("停止受理不等于已经停止；所有运行静止后才会退出，不会强制结束。").font(ADFont.note).foregroundStyle(ADColor.muted)
                HStack {
                    Spacer()
                    Button("不退出了") { choose(.cancel) }.buttonStyle(ADButtonStyle(.secondary))
                }
            case .quiet:
                StateBadge("全部运行已静止，正在退出", tone: .idle)
            case .failed(let p):
                ProblemView(p)
                HStack {
                    Button("不退出了") { choose(.cancel) }.buttonStyle(ADButtonStyle(.secondary))
                    Spacer()
                    Button("再试一次") { flow.stopAndWait() }.buttonStyle(ADButtonStyle(.primary))
                }
            }
        }
        .padding(ADSpace.xl)
        .frame(width: 600)
        .background(ADColor.panel)
        .environment(\.colorScheme, .light)
    }
}

/// What the menu bar panel can ask the host to do.
public struct MenuBarActions {
    public var openMain: () -> Void
    public var openPreview: (String) -> Void
    public var openSettings: () -> Void
    public var quit: () -> Void

    public init(openMain: @escaping () -> Void, openPreview: @escaping (String) -> Void,
                openSettings: @escaping () -> Void, quit: @escaping () -> Void) {
        self.openMain = openMain
        self.openPreview = openPreview
        self.openSettings = openSettings
        self.quit = quit
    }
}

/// P31: the menu bar panel. A quick entry, not task management: status,
/// the main window, one Desktop's preview, the explicit global stop (and
/// re-enabling input), settings, quit.
public struct MenuBarPanelView: View {
    @ObservedObject var store: ShellStore
    let actions: MenuBarActions
    @State private var confirmingStop = false

    public init(store: ShellStore, actions: MenuBarActions) {
        self.store = store
        self.actions = actions
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack {
                Image(systemName: "display.2").foregroundStyle(ADColor.ink)
                Text("Agent Desktop").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                StateBadge(Self.status(store))
            }
            Text(Self.summary(store)).font(ADFont.note).foregroundStyle(ADColor.muted)
            Divider().overlay(ADColor.line)
            Button { actions.openMain() } label: { Label("打开主界面", systemImage: "macwindow").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(ADButtonStyle(.quiet))
            if !store.desktops.isEmpty {
                Text("打开 Desktop 预览").font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
                ForEach(store.desktops.prefix(8).indices, id: \.self) { i in
                    let d = store.desktops[i]
                    let id = d["desktopId"]?.stringValue ?? ""
                    Button { actions.openPreview(id) } label: {
                        HStack {
                            Image(systemName: "eye")
                            Text(d["name"]?.stringValue ?? id).lineLimit(1)
                            Spacer()
                            StateBadge(DesktopControlPresentation.make(desktop: d, activeRuns: store.activeRuns).status)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(ADButtonStyle(.quiet))
                    .accessibilityLabel("预览 \(d["name"]?.stringValue ?? id)")
                }
            }
            Divider().overlay(ADColor.line)
            if store.inputAdmission == "stopped" {
                Button { Task { await store.enableInput() } } label: { Label("恢复输入", systemImage: "play.fill").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(!connected)
                Text("已停止的运行不会恢复，只是重新接受新的输入。").font(ADFont.note).foregroundStyle(ADColor.muted)
            } else if confirmingStop {
                Text("所有平台运行立即不再接受新输入，并进入停止流程。").font(ADFont.note).foregroundStyle(ADColor.ink)
                HStack {
                    Button("取消") { confirmingStop = false }.buttonStyle(ADButtonStyle(.secondary))
                    Button("确认停止所有输入") {
                        confirmingStop = false
                        Task { await store.stopAllInput() }
                    }
                    .buttonStyle(ADButtonStyle(.danger))
                }
            } else {
                Button { confirmingStop = true } label: { Label("停止所有输入", systemImage: "stop.fill").frame(maxWidth: .infinity, alignment: .leading) }
                    .buttonStyle(ADButtonStyle(.danger)).disabled(!connected)
            }
            if let p = store.stopProblem { ProblemView(p) }
            Divider().overlay(ADColor.line)
            Button { actions.openSettings() } label: { Label("设置", systemImage: "gearshape").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(ADButtonStyle(.quiet))
            Button { actions.quit() } label: { Label("退出 Agent Desktop…", systemImage: "power").frame(maxWidth: .infinity, alignment: .leading) }
                .buttonStyle(ADButtonStyle(.quiet))
        }
        .padding(ADSpace.l)
        .frame(width: 340)
        .background(ADColor.panel)
        .environment(\.colorScheme, .light)
    }

    public static func status(_ store: ShellStore) -> StatusText {
        switch store.connection {
        case .connecting: return StatusText("正在连接", .idle)
        case .disconnected: return StatusText("Runtime 未连接", .danger)
        case .connected:
            switch store.inputAdmission {
            case "stopped": return StatusText("输入已停止", .attention)
            case "stopping": return StatusText("正在停止输入", .attention)
            default: return store.activeRuns.isEmpty ? StatusText("就绪", .idle) : StatusText("运行中", .running)
            }
        }
    }

    public static func summary(_ store: ShellStore) -> String {
        guard case .connected = store.connection else { return "无法读取 Runtime 状态" }
        let stopping = store.activeRuns.filter { $0["phase"]?.stringValue == "stopping" }.count
        var s = "\(store.desktops.count) 个 Desktop · \(store.activeRuns.count) 个运行进行中"
        if stopping > 0 { s += "（\(stopping) 个停止中）" }
        return s
    }
}
