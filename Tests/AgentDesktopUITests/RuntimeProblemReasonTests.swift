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

// #203: a write done before access was withdrawn says so, whatever the
// code and reason, and is not taken as not performed.
@Test func aWriteDoneButWithheldIsNotShownAsNotPerformed() {
    let e = RuntimeError("grant_expired", "the grant expired", phase: .request, notSent: false,
                         details: .obj([("reason", .string("grant_expired")), ("writeOutcome", .string("completed")),
                                        ("recovery", .string("look_up_same_request_id"))]))
    let p = RuntimeProblem(e)
    #expect(p.advice == RuntimeProblem.writeDoneAdvice)
    #expect(p.notSent == false)
}

// Codex on 38edddd: a removed client pairs again under a new identity, so
// it is not told to look the request up again.
@Test func aWriteDoneForARemovedClientIsNotToldToReplayTheRequest() {
    let e = RuntimeError("client_revoked", "removed", phase: .request, notSent: false,
                         details: .obj([("reason", .string("client_revoked")), ("writeOutcome", .string("completed")),
                                        ("recovery", .string("check_outcome_do_not_resubmit"))]))
    let p = RuntimeProblem(e)
    #expect(p.advice == RuntimeProblem.writeDoneRevokedAdvice)
    #expect(!p.advice.contains("同一个请求查询"))
    #expect(p.notSent == false)
}
