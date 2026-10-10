import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// X1 (docs/plan/05 §5.2, 08 GX-13…16): three-valued verification. Only
// matched is success; a partial or unavailable element read never proves
// absence; an ambiguous target is never resolved by a guess.

private func el(_ role: String, label: String? = nil, value: String? = nil) -> ObservedElement {
    ObservedElement(role: role, label: label, value: value)
}

private func judge(_ p: GuiVerification, _ elements: [ObservedElement], _ coverage: ElementCoverage = .complete) -> GoalVerifier.Verdict {
    GoalVerifier.judge(p, elements: elements, coverage: coverage)
}

private func parse(_ json: String, params: JSONValue? = nil) throws -> GuiVerification {
    try GuiVerification(json: try StrictJSON.parse(Data(json.utf8)), params: params)
}

private let saved = el("static_text", label: "已保存：Ada")
private let nameField = el("text_field", label: "姓名", value: "Ada")
private let window = [saved, nameField, el("button", label: "应用")]

@Suite("X1 three-valued predicates")
struct X1PredicateTests {
    // GX-13: on a complete observation every leaf and combinator decides.
    @Test func gx13_completeObservationDecides() {
        #expect(judge(.elementTextEquals(text: "已保存：Ada"), window) == .matched)
        #expect(judge(.elementTextEquals(text: "已保存：Bob"), window) == .contradicted)
        #expect(judge(.elementExists(role: "button", label: "应用", text: nil), window) == .matched)
        #expect(judge(.elementExists(role: "button", label: "取消", text: nil), window) == .contradicted)
        #expect(judge(.elementExists(role: "text_field", label: "姓名", text: "Ada"), window) == .matched)
        #expect(judge(.elementExists(role: "text_field", label: "姓名", text: "Bob"), window) == .contradicted)
        let value = GuiVerification.valueEqualsParameter(role: "text_field", label: "姓名", param: "name", value: "Ada")
        #expect(judge(value, window) == .matched)
        #expect(judge(.valueEqualsParameter(role: "text_field", label: "姓名", param: "name", value: "Bob"), window) == .contradicted)
        // Combinators on decided operands.
        let yes = GuiVerification.elementTextEquals(text: "已保存：Ada"), no = GuiVerification.elementTextEquals(text: "x")
        #expect(judge(.not(yes), window) == .contradicted)
        #expect(judge(.not(no), window) == .matched)
        #expect(judge(.all([yes, value]), window) == .matched)
        #expect(judge(.all([yes, no]), window) == .contradicted)
        #expect(judge(.any([no, yes]), window) == .matched)
        #expect(judge(.any([no, no]), window) == .contradicted)
        // Normalization still applies to every comparison (v2 rule).
        #expect(judge(.elementTextEquals(text: "已保存：Ada"), [el("static_text", label: "\u{2066}已保存：Ada\u{2069}")]) == .matched)
    }

