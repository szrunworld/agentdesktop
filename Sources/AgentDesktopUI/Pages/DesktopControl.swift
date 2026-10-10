import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO

// U3 (Design P12–P18): who controls a Desktop and the owner's stop,
// takeover, handback and close of it. Every state shown comes from a
// runtime/1 answer (Desktop.control, DesktopStopReceipt, DesktopTakeover,
// DesktopHandback, DesktopClosePlan, Run); the page never decides one.

/// Desktop.control as the main window shows it. Without Desktop.control
/// (an older Runtime) the controller is derived from the Desktop's active
/// Runs and the page says so (U2b degradation).
public struct DesktopControlInfo: Equatable, Sendable {
    /// Desktop.control.state; nil when the Runtime gave no Desktop.control.
    public let state: String?
    public let status: StatusText
    public let controller: String
    public let controllerRunId: String?
    public let clientId: String?
    public let since: String?
    public let actionCount: Int?
    /// runtime/1 has no transport in Desktop.control or hub.connections.list.
    public let transport: String
    public let source: String

    public var fromRuntime: Bool { state != nil }

    public static let controlSource = "来自 Desktop.control"
    public static let transportMissing = "Runtime 未提供"
    /// Shown wherever the controller had to be derived.
    public static let missingNote = "Runtime 没有返回 Desktop.control：控制者由运行记录推出，可能不完整；停止、接管、交还仍以 Runtime 的回答为准。"

    public static func make(desktop: JSONValue, activeRuns: [JSONValue]) -> DesktopControlInfo {
        guard let c = desktop["control"], let state = c["state"]?.stringValue else {
            let p = DesktopControlPresentation.make(desktop: desktop, activeRuns: activeRuns)
            let run = activeRuns.first { $0["desktopId"] == desktop["desktopId"] }
            return .init(state: nil, status: p.status, controller: p.controller, controllerRunId: run?["runId"]?.stringValue,
                         clientId: run?["clientId"]?.stringValue, since: run?["createdAt"]?.stringValue, actionCount: p.actionCount,
                         transport: transportMissing, source: DesktopControlPresentation.derivedSource)
        }
        var status = Self.status(state)
        if desktop["state"]?.stringValue == "destroying" { status = StatusText("正在关闭", .attention) }
        let runId = c["controllerRunId"]?.stringValue
        let clientId = c["clientId"]?.stringValue
        let controller: String
        if state == "manual" {
            controller = "你（人工控制）"
        } else if let name = c["clientName"]?.stringValue {
            controller = name
        } else if let clientId {
            controller = clientId
        } else if let runId, let run = activeRuns.first(where: { $0["runId"]?.stringValue == runId }) {
            controller = RunStatusPresentation.originText(run["origin"]?.stringValue)
        } else if let runId {
            controller = "运行 \(runId)"
        } else {
            controller = state == "ready" ? "尚无控制者" : "没有控制者"
        }
        return .init(state: state, status: status, controller: controller, controllerRunId: runId, clientId: clientId,
                     since: c["since"]?.stringValue, actionCount: c["actionCount"]?.intValue, transport: transportMissing,
                     source: controlSource)
    }

    /// Words and tone per Desktop.control.state. "已停止" only for
    /// `stopped`, which the Runtime reports once nothing is in flight.
    public static func status(_ state: String) -> StatusText {
        switch state {
        case "creating": return StatusText("创建中", .idle)
        case "ready": return StatusText("等待接入", .idle)
        case "running": return StatusText("Agent 操作中", .running)
        case "manual": return StatusText("由你控制", .attention)
        case "stopping": return StatusText("正在停止", .attention)
        case "stopped": return StatusText("已停止", .idle)
        case "disconnected": return StatusText("连接断开", .attention)
        case "unknown": return StatusText("结果未知", .attention)
        case "error": return StatusText("出错", .danger)
        default: return StatusText("未知状态（\(state)）", .attention)
        }
    }

