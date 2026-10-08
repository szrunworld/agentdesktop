import AgentDesktopProtocol
import Foundation

/// What a badge says: words and a tone, always together.
public struct StatusText: Equatable, Sendable {
    public let text: String
    public let tone: StatusTone

    public init(_ text: String, _ tone: StatusTone) {
        self.text = text
        self.tone = tone
    }
}

// MARK: Action results (docs/plan/06 §6.4)

/// The levels of an action result. Only runtime/1 fields decide the level;
/// receiving or delivering is never shown as success.
public enum ActionResultLevel: String, Equatable, Sendable, CaseIterable {
    /// The request is in the ledger (request.show has it), no receipt yet.
    case accepted
    /// `delivery = not_dispatched`.
    case notDispatched
    /// `delivery = dispatched` and `execution = completed`; with
    /// `verification = not_requested` this is all the platform knows.
    case executedUnverified
    /// `execution = failed` after dispatch.
    case failed
    /// `delivery` or `execution` is `unknown`: only reconciliation, no retry.
    case unknown
}

public struct ActionResultPresentation: Equatable, Sendable {
    public let level: ActionResultLevel
    public let title: String
    public let tone: StatusTone
    /// For `notDispatched`: the error code that said why, when known.
    public let reasonCode: String?
    /// Never offered: §6.3 "没有「重试未知动作」按钮".
    public let canRetry: Bool
    /// Only `unknown` may be reconciled (run.reconcile, PR4).
    public let needsReconciliation: Bool
    /// ActionReceipt has no businessResult yet; the platform never judges it.
    public let businessResult: String

    public var status: StatusText { StatusText(title, tone) }

    public static let businessNotEvaluated = "业务结果：未评估"

    /// From an ActionReceipt (may be nil) and, when known, the error code the
    /// request failed with (the error response, or RequestRecord.outcome.error).
    public static func make(receipt: JSONValue?, errorCode: String? = nil) -> ActionResultPresentation {
        guard let receipt, let delivery = receipt["delivery"]?.stringValue,
              let execution = receipt["execution"]?.stringValue else {
            return .init(level: .accepted, title: "已受理", tone: .idle, reasonCode: nil, canRetry: false,
                         needsReconciliation: false, businessResult: businessNotEvaluated)
        }
        if delivery == "not_dispatched" {
            return .init(level: .notDispatched, title: "未发出", tone: .danger, reasonCode: errorCode, canRetry: false,
                         needsReconciliation: false, businessResult: businessNotEvaluated)
        }
        if delivery == "unknown" || execution == "unknown" {
            return .init(level: .unknown, title: "结果未知", tone: .attention, reasonCode: errorCode, canRetry: false,
                         needsReconciliation: true, businessResult: businessNotEvaluated)
        }
        if execution == "failed" {
            return .init(level: .failed, title: "执行失败", tone: .danger, reasonCode: errorCode, canRetry: false,
                         needsReconciliation: false, businessResult: businessNotEvaluated)
        }
        return .init(level: .executedUnverified, title: "已执行，未验证", tone: .running, reasonCode: nil, canRetry: false,
                     needsReconciliation: false, businessResult: businessNotEvaluated)
    }

    /// From a RequestRecord: `outcome` is the receipt, or `{error}` whose
    /// `details.receipt` carries it; no outcome means only accepted.
    public static func make(record: JSONValue) -> ActionResultPresentation {
        guard let outcome = record["outcome"], !outcome.isNull else { return make(receipt: nil) }
        if let error = outcome["error"] {
            return make(receipt: error["details"]?["receipt"], errorCode: error["code"]?.stringValue)
        }
        return make(receipt: outcome)
    }

    /// The line under the title for `notDispatched`: the reason, or that the
    /// Runtime gave none.
    public var reasonText: String? {
        guard level == .notDispatched || level == .failed else { return nil }
        guard let reasonCode else { return level == .notDispatched ? "Runtime 未提供原因" : nil }
        return "\(RuntimeProblem.text(reasonCode).0)（\(reasonCode)）"
    }
}

