import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// Projection semantics that the golden files do not spell out as rules.
@Suite struct ETestProjectorTests {
    let p = ACPProjector()
    let strict = ACPPrivacyPolicy()

    func call(_ us: [ACPSessionUpdate]) -> ACPToolCall? {
        for u in us {
            switch u {
            case let .toolCall(c), let .toolCallUpdate(c): return c
            default: continue
            }
        }
        return nil
    }

    func messages(_ us: [ACPSessionUpdate]) -> [String] {
        us.compactMap { if case let .agentMessage(s) = $0 { return s }; return nil }
    }

    // MARK: Three levels never confused (plan §5.2, docs/plan/06 §6.4)

    @Test func acceptedIsNotExecutedIsNotVerified() throws {
        let accepted = try #require(call(p.project(ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")),
                                                                                    ("kind", .string("click"))]), policy: strict)))
        #expect(accepted.level == .accepted && accepted.status == .pending)

        let dispatched = try #require(call(p.project(ETest.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb"))]),
                                                     policy: strict)))
        #expect(dispatched.level == .dispatched && dispatched.status == .inProgress)

        let executed = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt())]), policy: strict)))
        #expect(executed.level == .executed)
        #expect(executed.title.contains("已执行，未验证"))
        #expect(!executed.title.contains("已验证成功"))

        // Same receipt with businessResult not_evaluated and verification not_requested: still only executed.
        let nb = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(businessResult: "not_evaluated"))]),
                                             policy: strict)))
        #expect(nb.level == .executed)
        #expect(nb.detail.contains("业务结果：未评估"))

        let verified = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(verification: "matched"))]),
                                                   policy: strict)))
        #expect(verified.level == .verified)

        // All three ids line up, all three titles differ.
        #expect(Set([accepted.toolCallId, dispatched.toolCallId, executed.toolCallId]).count == 1)
        #expect(Set([accepted.title, dispatched.title, executed.title, verified.title]).count == 4)
    }

    @Test(arguments: ["not_requested", "pending", "inconclusive", "not_evaluated", "", "MATCHED"])
    func onlyAMatchedVerificationIsVerified(_ v: String) throws {
        let c = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(verification: v))]), policy: strict)))
        #expect(c.level == .executed)
        let ver = try #require(call(p.project(ETest.event("action.verified", [("requestId", .string("r1")), ("verification", .string(v))]),
                                              policy: strict)))
        #expect(ver.level == .executed)
    }

    @Test func verifiedNeedsDeliveryAndExecution() throws {
        // A receipt claiming verification on an unknown delivery stays unknown.
        let c = try #require(call(p.project(ETest.event("action.completed",
                                                        [("receipt", ETest.receipt(delivery: "unknown", verification: "matched"))]),
                                            policy: strict)))
        #expect(c.level == .unknown)
        // An event named completed whose receipt says failed is failed.
        let f = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(execution: "failed"))]), policy: strict)))
        #expect(f.level == .refused(code: "execution_failed") && f.status == .failed)
        // An unrecognised axis combination is never success.
        let odd = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(delivery: "maybe"))]), policy: strict)))
        #expect(odd.level == .unknown)
    }

    @Test func unknownIsNeverCompletedAndNeverFailed() throws {
        let c = try #require(call(p.project(ETest.event("action.unknown", [("receipt", ETest.receipt(delivery: "unknown", execution: "unknown"))]),
                                            policy: strict)))
        #expect(c.level == .unknown)
        #expect(c.status == .inProgress)
        #expect(c.title.contains("待核实"))
        #expect(c.detail.contains { $0.contains("不会自动重试") })
        let ended = messages(p.project(ETest.event("run.ended", [("outcome", .string("unknown"))]), policy: strict))
        #expect(ended.first?.contains("待核实") == true)
        #expect(ended.first?.contains("完成") == false)
    }

    @Test(arguments: [("success", "已投递"), ("failed", "失败"), ("cancelled", "已取消"), ("unknown", "待核实"), ("", "待核实"), ("weird", "待核实")])
    func runEndedOutcomes(_ outcome: String, _ shown: String) {
        let m = messages(p.project(ETest.event("run.ended", [("outcome", .string(outcome))]), policy: strict))
        #expect(m.count == 1)
        #expect(m[0].contains(shown), "\(m[0])")
        if outcome != "success" { #expect(!m[0].contains("已投递")) }
    }

    @Test func runKindDecidesSuccessWording() {
        var s = ACPProjectorSession()
        _ = s.project(ETest.event("run.started", [("kind", .string("unit"))]), policy: strict)
        let m = messages(s.project(ETest.event("run.ended", [("outcome", .string("success"))], cursor: 2), policy: strict))
        #expect(m[0].contains("已执行（业务结果：未评估）"))
        #expect(!m[0].contains("已验证"))
    }

    @Test func stopAndQuiescentWording() {
        #expect(messages(p.project(ETest.event("stop.accepted", [("reason", .string("stopped")), ("inFlight", .bool(false))]),
                                   policy: strict)) == ["正在停止"])
        #expect(messages(p.project(ETest.event("run.quiescent", [("revision", .int(3))]), policy: strict)) == ["已停止输入"])
    }

    // MARK: Tool kinds

    @Test(arguments: [("observe", ACPToolKind.read), ("wait", .read), ("click", .execute), ("type", .execute), ("key", .execute),
                      ("scroll", .execute), ("submit", .other), ("send_message", .other), ("external_submit", .other),
                      ("mystery", .other)])
    func toolKinds(_ kind: String, _ expected: ACPToolKind) throws {
        let c = try #require(call(p.project(ETest.event("action.accepted", [("requestId", .string("r")), ("kind", .string(kind))]),
                                            policy: strict)))
        #expect(c.kind == expected)
    }

    @Test func sessionRemembersKindForLaterEvents() throws {
        var s = ACPProjectorSession()
        _ = s.project(ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("observe"))]), policy: strict)
        let c = try #require(call(s.project(ETest.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb"))], cursor: 2),
                                            policy: strict)))
        #expect(c.kind == .read)
        #expect(c.title.hasPrefix("观察界面"))
    }

    @Test func firstWordOfAnActionAfterRunStartIsAToolCall() {
        var s = ACPProjectorSession()
        _ = s.project(ETest.event("run.started", [("kind", .string("act"))]), policy: strict)
        let out = s.project(ETest.event("action.completed", [("receipt", ETest.receipt())], cursor: 2), policy: strict)
        guard case .toolCall = out.first else { Issue.record("expected toolCall, got \(out)"); return }
    }

    // MARK: Robustness and determinism

    @Test func unknownTypesNeverCrashAndStayNeutral() {
        let payloads: [JSONValue] = [.null, .int(3), .string("x"), .array([.null]), .obj([("data", .string("x"))]),
                                     .obj([("receipt", .array([]))]), .obj([("outcome", .obj([]))])]
        let types = ["", "x", "run.", ".x", "action.accepted", "action.completed", "action.failed", "run.ended", "unit.started",
                     "stop.accepted", "zzz.yyy", String(repeating: "a.", count: 300)] + ACPEventType.allCases.map(\.rawValue)
        for t in types {
            for pl in payloads {
                let out = p.project(ACPRuntimeEvent(runId: "run_0a1b2c3d4e5f", cursor: 0, type: t, payload: pl), policy: strict)
                #expect(!out.isEmpty)
                if ACPEventType(rawValue: t) == nil {
                    #expect(out.count == 1)
                    guard case .agentThought = out[0] else { Issue.record("not a thought for \(t)"); continue }
                }
            }
        }
    }

    @Test func deterministic() {
        let e = ETest.event("action.completed", [("receipt", ETest.receipt())])
        #expect(p.project(e, policy: strict) == p.project(e, policy: strict))
    }

    @Test func everyCatalogueTypeIsMapped() {
        for t in ACPEventType.allCases {
            let out = p.project(ETest.event(t.rawValue, [("requestId", .string("r"))]), policy: strict)
            #expect(!out.isEmpty)
            for u in out { if case .agentThought = u { Issue.record("\(t.rawValue) fell through to the unknown path") } }
        }
        let emitted = Set(ACPEventType.allCases.filter(\.emitted).map(\.rawValue))
        #expect(emitted == ["run.started", "action.accepted", "action.dispatched", "action.completed", "action.failed",
                            "action.unknown", "run.finishing", "stop.accepted", "run.quiescent", "run.ended"])
    }

    // MARK: Privacy through the projector (T19–T21)

    @Test func t19ScreenshotsOffByDefault() {
        let e = ETest.event("action.completed", [("receipt", ETest.receipt()),
                                                 ("screenshot", .obj([("artifactId", .string("art_3f9c1a7be2d4")), ("windowId", .int(813)),
                                                                      ("base64", .string("iVBORw0KGgoAAAANSUhEUg=="))]))])
        let off = ETest.strings(p.project(e, policy: strict)).joined(separator: "\n")
        #expect(!off.contains("截图") && !off.contains("art_3f9c1a7be2d4") && !off.contains("iVBOR"))
        var all = ACPPrivacyPolicy(); all.screenshots = .all
        let on = ETest.strings(p.project(e, policy: all)).joined(separator: "\n")
        #expect(on.contains("截图：art_3f9c1a7be2d4"))
        #expect(!on.contains("iVBOR"), "never bytes")
        var submit = ACPPrivacyPolicy(); submit.screenshots = .onSubmit
        #expect(!ETest.strings(p.project(e, policy: submit)).joined().contains("截图"), "click is not a submit")
    }

    @Test func t20PageTextOffByDefault() {
        let e = ETest.event("action.completed", [("receipt", ETest.receipt()),
                                                 ("target", .obj([("windowId", .int(813)), ("windowTitle", .string("Inbox - Mail")),
                                                                  ("label", .string("Resume of Alice"))])),
                                                 ("summary", .string("Read the page"))])
        let off = ETest.strings(p.project(e, policy: strict)).joined(separator: "\n")
        for s in ["Inbox", "Resume", "Read the page"] { #expect(!off.contains(s)) }
        var wide = ACPPrivacyPolicy(); wide.pageText = true
        let on = ETest.strings(p.project(e, policy: wide)).joined(separator: "\n")
        #expect(on.contains("窗口：Inbox - Mail") && on.contains("元素：Resume of Alice"))
    }

    @Test func t21MetadataLeak() {
        // The plan's own example (§6.4).
        let e = ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("click")),
                                                ("title", .string("Click send to candidate: example@email.com"))])
        for policy in [strict, { var w = ACPPrivacyPolicy(); w.pageText = true; w.screenshots = .all; return w }()] {
            let text = ETest.strings(p.project(e, policy: policy)).joined(separator: "\n")
            #expect(!text.contains("example@email.com"))
            #expect(!text.contains("@"))
        }
        // Typed text never appears, whatever the policy.
        let typed = ETest.event("action.accepted", [("requestId", .string("r")), ("kind", .string("type")),
                                                    ("text", .string("Dear Alice, 13800138000"))])
        var wide = ACPPrivacyPolicy(); wide.pageText = true; wide.screenshots = .all
        #expect(!ETest.strings(p.project(typed, policy: wide)).joined().contains("Dear Alice"))
    }

    @Test func coordinatesAndProcessNeverShown() {
        let r = ETest.receipt(elementRef: .null, extra: [])
            .setting("target", .obj([("generation", .int(1)), ("process", .obj([("pid", .int(4242))])), ("windowId", .int(813)),
                                     ("elementRef", .null), ("point", .obj([("x", .double(123.5)), ("y", .double(456.25))]))]))
        var wide = ACPPrivacyPolicy(); wide.pageText = true; wide.screenshots = .all
        let text = ETest.strings(p.project(ETest.event("action.completed", [("receipt", r)]), policy: wide)).joined(separator: "\n")
        for s in ["123.5", "456.25", "4242", "813"] { #expect(!text.contains(s), "\(s) in \(text)") }
    }

    // MARK: Kevin's three tiers and cross-app data (README §五 constraint 3)

    @Test func everyEventTypeHasATier() {
        #expect(ACPEventType.runStarted.tier == .normal)
        #expect(ACPEventType.runEnded.tier == .normal)
        #expect(ACPEventType.actionCompleted.tier == .sensitive)
        #expect(ACPEventType.approvalRequired.tier == .protected)
        #expect(ACPEventType.questionAsked.tier == .protected)
        #expect(ACPEventType.tier(of: "made.up") == .protected)
        for t in ACPEventType.allCases { _ = t.tier } // exhaustive by construction
        #expect(ACPDataClass.typedValue.tier == .protected)
        #expect(ACPDataClass.credential.tier == .protected)
        #expect(ACPDataClass.screenshot.tier == .protected)
        #expect(ACPDataClass.withheld.tier == .protected)
        #expect(ACPDataClass.windowTitle.tier == .sensitive)
        #expect(ACPDataClass.pageText.tier == .sensitive)
        #expect(ACPDataClass.code.tier == .normal)
        #expect(ACPDataClassifier.classify(key: "params") == .typedValue)
        #expect(ACPDataClassifier.classify(key: "coveringTitle") == .withheld)
    }

    static let wide: ACPPrivacyPolicy = { var w = ACPPrivacyPolicy(); w.pageText = true; w.screenshots = .all; return w }()
    static let otherApp = ["WeChat", "李四", "example@email.com", "13800138000"]

    func text(_ e: ACPRuntimeEvent, _ policy: ACPPrivacyPolicy = wide) -> String {
        ETest.strings(p.project(e, policy: policy)).joined(separator: "\n")
    }

    /// Cross-app 1/4: a screenshot is shown (as a reference) only when it is
    /// scoped to the bound window; never bytes, never a screen capture.
    @Test func crossAppScreenshots() {
        let r = ETest.receipt()
        let own = ETest.event("action.completed", [("receipt", r), ("screenshot", .obj([("artifactId", .string("art_3f9c1a7be2d4")),
                                                                                         ("windowId", .int(813))]))])
        #expect(text(own).contains("截图：art_3f9c1a7be2d4"))
        let other = ETest.event("action.completed", [("receipt", r), ("screenshot", .obj([("artifactId", .string("art_cc11dd22ee33")),
                                                                                           ("windowId", .int(901))]))])
        #expect(!text(other).contains("art_cc11dd22ee33"))
        let screen = ETest.event("action.completed", [("receipt", r), ("image", .obj([("artifactId", .string("art_ff44aa55bb66"))]))])
        #expect(!text(screen).contains("art_ff44aa55bb66"))
        let bytes = ETest.event("action.completed", [("receipt", r), ("screenshot", .obj([("artifactId", .string("art_3f9c1a7be2d4")),
                                                                                           ("windowId", .int(813)),
                                                                                           ("base64", .string("iVBORw0KGgoAAAA"))]))])
        #expect(!text(bytes).contains("iVBOR"))
    }

    /// Cross-app 2/4: window titles come only from the bound target; a
    /// covering window's title, a mismatched target or a Runtime error
    /// message naming another window never appear.
    @Test func crossAppWindowTitles() {
        let covering = ETest.event("action.failed", [
            ("receipt", ETest.receipt(delivery: "not_dispatched", execution: "failed")),
            ("error", .obj([("code", .string("stale_observation")),
                            ("message", .string("window 901 (WeChat – 李四) covers the bound window 813")),
                            ("details", .obj([("reason", .string("occluded")), ("coveringTitle", .string("WeChat – 李四"))]))])),
            ("covering", .obj([("windowId", .int(901)), ("title", .string("WeChat – 李四"))])),
        ])
        let t = text(covering)
        for s in Self.otherApp + ["901"] { #expect(!t.contains(s), "\(s) in \(t)") }
        #expect(t.contains("原因：目标窗口被其他窗口遮挡"))

        let mismatch = ETest.event("action.completed", [("receipt", ETest.receipt()),
                                                        ("target", .obj([("windowId", .int(901)), ("title", .string("WeChat – 李四"))]))])
        for s in Self.otherApp { #expect(!text(mismatch).contains(s)) }
    }

    /// Cross-app 3/4: typed or pasted input (possibly copied from another
    /// app) never appears, under any policy.
    @Test func crossAppTypedInput() {
        let e = ETest.event("action.accepted", [("requestId", .string("req_000aaaaa0001")), ("kind", .string("type")),
                                                ("text", .string("copied from WeChat – 李四: 13800138000")),
                                                ("clipboard", .string("WeChat – 李四")), ("input", .string("example@email.com"))])
        for policy in [strict, Self.wide] {
            let t = text(e, policy)
            for s in Self.otherApp + ["copied"] { #expect(!t.contains(s)) }
        }
    }

    /// Cross-app 4/4: approval and question events are protected — status
    /// only, nothing of their parameters, summaries or choices.
    @Test func crossAppApprovalParameters() {
        let approval = ETest.event("approval.required", [
            ("kind", .string("submit")), ("summary", .string("Send WeChat – 李四 chat to example@email.com")),
            ("params", .obj([("text", .string("13800138000")), ("windowTitle", .string("WeChat – 李四"))])),
            ("arguments", .array([.string("WeChat")])),
        ])
        #expect(p.project(approval, policy: Self.wide).first == .agentMessage("等待批准（未批准前不会执行）"))
        for s in Self.otherApp { #expect(!text(approval).contains(s)) }
        let q = ETest.event("question.asked", [("message", .string("Forward 李四's message?")), ("choices", .array([.string("WeChat")]))])
        #expect(p.project(q, policy: Self.wide).first == .agentMessage("等待回答一个问题"))
        for s in Self.otherApp { #expect(!text(q).contains(s)) }
    }

    /// An action event the Runtime marks sensitive shows its status only.
    @Test func withheldEventIsStatusOnly() throws {
        let e = ETest.event("action.completed", [("receipt", ETest.receipt()), ("sensitive", .bool(true)),
                                                 ("title", .string("Open 李四 profile")),
                                                 ("screenshot", .obj([("artifactId", .string("art_3f9c1a7be2d4")), ("windowId", .int(813))]))])
        let c = try #require(call(p.project(e, policy: Self.wide)))
        #expect(c.detail == ["状态：已执行，未验证"])
        #expect(c.level == .executed)
    }
}
