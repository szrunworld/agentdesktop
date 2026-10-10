import AgentDesktopProtocol
import SwiftUI

// U3 views: the control banner (P13–P17), the stop / takeover / handback
// answers, the takeover confirmation (P12), the close plan (P18), the
// unknown-result review (P17) and the apps-and-size panel (app.quit,
// desktop.resize). Each shows a runtime/1 answer as given.

/// A dimmed backdrop with a centred panel inside the main window.
struct DesktopModal<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea().accessibilityHidden(true)
            content
                .background(ADColor.panel)
                .clipShape(RoundedRectangle(cornerRadius: ADRadius.panel))
                .shadow(color: .black.opacity(0.18), radius: 24, y: 8)
        }
    }
}

/// Title row of a control dialog with its close button.
struct DialogHeader: View {
    let title: String
    let subtitle: String
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
                Text(subtitle).font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            Spacer()
            Button(action: close) { Image(systemName: "xmark") }.buttonStyle(ADButtonStyle(.quiet))
                .accessibilityLabel("关闭对话框")
        }
        .padding(ADSpace.xl)
        .overlay(alignment: .bottom) { Rectangle().fill(ADColor.line).frame(height: 1) }
    }
}

/// A notice strip: title, detail, optional action on the right.
struct ControlNotice: View {
    let title: String
    let detail: String
    let tone: StatusTone
    var code: String?
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        HStack(alignment: .top, spacing: ADSpace.m) {
            Image(systemName: tone == .idle ? "lightbulb" : (tone == .danger ? "xmark.octagon" : "exclamationmark.triangle.fill"))
                .foregroundStyle(tone.foreground)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(ADFont.bodyStrong).foregroundStyle(tone == .idle ? ADColor.ink : tone.foreground)
                Text(detail).font(ADFont.note).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
                if let code, !code.isEmpty { Text(code).font(ADFont.identifier).foregroundStyle(ADColor.muted) }
            }
            Spacer()
            if let actionTitle {
                Button(actionTitle) { action?() }.buttonStyle(ADButtonStyle(.secondary)).disabled(action == nil)
            }
        }
        .padding(ADSpace.l)
        .background(RoundedRectangle(cornerRadius: ADRadius.panel).fill(tone == .idle ? ADColor.panel : tone.background.opacity(0.6)))
        .overlay(RoundedRectangle(cornerRadius: ADRadius.panel).stroke(tone == .idle ? ADColor.line : tone.foreground.opacity(0.35)))
        .accessibilityElement(children: .combine)
    }
}

/// What the owner's last control action got back, above the picture.
struct DesktopControlAnswers: View {
    @ObservedObject var flow: DesktopControlFlow
    let takeoverAgain: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.s) {
            if let t = flow.stopText {
                ControlNotice(title: t.title, detail: t.detail, tone: flow.stopProgress == .none ? .idle
                              : { if case .accepted = flow.stopProgress { return .attention }; return .idle }())
            }
            if let a = flow.takeoverAnswer, let t = DesktopControlFlow.takeoverText(a) {
                let pending: Bool = { if case .stopPending = a { return true }; return false }()
                ControlNotice(title: t.title, detail: t.detail + (pending && flow.holderQuiescent ? " 运行已静止，可以再次接管。" : ""),
                              tone: .attention, code: t.code,
                              actionTitle: pending ? "再次接管" : nil, action: pending ? takeoverAgain : nil)
            }
            if let t = flow.handbackText { ControlNotice(title: t.title, detail: t.detail, tone: .idle) }
            if let r = flow.resized {
                ControlNotice(title: "尺寸已改为 \(DesktopControlPresentation.sizeText(r))",
                              detail: "这个 Desktop 之前的观察都已失效：Agent 需要重新观察后才能继续动作。", tone: .idle)
            }
            ForEach([DesktopControlFlow.Operation.stop, .handback, .resize], id: \.self) { op in
                if let p = flow.problems[op] { ProblemView(p) }
            }
        }
    }
}

