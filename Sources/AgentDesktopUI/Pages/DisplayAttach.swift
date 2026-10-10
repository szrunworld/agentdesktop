import AgentDesktopProtocol
import SwiftUI

/// The owner's entry for opening one of the user's displays to a paired
/// app (docs/security/owner-display-attach.md, Kevin's ruling of
/// 2026-10-10): list the displays with the origin the Runtime proved, pick
/// a display and an app, and ask the Runtime (hub.displays.attach). The
/// user then confirms in the trusted window with Touch ID; the window only
/// shows what the Runtime answered. Opening a display gives the app no
/// window: each one still needs its own grant.
@MainActor
public final class AttachDisplayFlow: ObservableObject {
    public typealias StepState = CreateDesktopFlow.StepState

    @Published public private(set) var displays: [JSONValue] = []
    @Published public private(set) var clients: [JSONValue] = []
    @Published public private(set) var loadProblem: RuntimeProblem?
    @Published public var displayId: Int?
    @Published public var clientId: String?
    @Published public var name = ""
    @Published public private(set) var step: StepState = .pending
    @Published public private(set) var result: JSONValue?

    private let runtime: RuntimePort

    public init(runtime: RuntimePort) { self.runtime = runtime }

    public var started: Bool { step != .pending }
    public var isDone: Bool { step == .done }
    public var desktopId: String? { result?["desktop"]?["desktopId"]?.stringValue }
    public var canSubmit: Bool {
        guard step == .pending, let displayId, clientId != nil else { return false }
        return displays.first { $0["displayId"]?.intValue == displayId }.map(Self.attachable) ?? false
    }

    /// Only a display the Runtime proved physical and has not attached yet.
    public static func attachable(_ d: JSONValue) -> Bool { d["attachable"]?.boolValue == true }

    /// The origin as the Runtime proved it, in the user's words.
    public static func originText(_ d: JSONValue) -> StatusText {
        if d["desktopId"]?.stringValue != nil { return StatusText("已挂接", .idle) }
        switch d["origin"]?.stringValue {
        case "physical": return StatusText("已证实为物理显示器", .running)
        case "virtual": return StatusText("虚拟显示器，不可开放", .danger)
        default: return StatusText("来源未证实，不可开放", .attention)
        }
    }

    public static func sizeText(_ d: JSONValue) -> String {
        let f = d["frame"]
        let w = Int(f?["width"]?.doubleValue ?? 0), h = Int(f?["height"]?.doubleValue ?? 0)
        return "\(w) × \(h) 点\(d["hiDPI"]?.boolValue == true ? " · HiDPI" : "")\(d["builtin"]?.boolValue == true ? " · 内建" : " · 外接")"
    }

    /// Paired apps with an active grant: the only ones a display can be opened to.
    public static func openable(_ clients: [JSONValue]) -> [JSONValue] {
        clients.filter { $0["state"]?.stringValue == "active" && $0["grant"]?["state"]?.stringValue == "active" }
    }

    public func load() async {
        do {
            let d = try await runtime.call("hub.displays.list")
            let c = try await runtime.call("hub.clients.list")
            displays = d["displays"]?.arrayValue ?? []
            clients = Self.openable(c["clients"]?.arrayValue ?? [])
            if displayId == nil, let first = displays.first(where: Self.attachable) { displayId = first["displayId"]?.intValue }
            if clientId == nil, clients.count == 1 { clientId = clients[0]["clientId"]?.stringValue }
            loadProblem = nil
        } catch {
            loadProblem = RuntimeProblem(error)
        }
    }

    public func submit() async {
        guard canSubmit, let displayId, let clientId else { return }
        step = .running
        var params: [(String, JSONValue)] = [("displayId", .int(displayId)), ("clientId", .string(clientId))]
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { params.append(("name", .string(String(trimmed.prefix(64))))) }
        do {
            result = try await runtime.call("hub.displays.attach", .obj(params))
            step = .done
        } catch {
            step = .failed(RuntimeProblem(error))
        }
    }

    /// Back to the form after a refusal (the user said no, or the Runtime did).
    public func reset() {
        step = .pending
        result = nil
    }
}

/// The attach sheet: the form, then the Runtime's answer.
public struct AttachDisplaySheet: View {
    @ObservedObject var flow: AttachDisplayFlow
    let cancel: () -> Void
    let finished: (String) -> Void

