import AgentDesktopProtocol
import Foundation

// Lane UI-C (U4 Agents; docs/plan/11-parallel-lanes.md). The Agents page's
// state: only what the Runtime answered (hub.* as the owner), re-read on
// every Store round. Nothing here decides who may do what; every action is
// one runtime/1 call whose answer is shown as it came back.

/// The answer to one of the page's changes, as the page shows it: what the
/// Runtime accepted, the facts its answer carries, or why it refused.
public struct AgentsActionResult: Equatable, Sendable {
    public let title: String
    public let facts: [String]
    public let problem: RuntimeProblem?

    public var accepted: Bool { problem == nil }
}

/// The read-only "检查连接" of P09–P11 (UC24, UC25): what the Runtime says
/// about one Desktop and the paired apps whose grant names it. It reads only;
/// it never starts a Run or takes control.
public struct AgentsConnectionCheck: Equatable, Sendable {
    public let desktopId: String
    public let desktop: JSONValue?
    /// Active paired apps whose grant lists this desktopId, with their open connections.
    public let clients: [Entry]
    public let problem: RuntimeProblem?
    public let checkedAt: Date

    public struct Entry: Equatable, Sendable {
        public let clientId: String
        public let name: String
        /// nil when the Runtime does not offer hub.connections.list.
        public let connections: Int?
    }
}

@MainActor
public final class AgentsModel: ObservableObject {
    public enum Tab: String, CaseIterable, Identifiable, Sendable {
        case overview = "总览"
        case connect = "接入应用"
        public var id: String { rawValue }
    }

    /// Connection methods of the "接入应用" view (P09, P10, P11).
    public enum Channel: String, CaseIterable, Identifiable, Sendable {
        case cli = "CLI"
        case mcp = "MCP"
        case acp = "ACP · 可选"
        public var id: String { rawValue }
        public var symbol: String {
            switch self {
            case .cli: return "terminal"
            case .mcp: return "point.3.connected.trianglepath.dotted"
            case .acp: return "bubble.left.and.text.bubble.right"
            }
        }
    }

    @Published public var tab: Tab = .overview
    /// The client whose detail is shown (W03); nil shows the tab.
    @Published public var clientId: String?
    @Published public var channel: Channel = .cli
    @Published public var targetDesktopId: String?
    @Published public var showEndedWindowGrants = true

    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var clients: [JSONValue] = []
    @Published public private(set) var pairings: [JSONValue] = []
    @Published public private(set) var connections: [JSONValue] = []
    @Published public private(set) var windowGrants: [JSONValue] = []
    @Published public private(set) var grants: [JSONValue] = []
    @Published public private(set) var syncedAt: Date?
    /// A part of the page the Runtime did not answer (method → problem);
    /// the rest still shows.
    @Published public private(set) var partProblems: [String: RuntimeProblem] = [:]
    /// hub.pairing.status answers by pairingId (never with a credential).
    @Published public private(set) var pairingChecks: [String: JSONValue] = [:]
    @Published public private(set) var pairingCheckProblems: [String: RuntimeProblem] = [:]

    @Published public private(set) var detail: JSONValue?
    @Published public private(set) var detailProblem: RuntimeProblem?

    @Published public private(set) var working = false
    @Published public private(set) var lastResult: AgentsActionResult?
    @Published public private(set) var check: AgentsConnectionCheck?

    let store: ShellStore
    private let now: () -> Date
    private var ticket = 0
    private var detailTicket = 0

    public init(store: ShellStore, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
    }

    var runtime: RuntimePort { store.runtime }

    /// Whether the Runtime offers `method` (runtime.capabilities); the page
    /// never assumes a method exists.
    public func offers(_ method: String) -> Bool { store.offers(method) }

    /// True while the Runtime is reachable; changes are disabled otherwise
    /// (HB-UI-02).
    public var connected: Bool { if case .connected = store.connection { return true }; return false }

    /// Whether a change through `method` can be offered now.
    public func canChange(_ method: String) -> Bool { connected && offers(method) && !working }

    // MARK: Reading