/// P12: confirm a takeover. Agents' input stops first; the Desktop is
/// handed to the user only once nothing of their Run is in flight.
struct TakeoverDialog: View {
    @ObservedObject var flow: DesktopControlFlow
    let name: String
    let info: DesktopControlInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "接管这个 Desktop", subtitle: name, close: { flow.dialog = nil })
            VStack(alignment: .leading, spacing: ADSpace.l) {
                HStack(spacing: ADSpace.m) {
                    Image(systemName: "point.3.connected.trianglepath.dotted").foregroundStyle(ADColor.ink)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(info.controller).font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                        Text(info.state == "running" ? "当前正在发送输入" : "当前状态：\(info.status.text)")
                            .font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                    Spacer()
                    StateBadge(info.status)
                }
                .padding(ADSpace.l)
                .background(RoundedRectangle(cornerRadius: ADRadius.button).fill(ADColor.selected.opacity(0.5)))
                .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
                Text("先停止 Agent 的输入，等在途动作得到确认，再把这个 Desktop 的控制权交给你。")
                    .font(ADFont.body).foregroundStyle(ADColor.ink).fixedSize(horizontal: false, vertical: true)
                Text("其他 Desktop 不受影响。接管期间外部 Agent 的动作会被拒绝；完成后可交还控制，Agent 需要从新的观察继续，不重放旧队列。")
                    .font(ADFont.note).foregroundStyle(ADColor.primary).fixedSize(horizontal: false, vertical: true)
                if flow.working == .takeover {
                    HStack(spacing: ADSpace.s) {
                        ProgressView().controlSize(.small)
                        Text("正在停止 Agent 的输入并等待确认…").font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                }
                if let a = flow.takeoverAnswer, let t = DesktopControlFlow.takeoverText(a) {
                    ControlNotice(title: t.title, detail: t.detail, tone: .attention, code: t.code)
                }
            }
            .padding(ADSpace.xl)
            HStack {
                Spacer()
                Button("保留 Agent 控制") { flow.dialog = nil }.buttonStyle(ADButtonStyle(.secondary))
                    .keyboardShortcut(.cancelAction)
                Button { Task { await flow.takeover() } } label: { Label(takeoverTitle, systemImage: "computermouse") }
                    .buttonStyle(ADButtonStyle(.primary)).disabled(flow.working != nil)
            }
            .padding(ADSpace.xl)
            .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
        }
        .frame(width: 520)
    }

    var takeoverTitle: String {
        if case .stopPending = flow.takeoverAnswer { return "再次接管" }
        return "停止并接管"
    }
}

/// P18: what closing would end and keep, from desktop.closePlan. Closing
/// is offered only when the plan says it can close; a Run that blocks it
/// is stopped first and the plan read again.
struct CloseDesktopDialog: View {
    @ObservedObject var flow: DesktopControlFlow
    let name: String
    let info: DesktopControlInfo

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "关闭 Desktop?", subtitle: "\(name) · \(flow.desktopId)", close: { flow.dialog = nil })
            VStack(alignment: .leading, spacing: ADSpace.m) {
                row("当前状态") { StateBadge(info.status) }
                row("连接者") { Text(info.controller).font(ADFont.note).foregroundStyle(ADColor.ink) }
                if let plan = flow.closePlan {
                    planRows(plan)
                } else if flow.working == .closePlan {
                    HStack(spacing: ADSpace.s) { ProgressView().controlSize(.small); Text("正在读取关闭计划…").font(ADFont.note) }
                }
                if let p = flow.problems[.closePlan] { ProblemView(p) }
                if let p = flow.problems[.close] { ProblemView(p) }
                if let p = flow.problems[.stop] { ProblemView(p) }
                if let t = flow.stopText { ControlNotice(title: t.title, detail: t.detail, tone: .attention) }
                Rectangle().fill(ADColor.line).frame(height: 1)
                Text("关闭前会先停止输入并等待确认。其他 Desktop 继续运行。此操作不撤回已经发生的业务动作；截图、动作记录和运行记录保留。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            }
            .padding(ADSpace.xl)
            HStack {
                Spacer()
                Button("取消") { flow.dialog = nil }.buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                if Self.runBlocks(flow.closePlan) {
                    Button { Task { await flow.stopBeforeClose() } } label: { Label("先停止输入", systemImage: "stop.fill") }
                        .buttonStyle(ADButtonStyle(.danger)).disabled(flow.working != nil || stopWaiting)
                }
                Button { Task { await flow.close() } } label: { Label("关闭 Desktop", systemImage: "xmark") }
                    .buttonStyle(ADButtonStyle(.danger))
                    .disabled(flow.closePlan?["canClose"]?.boolValue != true || flow.working != nil)
            }
            .padding(ADSpace.xl)
            .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
        }
        .frame(width: 560)
    }

    var stopWaiting: Bool { if case .accepted = flow.stopProgress { return true }; return false }

    static func runBlocks(_ plan: JSONValue?) -> Bool {
        (plan?["blockers"]?.arrayValue ?? []).contains { $0["kind"]?.stringValue == "run" }
    }

    /// The plan in words (also used by tests).
    static func lines(_ plan: JSONValue) -> [(String, String)] {
        var out: [(String, String)] = []
        let physical = plan["display"]?.stringValue == "kept"
        out.append(("将释放", physical ? "这个 Desktop 的记录与输入入口；显示器是你的，保留不动" : "虚拟显示器、目标绑定和该 Desktop 的输入入口"))
        let quit = plan["quit"]?.arrayValue ?? []
        out.append(("将退出", quit.isEmpty ? "没有（这个 Desktop 没有启动仍在运行的应用）"
                    : quit.map(Self.processName).joined(separator: "、") + "（由这个 Desktop 启动）"))
        let keep = plan["keep"]?.arrayValue ?? []
        out.append(("应用处理", keep.isEmpty ? "没有其他应用的窗口在这里"
                    : keep.map(Self.processName).joined(separator: "、") + "：归还宿主共享窗口，不退出应用"))
        out.append(("将保留", "截图、动作记录和运行记录"))
        for b in plan["blockers"]?.arrayValue ?? [] {
            if b["kind"]?.stringValue == "run" {
                out.append(("阻止关闭", "运行 \(b["runId"]?.stringValue ?? "—")（\(RunStatusPresentation.originText(b["origin"]?.stringValue))）仍持有这个 Desktop：先停止输入"))
            } else {
                out.append(("阻止关闭", "还有 \(b["count"]?.intValue ?? 0) 个打开的会话：等调用方关闭会话后再关闭"))
            }
        }
        return out
    }

    static func processName(_ p: JSONValue) -> String {
        "\(p["appName"]?.stringValue ?? "未知应用")（pid \(p["process"]?["pid"]?.intValue ?? 0)）"
    }

    @ViewBuilder func planRows(_ plan: JSONValue) -> some View {
        ForEach(Array(Self.lines(plan).enumerated()), id: \.offset) { _, line in
            row(line.0) {
                Text(line.1).font(ADFont.note).foregroundStyle(line.0 == "阻止关闭" ? StatusTone.danger.foreground : ADColor.ink)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    func row<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(alignment: .top) {
            Text(label).font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 90, alignment: .leading)
            value()
            Spacer(minLength: 0)
        }
    }
}