    /// What the overview card and list rows take.
    public var presentation: DesktopControlPresentation {
        DesktopControlPresentation(status: status, controller: controller, actionCount: actionCount, source: source)
    }

    /// The owner may ask for a stop: not while one is already under way or
    /// done (P14, P15 grey the button out).
    public var canStop: Bool { state != "stopping" && state != "stopped" && state != "creating" }
    /// Takeover is offered while an agent or nobody holds the Desktop.
    public var canTakeover: Bool { state != "manual" && state != "creating" }
    /// Handback means something only after a takeover or a stop, or after a
    /// last Run that left the Desktop disconnected or unknown.
    public var canHandback: Bool { ["manual", "stopped", "disconnected", "unknown"].contains(state ?? "") }
}

/// The banner over a Desktop's picture for the control states that need
/// the owner's attention (P13–P17), from Desktop.control only.
public struct DesktopControlBannerText: Equatable, Sendable {
    public enum Action: Equatable, Sendable { case handback, review }
    public let title: String
    public let detail: String
    public let tone: StatusTone
    public let action: Action?
    public let actionTitle: String?

    public static func make(_ info: DesktopControlInfo) -> DesktopControlBannerText? {
        switch info.state {
        case "manual":
            return .init(title: "你正在控制这个 Desktop",
                         detail: "Agent 已停止输入，外部 Agent 发来的动作会被拒绝（control_busy）。人工操作只作用于此 Desktop；交还后 Agent 需要从新的观察继续，不重放旧队列。",
                         tone: .attention, action: .handback, actionTitle: "交还控制")
        case "stopping":
            return .init(title: "正在停止输入",
                         detail: "已关闭新动作入口，正在处理在途动作。收到执行端的静止确认后才显示「已停止」。",
                         tone: .attention, action: nil, actionTitle: nil)
        case "stopped":
            return .init(title: "输入已停止，Desktop 保留",
                         detail: "原有队列不会重放。重新开放输入后 Agent 可以重新连接，从新的观察继续；也可以查看记录或关闭 Desktop。",
                         tone: .idle, action: .handback, actionTitle: "重新开放输入")
        case "disconnected":
            return .init(title: "Agent 连接已断开",
                         detail: "本 Desktop 已暂停接收这个 Agent 的输入，其他 Desktop 继续运行。重新连接不会自动重试旧动作。",
                         tone: .attention, action: .handback, actionTitle: "清除并重新开放")
        case "unknown":
            return .init(title: "上一个动作结果待核对",
                         detail: "Runtime 无法确认上一个动作是否到达应用（结果未知）。不会自动重发；先重新观察，再决定是否结束。",
                         tone: .attention, action: .review, actionTitle: "核对动作结果")
        case "creating":
            return .init(title: "正在创建", detail: "Runtime 还在准备这个 Desktop 的资源；就绪前不接受输入。",
                         tone: .idle, action: nil, actionTitle: nil)
        case "error":
            return .init(title: "Desktop 出错", detail: "Runtime 报告这个 Desktop 的资源出错（例如显示器丢失或权限被撤销）；不会改用你的屏幕执行。",
                         tone: .danger, action: nil, actionTitle: nil)
        case nil:
            return .init(title: "控制状态来自运行记录", detail: DesktopControlInfo.missingNote, tone: .idle, action: nil, actionTitle: nil)
        default:
            return nil
        }
    }
}

/// Which A5 methods this Runtime offers (runtime.capabilities). A missing
/// one greys its button out with the reason.
public struct DesktopControlMethods: Equatable, Sendable {
    public let offered: Set<String>
    /// Capabilities not read yet: assume the catalog (the call answers).
    public static let all = DesktopControlMethods(offered: Set(MockRuntime.desktopsLaneMethods + ["desktop.destroy", "observe"]))

    public init(offered: Set<String>) { self.offered = offered }

