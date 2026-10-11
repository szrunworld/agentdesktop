import AgentDesktopProtocol
import Foundation
import SwiftUI

// Lane UI-E (U7 GUI Explorer; docs/plan/11-parallel-lanes.md). What the
// Explorer pages show, derived only from runtime/1 data: Run (kind unit,
// Run.unit) and its events (UnitRunEvent and the run.* lifecycle). Events
// hold ids, enums, codes and numbers; the pages never rebuild screenshots,
// typed text, goals or parameter values from anywhere else.

// MARK: In-process start (A6)

/// The main window's way to start a GUI unit Run in-process: a Durable Run
/// (gui_explorer / platform / platform_durable), never `unit.run` on the
/// wire (ADR v2.2; docs/plan/02 A6). The host gives it the Runtime's
/// `RuntimeService.startDurableUnitRun(params:)`; the answer is the Run.
/// Without one in the environment the pages only observe and say that
/// starting is not wired yet.
public struct ExplorerDurableStart: Sendable {
    let start: @Sendable (JSONValue) async -> Result<JSONValue, RuntimeError>

    public init(_ start: @escaping @Sendable (JSONValue) async -> Result<JSONValue, RuntimeError>) {
        self.start = start
    }

    /// Starts one Run with `unit_run_params`. The params never carry
    /// origin / lifetime / ownership (ExplorerDraft cannot produce them).
    public func callAsFunction(_ params: JSONValue) async -> Result<JSONValue, RuntimeError> {
        await start(params)
    }

    /// The mock's in-process entry (development, tests, renders).
    public static func mock(_ m: MockRuntime) -> ExplorerDurableStart {
        ExplorerDurableStart { params in m.startDurableUnitRun(params: params) }
    }
}

private struct ExplorerDurableStartKey: EnvironmentKey {
    static let defaultValue: ExplorerDurableStart? = nil
}

extension EnvironmentValues {
    /// The in-process Durable start for GUI Explorer; nil until the host
    /// supplies it (then 发起 shows as pending).
    public var explorerDurableStart: ExplorerDurableStart? {
        get { self[ExplorerDurableStartKey.self] }
        set { self[ExplorerDurableStartKey.self] = newValue }
    }
}

// MARK: P27 form

/// What the P27 form collects, and the `unit_run_params` it becomes.
public struct ExplorerDraft: Equatable, Sendable {
    public var desktopId: String?
    public var goal = ""
    /// Text expected on the new observation (element_text_equals).
    public var expectedText = ""
    public var allowed: Set<String> = ["click", "type", "key"]
    public var maxSteps = 20
    public var maxSeconds = 120
    /// The user confirmed the diagnostic's scope (UC41).
    public var scopeConfirmed = false

    public init(desktopId: String? = nil) { self.desktopId = desktopId }

    /// Actions the form offers, in order, with their names.
    public static let actions: [(String, String)] = [("click", "点击"), ("type", "输入文字"), ("key", "按键"),
                                                     ("scroll", "滚动"), ("wait", "等待")]
    /// Defaults are the ceiling (05 §5.2): the form can only tighten them.
    public static let stepCeiling = 20
    public static let secondsCeiling = 120