    public init(flow: AttachDisplayFlow, cancel: @escaping () -> Void, finished: @escaping (String) -> Void) {
        self.flow = flow
        self.cancel = cancel
        self.finished = finished
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            Text(flow.started ? "正在开放显示器" : "把我的显示器开放给一个程序").font(ADFont.sectionTitle).foregroundStyle(ADColor.ink)
            if flow.started { progress } else { form }
        }
        .padding(ADSpace.xl)
        .frame(width: 600)
        .background(ADColor.panel)
        .task { await flow.load() }
    }

    var form: some View {
        VStack(alignment: .leading, spacing: ADSpace.l) {
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("显示器（只有系统证实为物理显示器的才能开放）").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                if flow.displays.isEmpty, flow.loadProblem == nil {
                    Text("没有读到任何显示器。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                VStack(spacing: 0) {
                    ForEach(flow.displays.indices, id: \.self) { i in displayRow(flow.displays[i]) }
                }
                .adPanel()
            }
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("开放给哪个已配对的程序").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                if flow.clients.isEmpty {
                    Text("没有已配对、授权有效的程序。程序先在 Agents 中配对，才能开放显示器给它。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted)
                } else {
                    Picker("程序", selection: Binding(get: { flow.clientId ?? "" }, set: { flow.clientId = $0.isEmpty ? nil : $0 })) {
                        Text("请选择").tag("")
                        ForEach(flow.clients.indices, id: \.self) { i in
                            let c = flow.clients[i]
                            Text("\(c["agentName"]?.stringValue ?? "—")（\(c["clientId"]?.stringValue ?? "")）")
                                .tag(c["clientId"]?.stringValue ?? "")
                        }
                    }
                    .labelsHidden().frame(width: 360)
                    if let c = flow.clients.first(where: { $0["clientId"]?.stringValue == flow.clientId }) {
                        let apps = (c["grant"]?["apps"]?.arrayValue ?? []).compactMap(\.stringValue)
                        Text("它可申请的 App：" + (apps.isEmpty ? "无（没有 App 就申请不了任何窗口）" : apps.joined(separator: "、")))
                            .font(ADFont.note).foregroundStyle(ADColor.muted)
                    }
                }
            }
            VStack(alignment: .leading, spacing: ADSpace.xs) {
                Text("Desktop 名称（可选）").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                TextField("默认用显示器的名称", text: $flow.name).textFieldStyle(.roundedBorder).frame(width: 360)
            }
            if let p = flow.loadProblem { ProblemView(p, retry: { Task { await flow.load() } }) }
            Text("开放后，这个程序看不到显示器上的任何窗口：每一个窗口都要再经你用 Touch ID 单独授权（查看 / 操作 / 保存分开）。不会创建或移动任何东西。点「开放…」后，系统会要求你用 Touch ID 或登录密码确认。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("取消", action: cancel).buttonStyle(ADButtonStyle(.secondary)).keyboardShortcut(.cancelAction)
                Button("开放…") { Task { await flow.submit() } }.buttonStyle(ADButtonStyle(.primary))
                    .disabled(!flow.canSubmit).keyboardShortcut(.defaultAction)
            }
        }
    }

    func displayRow(_ d: JSONValue) -> some View {
        let id = d["displayId"]?.intValue ?? -1
        let on = flow.displayId == id
        let usable = AttachDisplayFlow.attachable(d)
        return Button { if usable { flow.displayId = id } } label: {
            HStack(spacing: ADSpace.m) {
                Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? ADColor.primary : ADColor.muted)
                VStack(alignment: .leading, spacing: 2) {
                    Text(d["name"]?.stringValue ?? "—").font(ADFont.noteStrong).foregroundStyle(usable ? ADColor.ink : ADColor.muted)
                    Text("编号 \(id) · " + AttachDisplayFlow.sizeText(d)).font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    if let why = d["originDetail"]?.stringValue {
                        Text(why).font(ADFont.identifier).foregroundStyle(ADColor.muted).lineLimit(2)
                    }
                }
                Spacer()
                StateBadge(AttachDisplayFlow.originText(d))
            }
            .padding(.horizontal, ADSpace.m).padding(.vertical, ADSpace.s).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!usable)
        .accessibilityLabel("显示器 \(d["name"]?.stringValue ?? "") \(AttachDisplayFlow.originText(d).text)")
    }

    var progress: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack(spacing: ADSpace.s) {
                stepIcon(flow.step)
                Text("开放显示器并写入授权").font(ADFont.body).foregroundStyle(ADColor.ink)
            }
            switch flow.step {
            case .running:
                Text("等待你在系统提示里用 Touch ID 或登录密码确认。不确认，或点「拒绝」，就什么都不会开放。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
            case .done:
                if let r = flow.result {
                    LabeledValue(label: "Desktop", value: "\(r["desktop"]?["name"]?.stringValue ?? "—")（\(flow.desktopId ?? "—")，物理）", labelWidth: 100)
                    LabeledValue(label: "开放给", value: r["grant"]?["clientId"]?.stringValue ?? "—", monospaced: true, labelWidth: 100)
                    LabeledValue(label: "授权版本", value: r["grant"]?["revision"]?.intValue.map(String.init) ?? "—", labelWidth: 100)
                    Text(r["created"]?.boolValue == true ? "已把这块显示器作为新的物理 Desktop。" : "这块显示器已经是物理 Desktop，这次只是开放给这个程序。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted)
                    Text("它现在还看不到任何窗口；它申请某个窗口时，你会再收到一次确认。").font(ADFont.note).foregroundStyle(ADColor.muted)
                }
            case let .failed(p):
                ProblemView(p)
            case .pending, .skipped:
                EmptyView()
            }
            HStack {
                Spacer()
                if flow.isDone {
                    Button("完成") { finished(flow.desktopId ?? "") }.buttonStyle(ADButtonStyle(.primary)).keyboardShortcut(.defaultAction)
                } else if case .failed = flow.step {
                    Button("关闭", action: cancel).buttonStyle(ADButtonStyle(.secondary))
                    Button("返回修改") { flow.reset() }.buttonStyle(ADButtonStyle(.primary))
                }
            }
        }
    }

    @ViewBuilder
    func stepIcon(_ s: AttachDisplayFlow.StepState) -> some View {
        switch s {
        case .running: ProgressView().controlSize(.small)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(StatusTone.running.foreground)
        case .failed: Image(systemName: "xmark.circle.fill").foregroundStyle(StatusTone.danger.foreground)
        case .pending, .skipped: Image(systemName: "circle").foregroundStyle(ADColor.muted)
        }
    }
}

