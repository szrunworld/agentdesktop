import AgentDesktopProtocol
import Foundation

// Runtime events → ACP session updates (docs/acp/08-event-mapping.md).
//
// Pure and deterministic: the output depends only on the event, the policy
// and (optionally) an `ACPEventContext` value. All redaction happens here,
// before anything reaches a peer, a log or a store. An unknown event type
// becomes one neutral thought line; nothing here throws or traps.

public struct ACPProjector: ACPEventProjector {
    public init() {}

    /// Verification values that mean the Runtime checked and it matched.
    /// Empty on purpose until the verification values are frozen in the
    /// catalogue (f1 E-1): today `ActionReceipt.verification` is the const
    /// `not_requested`, and Kevin's ruling forbids showing 「已验证」 before
    /// verification exists. Any other value is shown as executed, unverified.
    public static let verifiedValues: Set<String> = []
    /// Verification values that mean the Runtime checked and it did not
    /// match. Empty for the same reason.
    public static let contradictedValues: Set<String> = []

    public func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy) -> [ACPSessionUpdate] {
        project(event, policy: policy, context: ACPEventContext())
    }

    public func redact(_ text: String, policy: ACPPrivacyPolicy) -> String {
        ACPRedactor.redact(text, policy: policy)
    }

    /// Project with what earlier events of the session taught (action kinds,
    /// Run kind and start time). Still pure: the context is a value.
    public func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy, context: ACPEventContext) -> [ACPSessionUpdate] {
        let f = ACPEventFacts(event)
        let updates: [ACPSessionUpdate]
        if let t = ACPEventType(rawValue: f.type) {
            // A protected event, or one the Runtime marked withheld, shows its
            // status only: projected under the strictest policy with no content.
            let protected = t.tier == .protected || ACPDataClassifier.isWithheld(f.data)
            updates = project(t, f, protected ? ACPPrivacyPolicy() : policy, context, statusOnly: protected)
        } else if let u = ACPUnitEventType(rawValue: f.type) {
            updates = unit(u, f, statusOnly: u.tier == .protected || ACPDataClassifier.isWithheld(f.data))
        } else {
            let name = ACPRedactor.eventTypeName(f.type) ?? "未知类型"
            updates = [.agentThought("收到未识别的运行事件（\(name)），未作处理")]
        }
        return updates.map(Self.guardUpdate)
    }

    // MARK: Dispatch

    private func project(_ t: ACPEventType, _ f: ACPEventFacts, _ p: ACPPrivacyPolicy, _ c: ACPEventContext,
                         statusOnly: Bool) -> [ACPSessionUpdate] {
        let run = ACPRedactor.identifier(f.runId)
        switch t {
        case .runStarted:
            var text = "任务已开始（Run \(run)）"
            if f.string("lifetime") == "connection_scoped" { text += "；编辑器断开后将停止输入" }
            return [.agentMessage(text), plan(.running)]
        case .stopAccepted:
            var text = "正在停止"
            if f.data["inFlight"]?.boolValue == true { text += "（等待进行中的动作收尾）" }
            if let r = ACPEventText.closingReason(f.string("reason")) { text += "；原因：\(r)" }
            return [.agentMessage(text), plan(.stopping)]
        case .runFinishing:
            var text = "正在收尾"
            if f.data["inFlight"]?.boolValue == true { text += "（等待进行中的动作收尾）" }
            if let r = ACPEventText.closingReason(f.string("reason")) { text += "；原因：\(r)" }
            return [.agentMessage(text), plan(.stopping)]
        case .runQuiescent:
            return [.agentMessage("已停止输入"), plan(.quiescent)]
        case .runEnded:
            return runEnded(f, c)
        case .actionAccepted, .actionDispatched, .actionCompleted, .actionFailed, .actionUnknown, .actionRefused:
            return [action(t, f, p, c, statusOnly: statusOnly)]
        }
    }

    // MARK: GUI unit events (X1)

    /// `unit.verification` and `unit.recovery` as one thought line each:
    /// fixed text for the contract's closed values, a count, nothing else.
    /// No id, verifier, time or any other field of the payload is read.
    private func unit(_ t: ACPUnitEventType, _ f: ACPEventFacts, statusOnly: Bool) -> [ACPSessionUpdate] {
        switch t {
        case .verification:
            guard !statusOnly, let status = ACPEventText.unitVerification(f.string("status")) else {
                return [.agentThought("界面验证：未得出结论")]
            }
            var text = "界面验证：\(status)"
            if f.string("status") == "inconclusive", let why = ACPEventText.inconclusiveReason(f.string("reason")) {
                text += "（\(why)）"
            }
            return [.agentThought(text)]
        case .recovery:
            guard !statusOnly, let what = ACPEventText.recovery(f.string("kind")) else {
                return [.agentThought("已进行一次恢复")]
            }
            var text = "恢复：\(what)"
            if let n = f.data["count"]?.intValue, (1...99).contains(n) { text += "（第 \(n) 次）" }
            return [.agentThought(text)]
        }
    }

    // MARK: Actions

    static func toolCallId(_ f: ACPEventFacts) -> String {
        let req = f.requestId.map(ACPRedactor.identifier) ?? "seq\(f.cursor)"
        return "act:\(ACPRedactor.identifier(f.runId)):\(req)"
    }

    /// The three-level result from a receipt's axes. The receipt is the
    /// Runtime's record, so it wins over the event's name.
    static func level(receipt r: JSONValue, errorCode: String?) -> ACPActionLevel {
        let d = r["delivery"]?.stringValue ?? "", x = r["execution"]?.stringValue ?? ""
        if d == "unknown" || x == "unknown" { return .unknown }
        if d == "not_dispatched" { return .refused(code: ACPRedactor.errorCode(errorCode ?? "not_dispatched")) }
        if x == "failed" { return .failed(code: ACPRedactor.errorCode(errorCode ?? "execution_failed")) }
        guard d == "dispatched", x == "completed" else { return .unknown }
        return level(verification: r["verification"]?.stringValue)
    }

    /// Executed unless the Runtime reports a verification that matched or not.
    static func level(verification v: String?) -> ACPActionLevel {
        guard let v else { return .executed }
        if verifiedValues.contains(v) { return .verified }
        if contradictedValues.contains(v) { return .contradicted }
        return .executed
    }

    private func action(_ t: ACPEventType, _ f: ACPEventFacts, _ p: ACPPrivacyPolicy, _ c: ACPEventContext,
                        statusOnly: Bool) -> ACPSessionUpdate {
        let id = Self.toolCallId(f)
        let kind = f.string("kind") ?? c.actionKinds[id]
        let receipt = f.receipt
        let code = f.reasonCode

        let level: ACPActionLevel
        switch t {
        case .actionAccepted: level = .accepted
        case .actionDispatched: level = .dispatched
        case .actionCompleted: level = receipt.map { Self.level(receipt: $0, errorCode: code) } ?? .executed
        case .actionFailed:
            level = receipt.map { Self.level(receipt: $0, errorCode: code) }
                ?? .failed(code: ACPRedactor.errorCode(code ?? "execution_failed"))
        case .actionUnknown: level = .unknown
        // Refused before any input (G0, stale snapshot, stop, deadline): no receipt.
        case .actionRefused: level = .refused(code: ACPRedactor.errorCode(code ?? "not_dispatched"))
        default: level = .unknown
        }

        let label = ACPEventText.level(level)
        var detail = ["状态：\(label)"]
        if statusOnly {
            if level == .unknown { detail.append(ACPEventText.unknownHint) }
        } else {
            if let r = receipt {
                detail.append("投递：\(ACPEventText.delivery(r["delivery"]?.stringValue ?? "unknown"))")
                detail.append("执行：\(ACPEventText.execution(r["execution"]?.stringValue ?? "unknown"))")
                detail.append("验证：\(ACPEventText.verification(r["verification"]?.stringValue))")
            } else if t == .actionRefused {
                detail.append("投递：\(ACPEventText.delivery("not_dispatched"))")
            }
            if let b = receipt?["businessResult"]?.stringValue {
                detail.append("业务结果：\(ACPEventText.businessResult(b))")
            }
            if let ms = elapsedMs(f, receipt) { detail.append("耗时：\(ACPEventText.duration(ms: ms))") }
            if let target = targetRef(f, receipt) { detail.append("目标：\(target)") }
            if case let .refused(c) = level { detail.append("错误码：\(c)") }
            if case let .failed(c) = level { detail.append("错误码：\(c)") }
            // An unknown receipt's code (action_delivery_unknown) is shown too;
            // the reason's message never is.
            if level == .unknown, let c = code { detail.append("错误码：\(ACPRedactor.errorCode(c))") }
            if let rid = receipt?["receiptId"]?.stringValue { detail.append("回执：\(ACPRedactor.identifier(rid))") }
            if level == .unknown { detail.append(ACPEventText.unknownHint) }
            detail += widened(f, receipt, kind: kind, policy: p)
        }

        let call = ACPToolCall(toolCallId: id, title: "\(ACPEventText.category(kind)) — \(label)",
                               kind: ACPEventText.toolKind(kind), status: ACPEventText.status(level),
                               level: level, detail: detail)
        if t == .actionAccepted { return .toolCall(call) }
        // First word about this action in a Run whose start we saw: announce it.
        let knowsRun = c.runKinds[f.runId] != nil || c.runStartedAt[f.runId] != nil
        if knowsRun, !c.announced.contains(id) { return .toolCall(call) }
        return .toolCallUpdate(call)
    }

    private func elapsedMs(_ f: ACPEventFacts, _ r: JSONValue?) -> Int? {
        // receipt.elapsedMs is a planned field (methods.json plannedFields); until then, timing.
        if let ms = r?["elapsedMs"]?.intValue { return ms }
        guard let timing = r?["timing"],
              let a = timing["acceptedAt"]?.stringValue.flatMap(Self.date),
              let b = timing["completedAt"]?.stringValue.flatMap(Self.date) else { return nil }
        return Int(((b.timeIntervalSince(a)) * 1000).rounded())
    }

    /// A redacted target identifier: never coordinates, labels or titles.
    private func targetRef(_ f: ACPEventFacts, _ r: JSONValue?) -> String? {
        let t = r?["target"] ?? f.data["target"]
        guard let t, t.objectMembers != nil else { return nil }
        let window = t["windowId"]?.intValue
        let element = t["elementRef"]?.stringValue
        if window == nil, element == nil { return nil }
        return ACPRedactor.targetReference(windowId: window, elementRef: element)
    }

    /// Lines only an opt-in policy shows (sensitive tier, redacted). Never
    /// typed values, credentials, window titles or identity data (ruling P1:
    /// main window only), Runtime error messages (they may name other apps'
    /// windows), free-text titles or summaries (they may quote a window
    /// title or a name), or anything outside the bound target.
    private func widened(_ f: ACPEventFacts, _ r: JSONValue?, kind: String?, policy p: ACPPrivacyPolicy) -> [String] {
        var lines: [String] = []
        let target = Self.boundTarget(f, r)
        if p.pageText {
            // Page body only: the bound target's element label, redacted.
            // Window titles never leave the Runtime's main window.
            if let t = target, let v = t["label"]?.stringValue, !v.isEmpty {
                lines.append("元素：\(ACPRedactor.redact(v))")
            }
        }
        let shot: Bool
        switch p.screenshots {
        case .off: shot = false
        case .onSubmit: shot = ACPEventText.isSubmitLike(kind)
        case .all: shot = true
        }
        if shot, let windowId = (r?["target"] ?? f.data["target"])?["windowId"]?.intValue {
            for source in [f.data, r ?? .null] {
                for key in ["screenshot", "image", "evidence"] {
                    // A reference only (artifact id); bytes and paths never
                    // leave. Only an image scoped to the bound window: a
                    // screen or desktop capture could show other apps.
                    guard let img = source[key], img.objectMembers != nil, !ACPDataClassifier.isWithheld(img),
                          img["windowId"]?.intValue == windowId,
                          let a = img["artifactId"]?.stringValue else { continue }
                    lines.append("截图：\(ACPRedactor.identifier(a))（在 AgentDesktop 主窗口查看）")
                }
            }
        }
        return lines
    }

    /// The bound target object of an action, unless withheld. Objects about
    /// other windows (covering*, other*, foreign*) are never targets.
    static func boundTarget(_ f: ACPEventFacts, _ r: JSONValue?) -> JSONValue? {
        let candidates = [f.data["target"], r?["target"]].compactMap { $0 }.filter { $0.objectMembers != nil }
        guard let t = candidates.first, !ACPDataClassifier.isWithheld(t) else { return nil }
        // When both the event and the receipt name a window, they must agree.
        if candidates.count == 2, let a = candidates[0]["windowId"]?.intValue, let b = candidates[1]["windowId"]?.intValue, a != b {
            return nil
        }
        return t
    }

    // MARK: Run end

    private func runEnded(_ f: ACPEventFacts, _ c: ACPEventContext) -> [ACPSessionUpdate] {
        let outcome = f.string("outcome") ?? ""
        // run.ended carries phase, outcome and reason only; the kind is from run.started.
        let kind = c.runKinds[f.runId]
        var text: String
        let final: Stage
        switch outcome {
        case "success":
            if kind == "unit" || kind == "exec" {
                text = "任务结束：已执行（业务结果：未评估）"
                final = .ended(.success)
            } else {
                // A one-action act Run succeeds when its input was delivered (docs/plan/06 §6.4).
                text = "任务结束：已投递（业务结果：未评估）"
                final = .ended(.success)
            }
        case "failed": text = "任务结束：失败"; final = .ended(.failed)
        case "cancelled": text = "任务结束：已取消"; final = .ended(.cancelled)
        default: text = "任务结束：\(ACPEventText.terminalUnknown)（\(ACPEventText.terminalUnknownHint)）"; final = .ended(.unknown)
        }
        // Counted from this session's events (run.ended has no count): unknown
        // results and actions dispatched with no result.
        let n = c.unknownActions.values.filter { $0 == f.runId }.count
            + c.openActions.filter { c.actionRuns[$0.key] == f.runId && $0.value == "dispatched" }.count
        if n > 0 { text += "；\(n) 个动作待核实" }
        if let r = ACPEventText.closingReason(f.string("reason")) { text += "；原因：\(r)" }
        if let s = c.runStartedAt[f.runId].flatMap(Self.date), let e = f.at.flatMap(Self.date) {
            text += "；用时 \(ACPEventText.duration(ms: Int((e.timeIntervalSince(s) * 1000).rounded())))"
        }
        return settleOpenActions(f, c, outcome: outcome) + [.agentMessage(text), plan(final)]
    }

    /// Actions of this Run that never got a result event. Accepted but not
    /// dispatched: the Runtime refused before the delivery boundary (G0
    /// window-identity checks, stale observation), so nothing was sent —
    /// unless the whole Run ended unknown. Dispatched with no result:
    /// unknown, as the Runtime itself counts them (RunStore.inFlightActions).
    private func settleOpenActions(_ f: ACPEventFacts, _ c: ACPEventContext, outcome: String) -> [ACPSessionUpdate] {
        c.openActions.keys.sorted().compactMap { id -> ACPSessionUpdate? in
            guard c.actionRuns[id] == f.runId, let state = c.openActions[id] else { return nil }
            let kind = c.actionKinds[id]
            // Only a Run that ended known (success / failed / cancelled) lets
            // an accepted-only action count as not sent; otherwise unknown.
            guard state == "accepted", ["success", "failed", "cancelled"].contains(outcome) else {
                return Self.terminalUnknown(id, kind: kind, why: "Run 已结束，未收到该动作的执行结果")
            }
            let level: ACPActionLevel = .refused(code: "not_dispatched")
            let label = ACPEventText.level(level)
            let detail = ["状态：\(label)", "Run 已结束，未收到该动作的执行结果", "错误码：not_dispatched"]
            return .toolCallUpdate(ACPToolCall(toolCallId: id, title: "\(ACPEventText.category(kind)) — \(label)",
                                               kind: ACPEventText.toolKind(kind), status: ACPEventText.status(level),
                                               level: level, detail: detail))
        } + c.unknownActions.keys.sorted().compactMap { id -> ACPSessionUpdate? in
            guard c.unknownActions[id] == f.runId else { return nil }
            return Self.terminalUnknown(id, kind: c.actionKinds[id], why: nil)
        }
    }

    /// Ruling P2: once the Run has ended an unknown action is terminal —
    /// execution terminated, outcome unknown. Status `.failed` only because
    /// ACP v1 has no neutral terminal status (the Wire adds rawOutput
    /// {execution: terminated, outcome: unknown}); the level stays
    /// `.unknown`, never `.failed` / `.refused`, and it is never retried.
    static func terminalUnknown(_ id: String, kind: String?, why: String?) -> ACPSessionUpdate {
        var detail = ["状态：\(ACPEventText.terminalUnknown)", "执行已终止，结果未知"]
        if let why { detail.append(why) }
        detail.append(ACPEventText.terminalUnknownHint)
        return .toolCallUpdate(ACPToolCall(toolCallId: id, title: "\(ACPEventText.category(kind)) — \(ACPEventText.terminalUnknown)",
                                           kind: ACPEventText.toolKind(kind), status: .failed, level: .unknown, detail: detail))
    }

    // MARK: Plan (Run lifecycle as four steps)

    enum Ending { case success, failed, cancelled, unknown }
    enum Stage { case running, stopping, quiescent, ended(Ending) }

    private func plan(_ s: Stage) -> ACPSessionUpdate {
        let rank: Int
        switch s {
        case .running: rank = 2
        case .stopping: rank = 3
        case .quiescent: rank = 4
        case .ended: rank = 5
        }
        func st(doneAt: Int, activeAt: Int) -> ACPPlanEntry.Status {
            rank >= doneAt ? .completed : rank >= activeAt ? .inProgress : .pending
        }
        var result = ACPPlanEntry(content: "结果", status: rank == 4 ? .inProgress : .pending)
        if case let .ended(e) = s {
            switch e {
            case .success: result = ACPPlanEntry(content: "结果：已结束（业务结果未评估）", status: .completed)
            case .failed: result = ACPPlanEntry(content: "结果：失败", status: .completed)
            case .cancelled: result = ACPPlanEntry(content: "结果：已取消", status: .completed)
            // Ruling P2: terminal, not in progress; the content, not the
            // mark, says the outcome is unknown.
            case .unknown: result = ACPPlanEntry(content: "结果：未知 · 需要核实", status: .completed)
            }
        }
        return .plan([
            ACPPlanEntry(content: "受理任务", status: .completed),
            ACPPlanEntry(content: "执行", status: st(doneAt: 3, activeAt: 2)),
            ACPPlanEntry(content: "停止输入并收尾", status: st(doneAt: 4, activeAt: 3)),
            result,
        ])
    }

    // MARK: Helpers

    static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }

    /// Last pass over every string of an update (defence in depth).
    static func guardUpdate(_ u: ACPSessionUpdate) -> ACPSessionUpdate {
        let g = ACPRedactor.guardOutput
        func call(_ c: ACPToolCall) -> ACPToolCall {
            var c = c
            c.title = g(c.title)
            c.detail = c.detail.map(g)
            return c
        }
        switch u {
        case let .userMessage(s): return .userMessage(g(s))
        case let .agentMessage(s): return .agentMessage(g(s))
        case let .agentThought(s): return .agentThought(g(s))
        case let .plan(es): return .plan(es.map { ACPPlanEntry(content: g($0.content), status: $0.status) })
        case let .toolCall(c): return .toolCall(call(c))
        case let .toolCallUpdate(c): return .toolCallUpdate(call(c))
        case let .sessionInfo(title): return .sessionInfo(title: g(title))
        default: return u
        }
    }
}

/// A session's projector with its learned context. Value type: the server
/// keeps one per ACP session and feeds it events in cursor order.
public struct ACPProjectorSession: Sendable {
    public private(set) var context = ACPEventContext()
    public let projector = ACPProjector()
    public init() {}

    public mutating func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy) -> [ACPSessionUpdate] {
        let out = projector.project(event, policy: policy, context: context)
        context.absorb(event)
        return out
    }
}
