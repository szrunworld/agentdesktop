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
    private let now: () -> Date

    public init(runtime: RuntimePort, now: @escaping () -> Date = Date.init) { self.runtime = runtime; self.now = now }

    public var started: Bool { step != .pending }
    public var isDone: Bool { step == .done }
    public var desktopId: String? { result?["desktop"]?["desktopId"]?.stringValue }
    public var canSubmit: Bool {
        guard step == .pending, let displayId, let clientId, Self.openable(clients, now: now()).contains(where: { $0["clientId"]?.stringValue == clientId }) else { return false }
        return displays.first { $0["displayId"]?.intValue == displayId }.map(Self.openable) ?? false
    }

    /// A display the owner can open to an app: proved physical, whether
    /// not attached yet or already attached (the Desktop is then shared,
    /// `created: false`; Codex on a6a9088).
    public static func openable(_ d: JSONValue) -> Bool {
        d["attachable"]?.boolValue == true || (d["origin"]?.stringValue == "physical" && d["desktopId"]?.stringValue != nil)
    }

    /// Only a display the Runtime proved physical and has not attached yet.
    public static func attachable(_ d: JSONValue) -> Bool { d["attachable"]?.boolValue == true }

    /// The origin as the Runtime proved it, in the user's words.
    public static func originText(_ d: JSONValue) -> StatusText {
        if d["desktopId"]?.stringValue != nil { return StatusText("已挂接，可再开放给其他程序", .idle) }
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
    public static func openable(_ clients: [JSONValue], now: Date = Date()) -> [JSONValue] {
        clients.filter { client in
            guard client["state"]?.stringValue == "active", client["grant"]?["state"]?.stringValue == "active",
                  let expiry = client["grant"]?["expiresAt"]?.stringValue.flatMap(Timestamp.date) else { return false }
            return expiry > now
        }
    }

    public func load() async {
        do {
            let d = try await runtime.call("hub.displays.list")
            let c = try await runtime.call("hub.clients.list")
            displays = d["displays"]?.arrayValue ?? []
            clients = Self.openable(c["clients"]?.arrayValue ?? [], now: now())
            if displayId == nil, let first = displays.first(where: Self.attachable) ?? displays.first(where: Self.openable) {
                displayId = first["displayId"]?.intValue
            }
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
                Text("显示器（只有系统证实为物理显示器的才能开放；已挂接的可以再开放给另一个程序，共用同一个 Desktop）").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
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
        let usable = AttachDisplayFlow.openable(d)
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
    @Published public private(set) var windows: [JSONValue] = []
    @Published public private(set) var windowGrants: [JSONValue] = []
    @Published public var selectedWindowId: Int?
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
            let apps = Set(grants.flatMap { ($0["apps"]?.arrayValue ?? []).compactMap(\.stringValue) })
            let desktop = try await runtime.call("desktop.show", .obj([("desktopId", .string(desktopId))]))
            let displayFrame = desktop["screen"]?["frame"]
            let listed = try await runtime.call("window.list")
            windows = (listed["windows"]?.arrayValue ?? []).filter {
                $0["onScreen"]?.boolValue == true && $0["bundleId"]?.stringValue.map(apps.contains) == true
                    && Self.isCentered($0["frame"], within: displayFrame)
            }
            if let selectedWindowId, !windows.contains(where: { $0["windowId"]?.intValue == selectedWindowId }) {
                self.selectedWindowId = nil
            }
            let granted = try await runtime.call("hub.windows.list")
            windowGrants = (granted["windowGrants"]?.arrayValue ?? []).filter { $0["desktopId"]?.stringValue == desktopId }
            problem = nil
        } catch {
            problem = RuntimeProblem(error)
        }
    }

    /// Match the Runtime's physical window binding rule: the window's center
    /// must already lie within the display frame in global points.
    static func isCentered(_ window: JSONValue?, within display: JSONValue?) -> Bool {
        guard let wx = window?["x"]?.doubleValue, let wy = window?["y"]?.doubleValue,
              let ww = window?["width"]?.doubleValue, let wh = window?["height"]?.doubleValue,
              let dx = display?["x"]?.doubleValue, let dy = display?["y"]?.doubleValue,
              let dw = display?["width"]?.doubleValue, let dh = display?["height"]?.doubleValue else { return false }
        let x = wx + ww / 2, y = wy + wh / 2
        return x >= dx && x < dx + dw && y >= dy && y < dy + dh
    }

    /// Bind one window already on this physical display. The Runtime checks
    /// its exact window ID and location; no user window is moved.
    @discardableResult
    public func bindSelectedWindow() async -> Bool {
        guard let w = windows.first(where: { $0["windowId"]?.intValue == selectedWindowId }),
              let pid = w["process"]?["pid"]?.intValue, let windowId = w["windowId"]?.intValue else { return false }
        working = true
        defer { working = false }
        do {
            _ = try await runtime.call("window.bind", .obj([
                ("desktopId", .string(desktopId)), ("pid", .int(pid)), ("windowId", .int(windowId)),
            ]))
            problem = nil
            await load()
            return true
        } catch {
            problem = RuntimeProblem(error)
            return false
        }
    }

    /// Owner withdrawal of one window's grant. Runtime confirmation and
    /// connection cutoff are the same as for any hub.windows.revoke call.
    public func revokeWindow(_ id: String) async {
        guard windowGrants.contains(where: { $0["windowGrantId"]?.stringValue == id }) else { return }
        working = true
        defer { working = false }
        do {
            _ = try await runtime.call("hub.windows.revoke", .obj([("windowGrantId", .string(id))]))
            problem = nil
            await load()
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
    let bound: () -> Void

    public init(access: PhysicalDesktopAccess, gone: @escaping () -> Void, bound: @escaping () -> Void = {}) {
        self.access = access
        self.gone = gone
        self.bound = bound
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
            if !access.grants.isEmpty {
                Text("绑定这块显示器上的窗口").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                Text("选择已开放程序的窗口。绑定只指定输入目标，不移动窗口，也不给程序窗口访问权；程序仍需单独申请并由你批准。")
                    .font(ADFont.note).foregroundStyle(ADColor.muted)
                if access.windows.isEmpty {
                    Text("没有可选的可见窗口。打开目标应用后点刷新。")
                        .font(ADFont.note).foregroundStyle(ADColor.muted)
                }
                ForEach(access.windows.indices, id: \.self) { i in
                    let w = access.windows[i]
                    let id = w["windowId"]?.intValue ?? 0
                    Button {
                        access.selectedWindowId = id
                    } label: {
                        HStack {
                            Image(systemName: access.selectedWindowId == id ? "largecircle.fill.circle" : "circle")
                            Text(w["appName"]?.stringValue ?? "—")
                            Text(w["title"]?.stringValue ?? "（标题不可读）").lineLimit(1)
                            Spacer()
                            Text("pid \(w["process"]?["pid"]?.intValue ?? 0) · 窗口 \(id)")
                                .font(ADFont.identifier)
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("选择窗口 \(w["appName"]?.stringValue ?? "") \(id)")
                }
                HStack {
                    Button("刷新窗口") { Task { await access.load() } }.buttonStyle(ADButtonStyle(.secondary))
                    Button("绑定所选窗口") { Task { if await access.bindSelectedWindow() { bound() } } }
                        .buttonStyle(ADButtonStyle(.primary))
                        .disabled(access.working || access.selectedWindowId == nil)
                }
            }
            if !access.windowGrants.isEmpty {
                Text("窗口授权").font(ADFont.noteStrong).foregroundStyle(ADColor.ink)
                ForEach(access.windowGrants.indices, id: \.self) { i in
                    let g = access.windowGrants[i]
                    let id = g["windowGrantId"]?.stringValue ?? ""
                    HStack {
                        Text("\(g["clientId"]?.stringValue ?? "—") · 窗口 \(g["window"]?["windowId"]?.intValue ?? 0) · \((g["permissions"]?.arrayValue ?? []).compactMap(\.stringValue).joined(separator: ", "))")
                            .font(ADFont.note).lineLimit(1)
                        Spacer()
                        Text(g["state"]?.stringValue ?? "—").font(ADFont.identifier)
                        if g["state"]?.stringValue == "active" {
                            Button("撤销") { Task { await access.revokeWindow(id) } }
                                .buttonStyle(ADButtonStyle(.secondary)).disabled(access.working)
                                .accessibilityLabel("撤销窗口授权 \(id)")
                        }
                    }
                }
            }
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