    public init(capabilities: JSONValue?) {
        guard let list = capabilities?["interface"]?["methods"]?.arrayValue else { self = .all; return }
        offered = Set(list.compactMap { $0["method"]?.stringValue })
    }

    public func has(_ method: String) -> Bool { offered.contains(method) }

    public static func missing(_ method: String) -> String { "当前 Runtime 不提供 \(method)" }
}

/// One Desktop's control actions and their answers, as the Runtime gave
/// them. Closing the page drops this model and nothing else: no Run is
/// stopped or started by it going away (ADR-02).
@MainActor
public final class DesktopControlFlow: ObservableObject {
    public enum Dialog: Equatable, Sendable { case takeover, close, unknown(requestId: String) }

    public enum Operation: String, Sendable {
        case stop, takeover, handback, closePlan, close, quit, resize
    }

    /// A stop as received: accepted first, quiescent only with evidence.
    public enum StopProgress: Equatable, Sendable {
        case none
        /// desktop.stop accepted; the Run it stopped still finishes an
        /// action (quiescence pending).
        case accepted(runId: String)
        /// Nothing of the stopped Run is in flight (quiescence confirmed),
        /// or no Run held the Desktop.
        case quiescent(runId: String?)
    }

    /// desktop.takeover's answer, shown as the Runtime gave it.
    public enum TakeoverAnswer: Equatable, Sendable {
        case done(JSONValue)
        /// stop_pending: accepted, agents' input stays closed, the stopped
        /// Run still finishes an action; ask again later.
        case stopPending(holderRunId: String?, message: String)
        /// conflict, reason superseded: a handback or stop made while it
        /// waited stands; nothing was taken over.
        case superseded(message: String)
        case failed(RuntimeProblem)
    }

    public let desktopId: String
    @Published public var dialog: Dialog?
    @Published public private(set) var working: Operation?
    @Published public private(set) var stopReceipt: JSONValue?
    /// The stopped Run's latest RunStopState / Run (re-read while pending).
    @Published public private(set) var stoppedRun: JSONValue?
    @Published public private(set) var takeoverAnswer: TakeoverAnswer?
    /// After a stop_pending: the holder Run as last read.
    @Published public private(set) var pendingHolder: JSONValue?
    @Published public private(set) var handbackAnswer: JSONValue?
    @Published public private(set) var closePlan: JSONValue?
    @Published public private(set) var closed: JSONValue?
    @Published public private(set) var quitAnswers: [Int: JSONValue] = [:]
    @Published public private(set) var resized: JSONValue?
    @Published public private(set) var problems: [Operation: RuntimeProblem] = [:]

    private let runtime: RuntimePort
    /// Called after a change, so the Store re-reads Desktops and Runs.
    public var changed: (() async -> Void)?

    public init(runtime: RuntimePort, desktopId: String) {
        self.runtime = runtime
        self.desktopId = desktopId
    }

    var idParams: JSONValue { .obj([("desktopId", .string(desktopId))]) }

    public var stopProgress: StopProgress {
        guard let r = stopReceipt else { return .none }
        let run = stoppedRun ?? r["run"]
        guard let run, !run.isNull, let runId = run["runId"]?.stringValue else { return .quiescent(runId: nil) }
        return run["quiescence"]?.stringValue == "confirmed" ? .quiescent(runId: runId) : .accepted(runId: runId)
    }

    /// The two lines of a stop: accepted, then quiescent (UC08, UC09).
    public var stopText: (title: String, detail: String)? {
        switch stopProgress {
        case .none: return nil
        case .accepted(let id):
            return ("停止已受理，等待静止",
                    "已关闭这个 Desktop 的新动作入口；运行 \(id) 仍在处理在途动作（quiescence = pending）。收到静止确认前不显示「已停止」。")
        case .quiescent(let id?):
            return ("已停止", "运行 \(id) 已静止（quiescence = confirmed）。其他 Desktop 不受影响。")
        case .quiescent(nil):
            return ("已停止", "停止时没有运行持有这个 Desktop，没有在途动作；新输入已关闭。其他 Desktop 不受影响。")
        }
    }

