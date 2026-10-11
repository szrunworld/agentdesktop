import AgentDesktopProtocol
import Foundation

// What the Runs pages (U5: Hub W04–W05, P19–P20) say about a Run, an action
// and a request record. Only runtime/1 fields decide the words
// (docs/plan/06 §6.3–6.4); nothing here infers a state of its own.
//
// Lane UI-A keeps these here rather than in Presentation/Presentation.swift
// (a file no lane owns); a later shared PR may move them.

/// A Run's three axes, each in words, plus the GUI unit's verification.
public enum RunsText {
    /// Platform phase (`phase`). `stopping` stays 停止中 until the Runtime
    /// reports quiescence; `ended` only ever comes with `confirmed`.
    public static func phase(_ run: JSONValue) -> StatusText {
        switch run["phase"]?.stringValue {
        case "queued": return StatusText("排队中", .idle)
        case "running": return StatusText("运行中", .running)
        case "waiting_approval": return StatusText("等待审批", .attention)
        case "waiting_input": return StatusText("等待输入", .attention)
        case "stopping": return StatusText("停止中", .attention)
        case "ended": return StatusText("已结束", .idle)
        default: return StatusText("未知阶段", .attention)
        }
    }

    public static let unknownTitle = "结果未知 · 需要核实"

    /// Final result (`outcome`). A single `act` Run that succeeded was
    /// delivered, not proven: 已投递 (§6.4). A unit Run's success says only
    /// that it finished; whether the goal was reached is its verification.
    public static func outcome(_ run: JSONValue) -> StatusText {
        let kind = run["kind"]?.stringValue
        switch run["outcome"]?.stringValue {
        case nil: return StatusText("尚无结果", .idle)
        case "success":
            switch kind {
            case "act": return StatusText("已投递", .idle)
            case "unit": return StatusText("已完成", .running)
            default: return StatusText("成功", .running)
            }
        case "failed": return StatusText("失败", .danger)
        case "cancelled": return StatusText("已停止", .idle)
        case "unknown": return StatusText(unknownTitle, .attention)
        default: return StatusText("未知结果", .attention)
        }
    }

    /// Input quiescence (`quiescence`): only `confirmed` is evidence that
    /// the executor stopped sending input.
    public static func quiescence(_ run: JSONValue) -> StatusText {
        switch run["quiescence"]?.stringValue {
        case "not_confirmed": return StatusText("未确认", .idle)
        case "pending": return StatusText("等待静止证据", .attention)
        case "confirmed": return StatusText("已确认静止", .running)
        default: return StatusText("未知", .attention)
        }
    }

    /// The verification level of a Run (the third of §6.4's three levels):
    /// - `unit`: `Run.unit.verification.status` — matched / contradicted /
    ///   inconclusive (无法判定) / not_run;
    /// - `act`: the platform never verifies (`verification = not_requested`);
    /// - `exec`: nothing to verify (nil).
    public static func verification(_ run: JSONValue) -> StatusText? {
        switch run["kind"]?.stringValue {
        case "unit": return unitVerification(run["unit"]?["verification"]?["status"]?.stringValue)
        case "act": return StatusText("未请求验证", .idle)
        default: return nil
        }
    }

    public static func unitVerification(_ status: String?) -> StatusText {
        switch status {
        case "matched": return StatusText("已验证成功", .running)
        case "contradicted": return StatusText("验证未通过", .danger)
        case "inconclusive": return StatusText("无法判定", .attention)
        case "not_run": return StatusText("未验证", .idle)
        default: return StatusText("尚无验证", .idle)
        }
    }

    /// The one badge of a list row. While a Run is not ended it is its
    /// phase; once ended its outcome, except that a unit Run that finished
    /// shows its verification (a finished unit is not yet a reached goal).
    public static func summary(_ run: JSONValue) -> StatusText {
        guard run["phase"]?.stringValue == "ended" else { return phase(run) }
        if run["quiescence"]?.stringValue != "confirmed" { return StatusText("停止中", .attention) }
        if run["kind"]?.stringValue == "unit", run["outcome"]?.stringValue == "success",
           let v = verification(run) { return v }
        return outcome(run)
    }

    public static func kindText(_ kind: String?) -> String {
        switch kind {
        case "act": return "单次动作"
        case "exec": return "命令执行"
        case "unit": return "GUI 单元"
        default: return "—"
        }
    }

    public static func modeText(_ mode: String?) -> String {
        switch mode {
        case "auto": return "自动（auto）"
        case "replay_only": return "只回放（replay_only）"
        case "explore": return "探索（explore）"
        default: return "—"
        }
    }

