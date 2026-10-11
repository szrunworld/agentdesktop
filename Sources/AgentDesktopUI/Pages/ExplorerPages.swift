import AgentDesktopProtocol
import SwiftUI

// Lane UI-E (U7 GUI Explorer, P27–P29; docs/plan/11-parallel-lanes.md).
// The first-level GUI Explorer: unit Runs across Desktops (history), a
// new diagnostic (P27), and one Run's detail while running (P28) and once
// ended (P29). It is a view of the same RunStore the Runs entry shows, not
// a second execution system: it reads run.list / run.show / run.events /
// request.show, stops with run.cancel, and starts only through the
// in-process Durable entry the host supplies (ExplorerDurableStart).

// MARK: Run detail loader

/// Reads one unit Run: run.show, its events from the last `next`, and each
/// action's request record (request.show) once, for the §6.4 level.
@MainActor
public final class ExplorerRunLoader: ObservableObject {
    public let runId: String
    @Published public private(set) var run: JSONValue?
    @Published public private(set) var events: [JSONValue] = []
    @Published public private(set) var timeline = ExplorerTimeline(events: [])
    /// request.show answers by requestId.
    @Published public private(set) var records: [String: JSONValue] = [:]
    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var syncedAt: Date?
    @Published public private(set) var stopProblem: RuntimeProblem?
    @Published public private(set) var stopRequested = false
    private let runtime: RuntimePort
    private var next = 0

    public init(runtime: RuntimePort, runId: String) {
        self.runtime = runtime
        self.runId = runId
    }

    public func load() async {
        do {
            let r = try await runtime.call("run.show", .obj([("runId", .string(runId))]))
            var grew = false
            while true {
                let page = try await runtime.call("run.events", .obj([("runId", .string(runId)), ("after", .int(next)),
                                                                      ("limit", .int(500))]))
                let batch = page["events"]?.arrayValue ?? []
                events.append(contentsOf: batch)
                next = page["next"]?.intValue ?? next
                grew = grew || !batch.isEmpty
                if batch.count < 500 { break }
            }
            run = r
            if grew { timeline = ExplorerTimeline(events: events) }
            for a in timeline.allActions where records[a.requestId] == nil && a.requestId != "—" {
                if let rec = try? await runtime.call("request.show", .obj([("requestId", .string(a.requestId))])) {
                    records[a.requestId] = rec
                }
            }
            syncedAt = Date()
            state = .loaded
        } catch {
            state = ShellStore.failure(error)
        }
    }

    /// run.cancel: the Run goes to stopping; ended only once the execution
    /// side confirms quiescence. Other Desktops are not touched.
    public func stop() async {
        stopProblem = nil
        do {
            _ = try await runtime.call("run.cancel", .obj([("runId", .string(runId))]))
            stopRequested = true
        } catch {
            stopProblem = RuntimeProblem(error)
        }
        await load()
    }

    /// An action's result: the receipt level when request.show answered,
    /// else what `deliveryState` says.
    public func status(of a: ExplorerAction) -> StatusText {
        guard let rec = records[a.requestId] else { return a.status }
        let p = ActionResultPresentation.make(record: rec)
        // A request the ledger still shows as accepted adds nothing to the
        // event's own delivery state.
        return p.level == .accepted ? a.status : ExplorerText.receipt(p)
    }
}

// MARK: Entry page

/// GUI Explorer: history, or one Run's detail; P27 over either.
public struct ExplorerPage: View {
    public enum Route: Equatable { case history, run(String) }

    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    let connectionState: PageState
    let retry: () -> Void
    let starter: ExplorerDurableStart?
    @State var route: Route
    @State var composing: Bool
    @State var draft: ExplorerDraft
    @State private var starting = false
    @State private var startProblem: RuntimeProblem?
    /// A loader handed in already loaded (renders, tests).
    let presetLoader: ExplorerRunLoader?