/// P17: review an action whose result is unknown. No retry exists; ending
/// is closed until the Desktop has been observed again.
struct UnknownResultDialog: View {
    @ObservedObject var review: UnknownResultReview
    @ObservedObject var flow: DesktopControlFlow
    let name: String
    let canEndHere: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DialogHeader(title: "核对动作结果", subtitle: "\(name) · 结果未知", close: { flow.dialog = nil })
            VStack(alignment: .leading, spacing: ADSpace.l) {
                ControlNotice(title: "不要自动重复这次动作",
                              detail: "请求超时不代表应用没有收到输入。原始回执保持 unknown，新的观察不会改变它。", tone: .attention)
                HStack(alignment: .top, spacing: ADSpace.l) {
                    picture.frame(width: 320, height: 200)
                        .background(ADColor.canvas)
                        .overlay(RoundedRectangle(cornerRadius: ADRadius.button).stroke(ADColor.line))
                    VStack(alignment: .leading, spacing: ADSpace.s) {
                        LabeledValue(label: "请求", value: review.entry.requestId, monospaced: true, labelWidth: 90)
                        LabeledValue(label: "运行", value: review.entry.runId, monospaced: true, labelWidth: 90)
                        HStack {
                            Text("结果").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 90, alignment: .leading)
                            StateBadge(review.entry.presentation.status)
                        }
                        LabeledValue(label: "原始画面", value: review.entry.receipt?["snapshotId"]?.stringValue ?? "—", monospaced: true, labelWidth: 90)
                        LabeledValue(label: "新画面", value: review.observation?["snapshotId"]?.stringValue ?? "尚未观察", monospaced: true, labelWidth: 90)
                        LabeledValue(label: "重试", value: "不会自动发起", labelWidth: 90)
                        Button { Task { await review.reobserve() } } label: {
                            Label(review.observing ? "正在观察…" : "重新观察", systemImage: "arrow.clockwise").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(review.observing)
                    }
                }
                if let p = review.problem { ProblemView(p) }
                if let p = flow.problems[.handback] { ProblemView(p) }
                if let r = review.runAfter {
                    Text("已结束：运行 \(review.entry.runId) 的结果仍为 \(r["outcome"]?.stringValue ?? "—")，原始记录保留。")
                        .font(ADFont.note).foregroundStyle(ADColor.ink)
                }
                Text(canEndHere ? "先读取新画面，再检查是否产生预期变化。" : "这个动作所在的运行仍在进行，结束要在它结束后进行。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            .padding(ADSpace.xl)
            HStack {
                Text("保留未知，不补写业务结论").font(ADFont.note).foregroundStyle(ADColor.muted)
                Spacer()
                Button("稍后处理") { flow.dialog = nil }.buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button {
                    Task {
                        await flow.handback()
                        await review.ended()
                    }
                } label: { Label("结束连接并保留记录", systemImage: "stop") }
                    .buttonStyle(ADButtonStyle(.primary))
                    .disabled(!review.canEnd || !canEndHere || flow.working != nil)
                    .help(review.canEnd ? "" : "先重新观察，才能结束")
            }
            .padding(ADSpace.xl)
            .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
        }
        .frame(width: 720)
    }