    var trimmedGoal: String { goal.trimmingCharacters(in: .whitespacesAndNewlines) }
    var trimmedText: String { expectedText.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// Why the form cannot start yet; empty when it can.
    public var problems: [String] {
        var out: [String] = []
        if desktopId == nil { out.append("选择一个空闲的目标 Desktop") }
        if trimmedGoal.isEmpty { out.append("填写局部目标") }
        if trimmedGoal.count > 4096 { out.append("局部目标最多 4096 个字符") }
        if trimmedText.isEmpty { out.append("填写完成后应出现的文字") }
        if trimmedText.count > 1024 { out.append("完成文字最多 1024 个字符") }
        if allowed.isEmpty { out.append("至少允许一种动作") }
        if !(1...Self.stepCeiling).contains(maxSteps) { out.append("步数只能在 1–\(Self.stepCeiling) 之间") }
        if !(1...Self.secondsCeiling).contains(maxSeconds) { out.append("时限只能在 1–\(Self.secondsCeiling) 秒之间") }
        if !scopeConfirmed { out.append("确认诊断范围") }
        return out
    }

    /// `unit_run_params`. Ownership is decided by how the Run is started,
    /// so origin, lifetime and ownership are never part of it.
    public var params: JSONValue {
        .obj([
            ("desktopId", .string(desktopId ?? "")), ("mode", .string("auto")),
            ("goal", .obj([("description", .string(trimmedGoal))])),
            ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")),
                                                         ("role", .string("static_text")),
                                                         ("text", .string(trimmedText))])]))])),
            ("allowedActions", .array(Self.actions.map(\.0).filter(allowed.contains).map(JSONValue.string))),
            ("limits", .obj([("maxSteps", .int(maxSteps)), ("maxSeconds", .int(maxSeconds))])),
        ])
    }

    /// Desktops P27 may target: a bound window and no active Run holding
    /// control (control busy cannot start; P27 rule).
    public static func eligible(desktops: [JSONValue], activeRuns: [JSONValue]) -> [(desktop: JSONValue, blocked: String?)] {
        desktops.map { d in
            if d["state"]?.stringValue == "destroying" { return (d, "正在关闭") }
            if activeRuns.contains(where: { $0["desktopId"] == d["desktopId"] }) { return (d, "控制权已占用") }
            if d["binding"] == nil || d["binding"]?.isNull == true { return (d, "没有绑定窗口") }
            return (d, nil)
        }
    }
}

// MARK: Run timeline

/// One step of a unit Run, as its events tell it.
public struct ExplorerStep: Equatable, Sendable, Identifiable {
    public let index: Int
    public var modelAttempts = 0
    public var inferenceErrors: [String] = []
    /// unit.step.proposed kind (action / wait / finish / needs_user).
    public var proposal: String?
    public var actionKind: String?
    public var rejected: String?
    public var actions: [ExplorerAction] = []
    public var id: Int { index }

    public var proposalText: String {
        if let rejected { return "建议被拒绝，未发出（\(rejected)）" }
        switch proposal {
        case "action": return "模型建议：\(ExplorerText.actionKind(actionKind))"
        case "wait": return "模型建议：等待"
        case "finish": return "模型报告完成：不作为成功依据，由新观察复核"
        case "needs_user": return "模型请求人工处理"
        case nil: return modelAttempts > 0 ? "模型已调用，尚无有效建议" : "等待模型建议"
        default: return "模型建议：\(proposal ?? "—")"
        }
    }
}

/// One `unit.action`: the input the Runtime received for a proposal.
public struct ExplorerAction: Equatable, Sendable, Identifiable {
    public let actionId: String
    public let requestId: String
    public let deliveryState: String
    public var id: String { actionId }

    /// §6.4 levels from `deliveryState` alone (before request.show answers).
    public var status: StatusText { ExplorerText.delivery(deliveryState) }
}

public struct ExplorerVerification: Equatable, Sendable {
    public let status: String
    public let reason: String?
    public let observationId: String?
    public let checkedAt: String?

    public var text: StatusText { ExplorerText.verification(status) }
    public var reasonText: String? { reason.map(ExplorerText.inconclusiveReason) }
}

public struct ExplorerRecovery: Equatable, Sendable {
    public let stepIndex: Int
    public let kind: String
    public let count: Int
    public var text: String { ExplorerText.recovery(kind) }
}

/// Everything the run detail shows, from the Run's events in order.
/// Unknown event types are ignored; unknown enum values are shown by name.
public struct ExplorerTimeline: Equatable, Sendable {
    public private(set) var steps: [ExplorerStep] = []
    /// The latest `unit.progress`: steps used, steps left, attempts left, seconds left.
    public private(set) var progress: (stepIndex: Int, stepsLeft: Int, attemptsLeft: Int, secondsLeft: Int)?
    public private(set) var observations = 0
    public private(set) var verifications: [ExplorerVerification] = []
    public private(set) var recoveries: [ExplorerRecovery] = []
    public private(set) var needsInput: String?
    /// The five P28 stages: 1 观察, 2 模型建议, 3 实际动作, 4 重新观察, 5 条件验证.
    public private(set) var stage = 0

    public static func == (a: ExplorerTimeline, b: ExplorerTimeline) -> Bool {
        a.steps == b.steps && a.observations == b.observations && a.verifications == b.verifications
            && a.recoveries == b.recoveries && a.needsInput == b.needsInput && a.stage == b.stage
            && a.progress?.stepIndex == b.progress?.stepIndex && a.progress?.stepsLeft == b.progress?.stepsLeft
            && a.progress?.attemptsLeft == b.progress?.attemptsLeft && a.progress?.secondsLeft == b.progress?.secondsLeft
    }

