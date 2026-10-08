import Foundation

/// Ask / Auto (plan §6.3). Neither mode widens a permission: Auto only
/// skips the extra editor confirmation, it never approves on anyone's behalf.
public enum ACPPromptMode: String, Sendable {
    case ask
    case auto
}

/// The session config options the server exposes and how they feed the
/// privacy policy (docs/acp/00-input-plan-v1.0.md §6.3, §6.4). Defaults are
/// the strictest: ask, no screenshots, no page text.
public enum ACPSessionManagerOptions {
    public static let modeId = "mode"
    public static let screenshotsId = "screenshots"
    public static let pageTextId = "pageText"

    public static var defaults: [ACPConfigOption] {
        [
            ACPConfigOption(id: modeId, name: "执行确认", value: ACPPromptMode.ask.rawValue,
                            choices: [ACPPromptMode.ask.rawValue, ACPPromptMode.auto.rawValue]),
            ACPConfigOption(id: screenshotsId, name: "截图", value: ACPDisclosure.off.rawValue,
                            choices: [ACPDisclosure.off.rawValue, ACPDisclosure.onSubmit.rawValue,
                                      ACPDisclosure.all.rawValue]),
            ACPConfigOption(id: pageTextId, name: "页面文字", value: "off", choices: ["off", "on"]),
        ]
    }

    /// Stored options with anything missing or no longer valid reset to the
    /// default, in the canonical order. Unknown ids are dropped.
    public static func normalized(_ stored: [ACPConfigOption]) -> [ACPConfigOption] {
        defaults.map { def in
            guard let s = stored.first(where: { $0.id == def.id }), def.choices.contains(s.value) else { return def }
            var o = def
            o.value = s.value
            return o
        }
    }

    /// Set one option; unknown ids and values outside the choices are refused.
    public static func setting(_ options: [ACPConfigOption], id: String, value: String) throws -> [ACPConfigOption] {
        var all = normalized(options)
        guard let i = all.firstIndex(where: { $0.id == id }) else {
            throw ACPAgentServerErrors.invalidParams("未知的配置项")
        }
        guard all[i].choices.contains(value) else {
            throw ACPAgentServerErrors.invalidParams("配置项 \(id) 只接受：\(all[i].choices.joined(separator: " / "))")
        }
        all[i].value = value
        return all
    }

    public static func mode(_ options: [ACPConfigOption]) -> ACPPromptMode {
        let v = normalized(options).first(where: { $0.id == modeId })?.value ?? ""
        return ACPPromptMode(rawValue: v) ?? .ask
    }

    public static func policy(_ options: [ACPConfigOption]) -> ACPPrivacyPolicy {
        let all = normalized(options)
        var p = ACPPrivacyPolicy()
        if let v = all.first(where: { $0.id == screenshotsId })?.value, let d = ACPDisclosure(rawValue: v) {
            p.screenshots = d
        }
        p.pageText = all.first(where: { $0.id == pageTextId })?.value == "on"
        return p
    }
}

/// Stable, non-sensitive JSON-RPC errors the server answers with.
public enum ACPAgentServerErrors {
    public static func invalidParams(_ message: String) -> ACPError {
        ACPError(code: -32602, reason: "invalid_params", message: message)
    }
    /// Unknown session and a session of another principal answer the same,
    /// so a caller cannot probe which ids exist.
    public static var sessionNotFound: ACPError {
        ACPError(code: -32002, reason: "session_not_found", message: "没有这个会话，或当前身份无权访问")
    }
    public static var sessionNotOpen: ACPError {
        ACPError(code: -32002, reason: "session_not_open", message: "会话未在本连接上打开，请先新建或恢复")
    }
    public static var turnInProgress: ACPError {
        ACPError(code: -32000, reason: "turn_in_progress", message: "这个会话正在处理上一条 prompt")
    }
    public static var callerUnavailable: ACPError {
        ACPError(code: -32000, reason: "caller_unavailable", message: "Runtime 未返回已认证的调用方身份")
    }
    public static var storeFailed: ACPError {
        ACPError(code: -32603, reason: "store_failed", message: "会话绑定无法保存")
    }
}
