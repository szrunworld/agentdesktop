import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

// A refusal that names its reason tells the user what to do instead of the
// generic "no permission" text (the bind mode of the Desktop page).

@Test func aBindRefusedUntilGrantsSaysToLaunchTheAppInstead() {
    let e = RuntimeError("permission_denied", "only an app launched on desktop d_1 can be bound", phase: .handler, notSent: true,
                         details: .obj([("reason", .string("bind_requires_grant"))]))
    let p = RuntimeProblem(e)
    #expect(p.code == "permission_denied")
    #expect(p.notSent)
    #expect(p.advice.contains("启动应用"))
}

@Test func everySealReasonHasItsOwnAdviceAndOtherReasonsKeepTheCodeText() {
    for reason in ["bind_requires_grant", "screen_capture_requires_grant", "physical_desktop_requires_grant"] {
        #expect(RuntimeProblem.reasonAdvice(reason) != nil, "\(reason)")
    }
    let plain = RuntimeProblem(RuntimeError("permission_denied", "x", phase: .handler,
                                            details: .obj([("reason", .string("something_else"))])))
    #expect(plain.advice == RuntimeProblem.text("permission_denied").1)
}
