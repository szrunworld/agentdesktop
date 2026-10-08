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
                 "deadline_exceeded", "stop_pending", "run_not_active":
                return "未发出"
            case "execution_failed": return "执行失败"
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

    static let unknownHint = "不会自动重试，请在 AgentDesktop 主窗口核实"
    /// Ruling P2: the terminal form after the Run ended.
    static let terminalUnknown = "结果未知 · 需要核实"
    static let terminalUnknownHint = "不会重试；请在 AgentDesktop 主窗口核实结果后再决定下一步"

    /// G0 window-identity refusals (RuntimeService+Target.swift
    /// `details.reason`). Window ids, pids and app names in the message are
    /// never shown; only this fixed vocabulary is.
    static func targetReason(_ r: String?) -> String? {
        switch r ?? "" {
        case "window_gone": return "目标窗口已不在该桌面"
        case "not_visible": return "目标窗口不可见"
        case "occluded": return "目标窗口被其他窗口遮挡"
        case "other_window_of_process_in_front": return "同一应用的另一个窗口在前面"
        case "moved": return "目标窗口在发送时移动"
        case "target_changed_during_dispatch": return "发送过程中目标发生变化，输入可能到达其他窗口"
        default: return nil
        }
    }

    // MARK: Run lifecycle

    static func closingReason(_ r: String?) -> String? {
        switch r ?? "" {
        case "owner_lost", "connection_lost": return "编辑器连接已断开"
        case "runtime_restarted": return "Runtime 已重启"
        case "stopped", "cancelled", "cancel", "user_cancel", "user_stop", "stop", "cancel_requested": return "已请求停止"
        case "global_stop", "stop_all": return "已全部停止"
        case "deadline", "deadline_exceeded", "timeout": return "超过时限"
        case "input_disabled": return "输入已关闭"
        default: return nil
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