    // GX-14: a partial or unavailable read shows presence, never absence.
    @Test(arguments: [ElementCoverage.partial, .unavailable])
    func gx14_incompleteObservationNeverProvesAbsence(coverage: ElementCoverage) {
        let reason: GoalVerification.Reason = coverage == .partial ? .elementsPartial : .elementsUnavailable
        let missing = GuiVerification.elementExists(role: "button", label: "取消", text: nil)
        let present = GuiVerification.elementExists(role: "button", label: "应用", text: nil)
        // Found in what was read: it is there.
        #expect(judge(present, window, coverage) == .matched)
        // Not found in what was read: undecided, and not(…) of it too.
        #expect(judge(missing, window, coverage) == .inconclusive(reason))
        #expect(judge(.not(missing), window, coverage) == .inconclusive(reason))
        #expect(judge(.elementTextEquals(text: "已保存：Bob"), window, coverage) == .inconclusive(reason))
        // An empty, timed-out read is not "nothing on screen".
        #expect(judge(.not(present), [], coverage) == .inconclusive(reason))
        // all: undecided unless some operand is contradicted; any: matched wins.
        #expect(judge(.all([present, missing]), window, coverage) == .inconclusive(reason))
        #expect(judge(.any([missing, present]), window, coverage) == .matched)
        // value_equals_parameter needs a unique target: one candidate in a
        // read that is not complete may have a twin in the unread part, so
        // neither the right nor a wrong value decides (Codex on 3f59d7c).
        let right = GuiVerification.valueEqualsParameter(role: "text_field", label: "姓名", param: "name", value: "Ada")
        let wrong = GuiVerification.valueEqualsParameter(role: "text_field", label: "姓名", param: "name", value: "Bob")
        #expect(judge(right, window, coverage) == .inconclusive(reason))
        #expect(judge(wrong, window, coverage) == .inconclusive(reason))
        #expect(judge(.not(wrong), window, coverage) == .inconclusive(reason))
        // Two candidates are ambiguous however much was read.
        #expect(judge(right, [nameField, el("text_field", label: "姓名", value: "Ada")], coverage) == .inconclusive(.ambiguous))
        // A decided contradiction still decides (text that was read and differs is not one).
        #expect(judge(.all([present, .not(present)]), window, coverage) == .contradicted)
    }

    // GX-15: two elements answer the same label: the verifier does not
    // choose one; a missing or unreadable target is also undecided.
    @Test func gx15_ambiguousOrMissingTargetIsInconclusive() {
        let p = GuiVerification.valueEqualsParameter(role: "text_field", label: "姓名", param: "name", value: "Ada")
        let twin = [nameField, el("text_field", label: "姓名", value: "Ada")]
        #expect(judge(p, twin) == .inconclusive(.ambiguous))
        // Even when one of the two holds the value and the other does not.
        #expect(judge(p, [nameField, el("text_field", label: "姓名", value: "Bob")]) == .inconclusive(.ambiguous))
        #expect(judge(.not(p), twin) == .inconclusive(.ambiguous))
        #expect(judge(p, [saved]) == .inconclusive(.targetMissing))
        #expect(judge(p, [el("text_field", label: "姓名")]) == .inconclusive(.valueUnreadable))
        #expect(judge(p, [saved], .partial) == .inconclusive(.elementsPartial))
        // element_exists asks only "is there one": several are fine.
        #expect(judge(.elementExists(role: "text_field", label: "姓名", text: nil), twin) == .matched)
    }

