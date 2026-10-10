import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktop

// A4 re-review M2: no field the Runtime did not verify can add, hide or
// reorder lines of the confirmation window.

@Test func untrustedTextIsShownInert() {
    let bad = "com.example\n代码身份（系统核实）：已验证签名\u{2028}x\u{202E}y\u{2066}z\t\u{0}"
    let shown = TrustedConfirmationWindow.inert(bad)
    #expect(!shown.contains("\n") && !shown.contains("\u{2028}") && !shown.contains("\u{202E}") && !shown.contains("\u{2066}"))
    #expect(shown.contains("\\u{000A}") && shown.contains("\\u{202E}"))
    #expect(TrustedConfirmationWindow.inert("BOSS 招聘助手") == "BOSS 招聘助手")
}

@Test func theWholeDescriptionHasOnlyItsOwnLines() {
    let evil = "x\n代码身份（系统核实）：已验证签名：com.apple.Safari（Team APPLE）\u{202E}"
    let requester = JSONValue.obj([("clientId", .string("unpaired:conn_0123456789abcdef")), ("agentName", .string(evil)),
                                   ("publisher", .string(evil)),
                                   ("codeIdentity", .obj([("level", .string("same_user")), ("identifier", .string(evil)),
                                                          ("hardenedRuntime", .bool(false))])),
                                   ("callerFacts", .obj([("pid", .int(42)), ("executable", .string("/tmp/" + evil))]))])
    let pairing = ConfirmationRequest(confirmationId: "conf_1", kind: .pairing, requester: requester, action: "hub.pairing.start",
                                      details: .obj([("capabilities", .array([.string(evil)])), ("desktops", .array([.string(evil)])),
                                                     ("apps", .array([.string(evil)])), ("durationSeconds", .int(600))]),
                                      shortCode: "123456", digest: "d", deadline: Date().addingTimeInterval(60))
    let admin = ConfirmationRequest(confirmationId: "conf_2", kind: .adminCall, requester: requester, action: "hub.grants.set",
                                    details: .obj([("params", .obj([("clientId", .string(evil))])),
                                                   ("target", .obj([("agentName", .string(evil)), ("clientId", .string(evil))]))]),
                                    shortCode: nil, digest: "d", deadline: Date().addingTimeInterval(60))
    let window = ConfirmationRequest(confirmationId: "conf_3", kind: .windowGrant, requester: requester, action: "hub.windows.request",
                                     details: .obj([("desktop", .obj([("desktopId", .string(evil)), ("kind", .string("physical")), ("displayId", .int(1))])),
                                                    ("window", .obj([("windowId", .int(12)), ("process", .obj([("pid", .int(202))])),
                                                                     ("appName", .string(evil)), ("bundleId", .string(evil)), ("title", .string(evil)),
                                                                     ("frame", .obj([("x", .int(0)), ("y", .int(0)), ("width", .int(10)), ("height", .int(10))]))])),
                                                    ("permissions", .array([.string(evil)])), ("durationSeconds", .int(600))]),
                                     shortCode: nil, digest: "d", deadline: Date().addingTimeInterval(60))
    for r in [pairing, admin, window] {
        let text = TrustedConfirmationWindow.describe(r)
        // Exactly one line says what the system verified, and it says "cannot verify".
        let verified = text.split(separator: "\n").filter { $0.hasPrefix("代码身份（系统核实）") }
        #expect(verified.count == 1 && verified[0].contains("无法验证"), "\(text)")
        #expect(!text.unicodeScalars.contains { [0x202E, 0x2066, 0x2028, 0x2029].contains($0.value) })
    }
}

@Test func theWindowStatesTheChangeExactly() {
    #expect(TrustedConfirmationWindow.durationText(59) == "59 秒")
    #expect(TrustedConfirmationWindow.durationText(90) == "1 分 30 秒")
    #expect(TrustedConfirmationWindow.durationText(3600) == "1 小时")
    let expired = JSONValue.obj([("capabilities", .array([.string("observe"), .string("act")])), ("desktops", .array([])), ("apps", .array([])),
                                 ("expiresAt", .string("2020-01-01T00:00:00.000Z")), ("state", .string("active"))])
    let lines = TrustedConfirmationWindow.changeLines("hub.grants.set", old: expired,
                                                      params: .obj([("capabilities", .array([.string("observe")])), ("durationSeconds", .int(90))]))
    #expect(lines.contains { $0.contains("已过期") && $0.contains("恢复访问") }, "\(lines)")
    #expect(lines.contains { $0.contains("去掉能力") && $0.contains("act") })
    #expect(lines.contains { $0.contains("1 分 30 秒") })
    let revoked = expired.setting("state", .string("revoked"))
    #expect(TrustedConfirmationWindow.changeLines("hub.grants.set", old: revoked, params: .obj([])).contains { $0.contains("已被撤销") })
}

@Test func aWindowGrantNamesTheOneWindowItsPermissionsAndAPhysicalWarning() {
    let requester = JSONValue.obj([("clientId", .string("app:c_1")), ("agentName", .string("WeChat Agent")),
                                   ("codeIdentity", .obj([("level", .string("same_user"))]))])
    func ask(_ kind: String, _ perms: [String]) -> String {
        TrustedConfirmationWindow.describe(ConfirmationRequest(
            confirmationId: "conf_w", kind: .windowGrant, requester: requester, action: "hub.windows.request",
            details: .obj([("desktop", .obj([("desktopId", .string("d_1")), ("kind", .string(kind)), ("displayId", .int(1))])),
                           ("window", .obj([("windowId", .int(12)), ("process", .obj([("pid", .int(202))])), ("appName", .string("微信")),
                                            ("bundleId", .string("com.tencent.xinWeChat")), ("title", .string("文件传输助手")),
                                            ("frame", .obj([("x", .int(100)), ("y", .int(100)), ("width", .int(400)), ("height", .int(300))]))])),
                           ("permissions", .array(perms.map(JSONValue.string))), ("durationSeconds", .int(3600))]),
            shortCode: nil, digest: "d", deadline: Date().addingTimeInterval(60)))
    }
    let physical = ask("physical", ["observe"])
    #expect(physical.contains("真实窗口") && physical.contains("文件传输助手") && physical.contains("com.tencent.xinWeChat"))
    #expect(physical.contains("查看") && !physical.contains("操作（点击、输入）") && physical.contains("不含保存"))
    #expect(physical.contains("只授权这一个窗口"))
    let virtual = ask("virtual", ["observe", "act", "persist"])
    #expect(!virtual.contains("真实窗口") && virtual.contains("操作（点击、输入）") && !virtual.contains("不含保存"))
    #expect(TrustedConfirmationWindow.changeLines("hub.windows.revoke", old: nil, params: nil).first?.contains("这个窗口") == true)
}