    /// hub.clients.list, hub.connections.list, hub.windows.list and
    /// hub.grants.list, each only when offered; a late answer is dropped.
    public func load() async {
        ticket += 1
        let mine = ticket
        guard offers("hub.clients.list") else {
            state = .failed(Self.missing("hub.clients.list"))
            return
        }
        if clients.isEmpty, syncedAt == nil { state = .loading }
        do {
            let list = try await runtime.call("hub.clients.list")
            var problems: [String: RuntimeProblem] = [:]
            let conns = await optional("hub.connections.list", .obj([]), key: "connections", problems: &problems)
            let wins = await optional("hub.windows.list", .obj([("includeEnded", .bool(true))]), key: "windowGrants", problems: &problems)
            let gr = await optional("hub.grants.list", .obj([]), key: "grants", problems: &problems)
            guard mine == ticket else { return }
            apply(list: list, connections: conns, windowGrants: wins, grants: gr, problems: problems)
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
        if let id = clientId { await loadDetail(id) }
    }

    private func optional(_ method: String, _ params: JSONValue, key: String, problems: inout [String: RuntimeProblem]) async -> [JSONValue]? {
        guard offers(method) else { problems[method] = Self.missing(method); return nil }
        do {
            return try await runtime.call(method, params)[key]?.arrayValue ?? []
        } catch {
            problems[method] = RuntimeProblem(error)
            return nil
        }
    }

    /// Takes one round of answers. Internal so renders and tests can feed a
    /// contract-checked list (the base mock lists no pairings yet).
    func apply(list: JSONValue, connections conns: [JSONValue]?, windowGrants wins: [JSONValue]?, grants gr: [JSONValue]?,
               problems: [String: RuntimeProblem]) {
        clients = list["clients"]?.arrayValue ?? []
        pairings = list["pairings"]?.arrayValue ?? []
        if let conns { connections = conns }
        if let wins { windowGrants = wins }
        if let gr { grants = gr }
        partProblems = problems
        syncedAt = now()
        state = clients.isEmpty && pairings.isEmpty ? .empty : .loaded
    }

    public func open(_ clientId: String) {
        self.clientId = clientId
        detail = nil
        detailProblem = nil
        lastResult = nil
        Task { await loadDetail(clientId) }
    }

    public func closeDetail() {
        clientId = nil
        detail = nil
        detailProblem = nil
        lastResult = nil
    }

    /// hub.clients.show for the detail (W03).
    public func loadDetail(_ id: String) async {
        detailTicket += 1
        let mine = detailTicket
        guard offers("hub.clients.show") else {
            detail = nil
            detailProblem = Self.missing("hub.clients.show")
            return
        }
        do {
            let d = try await runtime.call("hub.clients.show", .obj([("clientId", .string(id))]))
            guard mine == detailTicket, clientId == id else { return }
            detail = d
            detailProblem = nil
        } catch {
            guard mine == detailTicket else { return }
            detail = nil
            detailProblem = RuntimeProblem(error)
        }
    }

    /// hub.pairing.status for one request; the page shows its state only.
    public func checkPairing(_ pairingId: String) async {
        guard offers("hub.pairing.status") else {
            pairingCheckProblems[pairingId] = Self.missing("hub.pairing.status")
            return
        }
        do {
            let r = try await runtime.call("hub.pairing.status", .obj([("pairingId", .string(pairingId))]))
            pairingChecks[pairingId] = Self.withoutSecrets(r)
            pairingCheckProblems[pairingId] = nil
        } catch {
            pairingCheckProblems[pairingId] = RuntimeProblem(error)
        }
    }

    /// The read-only check of P09–P11: desktop.show, hub.clients.list and
    /// hub.connections.list. Nothing that changes state is called.
    public func checkConnection(desktopId: String) async {
        var problem: RuntimeProblem?
        var desktop: JSONValue?
        var entries: [AgentsConnectionCheck.Entry] = []
        do {
            guard offers("desktop.show") else { throw RuntimeError.capabilityMissing("desktop.show") }
            if offers("desktop.show") {
                desktop = try await runtime.call("desktop.show", .obj([("desktopId", .string(desktopId))]))
            }
            guard offers("hub.clients.list") else { throw RuntimeError.capabilityMissing("hub.clients.list") }
            let list = try await runtime.call("hub.clients.list")
            let conns: [JSONValue]? = offers("hub.connections.list")
                ? (try await runtime.call("hub.connections.list"))["connections"]?.arrayValue ?? [] : nil
            let at = now()
            for c in list["clients"]?.arrayValue ?? [] where c["state"]?.stringValue == "active" {
                // An active grant past expiresAt is refused (grant_expired): not access (Codex P2).
                guard let g = c["grant"], g["state"]?.stringValue == "active",
                      let end = g["expiresAt"]?.stringValue.flatMap(Timestamp.date), end > at,
                      (g["desktops"]?.arrayValue ?? []).contains(.string(desktopId)),
                      let id = c["clientId"]?.stringValue else { continue }
                entries.append(.init(clientId: id, name: c["agentName"]?.stringValue ?? id,
                                     connections: conns.map { $0.filter { $0["clientId"]?.stringValue == id }.count }))
            }
        } catch {
            problem = RuntimeProblem(error)
        }
        check = AgentsConnectionCheck(desktopId: desktopId, desktop: desktop, clients: entries, problem: problem, checkedAt: now())
    }

    public func clearCheck() { check = nil }

    // MARK: Changes (each one call; the page confirms before calling)

    public func revokeClient(_ id: String) async {
        await change("hub.clients.revoke", .obj([("clientId", .string(id))])) { [self] r in
            AgentsActionResult(title: "已受理：移除 \(name(of: id))", facts: [
                "Runtime 返回的登记状态：\(r["state"]?.stringValue ?? "—")" + (r["revokedAt"]?.stringValue.map { "（\(TimeText.clock($0)) 移除）" } ?? ""),
                "授权状态：\(r["grant"]?["state"]?.stringValue ?? "—")",
            ] + stopFacts(id), problem: nil)
        }
    }

    public func revokeGrant(_ id: String) async {
        await change("hub.grants.revoke", .obj([("clientId", .string(id))])) { [self] r in
            AgentsActionResult(title: "已受理：撤销 \(name(of: id)) 的授权", facts: [
                "Runtime 返回的授权状态：\(r["state"]?.stringValue ?? "—")，版本 \(r["revision"]?.intValue.map(String.init) ?? "—")",
            ] + stopFacts(id), problem: nil)
        }
    }

    /// hub.grants.set for a narrowing the user confirmed. The params are
    /// rebuilt from the grant as the Runtime has it right now, and only if
    /// it is still the revision the user looked at: owner calls carry no
    /// expected revision, so stale arrays could bring back what someone
    /// removed meanwhile, and a duration computed before the dialog would
    /// count from the later call (Codex P1 on e38c3d6).
    public func narrowGrant(_ id: String, intent: GrantNarrowing.Intent) async {
        guard canChange("hub.grants.set") else { return }
        guard offers("hub.grants.list") else {
            lastResult = AgentsActionResult(title: "没有发送：Runtime 未提供 hub.grants.list", facts: [], problem: RuntimeProblem(RuntimeError.capabilityMissing("hub.grants.list")))
            return
        }
        let current: JSONValue?
        do {
            current = (try await runtime.call("hub.grants.list"))["grants"]?.arrayValue?.first { $0["clientId"]?.stringValue == id }
        } catch {
            lastResult = AgentsActionResult(title: "Runtime 没有受理这次操作", facts: [], problem: RuntimeProblem(error))
            await load()
            return
        }
        guard let g = current, g["revision"]?.intValue == intent.revision,
              let params = GrantNarrowing.params(clientId: id, grant: g, intent: intent, now: now()) else {
            lastResult = AgentsActionResult(title: "没有发送：授权在确认期间变了", facts: [], problem: Self.changedMeanwhile)
            await load()
            return
        }
        await change("hub.grants.set", params) { [self] r in
            AgentsActionResult(title: "已受理：收紧 \(name(of: id)) 的授权", facts: [
                "Runtime 返回的授权：版本 \(r["revision"]?.intValue.map(String.init) ?? "—")，状态 \(r["state"]?.stringValue ?? "—")，到期 \(TimeText.clock(r["expiresAt"]?.stringValue))",
                "能力：" + AgentsText.capabilities(r["capabilities"]),
                "新范围之外的运行由 Runtime 停止；以 Runs 中的状态为准。",
            ], problem: nil)
        }
    }

    public func revokeWindowGrant(_ windowGrantId: String) async {
        await change("hub.windows.revoke", .obj([("windowGrantId", .string(windowGrantId))])) { r in
            AgentsActionResult(title: "已受理：撤销窗口授权 \(windowGrantId)", facts: [
                "Runtime 返回的状态：\(r["state"]?.stringValue ?? "—")" + (r["endedReason"]?.stringValue.map { "（\(AgentsText.endedReason($0))）" } ?? ""),
                "这个应用的连接已被切断，它重连后不再能用这个窗口。",
            ], problem: nil)
        }
    }

    private func change(_ method: String, _ params: JSONValue, _ result: (JSONValue) -> AgentsActionResult) async {
        guard canChange(method) else { return }
        working = true
        defer { working = false }
        do {
            let r = try await runtime.call(method, params)
            await store.refreshRuns()
            lastResult = result(r)
        } catch {
            lastResult = AgentsActionResult(title: "Runtime 没有受理这次操作", facts: [], problem: RuntimeProblem(error))
        }
        await load()
    }

    // MARK: Derived (from the Runtime's answers only)

    public func name(of clientId: String) -> String {
        clients.first { $0["clientId"]?.stringValue == clientId }?["agentName"]?.stringValue ?? clientId
    }

    public func client(_ id: String) -> JSONValue? { clients.first { $0["clientId"]?.stringValue == id } }

    /// Prefer the refreshed client record, including an explicit absent grant.
    public func grant(of id: String) -> JSONValue? {
        if let g = (detail?["clientId"]?.stringValue == id ? detail : client(id))?["grant"] { return g.isNull ? nil : g }
        if let g = grants.first(where: { $0["clientId"]?.stringValue == id }) { return g }
        return nil
    }

    public func connections(of id: String) -> [JSONValue] {
        connections.filter { $0["clientId"]?.stringValue == id }
    }

    public func windowGrants(of id: String) -> [JSONValue] {
        windowGrants.filter { $0["clientId"]?.stringValue == id && (showEndedWindowGrants || $0["state"]?.stringValue == "active") }
    }

    public func runs(of id: String) -> [JSONValue] { store.runs.filter { $0["clientId"]?.stringValue == id } }

    /// Runs of the client the Runtime reports as stopping (HB-UI-04).
    public func stoppingRuns(of id: String) -> Int {
        runs(of: id).filter { $0["phase"]?.stringValue == "stopping" }.count
    }

    public func activeRuns(of id: String) -> Int {
        runs(of: id).filter { $0["phase"]?.stringValue != "ended" }.count
    }

    public var openPairings: [JSONValue] { pairings.filter { $0["state"]?.stringValue == "requested" } }

    public var currentNow: Date { now() }

    private func stopFacts(_ id: String) -> [String] {
        let n = stoppingRuns(of: id)
        return [
            n > 0 ? "\(n) 个平台运行停止中（等待执行端确认静止）" : "Runtime 没有报告这个应用正在停止的运行",
            "外部应用本身没有被结束：Hub 不终止它的进程",
        ]
    }

    static let changedMeanwhile = RuntimeProblem(code: "conflict", title: "授权已经变了",
                                                 advice: "确认期间这个应用的授权被改动、撤销或已到期，收紧没有发送。请重新查看后再决定。",
                                                 notSent: true)

    static func missing(_ method: String) -> RuntimeProblem {
        let (t, a) = RuntimeProblem.text("capability_missing")
        return RuntimeProblem(code: "capability_missing", title: t, advice: "\(a)（\(method)）")
    }

    /// The page never keeps or shows a credential, even if one came back.
    static func withoutSecrets(_ v: JSONValue) -> JSONValue {
        guard let members = v.objectMembers else { return v }
        return .object(members.filter { !["credential", "token"].contains($0.key) })
    }
}

/// A narrowing of a client's app-level grant (hub.grants.set): only items
/// already granted can be kept, and the end never moves later. The params
/// always carry durationSeconds, because without it the Runtime would
/// start a fresh default period (which could extend the grant).
public enum GrantNarrowing {
    /// Choices for a shorter period, in seconds (Hub W02: 1 h / 8 h / 7 d).
    public static let periods: [(String, Int)] = [("1 小时", 3600), ("8 小时", 28800), ("7 天", 604_800)]

