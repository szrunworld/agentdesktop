import AgentDesktopProtocol
import Foundation

/// A failure as a page shows it: a stable code, Chinese text that says what
/// happened and what the user can do, never a secret or an upstream body.
public struct UIProblem: Equatable, Sendable {
    public let code: ErrorCode
    public let title: String
    public let advice: String
    /// For CONFIG_CONFLICT: the revision the service holds now.
    public let currentRevision: Int?
    /// For VALIDATION_ERROR: the fields the service named.
    public let fields: [String]

    public init(code: ErrorCode, title: String, advice: String, currentRevision: Int? = nil, fields: [String] = []) {
        self.code = code
        self.title = title
        self.advice = advice
        self.currentRevision = currentRevision
        self.fields = fields
    }

    public init(_ error: Error) {
        guard let e = error as? ContractError else {
            self.init(code: .internalError, title: "发生内部错误", advice: "请稍后重试；如果持续出现，请导出诊断。")
            return
        }
        let (title, advice) = Self.text(e.code)
        let current = e.details?["currentRevision"]?.intValue
        let fields = (e.details?["fieldErrors"]?.arrayValue ?? e.details?["violations"]?.arrayValue ?? [])
            .compactMap { $0["path"]?.stringValue }
        self.init(code: e.code, title: title, advice: advice, currentRevision: current, fields: fields)
    }

    static func text(_ code: ErrorCode) -> (String, String) {
        switch code {
        case .configConflict: return ("配置已被其他窗口或命令修改", "你的草稿已保留。重新读取服务器版本后再决定是否保存，不会强制覆盖。")
        case .resourceInUse: return ("资源仍被引用", "先改默认配置、处理引用它的配置或结束使用它的运行，再删除。不会级联删除。")
        case .resourceDisabled: return ("资源已停用", "停用的资源不能用于新的绑定；已有运行继续使用原快照。")
        case .credentialRevoked: return ("凭据已撤销", "旧凭据身份已失效，使用它的运行会明确失败；请用新凭据重新开始。")
        case .credentialRequired: return ("缺少凭据", "这个连接没有可用的 API 密钥，请在连接设置中轮换凭据。")
        case .capabilityMismatch: return ("能力不匹配", "模型、适配器或执行后端不支持这一步（例如图像输入、GUI 协议或验证谓词）。不会去掉图像或猜测动作。")
        case .upstreamUnavailable: return ("模型服务暂时不可用", "Runtime 在预算内按策略处理重试；界面不会自行无限重试。")
        case .rateLimited: return ("模型服务限流", "Runtime 会在截止时间内遵守等待时间；也可以稍后再试。")
        case .authFailed: return ("认证失败", "请检查连接的 API 密钥或账户权限；不会自动换用其他账户。")
        case .modelNotFound: return ("模型不存在", "请检查模型 ID 或在连接中刷新模型列表。")
        case .upstreamProtocolError: return ("上游响应不符合协议", "已停止这一步并保留脱敏诊断，没有把不完整的输出交给执行器。")
        case .deadlineExceeded: return ("已到截止时间", "不会再开始新的模型调用或输入。")
        case .cancelled: return ("已取消", "本次操作已停止。")
        case .invalidAction: return ("模型建议的动作无效", "没有动作被执行。修正配置后可以新建运行。")
        case .staleObservation: return ("观察已过期", "目标窗口或画面已变化，旧坐标不会被点击；Runtime 会重新观察。")
        case .staleGeneration: return ("运行已进入新的世代", "迟到的结果已作废，不会被执行。")
        case .actionOutcomeUnknown: return ("有一项输入结果尚未确认", "不会自动重发。等待 Runtime 安全复核，冲突域保持隔离。")
        case .auditUnavailable: return ("审计记录不可写", "为保证可追溯，已停止后续模型调用与输入。")
        case .limitExceeded: return ("超出上限", "请求超过了服务端上限，只能调低，不能调高。")
        case .idempotencyConflict: return ("同一提交键对应了不同内容", "如果要创建一个新的独立操作，请确认后重新提交。")
        case .notFound: return ("找不到这个资源", "它可能已被删除，请返回列表刷新。")
        case .validationError: return ("输入不符合要求", "请修正标出的字段，你的输入已保留。")
        case .unsupportedProtocol: return ("协议尚未实现", "当前版本只支持 openai_chat。")
        case .desktopBusy: return ("Desktop 正忙或被隔离", "该冲突域有未核对的输入，请先在“需要处理的运行”中查看。")
        case .forbidden, .unauthorized: return ("没有权限", "当前调用者无权访问这个 Desktop 或会话。")
        case .operationNotCancellable: return ("操作已结束", "已完成的操作无法取消。")
        case .eventsCursorExpired: return ("事件游标已过期", "已重新读取完整状态。")
        case .usageUnavailable: return ("用量不可用", "上游没有报告用量，按“未知”处理。")
        case .unsupportedSchema, .unsupportedCommand: return ("服务版本不兼容", "请更新 Agent Desktop。")
        case .ipcFrameTooLarge: return ("请求过大", "请缩短输入内容。")
        case .coordinateOutOfBounds: return ("坐标越界", "建议的位置不在截图范围内，没有执行。")
        case .verificationFailed: return ("完成条件未满足", "新的观察中没有找到要求的文字，运行不会标为成功。")
        case .internalError: return ("发生内部错误", "请稍后重试；如果持续出现，请导出诊断。")
        }
    }
}

/// Read state shared by list pages: a failed refresh keeps the last good
/// data and its time (spec §2.2).
public enum LoadPhase: Equatable, Sendable {
    case idle, loading, loaded, failed
}

enum Format {
    static let shanghai = TimeZone(identifier: "Asia/Shanghai")!

    static func time(_ iso: String?) -> String {
        guard let iso, let d = ISO8601DateFormatter().date(from: iso) else { return "—" }
        let f = DateFormatter()
        f.timeZone = shanghai
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f.string(from: d)
    }

    /// A reference shown without most of its characters.
    static func masked(_ ref: String?) -> String {
        guard let ref, ref.count > 6 else { return "已保存" }
        return "…" + ref.suffix(4)
    }

    /// Unknown usage stays unknown; an explicit zero is a reported zero.
    static func tokens(_ v: JSONValue?) -> String {
        guard let v, !v.isNull, let n = v.intValue else { return "未知 / 未报告" }
        return n == 0 ? "0 / 明确报告" : String(n)
    }
}
