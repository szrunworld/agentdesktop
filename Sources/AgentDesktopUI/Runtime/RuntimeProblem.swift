import AgentDesktopProtocol
import Foundation

/// A runtime/1 failure as a page shows it: the stable code, Chinese text
/// saying what happened and what the user can do. Never a secret, typed
/// text or a parameter value (runtime/1 errors carry none).
///
/// The wording follows AgentDesktopAIUI's `UIProblem`; codes follow
/// `contracts/runtime/v1/errors.json` and the service → runtime/1 map in the
/// freeze document §6. RuntimeProblemTests checks every code has text.
public struct RuntimeProblem: Equatable, Sendable {
    public let code: String
    public let title: String
    public let advice: String
    /// True when the action was certainly not performed (`notSent`, #170):
    /// no input and no outside write went out.
    public let notSent: Bool

    public init(code: String, title: String, advice: String, notSent: Bool = false) {
        self.code = code
        self.title = title
        self.advice = advice
        self.notSent = notSent
    }

    public init(_ error: Error) {
        guard let e = error as? RuntimeError else {
            let (t, a) = Self.text("internal_error")
            self.init(code: "internal_error", title: t, advice: a)
            return
        }
        let (t, a) = Self.text(e.code)
        // A refusal that names its reason says what the user can do instead.
        let advice = e.details?["reason"]?.stringValue.flatMap(Self.reasonAdvice) ?? a
        self.init(code: e.code, title: t, advice: advice, notSent: e.notSent ?? false)
    }

    /// Advice for refusals whose `details.reason` changes what to do.
    static func reasonAdvice(_ reason: String) -> String? {
        switch reason {
        case "bind_requires_grant":
            return "在逐窗口授权上线前，只能绑定由这个 Desktop 启动的应用。请改用“启动应用”。"
        case "screen_capture_requires_grant":
            return "这个 Desktop 还没有绑定窗口；没有整屏授权时不截整个屏幕。请先绑定窗口。"
        case "no_launch_apps_configured":
            return "未配置允许启动的应用。启动前必须能证明新进程确实由这次启动创建；目前没有任何应用通过这项验证，所以 AgentDesktop 不会打开它。"
        case "launch_not_verified":
            return "这个应用（或它的当前版本）还没有通过启动归属验证，AgentDesktop 不会打开它。应用更新后需要重新验证。"
        case "launch_unprovable":
            return "无法证明这个应用的新进程由这次启动创建（没有有效签名、只允许单实例或没有 Bundle ID），AgentDesktop 不会打开它。"
        case "app_already_running":
            return "这个应用已经在运行，是你正在使用的实例。Agent 不会再启动它，也不会动它的窗口。"
        case "launch_failed":
            return "系统的启动调用失败了，无法确定应用是否已经启动。AgentDesktop 不会自动重试，也没有移动或绑定任何窗口；请查看屏幕后再决定是否重新启动。"
        case "launch_refused_after_open":
            return "应用已被打开，但无法证明新进程属于这次启动，所以没有移动或绑定它的窗口。它可能留在你的屏幕上，可以手动关闭。"
        case "physical_desktop_requires_grant":
            return "在逐窗口授权上线前，不能把你的显示器作为 Desktop。请使用虚拟 Desktop。"
        default:
            return nil
        }
    }

    /// Whether this failure means the Runtime cannot be reached at all; the
    /// page then shows the Disconnected state instead of an error.
    public var isDisconnection: Bool {
        ["runtime_offline", "connection_lost", "handshake_required", "version_mismatch", "instance_mismatch"].contains(code)
    }

