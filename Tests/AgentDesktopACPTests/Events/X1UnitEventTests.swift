import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// X1-3: the ACP projection of the GUI unit's verification and recovery
// events, after the X1-1 (inconclusive + reason) and X1-2 (stall kinds)
// contract increments. Fixed text for closed values only, never a payload
// string, never 「已验证」 (docs/acp/12-unit-run.md Q4 is open).

@Suite struct X1UnitEventTests {
    let p = ACPProjector()
    let strict = ACPPrivacyPolicy()
    let wide: ACPPrivacyPolicy = { var w = ACPPrivacyPolicy(); w.pageText = true; w.screenshots = .all; return w }()
    static let secret = "X1-SECRET 王小明 的私信 – 微信 验证码 834201"

    /// A whole UnitRunEvent, as the Runtime writes it.
    func event(_ type: String, _ data: [(String, JSONValue)], seq: Int = 7) -> (ACPRuntimeEvent, JSONValue) {
        let whole = JSONValue.obj([("runId", .string("run_0a1b2c3d4e5f")), ("sequence", .int(seq)),
                                   ("at", .string("2026-10-11T12:00:06.000Z")), ("type", .string(type)), ("data", .obj(data))])
        return (ACPRuntimeEvent(runId: "run_0a1b2c3d4e5f", cursor: seq, type: type, payload: whole), whole)
    }

    func thoughts(_ us: [ACPSessionUpdate]) -> [String] {
        us.compactMap { if case let .agentThought(s) = $0 { return s }; return nil }
    }

    /// The `enum` of one data field of one UnitRunEvent branch, from the contract.
    static func contractEnum(_ type: String, _ field: String) -> Set<String> {
        guard let schema = try? StrictJSON.parse(Data(RuntimeContract.embedded.schema.utf8)) else { return [] }
        for alt in schema["$defs"]?["UnitRunEvent"]?["oneOf"]?.arrayValue ?? []
        where alt["properties"]?["type"]?["const"]?.stringValue == type {
            return Set((alt["properties"]?["data"]?["properties"]?[field]?["enum"]?.arrayValue ?? []).compactMap(\.stringValue))
        }
        return []
    }