    func perform(_ op: Operation, _ body: () async throws -> Void) async {
        guard working == nil else { return }
        working = op
        problems[op] = nil
        do { try await body() } catch { problems[op] = RuntimeProblem(error) }
        working = nil
        await changed?()
    }

    // MARK: Stop (P14, P15)

    public func stop() async {
        await perform(.stop) {
            let r = try await runtime.call("desktop.stop", idParams)
            stopReceipt = r
            stoppedRun = nil
        }
    }

    // MARK: Takeover and handback (P12, P13)

    /// desktop.takeover after the owner confirmed P12. The answer is kept as
    /// the Runtime gave it; a stop_pending or superseded answer starts
    /// nothing.
    public func takeover() async {
        guard working == nil else { return }
        working = .takeover
        problems[.takeover] = nil
        do {
            let r = try await runtime.call("desktop.takeover", idParams)
            takeoverAnswer = .done(r)
            pendingHolder = nil
            dialog = nil
        } catch let e as RuntimeError {
            takeoverAnswer = Self.takeoverAnswer(e)
            if case .stopPending(let holder?, _) = takeoverAnswer {
                pendingHolder = try? await runtime.call("run.show", .obj([("runId", .string(holder))]))
            }
        } catch {
            takeoverAnswer = .failed(RuntimeProblem(error))
        }
        working = nil
        await changed?()
    }

    public static func takeoverAnswer(_ e: RuntimeError) -> TakeoverAnswer {
        if e.code == "stop_pending" {
            return .stopPending(holderRunId: e.details?["holderRunId"]?.stringValue, message: e.message)
        }
        if e.code == "conflict", e.details?["reason"]?.stringValue == "superseded" {
            return .superseded(message: e.message)
        }
        return .failed(RuntimeProblem(e))
    }

    /// Words for a takeover answer that did not take over.
    public static func takeoverText(_ a: TakeoverAnswer) -> (title: String, detail: String, code: String)? {
        switch a {
        case .done: return nil
        case .stopPending(let holder, let message):
            return ("接管已受理，Agent 仍在结束在途动作",
                    "Agent 的输入已关闭，运行 \(holder ?? "—") 还没有静止，所以还没有交给你。等它静止后再点「再次接管」（会是新的请求）。Runtime：\(message)",
                    "stop_pending")
        case .superseded(let message):
            return ("这次接管没有执行",
                    "等待期间你已交还或停止了这个 Desktop，那个决定保留，没有接管任何东西。Runtime：\(message)",
                    "conflict · superseded")
        case .failed(let p):
            return (p.title, p.advice, p.code)
        }
    }

    /// desktop.handback: ends the user's Run, reopens input, forgets the
    /// Desktop's observations (UC15: nothing queued is replayed).
    public func handback() async {
        await perform(.handback) {
            handbackAnswer = try await runtime.call("desktop.handback", idParams)
            takeoverAnswer = nil
            pendingHolder = nil
            stopReceipt = nil
            stoppedRun = nil
            if case .unknown = dialog { dialog = nil }
        }
    }

    public var handbackText: (title: String, detail: String)? {
        guard let h = handbackAnswer else { return nil }
        if h["handedBack"]?.boolValue == true {
            let ended = h["endedRunId"]?.stringValue.map { "已结束人工运行 \($0)；" } ?? ""
            let cleared = h["observationsCleared"]?.boolValue == true
                ? "之前的观察已全部失效，Agent 需要从新的观察继续，旧队列不重放。" : "Runtime 没有报告清除观察。"
            return ("已交还", ended + "输入已重新开放。" + cleared)
        }
        return ("没有需要交还的控制", "Runtime 回答 handedBack = false：这个 Desktop 没有被接管或停止（或由 Agent 持有、或处于全局停止），没有改变任何东西。")
    }