    public init(events: [JSONValue]) {
        var actedSinceObservation = false
        for e in events {
            let d = e["data"] ?? .obj([])
            switch e["type"]?.stringValue {
            case "unit.progress":
                progress = (d["stepIndex"]?.intValue ?? 0, d["stepsLeft"]?.intValue ?? 0,
                            d["attemptsLeft"]?.intValue ?? 0, d["secondsLeft"]?.intValue ?? 0)
                _ = step(d["stepIndex"]?.intValue ?? 0)
            case "unit.observation":
                observations += 1
                stage = actedSinceObservation ? 4 : 1
                actedSinceObservation = false
            case "unit.inference.attempt":
                let i = step(d["stepIndex"]?.intValue ?? 0)
                steps[i].modelAttempts += d["attempts"]?.intValue ?? 1
                if let code = d["errorCode"]?.stringValue { steps[i].inferenceErrors.append(code) }
                stage = 2
            case "unit.step.proposed":
                let i = step(d["stepIndex"]?.intValue ?? 0)
                steps[i].proposal = d["kind"]?.stringValue
                steps[i].actionKind = d["actionKind"]?.stringValue
                stage = 2
            case "unit.step.rejected":
                let i = step(d["stepIndex"]?.intValue ?? 0)
                steps[i].rejected = d["reason"]?.stringValue ?? "—"
                stage = 2
            case "unit.action":
                let i = step(d["stepIndex"]?.intValue ?? 0)
                steps[i].actions.append(ExplorerAction(actionId: d["actionId"]?.stringValue ?? "—",
                                                       requestId: d["requestId"]?.stringValue ?? "—",
                                                       deliveryState: d["deliveryState"]?.stringValue ?? "unknown"))
                stage = 3
                actedSinceObservation = true
            case "unit.verification":
                verifications.append(ExplorerVerification(status: d["status"]?.stringValue ?? "—", reason: d["reason"]?.stringValue,
                                                          observationId: d["observationId"]?.stringValue,
                                                          checkedAt: d["checkedAt"]?.stringValue))
                stage = 5
            case "unit.recovery":
                recoveries.append(ExplorerRecovery(stepIndex: d["stepIndex"]?.intValue ?? 0, kind: d["kind"]?.stringValue ?? "—",
                                                   count: d["count"]?.intValue ?? recoveries.count + 1))
            case "unit.needs_input":
                needsInput = d["reason"]?.stringValue ?? "needs_user"
            default:
                break
            }
        }
    }

    private mutating func step(_ index: Int) -> Int {
        if let i = steps.firstIndex(where: { $0.index == index }) { return i }
        steps.append(ExplorerStep(index: index))
        steps.sort { $0.index < $1.index }
        return steps.firstIndex(where: { $0.index == index })!
    }

    /// Model calls in the whole Run (counted apart from inputs; P29).
    public var modelAttempts: Int { steps.reduce(0) { $0 + $1.modelAttempts } }
    /// Inputs the Runtime confirmed delivered.
    public var confirmedInputs: Int { allActions.filter { $0.deliveryState == "confirmed" }.count }
    /// Inputs whose delivery is unknown: only verification, no retry.
    public var unknownInputs: Int { allActions.filter { $0.deliveryState == "unknown" }.count }
    public var allActions: [ExplorerAction] { steps.flatMap(\.actions) }
    public var latestVerification: ExplorerVerification? { verifications.last }

    /// "已用步数": the latest progress' stepIndex, else the steps seen.
    public var stepsUsed: Int { progress?.stepIndex ?? steps.count }
    /// The step budget the Run had (used + left), when progress is known.
    public var stepBudget: Int? { progress.map { $0.stepIndex + $0.stepsLeft } }
}

// MARK: Texts

public enum ExplorerText {
    public static func actionKind(_ k: String?) -> String {
        switch k {
        case "click": return "点击"
        case "type": return "输入文字"
        case "key": return "按键"
        case "scroll": return "滚动"
        case nil: return "动作"
        default: return k ?? "动作"
        }
    }