    public static func text(_ code: String) -> (String, String) {
        switch code {
        case "invalid_argument": return ("输入不符合要求", "请修正标出的字段，你的输入已保留。")
        case "schema_invalid": return ("请求格式不符合合同", "这是界面与 Runtime 版本不一致造成的，请更新 Agent Desktop。")
        case "frame_too_large": return ("请求过大", "请缩短输入内容。")
        case "not_found": return ("找不到这个资源", "它可能已被删除或已过保留期，请返回列表刷新。")
        case "invalid_target": return ("目标无效", "目标窗口或元素已不可用，没有发出输入。请重新观察。")
        case "runtime_offline": return ("Runtime 未运行", "本机服务没有响应。界面不会显示样例数据代替；请重新检测或重启 Agent Desktop。")
        case "permission_denied": return ("没有权限", "当前调用者无权访问这个 Desktop、会话或系统能力。")
        case "ownership_escalation_denied": return ("不能提升运行所有权", "外部连接发起的运行不能变成平台持续运行。")
        case "approval_required": return ("需要审批", "这个动作需要平台审批后才能执行。")
        case "control_busy": return ("Desktop 正被其他运行控制", "同一 Desktop 一次只接受一个控制者的输入。")
        case "stale_observation": return ("观察已过期", "目标窗口或画面已变化，旧坐标不会被点击；请重新观察。")
        case "idempotency_conflict": return ("同一请求编号对应了不同内容", "如果要创建一个新的独立操作，请确认后重新提交。")
        case "conflict": return ("与当前状态冲突", "数据已被其他窗口或命令修改，请重新读取后再决定。")
        case "run_not_active": return ("运行已结束", "已结束的运行不再接受输入或停止请求。")
        case "input_disabled": return ("输入已停止", "全局停止后不接受新输入；需要时在菜单栏重新允许输入。")
        case "stop_pending": return ("正在停止", "停止已受理，等待执行端确认静止后才显示已停止。")
        case "handshake_required": return ("连接尚未建立", "界面与 Runtime 的连接需要重新建立。")
        case "version_mismatch": return ("版本不兼容", "界面与 Runtime 的接口版本不一致，请更新 Agent Desktop。")
        case "instance_mismatch": return ("应答方不是 Agent Desktop Runtime", "端点上的程序不是本机 Runtime，界面不会继续使用它。")
        case "capability_missing": return ("功能不可用", "当前 Runtime 没有提供这项功能。")
        case "model_unavailable": return ("模型服务不可用", "请检查 AI 连接；Runtime 在预算内按策略处理重试，界面不会自行无限重试。")
        case "execution_failed": return ("执行失败", "执行端报告失败，详情见回执。")
        case "internal_error": return ("发生内部错误", "请稍后重试；如果持续出现，请导出诊断。")
        case "limit_exceeded": return ("超出上限", "已达到服务端的限制（步数、时间、预算，或截图的数量、存储与磁盘空间）；不带截图的观察仍可继续。")
        case "events_cursor_expired": return ("事件游标已过期", "已重新读取完整状态。")
        case "wait_timeout": return ("等待超时", "在等待时间内没有到达目标状态；运行本身不受影响。")
        case "deadline_exceeded": return ("已到截止时间", "不会再开始新的模型调用或输入。")
        case "pairing_required": return ("需要先配对", "这个应用尚未与 Agent Desktop 配对。")
        case "client_revoked": return ("应用已被移除", "这个应用的登记已被移除，需要重新配对。")
        case "grant_missing": return ("没有对应授权", "动作所需的能力或 Desktop 不在当前授权内。")
        case "grant_expired": return ("授权已过期", "请在 Agents 中重新授权。")
        case "permit_expired": return ("审批许可已失效", "许可已过期、已使用或已作废，需要重新审批。")
        case "target_moved": return ("目标已移动", "执行入口发现目标位置或绑定与观察不一致，没有发出输入。请重新观察。")
        case "audit_unavailable": return ("审计记录不可写", "为保证可追溯，已暂停新输入。")
        case "unsupported_backend": return ("当前后端不支持这个动作", "不会改用前台或真实鼠标代替。")
        case "capability_mismatch": return ("能力不匹配", "模型、配置或执行后端不支持这一步，不会猜测动作。")
        case "connection_lost": return ("连接中断", "与 Runtime 的连接已断开；已受理的运行不受界面断开影响。")
        case "request_acceptance_unknown": return ("不确定请求是否已受理", "请先查看运行记录，不要直接重复提交。")
        case "action_delivery_unknown": return ("输入结果未知", "输入可能已经到达应用。不会自动重发，只能核实。")
        case "cancel_acceptance_unknown": return ("不确定停止是否已受理", "请查看运行状态后再决定。")
        default: return ("发生未识别的错误", "错误码 \(code)；请导出诊断。")
        }
    }
}