    /// A Run event's type in words; types the catalog does not name yet
    /// (F1-01) are shown as they are.
    public static func eventTitle(_ type: String?) -> String {
        switch type {
        case "run.started": return "平台接收执行"
        case "action.accepted": return "动作已受理"
        case "action.dispatched": return "动作已投递"
        case "action.completed": return "动作已执行（未验证）"
        case "action.failed": return "动作执行失败或未发出"
        case "action.unknown": return "动作结果未知"
        case "action.refused": return "动作被拒绝，未发出"
        case "stop.accepted": return "停止请求已受理"
        case "run.finishing": return "正在完成"
        case "run.quiescent": return "执行端已确认输入静止"
        case "run.ended": return "运行结束"
        case "unit.observation": return "观察画面"
        case "unit.progress": return "单元进度"
        case "unit.inference.attempt": return "模型推理"
        case "unit.step.proposed": return "提出步骤"
        case "unit.step.rejected": return "步骤被拒绝"
        case "unit.action": return "单元动作"
        case "unit.recovery": return "恢复"
        case "unit.verification": return "验证"
        case "unit.needs_input": return "需要输入"
        default: return type ?? "—"
        }
    }

    /// The facts an event carries that help reading the timeline (ids,
    /// codes, enums; event data never holds content).
    public static func eventDetail(_ e: JSONValue) -> String {
        let d = e["data"]
        var parts: [String] = []
        if let r = d?["requestId"]?.stringValue ?? d?["receipt"]?["requestId"]?.stringValue { parts.append(r) }
        if let k = d?["kind"]?.stringValue { parts.append("kind \(k)") }
        if let r = d?["reason"]?.stringValue { parts.append("原因 \(r)") }
        if let r = d?["reason"]?["code"]?.stringValue { parts.append("原因 \(r)") }
        if let o = d?["outcome"]?.stringValue { parts.append("outcome \(o)") }
        if let s = d?["status"]?.stringValue { parts.append("status \(s)") }
        if let s = d?["deliveryState"]?.stringValue { parts.append("投递 \(s)") }
        if let o = d?["observationId"]?.stringValue { parts.append(o) }
        if let s = d?["stepIndex"]?.intValue { parts.append("第 \(s) 步") }
        if let r = d?["receipt"] {
            parts.append("投递 \(r["delivery"]?.stringValue ?? "—") · 执行 \(r["execution"]?.stringValue ?? "—")")
        }
        return parts.joined(separator: " · ")
    }
}

/// One action result in §6.4's three levels — delivery, execution,
/// verification — each with its own words, and the one badge that sums
/// them up. Built from a receipt (Run event or request record) or from a
/// request record that has no receipt (a refusal, or another method).
public struct ActionLevels: Equatable, Sendable {
    /// The summary badge. `结果未知 · 需要核实` for any unknown level;
    /// `已执行，未验证` is the best a platform receipt can say.
    public let summary: StatusText
    /// Nil when there is no receipt (accepted only, or not an input method).
    public let delivery: String?
    public let execution: String?
    public let verification: String?
    /// The code that said why (receipt.reason, or the request's error).
    public let reasonCode: String?
    public let reasonMessage: String?
    public let hasReceipt: Bool
    /// Only an unknown result may be reconciled (run.reconcile, PR4); no
    /// level ever offers a retry (§6.3).
    public let needsReconciliation: Bool
    public var canRetry: Bool { false }

    public static func receipt(_ receipt: JSONValue?, errorCode: String? = nil, refused: JSONValue? = nil) -> ActionLevels {
        guard let receipt, let delivery = receipt["delivery"]?.stringValue,
              let execution = receipt["execution"]?.stringValue else {
            if let refused {
                return ActionLevels(summary: StatusText("未发出", .danger), delivery: "未发出（被拒绝）", execution: nil,
                                    verification: nil, reasonCode: refused["code"]?.stringValue ?? errorCode,
                                    reasonMessage: refused["message"]?.stringValue, hasReceipt: false,
                                    needsReconciliation: false)
            }
            return ActionLevels(summary: StatusText("已受理", .idle), delivery: nil, execution: nil, verification: nil,
                                reasonCode: errorCode, reasonMessage: nil, hasReceipt: false, needsReconciliation: false)
        }
        let p = ActionResultPresentation.make(receipt: receipt, errorCode: errorCode)
        let summary = p.level == .unknown ? StatusText(RunsText.unknownTitle, .attention) : p.status
        let reason = receipt["reason"]
        return ActionLevels(summary: summary, delivery: deliveryText(delivery), execution: executionText(execution),
                            verification: verificationText(receipt["verification"]?.stringValue),
                            reasonCode: reason?["code"]?.stringValue ?? p.reasonCode,
                            reasonMessage: reason?["message"]?.stringValue, hasReceipt: true,
                            needsReconciliation: p.needsReconciliation)
    }