    /// Seconds kept back from what is left, so the time between building the
    /// params and the Runtime applying them can never move the end later.
    public static let safetyMargin = 5

    /// What the user chose, bound to the grant revision they saw.
    public struct Intent: Equatable, Sendable {
        public let keepCapabilities: Set<String>
        public let keepDesktops: Set<String>
        public let keepApps: Set<String>
        public let period: Int?
        public let revision: Int

        public init(keepCapabilities: Set<String>, keepDesktops: Set<String>, keepApps: Set<String>, period: Int?, revision: Int) {
            self.keepCapabilities = keepCapabilities
            self.keepDesktops = keepDesktops
            self.keepApps = keepApps
            self.period = period
            self.revision = revision
        }
    }

    public static func params(clientId: String, grant: JSONValue, intent: Intent, now: Date) -> JSONValue? {
        params(clientId: clientId, grant: grant, keepCapabilities: intent.keepCapabilities, keepDesktops: intent.keepDesktops,
               keepApps: intent.keepApps, period: intent.period, now: now)
    }

    public static func strings(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }

    /// Seconds left on `grant`, rounded down; nil when it is not active or has ended.
    public static func remaining(_ grant: JSONValue, now: Date) -> Int? {
        guard grant["state"]?.stringValue == "active", let end = grant["expiresAt"]?.stringValue.flatMap(Timestamp.date) else { return nil }
        let left = Int(end.timeIntervalSince(now).rounded(.down))
        return left >= 1 ? left : nil
    }