    // MARK: Close (P18), apps, size

    public func openClose() async {
        dialog = .close
        await loadClosePlan()
    }

    /// Reads the plan again. The previous plan is dropped first, so a
    /// failed read leaves no stale plan to close from (Codex P1 on 4dc1360).
    public func loadClosePlan() async {
        guard working == nil else { return }
        closePlan = nil
        await perform(.closePlan) { closePlan = try await runtime.call("desktop.closePlan", idParams) }
    }

    /// desktop.destroy, only when the plan shown says it can close and a
    /// plan read just now is the same: if anything changed (a new app
    /// launched, a Run started) the new plan is shown and nothing closes.
    public func close() async {
        guard let shown = closePlan, shown["canClose"]?.boolValue == true else { return }
        await perform(.close) {
            let fresh = try await runtime.call("desktop.closePlan", idParams)
            guard fresh == shown else {
                closePlan = fresh
                throw RuntimeError("conflict", "the close plan changed since it was shown; read the new plan before closing",
                                   phase: .handler, notSent: true)
            }
            closed = try await runtime.call("desktop.destroy", idParams)
            dialog = nil
        }
    }

    /// Stops input from inside the close dialog when a Run blocks closing;
    /// the plan is read again once the stop is quiescent.
    public func stopBeforeClose() async {
        await stop()
        if case .quiescent = stopProgress { await loadClosePlan() }
    }

    public func quit(pid: Int) async {
        await perform(.quit) {
            quitAnswers[pid] = try await runtime.call("app.quit", .obj([("desktopId", .string(desktopId)), ("pid", .int(pid))]))
        }
        await loadClosePlan()
    }

    public static func quitText(_ a: JSONValue) -> String {
        a["exited"]?.boolValue == true ? "已退出" : (a["quitRequested"]?.boolValue == true ? "已请求退出，尚未确认退出" : "未能请求退出")
    }

    public func resize(width: Int, height: Int) async {
        await perform(.resize) {
            resized = try await runtime.call("desktop.resize", .obj([("desktopId", .string(desktopId)), ("width", .int(width)),
                                                                     ("height", .int(height))]))
        }
    }

    // MARK: Re-reading

    /// Every update round: a pending stop or takeover re-reads its Run; an
    /// open close dialog re-reads its plan once the stop is quiescent.
    public func refresh() async {
        if case .accepted(let runId) = stopProgress,
           let r = try? await runtime.call("run.show", .obj([("runId", .string(runId))])) {
            stoppedRun = r
            if case .quiescent = stopProgress, dialog == .close { await loadClosePlan() }
        }
        if case .stopPending(let holder?, _) = takeoverAnswer,
           let r = try? await runtime.call("run.show", .obj([("runId", .string(holder))])) {
            pendingHolder = r
        }
    }

    /// Drops answers the Desktop has moved past, so an old "已停止" or
    /// "已交还" never sits over a newer state (called each update round
    /// with the Desktop's current Desktop.control.state).
    public func settle(state: String?) {
        guard let state, working == nil else { return }
        if case .quiescent = stopProgress, state != "stopped" { stopReceipt = nil; stoppedRun = nil }
        if case .done = takeoverAnswer, state != "manual" { takeoverAnswer = nil }
        if handbackAnswer != nil, !["ready", "running"].contains(state) { handbackAnswer = nil }
        if resized != nil, state != "ready", state != "running", state != "manual" { resized = nil }
    }

    /// After stop_pending: the holder is quiescent, a new takeover may go.
    public var holderQuiescent: Bool { pendingHolder?["quiescence"]?.stringValue == "confirmed" }
}