/// Which paired apps a physical Desktop is open to (hub.grants.list), and
/// the owner's way to take it back (hub.displays.detach).
@MainActor
public final class PhysicalDesktopAccess: ObservableObject {
    @Published public private(set) var grants: [JSONValue] = []
    @Published public private(set) var problem: RuntimeProblem?
    @Published public private(set) var working = false
    @Published public private(set) var detachedAll = false

    public let desktopId: String
    private let runtime: RuntimePort

    public init(runtime: RuntimePort, desktopId: String) {
        self.runtime = runtime
        self.desktopId = desktopId
    }

    public func load() async {
        do {
            let r = try await runtime.call("hub.grants.list")
            grants = (r["grants"]?.arrayValue ?? []).filter { ($0["desktops"]?.arrayValue ?? []).contains(.string(desktopId)) }
            problem = nil
        } catch {
            problem = RuntimeProblem(error)
        }
    }

    /// Take the Desktop back from one app, or from every app (and drop it).
    public func detach(clientId: String?) async {
        working = true
        defer { working = false }
        var p: [(String, JSONValue)] = [("desktopId", .string(desktopId))]
        if let clientId { p.append(("clientId", .string(clientId))) }
        do {
            let r = try await runtime.call("hub.displays.detach", .obj(p))
            detachedAll = r["destroyed"]?.boolValue == true
            problem = nil
            await load()
        } catch {
            problem = RuntimeProblem(error)
        }
    }
}

/// The panel on a physical Desktop's detail: who it is open to.
public struct PhysicalDesktopAccessView: View {
    @ObservedObject var access: PhysicalDesktopAccess
    /// Called once the Desktop was detached from everyone (it is gone).
    let gone: () -> Void

    public init(access: PhysicalDesktopAccess, gone: @escaping () -> Void) {
        self.access = access
        self.gone = gone
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: ADSpace.m) {
            HStack {
                Text("开放给的程序").font(ADFont.bodyStrong).foregroundStyle(ADColor.ink)
                Spacer()
                Button {
                    Task { await access.detach(clientId: nil); if access.detachedAll { gone() } }
                } label: { Label("全部收回并解除挂接", systemImage: "xmark.circle") }
                    .buttonStyle(ADButtonStyle(.danger)).disabled(access.working)
            }
            Text("这是你自己的显示器。开放只让程序申请这里的窗口；每个窗口仍要你单独授权。收回后它在这里的窗口授权立即结束。")
                .font(ADFont.note).foregroundStyle(ADColor.muted).fixedSize(horizontal: false, vertical: true)
            if let p = access.problem { ProblemView(p) }
            if access.grants.isEmpty {
                Text("没有程序被开放这块显示器。").font(ADFont.note).foregroundStyle(ADColor.muted)
            }
            ForEach(access.grants.indices, id: \.self) { i in
                let g = access.grants[i]
                let id = g["clientId"]?.stringValue ?? ""
                HStack(spacing: ADSpace.m) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(id).font(ADFont.code).foregroundStyle(ADColor.ink)
                        Text("App：" + ((g["apps"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: "、").nilIfEmpty ?? "无")
                             + " · 到期 \(g["expiresAt"]?.stringValue ?? "—")")
                            .font(ADFont.identifier).foregroundStyle(ADColor.muted)
                    }
                    Spacer()
                    Button("收回") { Task { await access.detach(clientId: id) } }
                        .buttonStyle(ADButtonStyle(.secondary)).disabled(access.working)
                        .accessibilityLabel("收回 \(id) 对这个 Desktop 的访问")
                }
                .padding(.vertical, ADSpace.xs)
                .overlay(alignment: .top) { Rectangle().fill(ADColor.line).frame(height: 1) }
            }
        }
        .padding(ADSpace.l)
        .adPanel()
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
