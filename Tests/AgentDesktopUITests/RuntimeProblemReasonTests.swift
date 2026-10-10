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
    for reason in ["bind_requires_grant", "screen_capture_requires_grant", "physical_desktop_requires_grant", "owner_only", "display_not_physical"] {
        #expect(RuntimeProblem.reasonAdvice(reason) != nil, "\(reason)")
    }
    let plain = RuntimeProblem(RuntimeError("permission_denied", "x", phase: .handler,
                                            details: .obj([("reason", .string("something_else"))])))
    #expect(plain.advice == RuntimeProblem.text("permission_denied").1)
}

@Test func anEmptyLaunchListSaysNoAppIsConfigured() {
    let e = RuntimeError("permission_denied", "no app is configured to be launched", phase: .handler, notSent: true,
                         details: .obj([("reason", .string("no_launch_apps_configured"))]))
    #expect(RuntimeProblem(e).advice.contains("未配置允许启动的应用"))
    #expect(RuntimeProblem.reasonAdvice("launch_not_verified") != nil)
}

@Test func everyLaunchOutcomeHasItsOwnAdvice() {
    let texts = ["no_launch_apps_configured", "launch_not_verified", "launch_unprovable", "app_already_running",
                 "launch_failed", "launch_refused_after_open"].map { RuntimeProblem.reasonAdvice($0) }
    #expect(texts.allSatisfy { $0 != nil })
    #expect(Set(texts.compactMap { $0 }).count == texts.count, "each reason says something different")
    #expect(RuntimeProblem.reasonAdvice("launch_failed")?.contains("不会自动重试") == true)
}