    // GX-15 in a run: the model says done, the target is ambiguous: no
    // success, nothing dispatched, the verdict says why.
    @Test func gx15_ambiguousTargetNeverSucceedsAndDispatchesNothing() async throws {
        let h = try GuiHarness([finish, finish], limits: [("maxSteps", .int(2))])
        try await h.setUpProfile()
        await h.observation.set(extraElements: [el("text_field", label: "姓名", value: "")])
        var params = h.startParams()
        params = params.setting("goal", .obj([("description", .string(GuiHarness.goal)), ("params", .obj([("name", .string(""))]))]))
        params = params.setting("verification", .obj([("all", .array([
            try StrictJSON.parse(Data(#"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name"}"#.utf8)),
        ]))]))
        // "" is not a usable parameter value: refused before any Run.
        guard case let .failure(e) = await h.admit(params) else { Issue.record("an empty parameter was admitted"); return }
        #expect(e.code == "schema_invalid")
        params = params.setting("goal", .obj([("description", .string(GuiHarness.goal)), ("params", .obj([("name", .string("Ada"))]))]))
        await h.observation.set(extraElements: [el("text_field", label: "姓名", value: "Ada")])
        let runId = try await h.start(params)
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending != .verified)
        #expect(await h.executor.executed.isEmpty)
        let verdicts = run.events.filter { $0["type"]?.stringValue == "unit.verification" }
        #expect(!verdicts.isEmpty)
        for v in verdicts {
            #expect(v["data"]?["status"]?.stringValue == "inconclusive")
            #expect(v["data"]?["reason"]?.stringValue == "ambiguous")
            #expect(RuntimeContract.shared.validate(v, "UnitRunEvent").isEmpty, "\(v.encoded())")
        }
        #expect(run.verification?.status == "inconclusive")
    }

    // GX-16: dynamic text. The status shows the result only some looks
    // later; finish while it lags is not success, and success comes from
    // the observation that shows it, after the model's finish.
    @Test func gx16_lateTextSucceedsOnlyWhenSeen() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish, finish])
        try await h.setUpProfile()
        await h.observation.set(statusLag: 2)
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .verified)
        let statuses = run.events.filter { $0["type"]?.stringValue == "unit.verification" }.compactMap { $0["data"]?["status"]?.stringValue }
        #expect(statuses.last == "matched")
        #expect(statuses.dropLast().allSatisfy { $0 == "contradicted" })
        #expect(statuses.count >= 2)
        // The matched verdict is on the newest observation of the run.
        let lastObservation = run.events.last { $0["type"]?.stringValue == "unit.observation" }?["data"]?["observationId"]?.stringValue
        #expect(run.verification?.observationId == lastObservation)
    }

    // GX-14 in a run: a timed-out element read never lets not(…) succeed.
    @Test func gx14_partialReadNeverSatisfiesNot() async throws {
        let h = try GuiHarness([finish, finish], limits: [("maxSteps", .int(2))])
        try await h.setUpProfile()
        await h.observation.set(coverage: .partial)
        let params = h.startParams().setting("verification", .obj([("all", .array([
            try StrictJSON.parse(Data(#"{"kind":"not","of":{"kind":"element_exists","role":"button","label":"删除"}}"#.utf8)),
        ]))]))
        let runId = try await h.start(params)
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending != .verified)
        #expect(run.verification?.status == "inconclusive")
        // The same predicate on a complete read is matched at once, with no model call.
        let h2 = try GuiHarness([])
        try await h2.setUpProfile()
        let run2Id = try await h2.start(params)
        await h2.finished(run2Id)
        #expect(h2.run(run2Id).ending == .verified)
        #expect(h2.ai.callCount == 0)
    }
}