    @ViewBuilder var picture: some View {
        if let img = review.image {
            Image(decorative: img, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(ADSpace.xs)
        } else {
            Text(review.observing ? "正在观察…" : "还没有新的观察").font(ADFont.note).foregroundStyle(ADColor.muted)
        }
    }
}

/// Right column below the connection panel: apps this Desktop launched
/// (app.quit ends only those), apps that only lent a window (never quit),
/// and the size (desktop.resize, virtual Desktops only).
struct DesktopManagePanel: View {
    @ObservedObject var flow: DesktopControlFlow
    let desktop: JSONValue
    let methods: DesktopControlMethods
    @State private var size = ""

    var isPhysical: Bool { desktop["kind"]?.stringValue == "physical" }

    var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack {
                Text("应用与尺寸").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                Button("刷新") { Task { await flow.loadClosePlan() } }.buttonStyle(ADButtonStyle(.quiet))
                    .disabled(!methods.has("desktop.closePlan") || flow.working != nil)
            }
            if !methods.has("desktop.closePlan") {
                Text(DesktopControlMethods.missing("desktop.closePlan")).font(ADFont.note).foregroundStyle(ADColor.muted)
            } else if let plan = flow.closePlan {
                let quit = plan["quit"]?.arrayValue ?? []
                let keep = plan["keep"]?.arrayValue ?? []
                if quit.isEmpty && keep.isEmpty {
                    Text("这个 Desktop 上没有应用窗口。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                ForEach(quit.indices, id: \.self) { i in
                    let pid = quit[i]["process"]?["pid"]?.intValue ?? 0
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(CloseDesktopDialog.processName(quit[i])).font(ADFont.note).foregroundStyle(ADColor.ink)
                            Text(flow.quitAnswers[pid].map(DesktopControlFlow.quitText) ?? "由这个 Desktop 启动")
                                .font(ADFont.identifier).foregroundStyle(ADColor.muted)
                        }
                        Spacer()
                        Button("退出") { Task { await flow.quit(pid: pid) } }.buttonStyle(ADButtonStyle(.secondary))
                            .disabled(!methods.has("app.quit") || flow.working != nil)
                            .help(methods.has("app.quit") ? "只结束这个 Desktop 启动的进程" : DesktopControlMethods.missing("app.quit"))
                    }
                }
                ForEach(keep.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(CloseDesktopDialog.processName(keep[i])).font(ADFont.note).foregroundStyle(ADColor.ink)
                        Text(keep[i]["reason"]?.stringValue == "physical_desktop" ? "物理 Desktop 上的应用：不会退出" : "宿主共享应用：只借用窗口，不会退出")
                            .font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
                ForEach(Array(flow.quitAnswers.keys.sorted()), id: \.self) { pid in
                    if !quit.contains(where: { $0["process"]?["pid"]?.intValue == pid }), let a = flow.quitAnswers[pid] {
                        Text("pid \(pid)：\(DesktopControlFlow.quitText(a))").font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                }
            }
            if let p = flow.problems[.quit] { ProblemView(p) }
            Rectangle().fill(ADColor.line).frame(height: 1)
            HStack {
                Text("尺寸").font(ADFont.note).foregroundStyle(ADColor.muted).frame(width: 50, alignment: .leading)
                Text(DesktopControlPresentation.sizeText(desktop)).font(ADFont.identifier).foregroundStyle(ADColor.ink)
                Spacer()
                Menu("调整") {
                    ForEach(CreateDesktopFlow.sizes, id: \.0) { s in
                        Button(s.0) { Task { await flow.resize(width: s.1, height: s.2) } }
                    }
                }
                .frame(width: 90)
                .disabled(isPhysical || !methods.has("desktop.resize") || flow.working != nil)
                .help(isPhysical ? "物理 Desktop 的显示器是你的，尺寸不变" : (methods.has("desktop.resize") ? "调整后之前的观察失效" : DesktopControlMethods.missing("desktop.resize")))
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }
}