    /// `unit.action.deliveryState` in the §6.4 words.
    public static func delivery(_ s: String) -> StatusText {
        switch s {
        case "not_sent": return StatusText("未发出", .danger)
        case "rejected": return StatusText("未发出 · 被拒绝", .danger)
        case "submitted": return StatusText("已受理", .idle)
        case "confirmed": return StatusText("已执行，未验证", .running)
        case "unknown": return StatusText("结果未知 · 需要核实", .attention)
        default: return StatusText("结果未知 · 需要核实", .attention)
        }
    }

    /// A receipt-level presentation in the Explorer's words: unknown always
    /// says it needs verification and never offers a retry.
    public static func receipt(_ p: ActionResultPresentation) -> StatusText {
        p.level == .unknown ? StatusText("结果未知 · 需要核实", .attention) : p.status
    }

    public static func verification(_ s: String?) -> StatusText {
        switch s {
        case "matched": return StatusText("已满足", .running)
        case "contradicted": return StatusText("未满足", .danger)
        case "inconclusive": return StatusText("无法判定", .attention)
        case "not_run", nil: return StatusText("尚未验证", .idle)
        default: return StatusText("验证：\(s ?? "—")", .attention)
        }
    }

    public static func inconclusiveReason(_ r: String) -> String {
        switch r {
        case "elements_partial": return "元素树读取不完整，无法证明“不存在”"
        case "elements_unavailable": return "这次没有读到元素树"
        case "ambiguous": return "目标标签对应了不止一个控件"
        case "target_missing": return "完整的元素树里找不到目标控件"
        case "value_unreadable": return "目标控件的值不可读"
        default: return "原因：\(r)"
        }
    }

    /// X1-2 kinds and any later kind: unknown kinds still read as 恢复.
    public static func recovery(_ k: String) -> String {
        switch k {
        case "reobserve_after_empty_reply": return "恢复 · 模型空回复后重新观察"
        case "repeated_action": return "恢复 · 停滞：重复同一动作"
        case "no_progress": return "恢复 · 停滞：长期无进展"
        case "state_loop": return "恢复 · 停滞：界面来回循环"
        default: return "恢复"
        }
    }

    /// Run.closingReason in words, with the code kept beside it.
    public static func closingReason(_ r: String?) -> String? {
        guard let r else { return nil }
        let words: String
        switch r {
        case "goal_verified": words = "完成条件已在新观察上满足"
        case "stopped": words = "已按请求停止"
        case "no_progress": words = "没有进展：恢复一次后仍停滞"
        case "loop_detected": words = "检测到循环：界面回到之前的状态"
        case "action_outcome_unknown": words = "有动作结果未知，运行已结束，需要核实"
        case "deadline_exceeded": words = "时限用完"
        case "limit_exceeded": words = "步数或推理次数用完"
        case "model_empty_response": words = "模型多次返回空回复"
        case "audit_unavailable": words = "运行记录无法写入，已停止"
        case "owner_lost": words = "发起的连接已断开"
        case "global_stop": words = "已停止所有输入"
        case "stale_observation", "stale_generation": words = "观察已过期或目标已变化"
        case "binding_changed", "desktop_not_found": words = "目标窗口或 Desktop 已变化"
        case "finished", "completed": words = "执行端报告结束"
        default: words = "结束原因"
        }
        return "\(words)（\(r)）"
    }

    /// The Run's result for the Explorer: a unit Run succeeds only on a
    /// matched verification; an unknown outcome needs verification.
    public static func runStatus(_ run: JSONValue) -> StatusText {
        if run["phase"]?.stringValue == "ended", run["quiescence"]?.stringValue == "confirmed" {
            switch run["outcome"]?.stringValue {
            case "success": return StatusText("已验证成功", .running)
            case "failed": return StatusText("未完成", .danger)
            case "cancelled": return StatusText("已停止", .idle)
            case "unknown": return StatusText("结果未知 · 需要核实", .attention)
            default: break
            }
        }
        if run["phase"]?.stringValue == "waiting_input" { return StatusText("等待人工", .attention) }
        return RunStatusPresentation.make(run: run)
    }

    public static func originText(_ run: JSONValue) -> String {
        run["origin"]?.stringValue == "gui_explorer" ? "主窗口 · Durable" : "外部 Agent · Delegated"
    }
}