    public init(store: ShellStore, navigation: ShellNavigation, connectionState: PageState, retry: @escaping () -> Void,
                starter: ExplorerDurableStart?, route: Route = .history, composing: Bool = false,
                draft: ExplorerDraft = ExplorerDraft(), loader: ExplorerRunLoader? = nil) {
        self.store = store
        self.navigation = navigation
        self.connectionState = connectionState
        self.retry = retry
        self.starter = starter
        _route = State(initialValue: route)
        _composing = State(initialValue: composing)
        _draft = State(initialValue: draft)
        presetLoader = loader
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    public var body: some View {
        ZStack {
            switch route {
            case .history:
                ExplorerHistoryView(store: store, connectionState: connectionState, retry: retry,
                                    canStart: starter != nil && connected,
                                    startWired: starter != nil,
                                    compose: { openCompose(desktopId: nil) },
                                    open: { route = .run($0) })
            case .run(let id):
                ExplorerRunDetailView(store: store, navigation: navigation,
                                      loader: presetLoader?.runId == id ? presetLoader! : ExplorerRunLoader(runtime: store.runtime, runId: id),
                                      back: { route = .history })
                    .id(id)
            }
            if composing {
                Color.black.opacity(0.28).ignoresSafeArea().accessibilityHidden(true)
                ExplorerStartSheet(store: store, draft: $draft, startWired: starter != nil, starting: starting,
                                   problem: startProblem,
                                   cancel: { composing = false; startProblem = nil },
                                   start: starter == nil || !connected ? nil : { Task { await start() } })
            }
        }
    }

    func openCompose(desktopId: String?) {
        let free = ExplorerDraft.eligible(desktops: store.desktops, activeRuns: store.activeRuns).first { $0.blocked == nil }
        draft = ExplorerDraft(desktopId: desktopId ?? free?.desktop["desktopId"]?.stringValue)
        startProblem = nil
        composing = true
    }

    /// The in-process Durable start; on success the new Run's detail opens.
    /// Closing this page later does not stop the Run (ADR-06).
    func start() async {
        guard let starter, draft.problems.isEmpty, !starting else { return }
        starting = true
        defer { starting = false }
        switch await starter(draft.params) {
        case let .success(run):
            composing = false
            startProblem = nil
            await store.refreshRuns()
            if let id = run["runId"]?.stringValue { route = .run(id) }
        case let .failure(e):
            startProblem = RuntimeProblem(e)
        }
    }
}

// MARK: History

/// First-level GUI Explorer: unit Runs across Desktops, newest first, from
/// the Store's run.list (kind is filtered here: run.list has no kind
/// filter yet, docs/plan/10 F1-09).
public struct ExplorerHistoryView: View {
    public enum Scope: String, CaseIterable, Identifiable {
        case all = "全部", active = "进行中", ended = "已结束"
        public var id: String { rawValue }
    }
    public enum Source: String, CaseIterable, Identifiable {
        case all = "全部来源", mainWindow = "主窗口发起", agents = "外部 Agent"
        public var id: String { rawValue }
    }

    @ObservedObject var store: ShellStore
    let connectionState: PageState
    let retry: () -> Void
    let canStart: Bool
    let startWired: Bool
    let compose: () -> Void
    let open: (String) -> Void
    @State var scope: Scope = .all
    @State var source: Source = .all

    public static func unitRuns(_ runs: [JSONValue], scope: Scope = .all, source: Source = .all) -> [JSONValue] {
        runs.filter { r in
            guard r["kind"]?.stringValue == "unit" else { return false }
            let ended = r["phase"]?.stringValue == "ended"
            switch scope {
            case .all: break
            case .active: if ended { return false }
            case .ended: if !ended { return false }
            }
            switch source {
            case .all: return true
            case .mainWindow: return r["origin"]?.stringValue == "gui_explorer"
            case .agents: return r["origin"]?.stringValue != "gui_explorer"
            }
        }
    }

    var state: PageState {
        if case .loaded = connectionState {
            switch store.runsState {
            case .empty: return .loaded
            default: return store.runsState
            }
        }
        return connectionState
    }

    public var body: some View {
        PageContainer(state: state, syncedAt: store.runsSyncedAt, retry: retry, header: {
            PageHeader(eyebrow: "GUI Explorer", title: "GUI Explorer",
                       subtitle: "跨 Desktop 的 GUI 运行历史（kind = unit）。与 Runs 是同一份运行记录的两个视图。") {
                Button { compose() } label: { Label(startWired ? "新建 GUI 诊断" : "新建 GUI 诊断 · 待接入", systemImage: "play.fill") }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(!canStart)
            }
        }) {
            VStack(alignment: .leading, spacing: ADSpace.l) {
                if !startWired { ExplorerNotice.startPending }
                filters
                list
                ExplorerNotice.learningLater
            }
        }
    }