/// P17: one action whose result is unknown. Nothing is retried. The owner
/// first observes the Desktop again (a new snapshot, never a change to
/// the original receipt); only then may they end it (desktop.handback),
/// which keeps the Run's outcome unknown (UC29–UC31).
@MainActor
public final class UnknownResultReview: ObservableObject {
    public let entry: ActionEntry
    public let desktopId: String
    @Published public private(set) var observation: JSONValue?
    @Published public private(set) var image: CGImage?
    @Published public private(set) var observing = false
    @Published public private(set) var problem: RuntimeProblem?
    /// run.show of the action's Run after ending: its outcome stays.
    @Published public private(set) var runAfter: JSONValue?

    private let runtime: RuntimePort

    public init(runtime: RuntimePort, desktopId: String, entry: ActionEntry) {
        self.runtime = runtime
        self.desktopId = desktopId
        self.entry = entry
    }

    /// UC29: ending is closed until a new observation with its picture exists.
    public var canEnd: Bool { observation != nil && image != nil }

    public func reobserve() async {
        guard !observing else { return }
        observing = true
        problem = nil
        do {
            let o = try await runtime.call("observe", .obj([("elements", .bool(false))]),
                                           context: RequestContext(desktopId: desktopId))
            // Published only with a picture the owner can look at: ending
            // stays closed when the new screen cannot be shown (Codex P1 on
            // 4dc1360).
            guard let img = try await Self.readImage(runtime, o["image"]) else {
                throw RuntimeError("execution_failed", "the new observation has no picture that can be shown", phase: .handler)
            }
            observation = o
            image = img
        } catch {
            problem = RuntimeProblem(error)
        }
        observing = false
    }

    /// After desktop.handback: what the Run says now (outcome unchanged).
    public func ended() async {
        runAfter = try? await runtime.call("run.show", .obj([("runId", .string(entry.runId))]))
    }

    static func readImage(_ runtime: RuntimePort, _ image: JSONValue?) async throws -> CGImage? {
        guard let image, !image.isNull, let id = image["artifactId"]?.stringValue else { return nil }
        var data = Data()
        var offset = 0
        while true {
            let c = try await runtime.call("artifact.read", .obj([("artifactId", .string(id)), ("offset", .int(offset)),
                                                                  ("length", .int(524_288))]))
            if let b = c["dataBase64"]?.stringValue, let d = Data(base64Encoded: b) { data.append(d) }
            offset += c["length"]?.intValue ?? 0
            if c["eof"]?.boolValue != false || (c["length"]?.intValue ?? 0) == 0 { break }
        }
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }
}

/// Stops from the overview, side by side and preview windows: one
/// DesktopControlFlow per Desktop, so a stop of A never touches B (UC10,
/// UC18) and each keeps its own accepted / quiescent answer.
@MainActor
public final class DesktopStops: ObservableObject {
    @Published public private(set) var flows: [String: DesktopControlFlow] = [:]
    private let store: ShellStore

    public init(store: ShellStore) { self.store = store }

    public func flow(_ desktopId: String) -> DesktopControlFlow {
        if let f = flows[desktopId] { return f }
        let f = DesktopControlFlow(runtime: store.runtime, desktopId: desktopId)
        f.changed = { [weak store] in await store?.refreshDesktops() }
        flows[desktopId] = f
        return f
    }

    public func stop(_ desktopId: String) async {
        let f = flow(desktopId)
        objectWillChange.send()
        await f.stop()
        objectWillChange.send()
    }

    /// Re-reads pending stops (each update round).
    public func refresh() async {
        for f in flows.values { await f.refresh() }
        objectWillChange.send()
    }

    /// One line under a card: the stop's answer, or its problem.
    public func note(_ desktopId: String) -> String? {
        guard let f = flows[desktopId] else { return nil }
        if let p = f.problems[.stop] { return "停止失败：\(p.title)（\(p.code)）" }
        return f.stopText?.title
    }

    /// Whether this Desktop's stop button may be pressed now.
    public func canStop(_ desktopId: String, info: DesktopControlInfo, methods: DesktopControlMethods) -> Bool {
        methods.has("desktop.stop") && info.canStop && flows[desktopId]?.working == nil
    }
}
