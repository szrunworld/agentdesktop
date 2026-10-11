import AgentDesktopProtocol
import Foundation

// Lane UI-A (U9): the platform Inbox (Hub W06), the reconciliation of
// unknown actions (W07) and the diagnostics export (W08), over PR4's
// runtime/1 methods: inbox.list / inbox.show / inbox.resolve,
// run.reconcile and diagnostics.export.
//
// Rules kept here (Hub v1 §3.3, E2E-08, RT-19):
// - A reconciliation only appends. The page never shows the Run's outcome
//   as anything but what the Runtime returns (unknown stays unknown), and
//   nothing here retries or replays an action.
// - Writes carry the revision the page last read; a conflict re-reads and
//   asks the person to decide again, it never resubmits by itself.
// - Stopping a waiting Run is two steps: the Runtime accepts the stop
//   (停止中), and only a later read showing ended / confirmed says 已停止.

/// Words for the Inbox fields; codes stay visible beside them.
enum InboxText {
    static func kind(_ k: String?) -> StatusText {
        switch k {
        case "unknown_reference": return StatusText("结果未知的动作", .attention)
        case "question": return StatusText("等待人工处理", .attention)
        case "approval": return StatusText("审批", .idle)
        case "external_reference": return StatusText("外部引用", .idle)
        default: return StatusText(k ?? "—", .idle)
        }
    }

    static func state(_ item: JSONValue) -> StatusText {
        guard item["state"]?.stringValue == "resolved" else { return StatusText("待处理", .attention) }
        let r = item["resolution"]
        switch r?["how"]?.stringValue {
        case "reconciled": return StatusText("已核实：\(verdict(r?["verdict"]?.stringValue))", .idle)
        // The stop was asked for; whether the Run has stopped is its own
        // phase and quiescence (HB-UI-05).
        case "run_cancelled": return StatusText("已请求停止", .idle)
        case "run_ended": return StatusText("运行已结束", .idle)
        default: return StatusText("已处理", .idle)
        }
    }

    static func verdict(_ v: String?) -> String {
        switch v {
        case "executed": return "已执行"
        case "not_executed": return "未执行"
        case "still_unknown": return "仍无法确定"
        default: return v ?? "—"
        }
    }

    static func verdictTone(_ v: String?) -> StatusTone {
        v == "still_unknown" ? .attention : .idle
    }

    static func source(_ s: String?) -> String {
        switch s {
        case "operator_attestation": return "本人确认"
        case "external_reference": return "外部记录"
        case "runtime_observation": return "平台观察"
        default: return s ?? "—"
        }
    }

    /// The unit executor's reason codes for a Run that waits for a person.
    static func questionReason(_ r: String?) -> String {
        switch r {
        case "login_required": return "需要登录"
        case "needs_user": return "需要人工处理"
        case "model_requested_user": return "模型请求人工处理"
        default: return r ?? "—"
        }
    }

    /// Whether a reconciliation can be recorded now: the Run has ended and
    /// its quiescence is confirmed (else the Runtime answers not_quiescent).
    static func quiescent(_ item: JSONValue) -> Bool {
        item["run"]?["phase"]?.stringValue == "ended" && item["run"]?["quiescence"]?.stringValue == "confirmed"
    }

    /// Date and time (Asia/Shanghai), for a window that can span days.
    static func dateTime(_ iso: String?) -> String {
        guard let iso, let date = Timestamp.date(iso) else { return "—" }
        let f = DateFormatter()
        f.timeZone = TimeText.shanghai
        f.dateFormat = "M月d日 HH:mm"
        return f.string(from: date)
    }

    static func runLine(_ item: JSONValue) -> String {
        let r = item["run"]
        return "phase \(r?["phase"]?.stringValue ?? "—") · outcome \(r?["outcome"]?.stringValue ?? "null") · quiescence \(r?["quiescence"]?.stringValue ?? "—")"
    }
}

/// The `details.reason` of a refusal, when it has one.
func runtimeReason(_ error: Error) -> String? {
    (error as? RuntimeError)?.details?["reason"]?.stringValue
}

// MARK: Inbox list (W06)

/// `inbox.list` with the page's filters, newest first, more pages with the
/// Runtime's cursor; re-read on every update round of the Store.
@MainActor
public final class InboxListLoader: ObservableObject {
    public struct Filter: Equatable, Sendable {
        /// open (the Runtime's default), resolved or all.
        public var state: String
        public var kind: String?
        public var desktopId: String?