    /// The hub.grants.set params, or nil when nothing would change, the
    /// grant is not active, or a kept item was never granted.
    public static func params(clientId: String, grant: JSONValue, keepCapabilities: Set<String>, keepDesktops: Set<String>,
                              keepApps: Set<String>, period: Int?, now: Date) -> JSONValue? {
        guard let left = remaining(grant, now: now) else { return nil }
        let caps = strings(grant["capabilities"]), desks = strings(grant["desktops"]), apps = strings(grant["apps"])
        guard keepCapabilities.isSubset(of: caps), keepDesktops.isSubset(of: desks), keepApps.isSubset(of: apps) else { return nil }
        let usable = left - safetyMargin
        guard usable >= 1 else { return nil }
        let seconds = min(usable, period ?? usable)
        let changed = keepCapabilities.count < caps.count || keepDesktops.count < desks.count || keepApps.count < apps.count
            || (period.map { $0 < usable } ?? false)
        guard changed else { return nil }
        return .obj([
            ("clientId", .string(clientId)),
            ("capabilities", .array(caps.filter(keepCapabilities.contains).map(JSONValue.string))),
            ("desktops", .array(desks.filter(keepDesktops.contains).map(JSONValue.string))),
            ("apps", .array(apps.filter(keepApps.contains).map(JSONValue.string))),
            ("durationSeconds", .int(max(1, seconds))),
        ])
    }