    var filters: some View {
        HStack(spacing: ADSpace.m) {
            Picker("范围", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 260)
            Picker("来源", selection: $source) { ForEach(Source.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).labelsHidden().frame(width: 330)
            Spacer()
            Text("\(Self.unitRuns(store.runs).count) 个 GUI 运行").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
    }

    static let columns: [(String, CGFloat)] = [("开始", 90), ("Desktop", 170), ("来源", 170), ("状态", 170),
                                               ("条件验证", 120), ("结束原因", 260)]

    @ViewBuilder var list: some View {
        let rows = Self.unitRuns(store.runs, scope: scope, source: source)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.columns, id: \.0) { c in
                    Text(c.0).font(ADFont.noteStrong).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                }
                Spacer()
            }
            .padding(.horizontal, ADSpace.l).frame(height: 40)
            .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
            if rows.isEmpty {
                EmptyState(title: "还没有 GUI 运行",
                           detail: "从这里新建一次 GUI 诊断，或由外部 Agent 通过 unit.run 发起；两者都会出现在这里和 Runs 里。",
                           action: nil)
            }
            ForEach(rows.indices, id: \.self) { i in row(rows[i]) }
        }
        .adPanel()
    }

    func row(_ r: JSONValue) -> some View {
        let desk = store.desktops.first { $0["desktopId"] == r["desktopId"] }
        return HStack(spacing: 0) {
            Text(TimeText.clock(r["createdAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                .frame(width: 90, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(desk?["name"]?.stringValue ?? "已关闭的 Desktop").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text(r["desktopId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(ExplorerText.originText(r)).font(ADFont.note).foregroundStyle(ADColor.ink)
                Text(r["runId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 170, alignment: .leading)
            StateBadge(ExplorerText.runStatus(r)).frame(width: 170, alignment: .leading)
            StateBadge(ExplorerText.verification(r["unit"]?["verification"]?["status"]?.stringValue)).frame(width: 120, alignment: .leading)
            Text(ExplorerText.closingReason(r["closingReason"]?.stringValue) ?? "—").font(ADFont.note).foregroundStyle(ADColor.ink)
                .lineLimit(2).frame(width: 260, alignment: .leading)
            Spacer()
            Button { if let id = r["runId"]?.stringValue { open(id) } } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary))
        }
        .padding(.horizontal, ADSpace.l)
        .frame(minHeight: 64)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

enum ExplorerNotice {
    static var startPending: some View {
        HStack(alignment: .top, spacing: ADSpace.s) {
            StateBadge("发起待接入", tone: .idle)
            VStack(alignment: .leading, spacing: 2) {
                Text("主窗口还没有接到 Runtime 的进程内 Durable 入口，现在只能查看运行。")
                    .font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text("不会改用线协议的 unit.run 代替：那样发起的是 Delegated 运行，关闭连接就会停止。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            Spacer()
        }
        .padding(ADSpace.l).adPanel()
    }

    static var learningLater: some View {
        Text("已学流程、应用知识、回放与验证属于学习阶段（P2），这里只显示运行历史。")
            .font(ADFont.note).foregroundStyle(ADColor.muted)
    }
}

// MARK: P27

/// 新建 GUI 诊断: target Desktop, goal, completion text, allowed actions,
/// limits (can only tighten), and the scope confirmation (UC41).
struct ExplorerStartSheet: View {
    @ObservedObject var store: ShellStore
    @Binding var draft: ExplorerDraft
    let startWired: Bool
    let starting: Bool
    let problem: RuntimeProblem?
    let cancel: () -> Void
    let start: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("新建 GUI 诊断").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                    Text("在一个 Desktop 的绑定窗口里验证一个局部目标。从这里发起的运行由平台持有，关闭页面不会停止它。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                Spacer()
                Button(action: cancel) { Image(systemName: "xmark") }.buttonStyle(ADButtonStyle(.quiet))
                    .accessibilityLabel("关闭")
            }
            .padding(ADSpace.xl)
            Rectangle().fill(ADColor.line).frame(height: 1)
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack(alignment: .top, spacing: ADSpace.l) {
                    field("目标 Desktop") { desktopPicker }
                    field("GUI 配置") {
                        Text("默认 GUI 配置 · 启动时由 Runtime 固定版本").font(ADFont.note).foregroundStyle(ADColor.ink)
                            .frame(maxWidth: .infinity, minHeight: 30, alignment: .leading)
                            .padding(.horizontal, ADSpace.s)
                            .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
                    }
                }
                field("局部目标") {
                    TextEditor(text: $draft.goal).font(ADFont.body).frame(height: 64)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(ADColor.line))
                }
                field("完成后应出现的文字", help: "由新的观察验证，不以模型说“完成”作为结果。只有新观察上验证为「已满足」才算成功。") {
                    TextField("例如：已保存", text: $draft.expectedText).textFieldStyle(.roundedBorder)
                }
                field("本次允许的动作") {
                    HStack(spacing: ADSpace.l) {
                        ForEach(ExplorerDraft.actions, id: \.0) { a in
                            Toggle(a.1, isOn: Binding(get: { draft.allowed.contains(a.0) },
                                                      set: { on in if on { draft.allowed.insert(a.0) } else { draft.allowed.remove(a.0) } }))
                                .toggleStyle(.checkbox).font(ADFont.note)
                        }
                        StateBadge("执行端不支持的动作会在启动时被拒绝", tone: .idle)
                    }
                }
                DisclosureGroup("运行限制（只能收紧默认值）") {
                    HStack(spacing: ADSpace.xl) {
                        Stepper("最多 \(draft.maxSteps) 步", value: $draft.maxSteps, in: 1...ExplorerDraft.stepCeiling)
                        Stepper("最多 \(draft.maxSeconds) 秒", value: $draft.maxSeconds, in: 10...ExplorerDraft.secondsCeiling, step: 10)
                        Spacer()
                    }
                    .font(ADFont.note).padding(.top, ADSpace.s)
                }
                .font(ADFont.note).padding(ADSpace.m)
                .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
                Toggle(isOn: $draft.scopeConfirmed) {
                    Text("我确认诊断范围：只在所选 Desktop 的绑定窗口里操作，只用上面允许的动作；运行会调用模型并执行真实输入。")
                        .font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
                }
                .toggleStyle(.checkbox)
                if let problem { ProblemView(problem) }
            }
            .padding(ADSpace.xl)
            Rectangle().fill(ADColor.line).frame(height: 1)
            HStack(spacing: ADSpace.m) {
                if !startWired {
                    StateBadge("发起待接入：宿主未提供进程内 Durable 入口", tone: .idle)
                } else if let first = draft.problems.first {
                    Text("还需要：\(first)").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                Spacer()
                Button("取消", action: cancel).buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button { start?() } label: { Label(starting ? "正在启动…" : "开始诊断", systemImage: "play.fill") }
                    .buttonStyle(ADButtonStyle(.primary))
                    .disabled(start == nil || !draft.problems.isEmpty || starting)
            }
            .padding(ADSpace.l)
        }
        .frame(width: 720)
        .adPanel()
        .shadow(color: .black.opacity(0.14), radius: 22, y: 8)
    }

    var desktopPicker: some View {
        let options = ExplorerDraft.eligible(desktops: store.desktops, activeRuns: store.activeRuns)
        return Picker("目标 Desktop", selection: Binding(get: { draft.desktopId ?? "" },
                                                       set: { draft.desktopId = $0.isEmpty ? nil : $0 })) {
            Text("选择 Desktop").tag("")
            ForEach(options.indices, id: \.self) { i in
                let d = options[i].desktop
                let name = d["name"]?.stringValue ?? "—"
                Text(options[i].blocked.map { "\(name) · \($0)" } ?? "\(name) · 空闲").tag(d["desktopId"]?.stringValue ?? "")
                    .selectionDisabled(options[i].blocked != nil)
            }
        }
        .labelsHidden().pickerStyle(.menu).frame(maxWidth: .infinity)
    }

    func field<F: View>(_ label: String, help: String? = nil, @ViewBuilder _ control: () -> F) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            control()
            if let help { Text(help).font(ADFont.note).foregroundStyle(ADColor.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: P28 / P29

/// One unit Run: progress, observations, proposals, actions, verification,
/// recovery and how it ended. Stopping waits for the execution side.
struct ExplorerRunDetailView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject var loader: ExplorerRunLoader
    let back: () -> Void

    init(store: ShellStore, navigation: ShellNavigation, loader: ExplorerRunLoader, back: @escaping () -> Void) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: loader)
        self.back = back
    }

    var run: JSONValue? { loader.run }
    var ended: Bool { run?["phase"]?.stringValue == "ended" }
    var stopping: Bool { run?["phase"]?.stringValue == "stopping" }

    var subtitle: String {
        guard let r = run else { return loader.runId }
        let desk = store.desktops.first { $0["desktopId"] == r["desktopId"] }?["name"]?.stringValue ?? (r["desktopId"]?.stringValue ?? "—")
        let profile = r["unit"]?["guiProfileId"]?.stringValue ?? "—"
        let rev = r["unit"]?["guiProfileRevision"]?.intValue.map { " r\($0)" } ?? ""
        return "\(loader.runId) · \(desk) · 配置 \(profile)\(rev)"
    }

    var body: some View {
        PageContainer(state: loader.state, emptyTitle: "没有这个运行", syncedAt: loader.syncedAt,
                      retry: { Task { await loader.load() } }, header: {
            PageHeader(eyebrow: "GUI Explorer / Run", title: "GUI 诊断", subtitle: subtitle) {
                HStack(spacing: ADSpace.s) {
                    Button(action: back) { Label("运行历史", systemImage: "chevron.left") }.buttonStyle(ADButtonStyle(.secondary))
                    Button { Task { await loader.stop() } } label: { Label(stopping ? "正在停止" : "停止诊断", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger)).disabled(run == nil || ended || stopping)
                }
            }
        }) {
            if let r = run { content(r) }
        }
        .task(id: store.tick) { await loader.load() }
    }

    func content(_ r: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            banner(r)
            if let p = loader.stopProblem { ProblemView(p) }
            stages
            HStack(alignment: .top, spacing: ADSpace.xl) {
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    stats
                    stepsPanel
                    HStack(alignment: .top, spacing: ADSpace.l) {
                        verificationPanel.frame(maxWidth: .infinity)
                        recoveryPanel.frame(maxWidth: .infinity)
                    }
                }
                .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: ADSpace.l) {
                    goalPanel(r)
                    bindingPanel(r)
                    statePanel(r)
                    picturePanel(r)
                }
                .frame(width: 330)
            }
        }
    }

    // Banner: how the Run ended, or that it is stopping / waiting.
    @ViewBuilder func banner(_ r: JSONValue) -> some View {
        let unknown = r["unknownActions"]?.intValue ?? 0
        switch (r["phase"]?.stringValue, r["outcome"]?.stringValue) {
        case ("ended", "success"):
            note(.running, "完成条件已满足", "新观察上的验证结果为「已满足」。模型报告「完成」本身不是成功依据；平台不评估业务结果。")
        case ("ended", "unknown"):
            note(.attention, "结果未知 · 需要核实", "有 \(unknown) 个动作结果未知。不会自动重发；只能重新观察并核实，原记录保持「结果未知」。")
        case ("ended", "failed"):
            note(.danger, "运行未完成", ExplorerText.closingReason(r["closingReason"]?.stringValue) ?? "Runtime 未提供结束原因")
        case ("ended", "cancelled"):
            note(.idle, "已停止", "执行端已确认在途输入静止。\(ExplorerText.closingReason(r["closingReason"]?.stringValue) ?? "")")
        case ("stopping", _):
            note(.attention, "正在停止", "停止请求已受理，等待执行端确认在途输入静止；之后到达的模型建议会被丢弃。不影响其他 Desktop。")
        case ("waiting_input", _):
            note(.attention, "等待人工", "运行请求人工处理（\(loader.timeline.needsInput ?? "needs_user")）。")
        default:
            EmptyView()
        }
    }

    func note(_ tone: StatusTone, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            StateBadge(title, tone: tone)
            Text(detail).font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
            Spacer()
        }
        .padding(ADSpace.l)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(tone.background))
        .overlay(RoundedRectangle(cornerRadius: ADRadius.panel).stroke(tone.foreground.opacity(0.25)))
    }

    static let stageNames = ["观察", "模型建议", "实际动作", "重新观察", "条件验证"]

    var stages: some View {
        let current = ended ? 6 : loader.timeline.stage
        return HStack(spacing: ADSpace.s) {
            ForEach(0..<5, id: \.self) { i in
                let done = i + 1 < current || ended
                let now = i + 1 == current
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Rectangle().fill(done || now ? ADColor.primary : ADColor.line).frame(height: now ? 3 : 2)
                    Text("\(i + 1) · \(Self.stageNames[i])").font(now ? ADFont.noteStrong : ADFont.note)
                        .foregroundStyle(now ? ADColor.ink : ADColor.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(now ? .isSelected : [])
            }
        }
    }

    var stats: some View {
        let t = loader.timeline
        let suffix = ended ? "结束时" : "最近一次进度"
        return HStack(spacing: ADSpace.m) {
            stat("已用步数", t.stepBudget.map { "\(t.stepsUsed) / \($0)" } ?? "\(t.stepsUsed)", suffix)
            stat("剩余步数", t.progress.map { "\($0.stepsLeft)" } ?? "—", suffix)
            stat("剩余推理次数", t.progress.map { "\($0.attemptsLeft)" } ?? "—", "单次运行合计")
            stat("剩余秒数", t.progress.map { "\($0.secondsLeft)" } ?? "—", suffix)
        }
    }

    func stat(_ label: String, _ value: String, _ hint: String) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted)
            Text(value).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            Text(hint).font(ADFont.identifier).foregroundStyle(ADColor.muted)
        }
        .padding(ADSpace.m).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    var stepsPanel: some View {
        panel("观察 · 模型建议 · 实际动作", trailing: "模型尝试 \(loader.timeline.modelAttempts) 次 · 实际输入 \(loader.timeline.confirmedInputs) 次") {
            if loader.timeline.steps.isEmpty {
                Text("还没有步骤。运行开始后先观察，并检查目标是否已经满足。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    .padding(.vertical, ADSpace.s)
            }
            ForEach(loader.timeline.steps) { s in stepRow(s) }
        }
    }

    func stepRow(_ s: ExplorerStep) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            HStack(spacing: ADSpace.s) {
                Text("第 \(s.index + 1) 步").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text("模型尝试 \(s.modelAttempts) 次").font(ADFont.note).foregroundStyle(ADColor.muted)
                if !s.inferenceErrors.isEmpty {
                    Text("调用错误：\(s.inferenceErrors.joined(separator: "、"))").font(ADFont.identifier).foregroundStyle(StatusTone.danger.foreground)
                }
                Spacer()
            }
            Text(s.proposalText).font(ADFont.note).foregroundStyle(s.rejected == nil ? ADColor.ink : StatusTone.danger.foreground)
            ForEach(s.actions) { a in
                HStack(spacing: ADSpace.s) {
                    StateBadge(loader.status(of: a))
                    Text(a.actionId).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    Text(a.requestId).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    Spacer()
                }
            }
            if s.actions.contains(where: { $0.deliveryState == "unknown" }) {
                Text("输入可能已到达应用。不会自动重发；只能重新观察并核实。")
                    .font(ADFont.note).foregroundStyle(StatusTone.attention.foreground)
            }
        }
        .padding(.vertical, ADSpace.s)
        .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }

    var verificationPanel: some View {
        let list = Array(loader.timeline.verifications.suffix(5).reversed())
        return panel("条件验证", trailing: "共 \(loader.timeline.verifications.count) 次") {
            if list.isEmpty { Text("尚未验证").font(ADFont.note).foregroundStyle(ADColor.muted) }
            ForEach(list.indices, id: \.self) { i in
                let v = list[i]
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: ADSpace.s) {
                        StateBadge(v.text)
                        Text(v.observationId ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                        Spacer()
                        Text(TimeText.clock(v.checkedAt)).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                    if v.status == "inconclusive" {
                        Text("无法判定：\(v.reasonText ?? "Runtime 未提供原因")；不算成功。").font(ADFont.note).foregroundStyle(ADColor.ink)
                    }
                }
                .padding(.vertical, 3)
            }
        }
    }

    var recoveryPanel: some View {
        let rec = loader.timeline.recoveries
        return panel("恢复", trailing: "恢复 \(rec.count) 次") {
            if rec.isEmpty { Text("没有发生恢复。").font(ADFont.note).foregroundStyle(ADColor.muted) }
            ForEach(rec.indices, id: \.self) { i in
                HStack(spacing: ADSpace.s) {
                    StateBadge(rec[i].text, tone: .attention)
                    Text("第 \(rec[i].stepIndex + 1) 步 · 第 \(rec[i].count) 次").font(ADFont.note).foregroundStyle(ADColor.muted)
                    Spacer()
                }
            }
            if !rec.isEmpty {
                Text("恢复只重新观察并验证，不重放已发出的输入。").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
        }
    }

    func goalPanel(_ r: JSONValue) -> some View {
        panel("本次目标") {
            LabeledValue(label: "目标摘要", value: Self.shortHash(r["unit"]?["goalHash"]?.stringValue), monospaced: true, labelWidth: 90)
            LabeledValue(label: "模式", value: r["unit"]?["mode"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
            Text("目标正文、完成条件和参数值不写进运行记录，这里只显示摘要。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    func bindingPanel(_ r: JSONValue) -> some View {
        let t = loader.timeline
        let rev = r["unit"]?["guiProfileRevision"]?.intValue.map { " / r\($0)" } ?? ""
        return panel("固定绑定") {
            LabeledValue(label: "GUI 配置", value: (r["unit"]?["guiProfileId"]?.stringValue ?? "—") + rev, labelWidth: 90)
            LabeledValue(label: "决策步骤", value: t.stepBudget.map { "\(t.stepsUsed) / \($0)" } ?? "\(t.stepsUsed)", labelWidth: 90)
            LabeledValue(label: "模型尝试", value: "\(t.modelAttempts) 次", labelWidth: 90)
            LabeledValue(label: "实际输入", value: "\(t.confirmedInputs) 次", labelWidth: 90)
            LabeledValue(label: "结果未知", value: "\(t.unknownInputs) 次", labelWidth: 90)
            LabeledValue(label: "用量", value: "见 设置 › 诊断与用量", labelWidth: 90)
        }
    }

    func statePanel(_ r: JSONValue) -> some View {
        panel("运行状态") {
            HStack { StateBadge(ExplorerText.runStatus(r)); Spacer() }
            LabeledValue(label: "phase", value: r["phase"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
            LabeledValue(label: "outcome", value: r["outcome"]?.stringValue ?? "尚无", monospaced: true, labelWidth: 90)
            LabeledValue(label: "quiescence", value: r["quiescence"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
            LabeledValue(label: "结束原因", value: r["closingReason"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
            LabeledValue(label: "条件验证", value: ExplorerText.verification(r["unit"]?["verification"]?["status"]?.stringValue).text, labelWidth: 90)
            LabeledValue(label: "来源", value: ExplorerText.originText(r), labelWidth: 90)
        }
    }

    func picturePanel(_ r: JSONValue) -> some View {
        panel("画面") {
            Text("运行记录不含截图和输入内容。实时画面在 Desktop 详情里查看。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            if let d = r["desktopId"]?.stringValue, store.desktops.contains(where: { $0["desktopId"]?.stringValue == d }) {
                Button { navigation.showDesktop(d) } label: { Label("打开 Desktop", systemImage: "display").frame(maxWidth: .infinity) }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
        }
    }

    func panel<C: View>(_ title: String, trailing: String? = nil, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                if let trailing { Text(trailing).font(ADFont.note).foregroundStyle(ADColor.muted) }
            }
            content()
        }
        .padding(ADSpace.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .adPanel()
    }

    static func shortHash(_ h: String?) -> String {
        guard let h, h.count > 19 else { return h ?? "—" }
        return String(h.prefix(19)) + "…"
    }
}