        public init(state: String = "open", kind: String? = nil, desktopId: String? = nil) {
            self.state = state
            self.kind = kind
            self.desktopId = desktopId
        }

        var params: [(String, JSONValue)] {
            var p: [(String, JSONValue)] = [("state", .string(state))]
            if let kind { p.append(("kind", .string(kind))) }
            if let desktopId { p.append(("desktopId", .string(desktopId))) }
            return p
        }
    }

    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var items: [JSONValue] = []
    @Published public private(set) var next: String?
    @Published public private(set) var syncedAt: Date?
    @Published public private(set) var loadingMore = false
    public private(set) var filter: Filter

    private let runtime: RuntimePort
    private let pageSize: Int
    private var ticket = 0

    public init(runtime: RuntimePort, filter: Filter = Filter(), pageSize: Int = 50) {
        self.runtime = runtime
        self.filter = filter
        self.pageSize = pageSize
    }

    public func apply(_ f: Filter) async {
        if f != filter {
            filter = f
            items = []
            next = nil
            syncedAt = nil
            state = .loading
        }
        await reload()
    }

    /// Refresh up to the contract's 100-item limit, then restart pagination.
    /// Older tail rows may have resolved or stopped matching the filter.
    public func reload() async {
        ticket += 1
        let mine = ticket
        let limit = min(100, max(pageSize, items.count))
        do {
            let r = try await runtime.call("inbox.list", .obj(filter.params + [("limit", .int(limit))]))
            guard mine == ticket else { return }
            let first = r["items"]?.arrayValue ?? []
            items = first
            next = r["next"]?.stringValue
            syncedAt = Date()
            state = items.isEmpty ? .empty : .loaded
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    public func loadMore() async {
        guard let cursor = next, !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        let mine = ticket
        do {
            let r = try await runtime.call("inbox.list", .obj(filter.params + [("cursor", .string(cursor)), ("limit", .int(pageSize))]))
            guard mine == ticket else { return }
            let known = Set(items.compactMap { $0["inboxId"]?.stringValue })
            items += (r["items"]?.arrayValue ?? []).filter { !known.contains($0["inboxId"]?.stringValue ?? "") }
            next = r["next"]?.stringValue
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }
}

// MARK: One item: show, reconcile, stop

/// What the person fills in to reconcile an action. Nothing is chosen for
/// them: the verdict starts empty.
public struct ReconcileDraft: Equatable, Sendable {
    public var verdict: String?
    public var source = "operator_attestation"
    public var note = ""
    /// One evidence reference per line (at most 8, each at most 256).
    public var evidence = ""

    public init(verdict: String? = nil, source: String = "operator_attestation", note: String = "", evidence: String = "") {
        self.verdict = verdict
        self.source = source
        self.note = note
        self.evidence = evidence
    }

    public var evidenceRefs: [String] {
        evidence.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    var trimmedNote: String { note.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why it cannot be sent yet, in words; nil when it can.
    public var problem: String? {
        if verdict == nil { return "请选择核实结论。" }
        if trimmedNote.unicodeScalars.count > 1024 { return "说明最多 1024 个字符。" }
        let refs = evidenceRefs
        if refs.count > 8 { return "证据引用最多 8 条。" }
        if refs.contains(where: { $0.unicodeScalars.count > 256 }) { return "每条证据引用最多 256 个字符。" }
        return nil
    }
}

/// One Inbox item as `inbox.show` gives it, with its reconciliations, and
/// the two writes a person can make on it: `run.reconcile` (an unknown
/// action) and `inbox.resolve` with `cancel_run` (a waiting Run).
@MainActor
public final class InboxItemModel: ObservableObject {
    public let inboxId: String
    @Published public private(set) var state: PageState = .loading
    @Published public private(set) var item: JSONValue?
    @Published public private(set) var syncedAt: Date?
    @Published public var draft = ReconcileDraft()
    @Published public private(set) var submitting = false
    @Published public private(set) var problem: RuntimeProblem?
    /// Set when a write lost to another one (revision_conflict, already
    /// resolved): the item was read again and the person decides again.
    @Published public private(set) var conflictNote: String?
    /// The reconciliation this page just recorded.
    @Published public private(set) var recorded: JSONValue?
    /// What `inbox.resolve` answered about the stop (phase, quiescence).
    @Published public private(set) var stopAnswer: JSONValue?

    private let runtime: RuntimePort
    private var ticket = 0

    public init(runtime: RuntimePort, inboxId: String) {
        self.runtime = runtime
        self.inboxId = inboxId
    }

    public func load() async {
        ticket += 1
        let mine = ticket
        do {
            let r = try await runtime.call("inbox.show", .obj([("inboxId", .string(inboxId))]))
            guard mine == ticket else { return }
            item = r
            syncedAt = Date()
            state = .loaded
        } catch {
            guard mine == ticket else { return }
            state = ShellStore.failure(error)
        }
    }

    var revision: Int { item?["revision"]?.intValue ?? 0 }

    public var canReconcile: Bool {
        guard case .loaded = state else { return false }
        guard let item, item["kind"]?.stringValue == "unknown_reference", item["state"]?.stringValue == "open" else { return false }
        return InboxText.quiescent(item) && !submitting
    }

    public var canStop: Bool {
        guard case .loaded = state else { return false }
        guard let item, item["kind"]?.stringValue == "question", item["state"]?.stringValue == "open" else { return false }
        return item["run"]?["phase"]?.stringValue == "waiting_input" && !submitting
    }

    /// `run.reconcile` with the revision last read. On success the draft is
    /// cleared and the item re-read; the Run's outcome is left as it is.
    public func reconcile() async {
        guard canReconcile, let item, let verdict = draft.verdict, draft.problem == nil,
              let runId = item["runId"]?.stringValue, let action = item["action"]?["requestId"]?.stringValue else { return }
        submitting = true
        problem = nil
        conflictNote = nil
        defer { submitting = false }
        var p: [(String, JSONValue)] = [
            ("runId", .string(runId)), ("actionRequestId", .string(action)), ("verdict", .string(verdict)),
            ("source", .string(draft.source)), ("expectedRevision", .int(revision)),
        ]
        if !draft.trimmedNote.isEmpty { p.append(("note", .string(draft.trimmedNote))) }
        let refs = draft.evidenceRefs
        if !refs.isEmpty { p.append(("evidenceRefs", .array(refs.map(JSONValue.string)))) }
        do {
            let r = try await runtime.call("run.reconcile", .obj(p))
            recorded = r["reconciliation"]
            draft = ReconcileDraft()
            if let fresh = r["item"] { self.item = fresh }
            await load()
        } catch {
            await refused(error)
        }
    }

    /// `inbox.resolve` with `cancel_run`: the Runtime stops the waiting Run
    /// as run.cancel does. The page shows the answer and re-reads; the Run
    /// is stopped only when a later read says ended / confirmed.
    public func stopRun() async {
        guard canStop else { return }
        submitting = true
        problem = nil
        conflictNote = nil
        defer { submitting = false }
        do {
            let r = try await runtime.call("inbox.resolve", .obj([("inboxId", .string(inboxId)), ("resolution", .string("cancel_run")),
                                                                   ("expectedRevision", .int(revision))]))
            stopAnswer = r["stop"]?["execution"]
            if let fresh = r["item"] { item = fresh }
            await load()
        } catch {
            await refused(error)
        }
    }

    private func refused(_ error: Error) async {
        switch runtimeReason(error) {
        case "revision_conflict":
            conflictNote = "这项在你读取之后已有新的记录。已重新读取，请看过最新记录后再决定。"
            await load()
        case "already_resolved":
            conflictNote = "这项已经被处理。已重新读取。"
            await load()
        case "not_quiescent":
            conflictNote = "运行还没有确认输入静止，现在不能核实。已重新读取。"
            await load()
        default:
            problem = RuntimeProblem(error)
        }
    }

    /// Stop progress for HB-UI-05: nil before any stop was asked here.
    public var stopProgress: StatusText? {
        guard stopAnswer != nil || item?["resolution"]?["how"]?.stringValue == "run_cancelled" else { return nil }
        let run = item?["run"]
        if run?["phase"]?.stringValue == "ended", run?["quiescence"]?.stringValue == "confirmed" {
            return StatusText("已停止", .idle)
        }
        return StatusText("停止中：等待输入静止", .attention)
    }
}

// MARK: Diagnostics export (W08)

/// `diagnostics.export`: a preview first (the manifest only, nothing
/// written), then the export into an artifact read back with artifact.read.
@MainActor
public final class DiagnosticsExportModel: ObservableObject {
    public static let sections = ["runtime", "capabilities", "connections", "clients", "desktops", "runs", "requests", "authorization"]

    public enum Window: String, CaseIterable, Identifiable, Sendable {
        case day = "最近 24 小时", week = "最近 7 天"
        public var id: String { rawValue }
        var seconds: TimeInterval { self == .day ? 86_400 : 7 * 86_400 }
    }

    @Published public var chosen: Set<String> = Set(DiagnosticsExportModel.sections) { didSet { if chosen != oldValue { invalidateScope() } } }
    @Published public var window: Window = .day { didSet { if window != oldValue { invalidateScope() } } }
    @Published public private(set) var preview: JSONValue?
    @Published public private(set) var export: (artifactId: String, data: Data, manifest: JSONValue)?
    @Published public private(set) var working = false
    @Published public private(set) var problem: RuntimeProblem?

    private let runtime: RuntimePort
    private let now: () -> Date

    public init(runtime: RuntimePort, now: @escaping () -> Date = Date.init) {
        self.runtime = runtime
        self.now = now
    }

    var params: [(String, JSONValue)] {
        // A little inside the 7-day limit so the request is never refused
        // for asking a few milliseconds too far back.
        let since = now().addingTimeInterval(-window.seconds + 60)
        let picked = Self.sections.filter { chosen.contains($0) }
        return [("sections", .array(picked.map(JSONValue.string))), ("since", .string(Timestamp.string(since)))]
    }

    private var scopeRevision = 0
    private var previewParams: [(String, JSONValue)]?

    private func invalidateScope() {
        scopeRevision += 1
        preview = nil
        previewParams = nil
        export = nil
        problem = nil
    }

    public var canRun: Bool { !chosen.isEmpty && !working }
    public var canExport: Bool { canRun && preview != nil && previewParams != nil }

    public func runPreview() async {
        guard canRun else { return }
        let revision = scopeRevision
        let requested = params
        preview = nil
        previewParams = nil
        export = nil
        working = true
        problem = nil
        defer { working = false }
        do {
            let manifest = try await runtime.call("diagnostics.export", .obj(requested + [("preview", .bool(true))]))["manifest"]
            guard revision == scopeRevision else { return }
            preview = manifest
            previewParams = manifest == nil ? nil : requested
        } catch {
            guard revision == scopeRevision else { return }
            problem = RuntimeProblem(error)
        }
    }

    public func runExport() async {
        guard canExport, let requested = previewParams else { return }
        let revision = scopeRevision
        export = nil
        working = true
        problem = nil
        defer { working = false }
        do {
            let r = try await runtime.call("diagnostics.export", .obj(requested + [("preview", .bool(false))]))
            guard revision == scopeRevision else { return }
            guard let id = r["artifact"]?["artifactId"]?.stringValue else {
                throw RuntimeError("internal_error", "diagnostics.export gave no artifact", phase: .handler)
            }
            let data = try await ActionRecordsLoader.readArtifact(runtime, id)
            guard revision == scopeRevision else { return }
            export = (id, data, r["manifest"] ?? .null)
            preview = r["manifest"]
        } catch {
            guard revision == scopeRevision else { return }
            problem = RuntimeProblem(error)
        }
    }

    static func sectionName(_ s: String) -> String {
        switch s {
        case "runtime": return "Runtime 身份与权限"
        case "capabilities": return "方法目录"
        case "connections": return "当前连接"
        case "clients": return "客户端与授权摘要"
        case "desktops": return "Desktop"
        case "runs": return "运行与停止证据"
        case "requests": return "请求计数"
        case "authorization": return "拒绝计数"
        default: return s
        }
    }

    static func excludedName(_ s: String) -> String {
        switch s {
        case "credentials and tokens": return "凭据与令牌"
        case "screenshots and other artifacts": return "截图与其他产物"
        case "typed text and action parameters": return "输入的文字与动作参数"
        case "request outcomes": return "请求结果内容"
        case "window titles and app content": return "窗口标题与应用内容"
        case "peer process facts (pid, executable path)": return "对端进程信息（pid、可执行文件路径）"
        case "free-text notes": return "自由文本备注"
        case "the endpoint path": return "端点路径"
        default: return s
        }
    }
}
