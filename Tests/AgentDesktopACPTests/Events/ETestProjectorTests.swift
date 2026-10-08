import AgentDesktopProtocol
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
    }

    @Test func verifiedNeedsDeliveryAndExecution() throws {
        // A receipt claiming verification on an unknown delivery stays unknown.
        let c = try #require(call(p.project(ETest.event("action.completed",
                                                        [("receipt", ETest.receipt(delivery: "unknown", verification: "matched"))]),
                                            policy: strict)))
        #expect(c.level == .unknown)
        // An event named completed whose receipt says failed is failed.
        let f = try #require(call(p.project(ETest.event("action.completed", [("receipt", ETest.receipt(execution: "failed"))]), policy: strict)))
        #expect(f.level == .failed(code: "execution_failed") && f.status == .failed)
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
        #expect(ended.first?.contains("结果未知 · 需要核实") == true)
        #expect(ended.first?.contains("完成") == false)
    }

    @Test(arguments: [("success", "已投递"), ("failed", "失败"), ("cancelled", "已取消"), ("unknown", "需要核实"), ("", "需要核实"), ("weird", "需要核实")])
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
                                   policy: strict)) == ["正在停止；原因：已请求停止"])
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
        // Exactly the frozen catalogue (#102), read from the contract itself.
        #expect(Set(ACPEventType.allCases.map(\.rawValue)) == ETest.catalogueTypes())
        #expect(ETest.catalogueTypes().count == 11)
    }

    /// Types the catalogue replaced or never had are not mapped: one neutral
    /// line, nothing of their payload.
    @Test(arguments: ["run.accepted", "run.queued", "run.waiting_approval", "run.waiting_input", "run.resumed", "action.verified",
                      "verification.succeeded", "verification.failed", "approval.required", "question.asked", "unit.started",
                      "unit.ended", "unit.step.proposed"])
    func provisionalTypesAreGone(_ type: String) {
        #expect(ACPEventType(rawValue: type) == nil)
        let out = p.project(ETest.event(type, [("requestId", .string("r")), ("summary", .string("WeChat – 李四"))]), policy: Self.wide)
        #expect(out == [.agentThought("收到未识别的运行事件（\(type)），未作处理")])
    }

    // MARK: Receipts and refusals with reasons (F1-03, #102)

    /// The contract's own fixture: an action refused before any input.
    @Test func actionRefusedFromTheContractFixture() throws {
        let doc = try ETest.contractFixture("event-action-refused.valid.json")
        let inst = try #require(doc["instance"])
        let e = ACPRuntimeEvent(runId: inst["runId"]?.stringValue ?? "", cursor: inst["sequence"]?.intValue ?? 0,
                                type: inst["type"]?.stringValue ?? "", payload: inst)
        for policy in [strict, Self.wide] {
            let c = try #require(call(p.project(e, policy: policy)))
            #expect(c.level == .refused(code: "stale_observation"))
            #expect(c.status == .failed)
            #expect(c.title.hasSuffix("未发出"))
            #expect(c.detail.contains("错误码：stale_observation"))
            #expect(c.detail.contains("投递：未发出"))
            // The reason's message names another window: never shown (P1).
            let all = ETest.strings(p.project(e, policy: policy)).joined(separator: "\n")
            #expect(!all.contains("covers") && !all.contains("77"), "\(all)")
        }
    }

    @Test func receiptReasonCodeOnFailedAndUnknown() throws {
        let doc = try ETest.contractFixture("receipt-not-dispatched-with-reason.valid.json")
        let r = try #require(doc["instance"])
        let f = try #require(call(p.project(ETest.event("action.failed", [("receipt", r)]), policy: Self.wide)))
        #expect(f.level == .refused(code: "execution_failed"), "not delivered: never executed")
        #expect(f.detail.contains("错误码：execution_failed"))
        #expect(f.title.hasSuffix("未发出"))
        #expect(f.detail.contains { $0.hasPrefix("回执：") })
        #expect(!ETest.strings([.toolCallUpdate(f)]).joined().contains("the app refused"))

        let unknown = ETest.receipt(delivery: "unknown", execution: "unknown",
                                    extra: [("reason", .obj([("code", .string("action_delivery_unknown")),
                                                             ("message", .string("it may have reached WeChat – 李四"))]))])
        let u = try #require(call(p.project(ETest.event("action.unknown", [("receipt", unknown)]), policy: Self.wide)))
        #expect(u.level == .unknown && u.status == .inProgress)
        #expect(u.detail.contains("错误码：action_delivery_unknown"))
        for s in Self.otherApp { #expect(!ETest.strings([.toolCallUpdate(u)]).joined().contains(s)) }

        // A code outside errors.json is never shown verbatim.
        let odd = ETest.event("action.refused", [("requestId", .string("r")),
                                                 ("reason", .obj([("code", .string("wechat_li_si")), ("message", .string("x"))]))])
        #expect(call(p.project(odd, policy: strict))?.level == .refused(code: "unlisted_error"))
    }

    /// One refusal is one terminal event: refused closes the action, so
    /// run.ended does not settle it a second time.
    @Test func refusalIsTheOnlyTerminalUpdate() {
        let out = session([
            ETest.event("run.started", [("kind", .string("act"))]),
            ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("click"))], cursor: 2),
            ETest.event("action.refused", [("requestId", .string("req_0001aaaabbbb")),
                                           ("reason", .obj([("code", .string("deadline_exceeded")), ("message", .string("late"))]))], cursor: 3),
            ETest.event("run.ended", [("phase", .string("ended")), ("outcome", .string("failed")), ("reason", .string("completed"))], cursor: 4),
        ])
        #expect(call(out[3]) == nil, "\(out[3])")
        #expect(messages(out[3]).first?.contains("原因：动作已处理完") == true)
    }

    @Test(arguments: [("completed", "动作已处理完"), ("finished", "调用方已结束任务"), ("exit 3", "命令已退出（退出码 3）"), ("stopped", "已请求停止"),
                      ("owner_lost", "编辑器连接已断开"), ("global_stop", "已全部停止"), ("runtime_restarted", "Runtime 已重启")])
    func closingReasonsTheRuntimeWrites(_ reason: String, _ shown: String) {
        let m = messages(p.project(ETest.event("run.ended", [("phase", .string("ended")), ("outcome", .string("cancelled")),
                                                             ("reason", .string(reason))]), policy: strict))
        #expect(m[0].contains("原因：\(shown)"), "\(m[0])")
        let s = messages(p.project(ETest.event("stop.accepted", [("reason", .string(reason)), ("inFlight", .bool(false)),
                                                                 ("revision", .int(2))]), policy: strict))
        #expect(s[0].contains("原因：\(shown)"), "\(s[0])")
    }

    @Test func freeTextClosingReasonIsNotShown() {
        let m = messages(p.project(ETest.event("run.ended", [("outcome", .string("cancelled")),
                                                             ("reason", .string("closed WeChat – 李四"))]), policy: strict))
        #expect(m == ["任务结束：已取消"])
    }

    /// run.ended has no unknownActions count: it comes from this session's events.
    @Test func unknownCountComesFromTheSession() {
        let out = session([
            ETest.event("run.started", [("kind", .string("act"))]),
            ETest.event("action.unknown", [("receipt", ETest.receipt(delivery: "unknown", execution: "unknown"))], cursor: 2),
            ETest.event("run.ended", [("outcome", .string("unknown")), ("unknownActions", .int(9)), ("kind", .string("unit")),
                                      ("verification", .string("matched"))], cursor: 3),
        ])
        let m = messages(out[2])
        #expect(m[0].contains("；1 个动作待核实"), "\(m[0])")
        #expect(!m[0].contains("9") && !m[0].contains("已验证"))
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
        #expect(on.contains("元素：Resume of Alice"))
        for s in ["Inbox", "窗口：", "Read the page"] { #expect(!on.contains(s), "ruling P1: \(s)") }
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
        #expect(ACPEventType.actionRefused.tier == .sensitive)
        #expect(ACPEventType.tier(of: "approval.required") == .protected)
        #expect(ACPEventType.tier(of: "unit.step.proposed") == .protected)
        #expect(ACPEventType.tier(of: "made.up") == .protected)
        for t in ACPEventType.allCases { _ = t.tier } // exhaustive by construction
        #expect(ACPDataClass.typedValue.tier == .protected)
        #expect(ACPDataClass.credential.tier == .protected)
        #expect(ACPDataClass.screenshot.tier == .protected)
        #expect(ACPDataClass.withheld.tier == .protected)
        #expect(ACPDataClass.windowTitle.tier == .protected)
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
        let covering = ETest.event("action.refused", [
            ("requestId", .string("req_0001aaaabbbb")),
            ("reason", .obj([("code", .string("stale_observation")),
                             ("message", .string("window 901 (WeChat – 李四) covers the bound window 813"))])),
            ("covering", .obj([("windowId", .int(901)), ("title", .string("WeChat – 李四"))])),
        ])
        let t = text(covering)
        for s in Self.otherApp + ["901", "covers"] { #expect(!t.contains(s), "\(s) in \(t)") }
        #expect(t.contains("错误码：stale_observation"))

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

    /// Cross-app 4/4: approval and question events are not in the Run event
    /// catalogue (the server raises the real request); if one arrives it is a
    /// neutral line, nothing of its parameters, summaries or choices.
    @Test func crossAppApprovalParameters() {
        let approval = ETest.event("approval.required", [
            ("kind", .string("submit")), ("summary", .string("Send WeChat – 李四 chat to example@email.com")),
            ("params", .obj([("text", .string("13800138000")), ("windowTitle", .string("WeChat – 李四"))])),
            ("arguments", .array([.string("WeChat")])),
        ])
        #expect(p.project(approval, policy: Self.wide) == [.agentThought("收到未识别的运行事件（approval.required），未作处理")])
        for s in Self.otherApp { #expect(!text(approval).contains(s)) }
        let q = ETest.event("question.asked", [("message", .string("Forward 李四's message?")), ("choices", .array([.string("WeChat")]))])
        #expect(p.project(q, policy: Self.wide) == [.agentThought("收到未识别的运行事件（question.asked），未作处理")])
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

    // MARK: Kevin's second ruling (README §七)

    /// P1: a bound-window title with a person's name never appears in any
    /// update, log line or stored JSON, even with every opt-in widened.
    @Test func p1WindowTitleNameNeverLeaves() {
        let name = "王小明"
        let title = "候选人 \(name) 的简历 – Preview"
        let target = JSONValue.obj([("windowId", .int(813)), ("elementRef", .string("el_7")), ("title", .string(title)),
                                    ("windowTitle", .string(title)), ("appName", .string("Preview \(name)")),
                                    ("label", .string("下载简历"))])
        let events = [
            ETest.event("run.started", [("kind", .string("act")), ("title", .string(title))]),
            ETest.event("action.accepted", [("requestId", .string("req_000aaaaa0009")), ("kind", .string("click")),
                                            ("title", .string("Click download on \(title)")), ("target", target)], cursor: 2),
            ETest.event("action.completed", [("receipt", ETest.receipt().setting("target", target)), ("target", target),
                                             ("summary", .string("Opened \(name)'s resume")), ("windowTitle", .string(title)),
                                             ("name", .string(name))], cursor: 3),
            ETest.event("unit.started", [("unitType", .string("resume.open")), ("name", .string(name))], cursor: 4),
            ETest.event("run.ended", [("outcome", .string("success")), ("windowTitle", .string(title))], cursor: 5),
        ]
        var session = ACPProjectorSession()
        var out: [String] = []
        for e in events {
            out += ETest.strings(session.project(e, policy: Self.wide))
            out.append(ACPRedactor.logLine(e))
            out.append(ACPRedactor.redactJSON(e.payload, policy: Self.wide).encoded())
        }
        for s in out {
            #expect(!s.contains(name), "name in \(s)")
            #expect(!s.contains("候选人"), "title in \(s)")
            #expect(!s.contains("Preview"), "title in \(s)")
        }
        // Page body text is still governed by pageText: the label shows.
        #expect(out.contains { $0.contains("元素：下载简历") })
        #expect(ACPDataClass.windowTitle.tier == .protected)
        #expect(ACPDataClass.identity.tier == .protected)
        #expect(ACPDataClassifier.classify(key: "appName") == .identity)
    }

    func session(_ events: [ACPRuntimeEvent]) -> [[ACPSessionUpdate]] {
        var s = ACPProjectorSession()
        return events.map { s.project($0, policy: strict) }
    }

    /// P2: unknown is in progress while the Run is active and becomes a
    /// terminal "结果未知 · 需要核实" (status failed, level unknown) at run.ended.
    @Test func p2UnknownBecomesTerminalAtRunEnd() throws {
        let out = session([
            ETest.event("run.started", [("kind", .string("act"))]),
            ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("type"))], cursor: 2),
            ETest.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb"))], cursor: 3),
            ETest.event("action.unknown", [("receipt", ETest.receipt(delivery: "unknown", execution: "unknown"))], cursor: 4),
            ETest.event("run.ended", [("outcome", .string("unknown"))], cursor: 5),
        ])
        let during = try #require(call(out[3]))
        #expect(during.level == .unknown && during.status == .inProgress)
        let final = try #require(call(out[4]))
        #expect(final.toolCallId == during.toolCallId)
        #expect(final.status == .failed)
        #expect(final.level == .unknown)
        #expect(final.title == "输入文字 — 结果未知 · 需要核实")
        #expect(final.detail.contains("执行已终止，结果未知"))
        #expect(final.detail.contains { $0.contains("不会重试") && $0.contains("AgentDesktop 主窗口") })
    }

    @Test func p2DispatchedWithoutResultIsTerminalUnknown() throws {
        let out = session([
            ETest.event("run.started", [("kind", .string("act"))]),
            ETest.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("click"))], cursor: 2),
            ETest.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb"))], cursor: 3),
            ETest.event("run.ended", [("outcome", .string("unknown")), ("reason", .string("runtime_restarted"))], cursor: 4),
        ])
        let final = try #require(call(out[3]))
        #expect(final.level == .unknown && final.status == .failed)
        if case .failed = final.level! { Issue.record("never level .failed") }
    }

    @Test func p2CompletedReceiptWithUnknownDeliveryIsTerminalToo() throws {
        let out = session([
            ETest.event("run.started", [("kind", .string("act"))]),
            ETest.event("action.completed", [("receipt", ETest.receipt(delivery: "unknown"))], cursor: 2),
            ETest.event("run.ended", [("outcome", .string("unknown"))], cursor: 3),
        ])
        let final = try #require(call(out[2]))
        #expect(final.level == .unknown && final.status == .failed)
    }

    @Test func p2KnownActionsAreNotReopened() {
        let out = session([
            ETest.event("run.started", [("kind", .string("unit"))]),
            ETest.event("action.refused", [("requestId", .string("req_0001aaaabbbb")),
                                           ("reason", .obj([("code", .string("stop_pending")), ("message", .string("x"))]))], cursor: 2),
            ETest.event("action.completed", [("receipt", ETest.receipt(requestId: "req_0002ccccdddd"))], cursor: 3),
            ETest.event("run.ended", [("outcome", .string("success"))], cursor: 4),
        ])
        #expect(call(out[3]) == nil, "no terminal update for refused or executed actions: \(out[3])")
    }

    @Test func p2OtherRunsUnaffected() {
        let out = session([
            ETest.event("action.unknown", [("receipt", ETest.receipt(delivery: "unknown", execution: "unknown"))], run: "run_aaaaaaaaaaaa"),
            ETest.event("run.ended", [("outcome", .string("unknown"))], run: "run_bbbbbbbbbbbb", cursor: 2),
        ])
        #expect(call(out[1]) == nil)
    }
}