    /// What the narrowing takes away, for the confirmation.
    public static func removed(grant: JSONValue, params: JSONValue, now: Date) -> [String] {
        var out: [String] = []
        for (key, label) in [("capabilities", "能力"), ("desktops", "Desktop"), ("apps", "App")] {
            let gone = strings(grant[key]).filter { !strings(params[key]).contains($0) }
            if !gone.isEmpty {
                out.append("去掉\(label)：" + gone.map { key == "capabilities" ? AgentsText.capability($0) : $0 }.joined(separator: "、"))
            }
        }
        if let left = remaining(grant, now: now), let s = params["durationSeconds"]?.intValue, s < left - safetyMargin {
            out.append("期限缩短为 \(AgentsText.duration(s))（原来还剩 \(AgentsText.duration(left))）")
        }
        return out
    }
}

/// Words for what the Runtime reports, shown together with the raw value.
public enum AgentsText {
    /// The code identity level exactly as the Runtime gives it, with a gloss.
    public static func codeIdentity(_ v: JSONValue?) -> StatusText {
        switch v?["level"]?.stringValue {
        case "verified": return StatusText("verified · 已核验签名", .running)
        case "shared_interpreter": return StatusText("shared_interpreter · 共享", .attention)
        case "same_user": return StatusText("same_user · 仅同一用户", .attention)
        case "in_process": return StatusText("in_process · 宿主自身", .idle)
        case let other?: return StatusText(other, .idle)
        case nil: return StatusText("未读到代码身份", .idle)
        }
    }

