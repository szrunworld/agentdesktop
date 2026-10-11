import AgentDesktopProtocol
import AppKit
import SwiftUI

/// Runs › 动作记录 (P19): the write requests the Runtime accepted
/// (`request.list`), newest first, filtered by Desktop and result, more
/// pages with the cursor; `导出记录` is `request.export`. Each result is
/// §6.4's summary; 详情 opens the receipt (P20).
public struct ActionRecordsView: View {
    @ObservedObject var store: ShellStore
    @ObservedObject var navigation: ShellNavigation
    @Binding var tab: RunsPage.RunsTab
    @StateObject private var loader: ActionRecordsLoader
    @State private var desktop: String? = nil
    @State private var result: String? = nil
    @State private var query = ""
    @State private var receipt: String?

    public init(store: ShellStore, navigation: ShellNavigation, tab: Binding<RunsPage.RunsTab> = .constant(.records)) {
        self.store = store
        self.navigation = navigation
        _tab = tab
        _loader = StateObject(wrappedValue: ActionRecordsLoader(runtime: store.runtime))
    }

    /// With a loader that has already read (renders, tests).
    init(store: ShellStore, navigation: ShellNavigation, loader: ActionRecordsLoader, receipt: String? = nil) {
        self.store = store
        self.navigation = navigation
        _tab = .constant(.records)
        _loader = StateObject(wrappedValue: loader)
        _receipt = State(initialValue: receipt)
    }

    var filter: ActionRecordsLoader.Filter { ActionRecordsLoader.Filter(desktopId: desktop, state: result) }

    static let columns: [(String, CGFloat)] = [("时间", 100), ("Desktop / 调用者", 220), ("动作", 220),
                                               ("请求", 170), ("结果", 200)]

