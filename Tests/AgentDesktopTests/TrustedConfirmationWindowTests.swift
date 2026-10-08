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
    for r in [pairing, admin] {
        let text = TrustedConfirmationWindow.describe(r)
        // Exactly one line says what the system verified, and it says "cannot verify".
        let verified = text.split(separator: "\n").filter { $0.hasPrefix("代码身份（系统核实）") }
        #expect(verified.count == 1 && verified[0].contains("无法验证"), "\(text)")
        #expect(!text.unicodeScalars.contains { [0x202E, 0x2066, 0x2028, 0x2029].contains($0.value) })
    }
}