@Suite("X1 predicate admission")
struct X1AdmissionTests {
    @Test func wireFormRoundTripsWithoutParameterValues() throws {
        let json = #"{"kind":"all","of":[{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name"},{"kind":"not","of":{"kind":"element_exists","role":"button","label":"删除"}}]}"#
        let p = try parse(json, params: .obj([("name", .string("Ada Lovelace"))]))
        #expect(p.leafKinds == ["value_equals_parameter", "element_exists"])
        #expect(!p.json.encoded().contains("Ada Lovelace"))
        #expect(try GuiVerification(json: p.json, params: .obj([("name", .string("Ada Lovelace"))])) == p)
        // Parameter forms: integers and booleans have one on-screen text.
        #expect(try parse(#"{"kind":"value_equals_parameter","role":"text_field","label":"数量","param":"n"}"#,
                          params: .obj([("n", .int(3))])) == .valueEqualsParameter(role: "text_field", label: "数量", param: "n", value: "3"))
        #expect(throws: ContractError.self) {
            try parse(#"{"kind":"value_equals_parameter","role":"text_field","label":"数量","param":"n"}"#, params: .obj([("n", .double(1.5))]))
        }
    }

    @Test func boundsAndShapesAreRefused() throws {
        // Missing parameter, no label/text, not over a list, too deep, too many.
        #expect(throws: ContractError.self) { try parse(#"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name"}"#) }
        #expect(throws: ContractError.self) { try parse(#"{"kind":"element_exists","role":"button"}"#) }
        #expect(throws: ContractError.self) { try parse(#"{"kind":"not","of":[]}"#) }
        let leaf = #"{"kind":"element_exists","role":"button","label":"a"}"#
        let deep = (0..<4).reduce(leaf) { inner, _ in #"{"kind":"not","of":\#(inner)}"# }   // 5 levels
        #expect(throws: ContractError.self) { try parse(deep) }
        let wide = #"{"kind":"all","of":["# + Array(repeating: leaf, count: 9).joined(separator: ",") + "]}"
        #expect(throws: ContractError.self) { try parse(wide) }
        let many = #"{"kind":"all","of":["# + Array(repeating: #"{"kind":"any","of":[\#(leaf),\#(leaf)]}"#, count: 6).joined(separator: ",") + "]}"
        #expect(throws: ContractError.self) { try parse(many) }   // 19 predicates
    }

    @Test func admissionRefusesBeforeAnyRun() async throws {
        // A backend that verifies only static text: a nested element_exists is unsupported.
        let h = try GuiHarness([], predicates: ["element_text_equals"])
        try await h.setUpProfile()
        let nested = h.startParams().setting("verification", .obj([("all", .array([
            try StrictJSON.parse(Data(#"{"kind":"any","of":[{"kind":"element_text_equals","role":"static_text","text":"x"},{"kind":"element_exists","role":"button","label":"a"}]}"#.utf8)),
        ]))]))
        guard case let .failure(e) = await h.admit(nested) else { Issue.record("admitted"); return }
        #expect(e.code == "capability_mismatch")
        #expect(e.details?["reason"]?.stringValue == "predicate_unsupported")
        // A parameter the goal does not carry.
        let h2 = try GuiHarness([])
        try await h2.setUpProfile()
        let unbound = h2.startParams().setting("verification", .obj([("all", .array([
            try StrictJSON.parse(Data(#"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name"}"#.utf8)),
        ]))]))
        guard case let .failure(e2) = await h2.admit(unbound) else { Issue.record("admitted"); return }
        #expect(e2.code == "schema_invalid")
        #expect(e2.details?["reason"]?.stringValue == "verification_invalid")
        #expect(e2.notSent == true)
    }

    // The contract accepts every new shape inside unit_run_params and refuses malformed ones.
    @Test func contractShapes() throws {
        let runtime = RuntimeContract.shared
        func params(_ predicate: String) throws -> JSONValue {
            .obj([("desktopId", .string("desk-a")), ("mode", .string("explore")),
                  ("goal", .obj([("description", .string("填写姓名")), ("params", .obj([("name", .string("Ada"))]))])),
                  ("verification", .obj([("all", .array([try StrictJSON.parse(Data(predicate.utf8))]))])),
                  ("allowedActions", .array([.string("click")]))])
        }
        for good in [
            #"{"kind":"element_exists","role":"button","label":"应用"}"#,
            #"{"kind":"element_exists","role":"static_text","text":"已保存"}"#,
            #"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name"}"#,
            #"{"kind":"any","of":[{"kind":"element_text_equals","role":"static_text","text":"a"},{"kind":"not","of":{"kind":"element_exists","role":"button","label":"b"}}]}"#,
        ] { #expect(runtime.validate(try params(good), "unit_run_params").isEmpty, "\(good)") }
        for bad in [
            #"{"kind":"element_exists","role":"button"}"#,
            #"{"kind":"element_exists","role":"Button","label":"a"}"#,
            #"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"9x"}"#,
            #"{"kind":"value_equals_parameter","role":"text_field","label":"姓名","param":"name","value":"Ada"}"#,
            #"{"kind":"not","of":[{"kind":"element_exists","role":"button","label":"a"}]}"#,
            #"{"kind":"all","of":[]}"#,
            #"{"kind":"element_text_equals","role":"button","text":"a"}"#,
        ] { #expect(!runtime.validate(try params(bad), "unit_run_params").isEmpty, "\(bad)") }
    }
}