    public var body: some View {
        PageContainer(state: pageState, emptyTitle: "还没有动作记录",
                      emptyDetail: "外部 Agent 或主窗口发出的写请求（动作、创建 Desktop 等）被 Runtime 受理后会出现在这里，保留 7 天。",
                      syncedAt: loader.syncedAt, retry: { Task { await loader.reload() } }, header: {
            PageHeader(eyebrow: "Activity / Receipts", title: "动作记录",
                       subtitle: "查看桌面执行事实与回执。这里不判断业务结果，也不代替测试断言。") {
                HStack(spacing: ADSpace.s) {
                    RunsTabBar(tab: $tab)
                    Button { Task { await loader.exportRecords() } } label: {
                        Label(loader.exporting ? "正在导出…" : "导出记录", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ADButtonStyle(.secondary)).disabled(loader.exporting || !connected)
                }
            }
        }) {
            content
        }
        .task(id: store.tick) { await loader.reload() }
        .onChange(of: filter) { f in Task { await loader.apply(f) } }
        .overlay {
            if let id = receipt {
                ReceiptDetailView(runtime: store.runtime, requestId: id,
                                  record: loader.records.first { $0["requestId"]?.stringValue == id },
                                  desktopName: desktopName(loader.records.first { $0["requestId"]?.stringValue == id }),
                                  close: { receipt = nil })
            }
        }
    }

    var connected: Bool { if case .connected = store.connection { return true }; return false }

    var pageState: PageState {
        if case .empty = loader.state, filter != ActionRecordsLoader.Filter() { return .loaded }
        return loader.state
    }

    func desktopName(_ r: JSONValue?) -> String? {
        guard let id = r?["desktopId"] else { return nil }
        return store.desktops.first { $0["desktopId"] == id }?["name"]?.stringValue
    }

    var content: some View {
        let shown = loader.search(query)
        return VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack(spacing: ADSpace.s) {
                RunsFilterMenu(title: "Desktop", options: [(nil, "所有 Desktop")] + store.desktops.map {
                    ($0["desktopId"]?.stringValue, $0["name"]?.stringValue ?? "—")
                }, selection: $desktop)
                RunsFilterMenu(title: "结果", options: [(nil, "所有结果"), ("accepted", "已受理"), ("completed", "已完成"),
                                                      ("failed", "失败或未发出"), ("unknown", "结果未知")], selection: $result)
                Spacer()
                HStack(spacing: ADSpace.s) {
                    Image(systemName: "magnifyingglass").foregroundStyle(ADColor.muted)
                    TextField("搜索动作或 requestId", text: $query).textFieldStyle(.plain).font(ADFont.note)
                }
                .padding(.horizontal, ADSpace.m).frame(width: 290, height: 34)
                .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.panel))
                .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
            }
            exportStatus
            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    ForEach(Self.columns, id: \.0) { c in
                        Text(c.0).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: c.1, alignment: .leading)
                    }
                    Spacer()
                }
                .padding(.horizontal, ADSpace.l).frame(height: 44)
                .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
                if shown.isEmpty {
                    Text(query.isEmpty ? "没有符合条件的记录。" : "已加载的记录里没有匹配「\(query)」的。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted).padding(ADSpace.l)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(shown.indices, id: \.self) { i in row(shown[i]) }
                if loader.next != nil {
                    Button("加载更多") { Task { await loader.loadMore() } }.buttonStyle(ADButtonStyle(.secondary)).padding(ADSpace.m)
                }
            }
            .adPanel()
            Text("「已执行，未验证」只表示输入已投递并完成，不表示目标窗口已变化；业务结果一律未评估。已关闭的 Desktop 仍保留记录；搜索只在已加载的记录中进行。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    var exportStatus: some View {
        if let p = loader.exportProblem {
            Text("导出失败：\(p.title)（\(p.code)）。\(p.advice)").font(ADFont.note).foregroundStyle(StatusTone.danger.foreground)
        } else if let e = loader.export {
            HStack(spacing: ADSpace.m) {
                StateBadge("已导出 \(e.count) 条", tone: .running)
                Text("产物 \(e.artifactId) · \(e.data.count) 字节\(e.truncated ? " · 超过 10000 条，已截断，请缩小筛选" : "")")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
                Spacer()
                Button("保存 JSON…") { RunsSave.save(e.data, name: "agentdesktop-requests.json") }
                    .buttonStyle(ADButtonStyle(.secondary))
            }
            .padding(ADSpace.m).adPanel()
        }
    }

    func row(_ r: JSONValue) -> some View {
        let levels = ActionLevels.record(r)
        let id = r["requestId"]?.stringValue ?? "—"
        return HStack(spacing: 0) {
            Text(TimeText.clock(r["acceptedAt"]?.stringValue)).font(ADFont.code).foregroundStyle(ADColor.ink)
                .frame(width: 100, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(desktopName(r) ?? (r["desktopId"] == nil ? "未指定 Desktop" : "已关闭的 Desktop"))
                    .font(ADFont.noteStrong).foregroundStyle(ADColor.ink).lineLimit(1)
                Text(r["clientId"]?.stringValue ?? "—").font(ADFont.note).foregroundStyle(ADColor.muted).lineLimit(1)
            }.frame(width: 220, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(r["method"]?.stringValue ?? "—").font(ADFont.note).foregroundStyle(ADColor.ink)
                Text(ActionsRecord.detail(r)).font(ADFont.identifier).foregroundStyle(ADColor.muted)
            }.frame(width: 220, alignment: .leading)
            Text(id).font(ADFont.code).foregroundStyle(ADColor.ink).lineLimit(1).frame(width: 170, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                StateBadge(levels.summary)
                if let reason = levels.reasonCode { Text(reason).font(ADFont.identifier).foregroundStyle(ADColor.muted) }
            }.frame(width: 200, alignment: .leading)
            Spacer(minLength: 0)
            Button { receipt = id } label: { Label("详情", systemImage: "chevron.right") }
                .buttonStyle(ADButtonStyle(.secondary)).accessibilityLabel("查看回执 \(id)")
        }
        .padding(.horizontal, ADSpace.l).frame(minHeight: 66)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// One action in a Run's detail: the summary, the three levels each in its
/// own row, the locating IDs and the business result the platform never
/// evaluates. No level offers a retry.
struct RunsReceiptCard: View {
    let entry: ActionEntry
    let open: (() -> Void)?

    var body: some View {
        let l = entry.levels
        VStack(alignment: .leading, spacing: ADSpace.s) {
            HStack(spacing: ADSpace.m) {
                StateBadge(l.summary)
                if let reason = l.reasonText { Text(reason).font(ADFont.note).foregroundStyle(ADColor.ink) }
                Spacer()
                Text(entry.requestId).font(ADFont.code).foregroundStyle(ADColor.muted)
                if let open { Button("回执", action: open).buttonStyle(ADButtonStyle(.secondary)) }
            }
            ActionLevelRows(levels: l)
            LabeledValue(label: "画面 ID", value: entry.receipt?["snapshotId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
            Text(ActionResultPresentation.businessNotEvaluated).font(ADFont.noteStrong).foregroundStyle(ADColor.muted)
            if l.needsReconciliation {
                Text("输入可能已到达应用。不会自动重发；只能重新观察并核实，原记录保持「结果未知」。")
                    .font(ADFont.note).foregroundStyle(StatusTone.attention.foreground).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(ADSpace.l).adPanel()
    }
}

/// 投递 / 执行 / 验证, one row each (§6.4).
struct ActionLevelRows: View {
    let levels: ActionLevels

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.xs) {
            LabeledValue(label: "投递", value: levels.delivery ?? (levels.hasReceipt ? "—" : "尚无回执"), labelWidth: 90)
            LabeledValue(label: "执行", value: levels.execution ?? (levels.hasReceipt ? "—" : "尚无回执"), labelWidth: 90)
            LabeledValue(label: "验证", value: levels.verification ?? (levels.hasReceipt ? "—" : "尚无回执"), labelWidth: 90)
        }
    }
}

/// 动作回执 (P20) over the page: the request record with its receipt, the
/// three levels, the locating IDs and the record as JSON to copy or save.
/// It reads `request.show` itself unless given the record.
struct ReceiptDetailView: View {
    let runtime: RuntimePort
    let requestId: String
    let desktopName: String?
    let close: () -> Void
    @State private var record: JSONValue?
    @State private var problem: RuntimeProblem?

    init(runtime: RuntimePort, requestId: String, record: JSONValue? = nil, desktopName: String?, close: @escaping () -> Void) {
        self.runtime = runtime
        self.requestId = requestId
        self.desktopName = desktopName
        self.close = close
        _record = State(initialValue: record)
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.28).ignoresSafeArea().onTapGesture(perform: close)
            VStack(alignment: .leading, spacing: 0) {
                head
                Divider().overlay(ADColor.line)
                Group {
                    if let record { detail(record) }
                    else if let problem { ProblemView(problem, retry: { Task { await load() } }) }
                    else { ProgressView().frame(maxWidth: .infinity, minHeight: 200) }
                }
                .padding(ADSpace.xl)
                Divider().overlay(ADColor.line)
                HStack {
                    Spacer()
                    Button("关闭", action: close).buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                    Button { if let record { RunsSave.save(Data(ActionsRecord.prettyJSON(record).utf8), name: "\(requestId).json") } } label: {
                        Label("导出 JSON", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(record == nil)
                }
                .padding(ADSpace.l)
            }
            .frame(width: 940)
            .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(ADColor.panel)
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8))
        }
        .task { if record == nil { await load() } }
    }

    func load() async {
        do {
            record = try await runtime.call("request.show", .obj([("requestId", .string(requestId))]))
            problem = nil
        } catch {
            problem = RuntimeProblem(error)
        }
    }

    var head: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("动作回执").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                Text(requestId).font(ADFont.code).foregroundStyle(ADColor.muted)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ADButtonStyle(.quiet)).accessibilityLabel("关闭")
        }
        .padding(ADSpace.xl)
    }

    func detail(_ r: JSONValue) -> some View {
        let receipt = ActionsRecord.receipt(of: r)
        let l = ActionLevels.record(r)
        return HStack(alignment: .top, spacing: ADSpace.xl) {
            VStack(alignment: .leading, spacing: ADSpace.m) {
                HStack {
                    Text("关联画面").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                    Spacer()
                    StateBadge("画面 ID", tone: .idle)
                }
                VStack(spacing: ADSpace.s) {
                    Image(systemName: "photo").font(.system(size: 28)).foregroundStyle(ADColor.muted)
                    Text(receipt?["snapshotId"]?.stringValue ?? "这条记录没有画面").font(ADFont.code).foregroundStyle(ADColor.ink)
                    Text("回执只记录动作时的画面 ID。按画面 ID 取图尚未提供（F1-05），这里不显示示例画面。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted).multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(ADSpace.l).frame(maxWidth: .infinity, minHeight: 200)
                .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(ADColor.canvas))
                .overlay(RoundedRectangle(cornerRadius: ADRadius.panel).stroke(ADColor.line))
                VStack(alignment: .leading, spacing: ADSpace.xs) {
                    LabeledValue(label: "desktopId", value: r["desktopId"]?.stringValue ?? receipt?["desktopId"]?.stringValue ?? "—",
                                 monospaced: true, labelWidth: 90)
                    LabeledValue(label: "runId", value: receipt?["runId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                    LabeledValue(label: "receiptId", value: receipt?["receiptId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                    LabeledValue(label: "route", value: receipt?["route"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                }
            }
            .frame(width: 400)
            VStack(alignment: .leading, spacing: ADSpace.s) {
                LabeledValue(label: "Desktop", value: desktopName ?? (r["desktopId"] == nil ? "未指定" : "已关闭的 Desktop"), labelWidth: 90)
                LabeledValue(label: "调用方", value: r["clientId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                LabeledValue(label: "动作", value: r["method"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                HStack(spacing: ADSpace.m) {
                    Text("结果").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 90, alignment: .leading)
                    StateBadge(l.summary)
                    if let reason = l.reasonText { Text(reason).font(ADFont.note).foregroundStyle(ADColor.ink) }
                }
                ActionLevelRows(levels: l)
                CodeBox(title: receipt != nil ? "RequestRecord · 含 ActionReceipt" : "RequestRecord", code: ActionsRecord.prettyJSON(r))
                    .frame(maxHeight: 300)
                Text(l.hasReceipt ? "回执只说明动作层发生了什么：completed 也不代表业务成功，目标是否变化要由新的观察或调用方自己验证。"
                     : "这条记录没有动作回执。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// Saving a file the user asked for: a save panel, only on their click.
enum RunsSave {
    @MainActor
    static func save(_ data: Data, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? data.write(to: url, options: .atomic)
    }
}