    public static func clientState(_ c: JSONValue?) -> StatusText {
        switch c?["state"]?.stringValue {
        case "active": return StatusText("登记有效", .running)
        case "revoked": return StatusText("已移除", .danger)
        case let other?: return StatusText(other, .idle)
        case nil: return StatusText("—", .idle)
        }
    }

    public static func grantState(_ g: JSONValue?, now: Date) -> StatusText {
        guard let g, !g.isNull else { return StatusText("没有授权", .idle) }
        switch g["state"]?.stringValue {
        case "revoked": return StatusText("授权已撤销", .danger)
        case "active":
            if let end = g["expiresAt"]?.stringValue.flatMap(Timestamp.date), end <= now { return StatusText("授权已到期", .attention) }
            return StatusText("授权有效", .running)
        case let other?: return StatusText(other, .idle)
        case nil: return StatusText("—", .idle)
        }
    }

    public static func connection(_ count: Int) -> StatusText {
        count > 0 ? StatusText("在线 · \(count) 条连接", .running) : StatusText("当前没有连接", .idle)
    }

    public static func capability(_ c: String) -> String {
        switch c {
        case "observe": return "观察 observe"
        case "act": return "操作 act"
        case "desktop.manage": return "管理 Desktop desktop.manage"
        case "run": return "运行 run"
        case "unit.run": return "GUI 单元 unit.run"
        default: return c
        }
    }

    public static func capabilities(_ v: JSONValue?) -> String {
        let list = GrantNarrowing.strings(v)
        return list.isEmpty ? "无" : list.joined(separator: "、")
    }

    public static func desktop(_ id: String) -> String { id == "created" ? "它自己创建的 Desktop（created）" : id }

    public static func windowPermission(_ p: String) -> String {
        switch p {
        case "observe": return "Observe 查看"
        case "act": return "Act 操作"
        case "persist": return "Persist 保存截图"
        default: return p
        }
    }

    public static func windowState(_ w: JSONValue) -> StatusText {
        switch w["state"]?.stringValue {
        case "active": return StatusText("有效", .running)
        case "revoked": return StatusText("已撤销", .danger)
        case "ended": return StatusText("已结束", .idle)
        case let other?: return StatusText(other, .idle)
        case nil: return StatusText("—", .idle)
        }
    }

    public static func endedReason(_ r: String) -> String {
        switch r {
        case "window_closed": return "窗口已关闭"
        case "process_changed": return "进程已变"
        case "app_changed": return "App 已变"
        case "window_grant_revoked": return "窗口授权被撤销"
        case "client_revoked": return "应用被移除"
        case "grant_revoked": return "应用授权被撤销"
        case "app_removed": return "App 不在授权内了"
        case "desktop_removed": return "Desktop 不在授权内了"
        case "desktop_destroyed": return "Desktop 已关闭"
        default: return r
        }
    }

    public static func pairingState(_ s: String?) -> StatusText {
        switch s {
        case "requested": return StatusText("等待你在确认窗口中处理", .attention)
        case "approved": return StatusText("已批准", .running)
        case "denied": return StatusText("已拒绝", .idle)
        case "expired": return StatusText("已过期", .idle)
        case let other?: return StatusText(other, .idle)
        case nil: return StatusText("—", .idle)
        }
    }

    public static func duration(_ seconds: Int) -> String {
        if seconds >= 86400 { return "\(seconds / 86400) 天\(seconds % 86400 >= 3600 ? " \(seconds % 86400 / 3600) 小时" : "")" }
        if seconds >= 3600 { return "\(seconds / 3600) 小时\(seconds % 3600 >= 60 ? " \(seconds % 3600 / 60) 分" : "")" }
        if seconds >= 60 { return "\(seconds / 60) 分" }
        return "\(seconds) 秒"
    }
}