// MARK: Runs

public enum RunStatusPresentation {
    /// Phase while running; outcome once ended. `stopping` stays "停止中"
    /// until quiescence is confirmed (§6.3). A single `act` Run that ended
    /// with `success` was delivered, not proven: "已投递" (§6.4).
    public static func make(run: JSONValue) -> StatusText {
        let phase = run["phase"]?.stringValue ?? ""
        switch phase {
        case "queued": return StatusText("排队中", .idle)
        case "running": return StatusText("运行中", .running)
        case "waiting_approval": return StatusText("等待审批", .attention)
        case "waiting_input": return StatusText("等待输入", .attention)
        case "stopping": return StatusText("停止中", .attention)
        case "ended":
            if run["quiescence"]?.stringValue != "confirmed" { return StatusText("停止中", .attention) }
            switch run["outcome"]?.stringValue {
            case "success":
                return run["kind"]?.stringValue == "act" ? StatusText("已投递", .idle) : StatusText("成功", .running)
            case "failed": return StatusText("失败", .danger)
            case "cancelled": return StatusText("已停止", .idle)
            case "unknown": return StatusText("结果未知", .attention)
            default: return StatusText("已结束", .idle)
            }
        default: return StatusText("未知状态", .attention)
        }
    }

    public static func originText(_ origin: String?) -> String {
        switch origin {
        case "agent_hub": return "外部 Agent"
        case "gui_explorer": return "GUI Explorer"
        case "workflow_replay": return "流程回放"
        case "user": return "人工"
        default: return "—"
        }
    }
}

// MARK: Desktops

/// What a Desktop card shows about who controls it. Desktop.control is not
/// in the contract yet (A5), so the controller comes from the Desktop's
/// active Runs (run.list {desktopId, active:true}) and says so.
public struct DesktopControlPresentation: Equatable, Sendable {
    public let status: StatusText
    public let controller: String
    /// Receipts of the active Run (Run.receipts), the only count available.
    public let actionCount: Int?
    public let source: String

    public static let derivedSource = "来自运行记录"

    public static func make(desktop: JSONValue, activeRuns: [JSONValue]) -> DesktopControlPresentation {
        if desktop["state"]?.stringValue == "destroying" {
            return .init(status: StatusText("正在关闭", .attention), controller: "—", actionCount: nil, source: derivedSource)
        }
        guard let run = activeRuns.first(where: { $0["desktopId"] == desktop["desktopId"] }) else {
            return .init(status: StatusText("等待接入", .idle), controller: "尚无控制者", actionCount: 0, source: derivedSource)
        }
        let status: StatusText
        switch run["phase"]?.stringValue {
        case "stopping": status = StatusText("停止中", .attention)
        case "waiting_approval", "waiting_input": status = StatusText("等待中", .attention)
        default:
            status = run["origin"]?.stringValue == "user" ? StatusText("人工控制中", .attention)
                : StatusText(run["origin"]?.stringValue == "gui_explorer" ? "Explorer 运行中" : "Agent 操作中", .running)
        }
        let who = run["clientId"]?.stringValue ?? RunStatusPresentation.originText(run["origin"]?.stringValue)
        return .init(status: status, controller: who, actionCount: run["receipts"]?.arrayValue?.count, source: derivedSource)
    }

    /// "1280 × 800" from Desktop.screen.frame.
    public static func sizeText(_ desktop: JSONValue) -> String {
        guard let f = desktop["screen"]?["frame"], let w = f["width"]?.intValue, let h = f["height"]?.intValue else { return "—" }
        return "\(w) × \(h)"
    }
}

enum TimeText {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    static func clock(_ iso: String?) -> String {
        guard let iso else { return "—" }
        let p = ISO8601DateFormatter()
        p.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = p.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
        guard let date else { return "—" }
        let f = DateFormatter()
        f.timeZone = shanghai
        f.dateFormat = "HH:mm:ss"
        return f.string(from: date)
    }
}
