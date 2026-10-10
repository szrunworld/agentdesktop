import AgentDesktopProtocol
import AgentDesktopRuntime
import AppKit
import Foundation
import LocalAuthentication

/// A4 S1: the host's trusted confirmation. The window shows who asks (with
/// what the Runtime itself read of its code identity), what exactly would be
/// allowed and for how long; "批准" then needs the user's own
/// authentication (Touch ID or the login password) through the system,
/// which another process cannot click or type for them. Return or Escape
/// deny; no answer before the deadline denies. Without a way to
/// authenticate the user, nothing is approved.
final class TrustedConfirmationWindow: TrustedConfirmer, @unchecked Sendable {
    private final class Box<T>: @unchecked Sendable { var value: T; init(_ v: T) { value = v } }

    private enum Answer { case approve, deny, timedOut, cancelled }

    func confirm(_ request: ConfirmationRequest) -> ConfirmationDecision {
        guard !Thread.isMainThread else { return .unavailable("asked on the main thread") }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable("this Mac cannot authenticate the user: \(error?.localizedDescription ?? "unknown")")
        }
        // 1. The window, on the main thread.
        let answer = Box<Answer>(.cancelled)
        let shown = DispatchSemaphore(value: 0)
        DispatchQueue.main.async {
            MainActor.assumeIsolated { answer.value = Self.ask(request) }
            shown.signal()
        }
        guard shown.wait(timeout: .now() + max(0, request.deadline.timeIntervalSinceNow) + 5) == .success else { return .timedOut }
        NSLog("AgentDesktop confirmation %@: window answer %@", request.confirmationId, String(describing: answer.value))
        switch answer.value {
        case .approve: break
        case .deny: return .denied
        case .timedOut: return .timedOut
        case .cancelled: return .cancelled
        }
        // 2. The user proves it is them.
        let ok = Box(false), failure = Box<LAError.Code?>(nil)
        let done = DispatchSemaphore(value: 0)
        context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: Self.reason(request)) { success, e in
            ok.value = success
            failure.value = (e as? LAError)?.code
            done.signal()
        }
        guard done.wait(timeout: .now() + max(1, request.deadline.timeIntervalSinceNow)) == .success else {
            context.invalidate()
            return .timedOut
        }
        NSLog("AgentDesktop confirmation %@: authentication %@ (%@)", request.confirmationId, ok.value ? "passed" : "failed",
              String(describing: failure.value))
        guard ok.value else {
            switch failure.value {
            case .userCancel?, .appCancel?, .systemCancel?: return .cancelled
            default: return .denied
            }
        }
        // What was displayed is what is approved: the digest of the shown fields.
        let displayed = ConfirmationRequest.digest(kind: request.kind, requester: request.requester["clientId"]?.stringValue ?? "",
                                               action: request.action, details: request.details)
        return .approved(digest: displayed)
    }

    static func reason(_ r: ConfirmationRequest) -> String {
        let who = inert(r.requester["agentName"]?.stringValue ?? r.requester["clientId"]?.stringValue ?? "?", max: 64)
        switch r.kind {
        case .pairing: return "允许「\(who)」使用 Agent Desktop"
        case .windowGrant: return "允许「\(who)」访问一个窗口"
        case .adminCall: return "允许「\(who)」执行 \(r.action)"
        case .displayAttach:
            let target = inert(r.details["client"]?["agentName"]?.stringValue ?? r.details["client"]?["clientId"]?.stringValue ?? "?", max: 64)
            return "把显示器「\(inert(r.details["display"]?["name"]?.stringValue, max: 64))」开放给「\(target)」"
        }
    }

    @MainActor
    private static func ask(_ r: ConfirmationRequest) -> Answer {
        NSApp.activate()
        let alert = NSAlert()
        alert.alertStyle = .warning
        let who = inert(r.requester["agentName"]?.stringValue ?? r.requester["clientId"]?.stringValue ?? "?", max: 64)
        switch r.kind {
        case .pairing: alert.messageText = "一个程序请求使用 Agent Desktop（自报名称「\(who)」）"
        case .windowGrant: alert.messageText = "一个已配对的程序请求访问一个窗口（自报名称「\(who)」）"
        case .adminCall: alert.messageText = "一个已配对的程序请求执行管理操作（自报名称「\(who)」）"
        case .displayAttach: alert.messageText = "把你的一块显示器开放给一个已配对的程序"
        }
        alert.informativeText = describe(r)
        // Return and Escape deny; approving is a deliberate second button
        // and then the system's authentication.
        alert.addButton(withTitle: "拒绝")
        alert.addButton(withTitle: "批准…")
        alert.buttons[0].keyEquivalent = "\r"
        alert.buttons[1].keyEquivalent = ""
        alert.window.level = .modalPanel
        let timedOut = Box(false)
        let timer = Timer(timeInterval: max(1, r.deadline.timeIntervalSinceNow), repeats: false) { _ in
            timedOut.value = true
            NSApp.abortModal()
        }
        RunLoop.main.add(timer, forMode: .modalPanel)
        RunLoop.main.add(timer, forMode: .common)
        let response = alert.runModal()
        timer.invalidate()
        NSLog("AgentDesktop confirmation %@: modal response %ld", r.confirmationId, response.rawValue)
        if timedOut.value { return .timedOut }
        switch response {
        case .alertSecondButtonReturn: return .approve
        case .alertFirstButtonReturn: return .deny
        default: return .cancelled
        }
    }

    /// Anything that did not come from the Runtime's own checks is shown
    /// inert (review M2): control, format (bidi), line and paragraph
    /// separator characters become visible \u{…} escapes, so no field can
    /// start a new line, reorder text, or pose as another line.
    static func inert(_ s: String?, max: Int = 300) -> String {
        guard let s else { return "—" }
        var out = ""
        for u in s.unicodeScalars {
            switch u.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned:
                out += String(format: "\\u{%04X}", u.value)
            default:
                out.unicodeScalars.append(u)
            }
        }
        return out.count > max ? String(out.prefix(max)) + "…（已截断显示）" : out
    }

    static func identityText(_ ci: JSONValue?) -> String {
        let id = inert(ci?["identifier"]?.stringValue ?? "未知", max: 120)
        let team = ci?["teamId"]?.stringValue.map { inert($0, max: 20) }
        switch ci?["level"]?.stringValue {
        case "verified": return "已验证签名：\(id)（Team \(team ?? "?")）。凭据绑定到这份签名的代码；但任何能让它替自己办事的程序，仍可借它的身份"
        case "shared_interpreter": return "解释器 \(id)（Team \(team ?? "?")）：这个解释器运行的任何脚本都共享此身份"
        default: return "无法验证代码身份（\(id)）：只能确认是本机同一用户的进程，凭据被复制后可被其他程序使用"
        }
    }

    /// The change a grant call makes, spelled out against the grant shown.
    static func changeLines(_ action: String, old: JSONValue?, params: JSONValue?) -> [String] {
        func list(_ v: JSONValue?) -> [String] { (v?.arrayValue ?? []).compactMap(\.stringValue) }
        switch action {
        case "hub.clients.revoke": return ["变化：移除这个客户端，它的凭据永久失效，Run 全部停止"]
        case "hub.grants.revoke": return ["变化：收回它的全部授权，Run 全部停止"]
        case "hub.windows.revoke": return ["变化：收回它对这个窗口的授权，它的连接会被断开，只在授权下临时保留的截图会删除"]
        case "hub.grants.set":
            guard let old, old != .null else { return ["⚠️ 变化：设定新授权（当前没有有效授权）"] }
            var out: [String] = []
            if old["state"]?.stringValue != "active" {
                out.append("⚠️ 原授权已被撤销：这次会重新给予访问（系统会拒绝执行）")
            } else if let exp = old["expiresAt"]?.stringValue, exp < Timestamp.string(Date()) {
                out.append("⚠️ 原授权已过期：这次会恢复访问")
            }
            for (label, key) in [("能力", "capabilities"), ("Desktop", "desktops"), ("App", "apps")] {
                let before = Set(list(old[key])), after = Set(list(params?[key]))
                let removed = before.subtracting(after).sorted(), added = after.subtracting(before).sorted()
                if !removed.isEmpty { out.append("变化：去掉\(label) " + removed.map { inert($0, max: 120) }.joined(separator: "、")) }
                if !added.isEmpty { out.append("⚠️ 变化：新增\(label) " + added.map { inert($0, max: 120) }.joined(separator: "、")) }
            }
            let seconds = params?["durationSeconds"]?.intValue ?? 3600
            out.append("变化：期限改为批准后 \(durationText(seconds))（原到期：\(inert(old["expiresAt"]?.stringValue, max: 40))；不会晚于原到期）")
            return out
        default: return []
        }
    }

    /// An exact duration: hours, minutes and seconds as they are.
    static func durationText(_ s: Int) -> String {
        let h = s / 3600, m = s % 3600 / 60, sec = s % 60
        return [h > 0 ? "\(h) 小时" : nil, m > 0 ? "\(m) 分" : nil, sec > 0 || s == 0 ? "\(sec) 秒" : nil].compactMap { $0 }.joined(separator: " ")
    }

    static let capabilityNames = ["observe": "查看（截图、元素、列表）", "act": "操作（点击、输入）",
                                  "desktop.manage": "管理 Desktop（创建、启动 App、绑定窗口）", "run": "运行与事件",
                                  "unit.run": "运行任务单元"]

    static let windowPermissionNames = ["observe": "查看（窗口截图、界面元素）", "act": "操作（点击、输入）",
                                        "persist": "保存（截图按正常期限保留，之后可读取）"]

    /// The window a grant would cover, as the Runtime read it.
    static func windowLines(_ d: JSONValue) -> [String] {
        var lines: [String] = []
        let w = d["window"] ?? .null, desk = d["desktop"] ?? .null
        lines.append("App：\(inert(w["appName"]?.stringValue, max: 80))（\(inert(w["bundleId"]?.stringValue, max: 200))，pid \(w["process"]?["pid"]?.intValue ?? 0)）")
        lines.append("窗口标题：\(inert(w["title"]?.stringValue ?? "（系统未提供）", max: 200))")
        let f = w["frame"]
        lines.append("窗口：编号 \(w["windowId"]?.intValue ?? 0)，位置 (\(Int(f?["x"]?.doubleValue ?? 0)), \(Int(f?["y"]?.doubleValue ?? 0)))，大小 \(Int(f?["width"]?.doubleValue ?? 0))×\(Int(f?["height"]?.doubleValue ?? 0))")
        if desk["kind"]?.stringValue == "physical" {
            lines.append("⚠️ 这是你自己屏幕上的真实窗口（显示器 \(desk["displayId"]?.intValue ?? 0)，Desktop \(inert(desk["desktopId"]?.stringValue, max: 128))）")
        } else {
            lines.append("Desktop：\(inert(desk["desktopId"]?.stringValue, max: 128))（Agent 的虚拟屏幕；绑定时这个窗口会被移过去）")
        }
        return lines
    }

    /// The display an owner would open to a client, as the Runtime proved it.
    static func displayLines(_ d: JSONValue) -> [String] {
        let display = d["display"] ?? .null, desk = d["desktop"] ?? .null, client = d["client"] ?? .null
        let f = display["frame"]
        var lines: [String] = []
        lines.append("显示器：\(inert(display["name"]?.stringValue, max: 80))（编号 \(display["displayId"]?.intValue ?? 0)，\(display["builtin"]?.boolValue == true ? "内建" : "外接")）")
        lines.append("分辨率：\(Int(f?["width"]?.doubleValue ?? 0))×\(Int(f?["height"]?.doubleValue ?? 0)) 点\(display["hiDPI"]?.boolValue == true ? "（HiDPI）" : "")，位置 (\(Int(f?["x"]?.doubleValue ?? 0)), \(Int(f?["y"]?.doubleValue ?? 0)))")
        lines.append("来源判定（系统核实）：" + (display["origin"]?.stringValue == "physical" ? "已证实为物理显示器（内建，或与硬件帧缓冲一一对应的外接显示器）" : "⚠️ 未证实为物理显示器（系统会拒绝执行）"))
        if let id = desk["desktopId"]?.stringValue {
            lines.append("Desktop：\(inert(desk["name"]?.stringValue, max: 64))（\(inert(id, max: 128))，已挂接；这次只是把它开放给下面的程序）")
        } else {
            lines.append("Desktop：\(inert(desk["name"]?.stringValue, max: 64))（新建，物理；不创建、不移动任何东西）")
        }
        lines.append("")
        lines.append("开放给：\(inert(client["agentName"]?.stringValue, max: 64))（\(inert(client["clientId"]?.stringValue, max: 80))）")
        if let p = client["publisher"]?.stringValue { lines.append("自报发布者：\(inert(p, max: 128))") }
        lines.append("它的代码身份（系统核实）：" + identityText(client["codeIdentity"]))
        if let g = client["grant"], g != .null {
            let apps = (g["apps"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines.append("它可申请的 App：" + (apps.isEmpty ? "无（没有 App 就申请不了任何窗口）" : apps.map { inert($0, max: 200) }.joined(separator: "、")))
            lines.append("它的授权到期：\(inert(g["expiresAt"]?.stringValue, max: 40))")
        }
        lines.append("⚠️ 这是你自己正在使用的屏幕。开放后它看不到任何窗口：每一个窗口都要再经你用 Touch ID 单独授权（查看 / 操作 / 保存分开）。")
        return lines
    }

    static func describe(_ r: ConfirmationRequest) -> String {
        var lines: [String] = []
        let q = r.requester
        if r.kind == .displayAttach {
            // Asked of the owner, about a client: the requester is this app's
            // own window, so the lines are about the display and the client.
            lines.append("发起方：Agent Desktop 主窗口（本机用户）")
            lines.append("")
            lines += displayLines(r.details)
            lines.append("")
            lines.append("批准需要验证你的身份（Touch ID 或登录密码）。不回答将在 \(max(1, Int(r.deadline.timeIntervalSinceNow))) 秒后自动拒绝。")
            return lines.joined(separator: "\n")
        }
        // What the Runtime itself verified first; what the app says about
        // itself after, marked as such.
        lines.append("代码身份（系统核实）：" + identityText(q["codeIdentity"]))
        if let exe = q["callerFacts"]?["executable"]?.stringValue { lines.append("程序：\(inert(exe))（pid \(q["callerFacts"]?["pid"]?.intValue ?? 0)）") }
        lines.append("客户端：\(inert(q["clientId"]?.stringValue, max: 80))")
        lines.append("自报名称：\(inert(q["agentName"]?.stringValue, max: 64))")
        if let p = q["publisher"]?.stringValue { lines.append("自报发布者：\(inert(p, max: 128))") }
        lines.append("")
        switch r.kind {
        case .pairing:
            if let code = r.shortCode { lines.append("配对码：\(code)（请与申请方显示的配对码核对）") }
            let caps = (r.details["capabilities"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines.append("权限：" + (caps.isEmpty ? "无" : caps.map { capabilityNames[$0] ?? inert($0, max: 40) }.joined(separator: "、")))
            let desks = (r.details["desktops"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines.append("Desktop：" + (desks.isEmpty ? "无" : desks.map { $0 == "created" ? "它自己创建的 Desktop" : inert($0, max: 128) }.joined(separator: "、")))
            let apps = (r.details["apps"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines.append("App：" + (apps.isEmpty ? "无" : apps.map { inert($0, max: 200) }.joined(separator: "、")))
            let seconds = r.details["durationSeconds"]?.intValue ?? 0
            lines.append("期限：批准后 " + (seconds >= 3600 ? "\(seconds / 3600) 小时\(seconds % 3600 / 60 > 0 ? " \(seconds % 3600 / 60) 分钟" : "")" : "\(max(1, seconds / 60)) 分钟"))
        case .windowGrant:
            lines += windowLines(r.details)
            let perms = (r.details["permissions"]?.arrayValue ?? []).compactMap(\.stringValue)
            lines.append("权限：" + (perms.isEmpty ? "无" : perms.map { windowPermissionNames[$0] ?? inert($0, max: 40) }.joined(separator: "、")))
            if !perms.contains("persist") { lines.append("不含保存：截图只临时保留 2 分钟，授权结束即删除") }
            lines.append("期限：批准后 " + durationText(r.details["durationSeconds"]?.intValue ?? 0) + "；窗口关闭、程序退出或你撤销后立即失效")
            lines.append("只授权这一个窗口，不包括这个 App 的其他窗口。")
        case .adminCall:
            lines.append("操作：\(inert(r.action, max: 80))")
            if let g = r.details["windowGrant"] {
                lines.append("窗口授权：\(inert(g["windowGrantId"]?.stringValue, max: 80))，\(inert(g["window"]?["appName"]?.stringValue, max: 80)) 的窗口 \(g["window"]?["windowId"]?.intValue ?? 0)")
            }
            if r.action.hasPrefix("ai.connections.") || r.action.hasPrefix("ai.credentials.") {
                lines.append("⚠️ 这会改变全局的 AI 连接：之后主窗口的截图和文字会发往这里配置的服务")
            }
            if let t = r.details["target"] {
                lines.append("作用对象：\(inert(t["agentName"]?.stringValue, max: 64))（\(inert(t["clientId"]?.stringValue, max: 80))）")
                lines.append("对象的代码身份：" + identityText(t["codeIdentity"]))
                if let g = t["grant"], g != .null { lines.append("对象当前授权：\(inert(g.encoded(), max: 2000))") }
                if t["isRequester"]?.boolValue == true { lines.append("作用对象就是请求方自己：它在放弃自己的权限") }
                if t["sameProgramAsRequester"]?.boolValue == true { lines.append("⚠️ 作用对象与请求方是同一个程序：这可能是在给自己扩权") }
                lines += changeLines(r.action, old: t["grant"], params: r.details["params"])
            }
            // Shown in full: the Runtime refuses anything too large to show.
            lines.append("完整参数：" + inert((r.details["params"] ?? r.details).encoded(), max: 4000))
        case .displayAttach:
            lines += displayLines(r.details)
        }
        lines.append("")
        lines.append("批准需要验证你的身份（Touch ID 或登录密码）。不回答将在 \(max(1, Int(r.deadline.timeIntervalSinceNow))) 秒后自动拒绝。")
        return lines.joined(separator: "\n")
    }
}