    /// From a RequestRecord (request.show / request.list). An input action
    /// carries its receipt (as the outcome, or in the error's details);
    /// any other method is summed up by the record's state.
    public static func record(_ r: JSONValue) -> ActionLevels {
        let outcome = r["outcome"]
        let error = outcome?["error"]
        let code = error?["code"]?.stringValue
        if let receipt = ActionsRecord.receipt(of: r) { return Self.receipt(receipt, errorCode: code) }
        let state = r["state"]?.stringValue
        if let error {
            if state == "unknown" {
                return ActionLevels(summary: StatusText(RunsText.unknownTitle, .attention), delivery: nil, execution: nil,
                                    verification: nil, reasonCode: code, reasonMessage: error["message"]?.stringValue,
                                    hasReceipt: false, needsReconciliation: true)
            }
            let notSent = error["notSent"]?.boolValue == true
            return ActionLevels(summary: StatusText(notSent ? "未发出" : "失败", .danger),
                                delivery: notSent ? "未发出" : nil, execution: nil, verification: nil,
                                reasonCode: code, reasonMessage: error["message"]?.stringValue, hasReceipt: false,
                                needsReconciliation: false)
        }
        let summary: StatusText
        switch state {
        case "completed": summary = StatusText("已完成", .running)
        case "failed": summary = StatusText("失败", .danger)
        case "unknown": summary = StatusText(RunsText.unknownTitle, .attention)
        default: summary = StatusText("已受理", .idle)
        }
        return ActionLevels(summary: summary, delivery: nil, execution: nil, verification: nil, reasonCode: nil,
                            reasonMessage: nil, hasReceipt: false, needsReconciliation: state == "unknown")
    }

    /// "原因文字（code）", or that the Runtime gave none when one is due.
    public var reasonText: String? {
        if let reasonCode { return "\(RuntimeProblem.text(reasonCode).0)（\(reasonCode)）" }
        return summary.text == "未发出" ? "Runtime 未提供原因" : nil
    }

    static func deliveryText(_ v: String) -> String {
        switch v {
        case "dispatched": return "已投递（dispatched）"
        case "not_dispatched": return "未发出（not_dispatched）"
        case "unknown": return "未知（unknown）"
        default: return v
        }
    }

    static func executionText(_ v: String) -> String {
        switch v {
        case "completed": return "已执行（completed）"
        case "failed": return "失败（failed）"
        case "unknown": return "未知（unknown）"
        default: return v
        }
    }

    static func verificationText(_ v: String?) -> String {
        switch v {
        case "not_requested", nil: return "未请求（平台不判断目标是否变化）"
        default: return v!
        }
    }
}

/// Reading a RequestRecord.
public enum ActionsRecord {
    /// The ActionReceipt inside a record. The ledger stores a success as
    /// `outcome.data` and a failure as `outcome.error` (with the receipt in
    /// `details.receipt`); a bare receipt as the outcome (older mock
    /// records) is read too.
    public static func receipt(of r: JSONValue) -> JSONValue? {
        guard let outcome = r["outcome"], !outcome.isNull else { return nil }
        if let e = outcome["error"] { return e["details"]?["receipt"] }
        if let d = outcome["data"] { return d["delivery"] != nil ? d : nil }
        return outcome["delivery"] != nil ? outcome : nil
    }

    /// "route ax · 81 ms" from a receipt's route and timing.
    public static func detail(_ r: JSONValue) -> String {
        guard let receipt = receipt(of: r) else { return r["state"]?.stringValue ?? "—" }
        var parts: [String] = []
        if let route = receipt["route"]?.stringValue { parts.append("route \(route)") }
        if let ms = elapsedMs(receipt) { parts.append("\(ms) ms") }
        return parts.isEmpty ? "—" : parts.joined(separator: " · ")
    }

    /// Accepted → completed, from the receipt's timing.
    public static func elapsedMs(_ receipt: JSONValue) -> Int? {
        guard let a = Timestamp.parse(receipt["timing"]?["acceptedAt"]?.stringValue),
              let c = Timestamp.parse(receipt["timing"]?["completedAt"]?.stringValue) else { return nil }
        return max(0, Int((c.timeIntervalSince(a) * 1000).rounded()))
    }

    /// A value as indented JSON in its own key order (P20's code box and
    /// the exported receipt).
    public static func prettyJSON(_ v: JSONValue, indent: String = "") -> String {
        let inner = indent + "  "
        switch v {
        case let .array(items):
            guard !items.isEmpty else { return "[]" }
            return "[\n" + items.map { inner + prettyJSON($0, indent: inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        case let .object(members):
            guard !members.isEmpty else { return "{}" }
            return "{\n" + members.map { inner + JSONValue.string($0.key).encoded() + ": " + prettyJSON($0.value, indent: inner) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        default:
            return v.encoded()
        }
    }
}

extension Timestamp {
    static func parse(_ iso: String?) -> Date? { iso.flatMap(date) }
}
