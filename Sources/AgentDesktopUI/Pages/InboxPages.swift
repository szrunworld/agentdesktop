import AgentDesktopProtocol
import SwiftUI

// Lane UI-A (U9): Inbox (Hub W06), Settings › 核实 (W07) and the
// diagnostics export of Settings › 诊断与用量 (W08). Models in
// InboxModels.swift.

/// Inbox (Hub W06): what waits for a person, from `inbox.list`: actions
/// whose delivery is unknown and Runs waiting for input. The list on the
/// left, the selected item on the right.
public struct InboxPage: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var loader: InboxListLoader
    @State private var stateFilter = "open"
    @State private var kind: String? = nil
    @State private var desktop: String? = nil
    @State private var selected: String?

    public init(store: ShellStore, navigation: ShellNavigation, selected: String? = nil) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: InboxListLoader(runtime: store.runtime))
        _selected = State(initialValue: selected)
    }

    /// With a loader that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, loader: InboxListLoader, selected: String? = nil) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: loader)
        _selected = State(initialValue: selected)
        _stateFilter = State(initialValue: loader.filter.state)
    }

    var filter: InboxListLoader.Filter { InboxListLoader.Filter(state: stateFilter, kind: kind, desktopId: desktop) }

    public var body: some View {
        PageContainer(state: pageState, emptyTitle: "没有待处理的事项",
                      emptyDetail: "结果未知、需要核实的动作，以及等待人工处理的运行，会出现在这里。业务审批仍由各自的应用处理。",
                      syncedAt: loader.syncedAt, retry: { Task { await loader.reload() } }, header: {
            PageHeader(eyebrow: "Inbox", title: "Inbox",
                       subtitle: "需要你决定的平台事项。核实只追加记录，原结果保持「结果未知」；这里不会重发任何动作。") {
                if store.isSample { SampleMark() }
            }
        }) {
            content
        }
        .task(id: store.tick) { await loader.reload() }
        .onChange(of: filter) { f in Task { await loader.apply(f) } }
    }

    /// The filter row stays usable while a filtered list is empty.
    var pageState: PageState {
        if case .empty = loader.state { return .loaded }
        return loader.state
    }

    var content: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            filters
            HStack(alignment: .top, spacing: ADSpace.l) {
                list.frame(width: 360)
                Group {
                    if let id = selected {
                        InboxItemDetailView(store: store, navigation: navigation, inboxId: id).id(id)
                    } else {
                        VStack(alignment: .leading, spacing: ADSpace.s) {
                            Text("选择左侧一项查看详情").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                            Text("结果未知的动作在运行结束、输入静止后可以核实；等待人工处理的运行可以在这里停止。")
                                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
    }

    var filters: some View {
        HStack(spacing: ADSpace.s) {
            Picker("状态", selection: $stateFilter) {
                Text("待处理").tag("open")
                Text("已处理").tag("resolved")
                Text("全部").tag("all")
            }
            .pickerStyle(.segmented).labelsHidden().frame(width: 220)
            RunsFilterMenu(title: "类型", options: [(nil, "所有类型"), ("unknown_reference", "结果未知的动作"), ("question", "等待人工处理")],
                           selection: $kind)
            RunsFilterMenu(title: "Desktop", options: [(nil, "所有 Desktop")] + store.desktops.map {
                ($0["desktopId"]?.stringValue, $0["name"]?.stringValue ?? "—")
            }, selection: $desktop)
            Spacer()
            Text("\(loader.items.count) 项\(loader.next != nil ? "，还有更多" : "")").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
    }

    var list: some View {
        VStack(spacing: 0) {
            if loader.items.isEmpty {
                HStack {
                    Text("没有符合条件的事项。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    Spacer()
                }.padding(ADSpace.l)
            }
            ForEach(loader.items.indices, id: \.self) { i in
                InboxRow(item: loader.items[i], desktopName: desktopName(loader.items[i]),
                         selected: loader.items[i]["inboxId"]?.stringValue == selected) {
                    selected = loader.items[i]["inboxId"]?.stringValue
                }
            }
            if loader.next != nil {
                Button(loader.loadingMore ? "正在读取…" : "加载更多") { Task { await loader.loadMore() } }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(loader.loadingMore).padding(ADSpace.m)
            }
        }
        .adPanel()
    }

    func desktopName(_ item: JSONValue) -> String? {
        store.desktops.first { $0["desktopId"] == item["desktopId"] }?["name"]?.stringValue
    }
}

/// One row of an Inbox list.
struct InboxRow: View {
    let item: JSONValue
    let desktopName: String?
    let selected: Bool
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                HStack(spacing: ADSpace.s) {
                    StateBadge(InboxText.kind(item["kind"]?.stringValue))
                    Spacer()
                    StateBadge(InboxText.state(item))
                }
                Text(summary).font(ADFont.noteStrong).foregroundStyle(ADColor.ink).lineLimit(1)
                Text("\(desktopName ?? "已关闭的 Desktop") · \(item["clientId"]?.stringValue ?? "平台") · \(TimeText.clock(item["createdAt"]?.stringValue))")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).lineLimit(1)
                Text(item["runId"]?.stringValue ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    .lineLimit(1).truncationMode(.middle)
            }
            .padding(ADSpace.m).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? ADColor.selected : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    var summary: String {
        switch item["kind"]?.stringValue {
        case "unknown_reference":
            let a = item["action"]
            return "动作 \(a?["kind"]?.stringValue ?? "—") 的结果未知 · \(a?["requestId"]?.stringValue ?? "—")"
        case "question":
            return "运行等待人工处理：\(InboxText.questionReason(item["question"]?["reason"]?.stringValue))"
        default:
            return item["inboxId"]?.stringValue ?? "—"
        }
    }
}

/// One Inbox item (inbox.show): the Run's three axes as the Runtime has
/// them, the action or the question, every reconciliation (oldest first),
/// and what a person can do: reconcile an unknown action, or stop a Run
/// waiting for input. Nothing here retries or forces a success.
struct InboxItemDetailView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var model: InboxItemModel
    @State private var confirmReconcile = false
    @State private var confirmStop = false

    init(store: ShellStore, navigation: ShellNavigation, inboxId: String) {
        self.store = store
        self.navigation = navigation
        _model = StateObject(wrappedValue: InboxItemModel(runtime: store.runtime, inboxId: inboxId))
    }

    /// With a model that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, model: InboxItemModel) {
        self.store = store
        self.navigation = navigation
        _model = StateObject(wrappedValue: model)
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    var body: some View {
        Group {
            switch model.state {
            case .loading:
                Text("正在读取…").font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
            case let .failed(p), let .disconnected(p):
                InboxNotice(title: "读取失败：\(p.title)（\(p.code)）", text: p.advice, tone: .danger)
            default:
                if let item = model.item { content(item) }
            }
        }
        .task(id: store.tick) { await model.load() }
        .confirmationDialog("记录这条核实？", isPresented: $confirmReconcile) {
            Button("记录核实") { Task { await model.reconcile() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只追加一条核实记录：动作回执、请求记录和运行的最终结果都保持「结果未知」，不会重发这个动作。记录之后不能修改或删除，只能再追加。")
        }
        .confirmationDialog("停止这个等待中的运行？", isPresented: $confirmStop) {
            Button("停止此运行", role: .destructive) { Task { await model.stopRun() } }
            Button("取消", role: .cancel) {}
        } message: {
            Text("运行不再等待并进入停止流程，不会代替它回答问题，也不会发送任何输入。要等执行端确认输入静止后才显示已停止。")
        }
    }

    func content(_ item: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            HStack(spacing: ADSpace.s) {
                StateBadge(InboxText.kind(item["kind"]?.stringValue))
                StateBadge(InboxText.state(item))
                Spacer()
                if let runId = item["runId"]?.stringValue {
                    Button { navigation.showRun(runId) } label: { Label("打开运行", systemImage: "arrow.up.right") }
                        .buttonStyle(ADButtonStyle(.secondary))
                }
            }
            runPanel(item)
            if let note = model.conflictNote { InboxNotice(title: note, text: "", tone: .attention) }
            if let p = model.problem {
                InboxNotice(title: "没有被受理：\(p.title)（\(p.code)）", text: p.advice, tone: .danger)
            }
            switch item["kind"]?.stringValue {
            case "unknown_reference":
                actionPanel(item)
                reconciliations(item)
                reconcileForm(item)
            case "question":
                questionPanel(item)
            default:
                EmptyView()
            }
        }
    }

    func runPanel(_ item: JSONValue) -> some View {
        let r = item["run"]
        return VStack(alignment: .leading, spacing: ADSpace.s) {
            Text("运行（来自 Runtime）").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            HStack(spacing: ADSpace.m) {
                axis("执行阶段", RunsText.phase(r ?? .null), r?["phase"]?.stringValue)
                axis("最终结果", RunsText.outcome(r ?? .null), r?["outcome"]?.stringValue ?? "null")
                axis("输入静止", RunsText.quiescence(r ?? .null), r?["quiescence"]?.stringValue)
            }
            LabeledValue(label: "runId", value: item["runId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "Desktop", value: store.desktops.first { $0["desktopId"] == item["desktopId"] }?["name"]?.stringValue
                ?? item["desktopId"]?.stringValue ?? "—", labelWidth: 100)
            LabeledValue(label: "调用主体", value: item["clientId"]?.stringValue ?? "平台", monospaced: true, labelWidth: 100)
            LabeledValue(label: "结束原因", value: r?["closingReason"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "inboxId", value: item["inboxId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    func axis(_ label: String, _ status: StatusText, _ code: String?) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted)
            StateBadge(status)
            Text(code ?? "—").font(ADFont.identifier).foregroundStyle(ADColor.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    func actionPanel(_ item: JSONValue) -> some View {
        let a = item["action"]
        return VStack(alignment: .leading, spacing: ADSpace.s) {
            Text("结果未知的动作").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            LabeledValue(label: "requestId", value: a?["requestId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "动作类型", value: a?["kind"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            LabeledValue(label: "回执", value: a?["receiptId"]?.stringValue ?? "没有回执（Runtime 在写回执前停止）", monospaced: true, labelWidth: 100)
            LabeledValue(label: "投递时间", value: TimeText.clock(a?["dispatchedAt"]?.stringValue), monospaced: true, labelWidth: 100)
            LabeledValue(label: "变为未知", value: TimeText.clock(a?["becameUnknownAt"]?.stringValue), monospaced: true, labelWidth: 100)
            LabeledValue(label: "原因", value: a?["reasonCode"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
            Text("平台不知道这个动作是否到达了应用。用同一个 requestId 再发仍然只会得到「结果未知」；如果要再做一次，调用方必须用新的 requestId。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }

    func reconciliations(_ item: JSONValue) -> some View {
        let recs = item["reconciliations"]?.arrayValue ?? []
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("核实记录（只追加）").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                Text("\(recs.count) 条").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .padding(ADSpace.l)
            if recs.isEmpty {
                Text("还没有核实记录。").font(ADFont.note).foregroundStyle(ADColor.muted)
                    .padding(.horizontal, ADSpace.l).padding(.bottom, ADSpace.l)
            }
            ForEach(recs.indices, id: \.self) { i in
                let rec = recs[i]
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    HStack(spacing: ADSpace.s) {
                        Text("#\(rec["sequence"]?.intValue ?? i + 1)").font(ADFont.code).foregroundStyle(ADColor.muted)
                        StateBadge(InboxText.verdict(rec["verdict"]?.stringValue), tone: InboxText.verdictTone(rec["verdict"]?.stringValue))
                        Text(InboxText.source(rec["source"]?.stringValue)).font(ADFont.note).foregroundStyle(ADColor.ink)
                        Spacer()
                        Text(TimeText.clock(rec["at"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.muted)
                    }
                    Text("记录人 \(rec["by"]?.stringValue ?? "—")").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    if let note = rec["note"]?.stringValue {
                        Text(note).font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
                    }
                    let refs = rec["evidenceRefs"]?.arrayValue?.compactMap(\.stringValue) ?? []
                    if !refs.isEmpty {
                        Text("证据：" + refs.joined(separator: "，")).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
                .padding(.horizontal, ADSpace.l).padding(.vertical, ADSpace.s)
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
            }
        }
        .adPanel()
    }

    @ViewBuilder
    func reconcileForm(_ item: JSONValue) -> some View {
        if item["state"]?.stringValue == "resolved" {
            InboxNotice(title: "已核实为「\(InboxText.verdict(item["resolution"]?["verdict"]?.stringValue))」",
                        text: "核实不会改写运行的最终结果：运行仍显示结果未知。这条记录不能修改或删除。", tone: .idle)
        } else if !InboxText.quiescent(item) {
            InboxNotice(title: "运行结束并确认输入静止后才能核实",
                        text: "现在是 \(InboxText.runLine(item))。核实要基于已经静止的状态，避免动作仍在进行时下结论。", tone: .attention)
        } else {
            VStack(alignment: .leading, spacing: ADSpace.m) {
                Text("记录核实结论").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Text("根据应用里能看到的情况或外部记录判断这个动作是否发生了。「已执行」或「未执行」会关闭这项；「仍无法确定」只追加记录，这项保持待处理。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                Picker("核实结论", selection: $model.draft.verdict) {
                    Text("请选择").tag(String?.none)
                    Text("已执行").tag(String?.some("executed"))
                    Text("未执行").tag(String?.some("not_executed"))
                    Text("仍无法确定").tag(String?.some("still_unknown"))
                }
                .pickerStyle(.menu).frame(maxWidth: 320)
                Picker("依据", selection: $model.draft.source) {
                    Text("本人确认").tag("operator_attestation")
                    Text("外部记录").tag("external_reference")
                }
                .pickerStyle(.segmented).frame(maxWidth: 320)
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("说明（可选，最多 1024 字）").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                    TextField("例如：在应用的发送记录里没有找到这条", text: $model.draft.note, axis: .vertical)
                        .textFieldStyle(.roundedBorder).lineLimit(2...4)
                }
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    Text("证据引用（可选，每行一条，最多 8 条）").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                    TextField("例如：app-log:42", text: $model.draft.evidence, axis: .vertical)
                        .textFieldStyle(.roundedBorder).font(ADFont.code).lineLimit(1...4)
                }
                HStack(spacing: ADSpace.m) {
                    Button(model.submitting ? "正在记录…" : "记录核实") { confirmReconcile = true }
                        .buttonStyle(ADButtonStyle(.primary))
                        .disabled(!connected || !model.canReconcile || model.draft.problem != nil)
                    if let why = model.draft.problem {
                        Text(why).font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    Spacer()
                    Text("已有 \(item["revision"]?.intValue ?? 0) 条核实记录").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                }
                Text("没有重试、强制成功或重放：要再做这个动作，需要调用方用新的 requestId 重新发起。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
        }
    }

    func questionPanel(_ item: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            Text("运行在等待人工处理").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
            LabeledValue(label: "原因", value: "\(InboxText.questionReason(item["question"]?["reason"]?.stringValue))（\(item["question"]?["reason"]?.stringValue ?? "—")）",
                         labelWidth: 100)
            Text("目前只能停止这个运行：平台还不能代替它回答问题或给出审批。请在对应的 Desktop 上完成需要人工处理的步骤后，由发起方重新运行。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            if let progress = model.stopProgress {
                HStack(spacing: ADSpace.s) {
                    StateBadge(progress)
                    if let s = model.stopAnswer {
                        Text("停止请求已受理 · phase \(s["phase"]?.stringValue ?? "—") · quiescence \(s["quiescence"]?.stringValue ?? "—")")
                            .font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
            }
            HStack {
                Button(model.submitting ? "正在停止…" : "停止此运行") { confirmStop = true }
                    .buttonStyle(ADButtonStyle(.danger)).disabled(!connected || !model.canStop)
                if let d = item["desktopId"]?.stringValue, store.desktops.contains(where: { $0["desktopId"]?.stringValue == d }) {
                    Button { navigation.showDesktop(d) } label: { Label("打开 Desktop", systemImage: "display") }
                        .buttonStyle(ADButtonStyle(.secondary))
                }
            }
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading).adPanel()
    }
}

/// A short tinted notice.
struct InboxNotice: View {
    let title: String
    let text: String
    let tone: StatusTone

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            Text(title).font(ADFont.bodyStrong).foregroundStyle(tone == .idle ? ADColor.ink : tone.foreground)
            if !text.isEmpty {
                Text(text).font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ADSpace.l).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(tone.background))
    }
}

// MARK: Settings › 核实 (W07)

/// Settings › 核实 (Hub W07): every action whose delivery is unknown, open
/// or already reconciled, with the same detail as the Inbox.
struct SettingsVerificationPage: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @StateObject private var loader: InboxListLoader
    @State private var stateFilter = "open"
    @State private var selected: String?

    init(store: ShellStore, navigation: ShellNavigation) {
        self.store = store
        self.navigation = navigation
        _loader = StateObject(wrappedValue: InboxListLoader(runtime: store.runtime,
                                                            filter: .init(state: "open", kind: "unknown_reference")))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("核实结果未知的动作").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                Text("投递结果未知的动作在运行结束、输入静止后可以核实。核实只追加一条记录：回执、请求记录和运行的最终结果都不变，也不会重发动作。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Picker("状态", selection: $stateFilter) {
                    Text("待核实").tag("open")
                    Text("已核实").tag("resolved")
                    Text("全部").tag("all")
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                Spacer()
                if let at = loader.syncedAt {
                    Text("同步于 \(PageContainer<EmptyView, EmptyView>.time(at))").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            }
            switch loader.state {
            case .loading:
                Text("正在读取…").font(ADFont.note).foregroundStyle(ADColor.muted)
            case let .failed(p), let .disconnected(p):
                InboxNotice(title: "读取失败：\(p.title)（\(p.code)）", text: p.advice, tone: .danger)
            default:
                HStack(alignment: .top, spacing: ADSpace.l) {
                    VStack(spacing: 0) {
                        if loader.items.isEmpty {
                            Text(stateFilter == "open" ? "没有待核实的动作。" : "没有符合条件的动作。")
                                .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        ForEach(loader.items.indices, id: \.self) { i in
                            InboxRow(item: loader.items[i], desktopName: store.desktops.first { $0["desktopId"] == loader.items[i]["desktopId"] }?["name"]?.stringValue,
                                     selected: loader.items[i]["inboxId"]?.stringValue == selected) {
                                selected = loader.items[i]["inboxId"]?.stringValue
                            }
                        }
                        if loader.next != nil {
                            Button(loader.loadingMore ? "正在读取…" : "加载更多") { Task { await loader.loadMore() } }
                                .buttonStyle(ADButtonStyle(.secondary)).disabled(loader.loadingMore).padding(ADSpace.m)
                        }
                    }
                    .adPanel().frame(width: 320)
                    if let id = selected {
                        InboxItemDetailView(store: store, navigation: navigation, inboxId: id).id(id)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                    } else {
                        Spacer()
                    }
                }
            }
        }
        .task(id: store.tick) { await loader.reload() }
        .onChange(of: stateFilter) { s in Task { await loader.apply(.init(state: s, kind: "unknown_reference")) } }
    }
}

// MARK: 诊断导出 (W08)

/// The diagnostics export of Settings › 诊断与用量: choose the sections and
/// the window, preview what an export would hold, then export it into an
/// artifact and save it. The Runtime decides what is left out; the page
/// lists that too.
struct DiagnosticsExportPanel: View {
    @ObservedObject var model: DiagnosticsExportModel
    let connected: Bool

    var body: some View {
        SettingsPanel(title: "诊断导出") {
            VStack(alignment: .leading, spacing: ADSpace.m) {
                Text("把 Runtime 的状态写成一个 JSON 文件，用于排查问题。只读：不修复、不重启、不改授权，也不创建运行。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
                    .padding(.top, ADSpace.m)
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), alignment: .leading)], alignment: .leading, spacing: ADSpace.s) {
                    ForEach(DiagnosticsExportModel.sections, id: \.self) { s in
                        Toggle(DiagnosticsExportModel.sectionName(s), isOn: Binding(
                            get: { model.chosen.contains(s) },
                            set: { on in if on { model.chosen.insert(s) } else { model.chosen.remove(s) } }))
                            .toggleStyle(.checkbox).font(ADFont.note)
                    }
                }
                Picker("时间范围", selection: $model.window) {
                    ForEach(DiagnosticsExportModel.Window.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 260)
                HStack(spacing: ADSpace.m) {
                    Button("预览内容") { Task { await model.runPreview() } }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(!connected || !model.canRun)
                    Button(model.working ? "正在导出…" : "导出") { Task { await model.runExport() } }
                        .buttonStyle(ADButtonStyle(.primary)).disabled(!connected || !model.canExport)
                    if model.chosen.isEmpty { Text("至少选择一项。").font(ADFont.note).foregroundStyle(ADColor.muted) }
                }
                if let p = model.problem {
                    Text("导出失败：\(p.title)（\(p.code)）。\(p.advice)").font(ADFont.note).foregroundStyle(StatusTone.danger.foreground)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let m = model.preview { manifest(m) }
                if let e = model.export {
                    HStack(spacing: ADSpace.m) {
                        StateBadge("已导出", tone: .running)
                        Text("产物 \(e.artifactId) · \(e.data.count) 字节").font(ADFont.note).foregroundStyle(ADColor.muted)
                        Spacer()
                        Button("保存 JSON…") { RunsSave.save(e.data, name: "agentdesktop-diagnostics.json") }
                            .buttonStyle(ADButtonStyle(.secondary))
                    }
                }
            }
        }
    }

    func manifest(_ m: JSONValue) -> some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            Text("\(m["scope"]?["role"]?.stringValue == "owner" ? "本机用户范围" : "仅本客户端范围") · 自 \(InboxText.dateTime(m["since"]?.stringValue)) 起")
                .font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
            ForEach((m["sections"]?.arrayValue ?? []).indices, id: \.self) { i in
                let s = m["sections"]!.arrayValue![i]
                HStack(spacing: ADSpace.s) {
                    Text(DiagnosticsExportModel.sectionName(s["name"]?.stringValue ?? "")).font(ADFont.note).foregroundStyle(ADColor.ink)
                        .frame(width: 150, alignment: .leading)
                    Text("\(s["items"]?.intValue ?? 0) 项").font(ADFont.code).foregroundStyle(ADColor.muted)
                    if s["truncated"]?.boolValue == true { StateBadge("已截断，请缩短时间范围", tone: .attention) }
                    if s["unavailable"]?.boolValue == true { StateBadge("无法读取", tone: .danger) }
                }
            }
            let excluded = m["excluded"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if !excluded.isEmpty {
                Text("导出永远不包含：" + excluded.map(DiagnosticsExportModel.excludedName).joined(separator: "、"))
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ADSpace.m).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.canvas))
    }
}