    // The projector's vocabularies are exactly the contract's.
    @Test func vocabulariesMatchTheContract() {
        #expect(ACPUnitEventType.verificationStatuses == Self.contractEnum("unit.verification", "status"))
        #expect(ACPUnitEventType.inconclusiveReasons == Self.contractEnum("unit.verification", "reason"))
        #expect(ACPUnitEventType.recoveryKinds == Self.contractEnum("unit.recovery", "kind"))
        #expect(ACPUnitEventType.verificationStatuses.contains("inconclusive"))
        #expect(ACPUnitEventType.recoveryKinds.isSuperset(of: ["repeated_action", "no_progress", "state_loop"]))
        for t in ACPUnitEventType.allCases {
            #expect(ACPEventType(rawValue: t.rawValue) == nil, "not part of the frozen platform catalogue")
            #expect(ACPEventType.tier(of: t.rawValue) == .normal)
        }
        // Every other unit.* type stays protected: one neutral line.
        #expect(ACPEventType.tier(of: "unit.step.proposed") == .protected)
        #expect(thoughts(p.project(event("unit.step.proposed", [("stepIndex", .int(0))]).0, policy: wide))
                == ["收到未识别的运行事件（unit.step.proposed），未作处理"])
    }

    @Test func verificationStatusesAndReasons() {
        let cases: [([(String, JSONValue)], String)] = [
            ([("status", .string("matched"))], "界面验证：已通过"),
            ([("status", .string("contradicted"))], "界面验证：未通过"),
            ([("status", .string("inconclusive"))], "界面验证：无法判定"),
            ([("status", .string("inconclusive")), ("reason", .string("elements_partial"))], "界面验证：无法判定（界面元素只读到一部分）"),
            ([("status", .string("inconclusive")), ("reason", .string("elements_unavailable"))], "界面验证：无法判定（没有读到界面元素）"),
            ([("status", .string("inconclusive")), ("reason", .string("ambiguous"))], "界面验证：无法判定（目标控件不止一个）"),
            ([("status", .string("inconclusive")), ("reason", .string("target_missing"))], "界面验证：无法判定（没有找到目标控件）"),
            ([("status", .string("inconclusive")), ("reason", .string("value_unreadable"))], "界面验证：无法判定（目标控件的值读不出）"),
        ]
        for (extra, text) in cases {
            let data = extra + [("verifierId", .string("element_text_equals")), ("observationId", .string("obs_ac0000b2")),
                                ("checkedAt", .string("2026-10-11T12:00:06.000Z"))]
            let (e, whole) = event("unit.verification", data)
            #expect(RuntimeContract.shared.validate(whole, "UnitRunEvent").isEmpty, "\(whole.encoded())")
            for policy in [strict, wide] {
                let out = p.project(e, policy: policy)
                #expect(out == [.agentThought(text)])
            }
        }
        // Every reason has its own text.
        #expect(Set(ACPUnitEventType.inconclusiveReasons.compactMap(ACPEventText.inconclusiveReason)).count == 5)
    }

    // Values outside the vocabularies show nothing of themselves; a reason on
    // a decided verdict is ignored; never 「已验证」.
    @Test func unknownValuesShowNothingOfThemselves() {
        let odd: [[(String, JSONValue)]] = [
            [("status", .string(Self.secret))],
            [("status", .string("passed"))],
            [],
            [("status", .string("inconclusive")), ("reason", .string(Self.secret))],
            [("status", .string("matched")), ("reason", .string("ambiguous"))],
        ]
        let expected = ["界面验证：未得出结论", "界面验证：未得出结论", "界面验证：未得出结论", "界面验证：无法判定", "界面验证：已通过"]
        for (data, text) in zip(odd, expected) {
            #expect(thoughts(p.project(event("unit.verification", data).0, policy: wide)) == [text])
        }
        for status in ACPUnitEventType.verificationStatuses {
            let t = thoughts(p.project(event("unit.verification", [("status", .string(status))]).0, policy: wide)).joined()
            #expect(!t.contains("已验证"), "\(status): \(t)")
        }
    }

    @Test func recoveryKinds() {
        let cases: [(String, String)] = [
            ("reobserve_after_empty_reply", "恢复：模型回复为空，重新观察后再问一次（第 1 次）"),
            ("repeated_action", "恢复：重复同一动作没有带来变化，重新观察，换一种做法（第 1 次）"),
            ("no_progress", "恢复：连续几步界面没有变化，重新观察，换一种做法（第 1 次）"),
            ("state_loop", "恢复：界面回到了之前的状态，重新观察，换一种做法（第 1 次）"),
        ]
        #expect(Set(cases.map(\.0)) == ACPUnitEventType.recoveryKinds)
        for (kind, text) in cases {
            let (e, whole) = event("unit.recovery", [("stepIndex", .int(2)), ("kind", .string(kind)), ("count", .int(1))])
            #expect(RuntimeContract.shared.validate(whole, "UnitRunEvent").isEmpty, "\(whole.encoded())")
            #expect(p.project(e, policy: strict) == [.agentThought(text)])
        }
        // Unknown kind or odd count: the fact of a recovery, nothing else.
        #expect(thoughts(p.project(event("unit.recovery", [("kind", .string(Self.secret)), ("count", .int(1))]).0, policy: wide))
                == ["已进行一次恢复"])
        #expect(thoughts(p.project(event("unit.recovery", [("kind", .string("no_progress")), ("count", .int(-3))]).0, policy: wide))
                == ["恢复：连续几步界面没有变化，重新观察，换一种做法"])
    }

    // Privacy: fields outside the contract (titles, typed text) are never
    // read, under any policy; a payload marked withheld shows status only.
    @Test func payloadStringsNeverLeak() {
        for type in ACPUnitEventType.allCases.map(\.rawValue) {
            let data: [(String, JSONValue)] = [("status", .string("inconclusive")), ("reason", .string("ambiguous")),
                                               ("kind", .string("state_loop")), ("count", .int(1)),
                                               ("windowTitle", .string(Self.secret)), ("text", .string(Self.secret)),
                                               ("label", .string(Self.secret)), ("value", .string(Self.secret)),
                                               ("param", .string(Self.secret)), ("observationId", .string("obs_\(Self.secret)"))]
            for policy in [strict, wide] {
                let t = thoughts(p.project(event(type, data).0, policy: policy)).joined()
                for s in ["X1-SECRET", "王小明", "微信", "834201", "obs_"] { #expect(!t.contains(s), "\(type) leaked \(s): \(t)") }
            }
            let withheld = thoughts(p.project(event(type, data + [("withheld", .bool(true))]).0, policy: wide))
            #expect(withheld == [type == "unit.verification" ? "界面验证：未得出结论" : "已进行一次恢复"])
        }
    }

    // The closing reasons a stalled unit Run ends with (X1-2) are shown.
    @Test func stallClosingReasonsAreShown() {
        for (reason, text) in [("no_progress", "原因：没有进展"), ("loop_detected", "原因：界面来回循环")] {
            let out = p.project(ETest.event("run.ended", [("phase", .string("ended")), ("outcome", .string("failed")),
                                                          ("reason", .string(reason))]), policy: strict)
            let m = out.compactMap { if case let .agentMessage(s) = $0 { return s }; return nil }.joined()
            #expect(m.contains("任务结束：失败") && m.contains(text), "\(m)")
        }
    }

    // A session projector: unit events change nothing it learned.
    @Test func unitEventsLeaveTheContextAlone() {
        var s = ACPProjectorSession()
        _ = s.project(ETest.event("run.started", [("kind", .string("unit"))]), policy: strict)
        let before = s.context
        _ = s.project(event("unit.verification", [("status", .string("inconclusive")), ("reason", .string("elements_partial"))]).0,
                      policy: strict)
        _ = s.project(event("unit.recovery", [("stepIndex", .int(1)), ("kind", .string("repeated_action")), ("count", .int(1))]).0,
                      policy: strict)
        #expect(s.context == before)
    }
}
