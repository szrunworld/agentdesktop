import Foundation

// Everything a person reads, in one place (简体中文). Only fixed strings and
// already-redacted values are interpolated here.

enum ACPEventText {
    // MARK: Action categories and tool kinds

    static func category(_ kind: String?) -> String {
        switch kind ?? "" {
        case "click": return "点击"
        case "type": return "输入文字"
        case "key": return "按键"
        case "scroll": return "滚动"
        case "drag": return "拖动"
        case "observe", "snapshot", "read": return "观察界面"
        case "wait": return "等待界面"
        case "launch": return "启动应用"
        case let k where isSubmitLike(k): return "提交"
        default: return "界面动作"
        }
    }

    /// External effects (submit, send, publish …) are `other`: the editor
    /// should not render them as a local command.
    static func isSubmitLike(_ kind: String?) -> Bool {
        guard let k = kind?.lowercased() else { return false }
        return ["submit", "send", "publish", "post", "external_submit", "outbound", "upload", "pay"].contains(k)
            || k.hasPrefix("submit") || k.hasPrefix("send") || k.hasSuffix("_submit")
    }

    static func toolKind(_ kind: String?) -> ACPToolKind {
        guard let k = kind else { return .other }
        if isSubmitLike(k) { return .other }
        switch k {
        case "observe", "snapshot", "read", "wait": return .read
        case "click", "type", "key", "scroll", "drag", "launch", "act": return .execute
        default: return .other
        }
    }

    // MARK: Three-level action result (docs/plan/06 §6.4)

    static func level(_ l: ACPActionLevel) -> String {
        switch l {
        case .accepted: return "已受理"
        case .dispatched: return "已发出，等待执行结果"
        case .executed: return "已执行，未验证"
        case .verified: return "已验证成功"
        case .contradicted: return "验证未通过"
        case .unknown: return "结果待核实"
        case .failed: return "执行失败"
        case let .refused(code):
            switch code {
            case "not_dispatched", "input_disabled", "target_moved", "invalid_target", "stale_observation",
                 "deadline_exceeded", "stop_pending", "run_not_active", "audit_unavailable", "control_busy",
                 // A receipt with delivery not_dispatched and code execution_failed
                 // (the platform failed before sending): nothing ran, so not "执行失败".
                 "execution_failed", "permission_denied":
                return "未发出"
            default: return "已拒绝"
            }
        }
    }

    static func status(_ l: ACPActionLevel) -> ACPToolStatus {
        switch l {
        case .accepted: return .pending
        case .dispatched: return .inProgress
        case .executed, .verified: return .completed
        case .contradicted, .refused, .failed: return .failed
        // Neither done nor failed: a failed mark invites a retry, which is forbidden.
        case .unknown: return .inProgress
        }
    }

    static func delivery(_ v: String) -> String {
        switch v {
        case "dispatched": return "已发出"
        case "not_dispatched": return "未发出"
        case "unknown": return "未知"
        default: return "未知"
        }
    }

    static func execution(_ v: String) -> String {
        switch v {
        case "completed": return "已完成"
        case "failed": return "失败"
        default: return "未知"
        }
    }

    static func verification(_ v: String?) -> String {
        guard let v else { return "未请求" }
        if ACPProjector.verifiedValues.contains(v) { return "已通过" }
        if ACPProjector.contradictedValues.contains(v) { return "未通过" }
        switch v {
        case "not_requested": return "未请求"
        case "pending": return "进行中"
        default: return "未得出结论"
        }
    }

    static func businessResult(_ v: String) -> String {
        switch v {
        case "not_evaluated": return "未评估"
        case let x where ACPProjector.verifiedValues.contains(x): return "已证实"
        case let x where ACPProjector.contradictedValues.contains(x): return "未证实"
        default: return "未评估"
        }
    }

    // MARK: GUI unit (X1)

    /// `unit.verification` status. Not 「已验证」: whether a matched check
    /// may read as verified is open (docs/acp/12-unit-run.md Q4).
    static func unitVerification(_ status: String?) -> String? {
        switch status ?? "" {
        case "matched": return "已通过"
        case "contradicted": return "未通过"
        case "inconclusive": return "无法判定"
        default: return nil
        }
    }

    /// Why an inconclusive verdict could not decide.
    static func inconclusiveReason(_ reason: String?) -> String? {
        switch reason ?? "" {
        case "elements_partial": return "界面元素只读到一部分"
        case "elements_unavailable": return "没有读到界面元素"
        case "ambiguous": return "目标控件不止一个"
        case "target_missing": return "没有找到目标控件"
        case "value_unreadable": return "目标控件的值读不出"
        default: return nil
        }
    }

    /// `unit.recovery` kind.
    static func recovery(_ kind: String?) -> String? {
        switch kind ?? "" {
        case "reobserve_after_empty_reply": return "模型回复为空，重新观察后再问一次"
        case "reobserve_after_no_action_line": return "模型回复缺少 Action 行，重新观察后再问一次"
        case "repeated_action": return "重复同一动作没有带来变化，重新观察，换一种做法"
        case "no_progress": return "连续几步界面没有变化，重新观察，换一种做法"
        case "state_loop": return "界面回到了之前的状态，重新观察，换一种做法"
        default: return nil
        }
    }

    static let unknownHint = "不会自动重试，请在 AgentDesktop 主窗口核实"
    /// Ruling P2: the terminal form after the Run ended.
    static let terminalUnknown = "结果未知 · 需要核实"
    static let terminalUnknownHint = "不会重试；请在 AgentDesktop 主窗口核实结果后再决定下一步"

    // MARK: Run lifecycle

    /// Closing reasons (`run.ended` / `stop.accepted` / `run.finishing`
    /// data.reason). The catalogue types the field as a free string; these
    /// are the values the Runtime writes today (ExecutionCoordinator.stop
    /// callers, RunStore restart recovery) plus f1's E-8 list. Any other
    /// value is not shown.
    static func closingReason(_ r: String?) -> String? {
        let r = r ?? ""
        switch r {
        case "completed": return "动作已处理完"
        case "finished": return "调用方已结束任务"
        case "stopped", "cancelled": return "已请求停止"
        case "failed": return "任务失败"
        case "owner_lost": return "编辑器连接已断开"
        case "global_stop": return "已全部停止"
        case "runtime_restarted": return "Runtime 已重启"
        case "grant_revoked": return "授权已撤销"
        case "deadline_exceeded": return "超过时限"
        // A GUI unit Run that stopped making progress (X1-2).
        case "no_progress": return "没有进展"
        case "loop_detected": return "界面来回循环"
        default:
            // run.finish {exitCode}: "exit <n>" — a number, safe to show.
            if r.range(of: #"^exit -?[0-9]{1,4}$"#, options: .regularExpression) != nil {
                return "命令已退出（退出码 \(r.dropFirst(5))）"
            }
            return nil
        }
    }

    static func duration(ms: Int) -> String {
        if ms < 1000 { return "\(max(ms, 0)) 毫秒" }
        if ms < 60_000 {
            let tenths = (ms + 50) / 100
            return "\(tenths / 10).\(tenths % 10) 秒"
        }
        let s = ms / 1000
        return "\(s / 60) 分 \(s % 60) 秒"
    }
}
