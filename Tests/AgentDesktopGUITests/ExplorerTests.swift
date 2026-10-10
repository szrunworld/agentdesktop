import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// Case IDs from docs/ai-gui/tests/cases.csv. The executor and observation
// are spies over a simulated neutral form: these prove the GUI layer's
// loop, budgets, cancellation and verification, not native input
// isolation (G0, T01). Since A6 a run is a unit Run of the Runtime; here
// RecordingSink plays the Runtime's part and keeps what the explorer wrote.

let contract = ContractBundle.shared

func schemaClean(_ v: JSONValue, _ def: String, domain: Bool = true) throws -> Bool {
    let violations = try contract.validate(v, def)
    if !violations.isEmpty { Issue.record("\(def): \(violations.prefix(6))") }
    return violations.isEmpty
}

/// Every unit.* event against the Runtime's UnitRunEvent catalogue.
func unitEventsClean(_ events: [JSONValue]) -> Bool {
    var clean = true
    for e in events {
        let v = RuntimeContract.shared.validate(e, "UnitRunEvent")
        if !v.isEmpty { Issue.record("UnitRunEvent: \(v.prefix(4)) in \(e.encoded())"); clean = false }
    }
    return clean
}

@Suite("Explorer and unit Runs")
struct ExplorerTests {
    // MAC-001-A as a unit test: name=Ada, Apply, verified by a newer observation.
    @Test func mac001_neutralHappyPath() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        // The page shows the result one look late, so success has to come
        // from the observation taken after the model's finish.
        await h.observation.set(statusLag: 1)
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)

        #expect(run.ending == .verified)
        #expect(h.form.status == GuiHarness.expected)
        #expect(await h.executor.executed.count == 3, "click name, type Ada, click Apply")
        #expect(h.form.submissions == 1)
        #expect(h.ai.callCount == 4)
        #expect(run.modelAttempts == 4)
        #expect(run.steps == 4)
        #expect(run.verification?.status == "matched")
        // The verifier read an observation taken after the finish proposal.
        let finishSnapshot = h.ai.contexts.last.map { ctx -> String in
            if case let .guiStep(p) = ctx.purpose { return p.snapshotId }; return ""
        }
        let verifiedObs = try #require(run.verification?.observationId)
        #expect(Int(verifiedObs.dropFirst(4))! > Int(finishSnapshot!.dropFirst(5))!)
        #expect(run.lastDelivery == "confirmed")
        #expect(run.count("unit.action") == 3 && run.count("unit.step.proposed") == 4)
        let verifications = run.events.filter { $0["type"]?.stringValue == "unit.verification" }
        #expect(verifications.last?["data"]?["verifierId"]?.stringValue == GoalVerifier.verifierId)
        #expect(await h.audit.actions.count == 3)
        #expect(await h.audit.inferences.count == 4)
        #expect(unitEventsClean(run.events))
        let text = run.events.map { $0.encoded() }.joined()
        #expect(!text.contains("Ada"), "typed text never appears in events")
        #expect(!text.contains("中立表单") && !text.contains("sk-canary-gui"), "no goal, no secret")
    }

    @Test func verifiedRightAfterTheLastInputNeedsNoFinish() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .verified)
        #expect(h.ai.callCount == 3, "the re-observation after Apply already verified the goal")
        #expect(await h.executor.executed.count == 3)
    }

    @Test func alreadySatisfiedSucceedsWithoutAModelCall() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        h.form.apply(.click(sourcePixel: Point(x: 200, y: 100)))
        h.form.apply(.type(text: "Ada"))
        h.form.apply(.click(sourcePixel: Point(x: 200, y: 300)))
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .verified)
        #expect(h.ai.callCount == 0)
        #expect(await h.executor.executed.isEmpty)
    }

    // Every predicate of verification.all must hold on the same observation.
    @Test func everyPredicateMustHold() async throws {
        let h = try GuiHarness(Array(repeating: finish, count: 2), limits: [("maxSteps", .int(2))])
        try await h.setUpProfile()
        h.form.apply(.click(sourcePixel: Point(x: 200, y: 100)))
        h.form.apply(.type(text: "Ada"))
        h.form.apply(.click(sourcePixel: Point(x: 200, y: 300)))
        let both = h.startParams().setting("verification", .obj([("all", .array([
            .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string(GuiHarness.expected))]),
            .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string("不会出现"))]),
        ]))]))
        let runId = try await h.start(both)
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "limit_exceeded"))
        #expect(h.run(runId).verification?.status == "contradicted")
    }

    // GUI-003: finish alone never succeeds; the bound text decides.
    @Test func gui003_finishWithoutTheTextDoesNotSucceed() async throws {
        let h = try GuiHarness(Array(repeating: finish, count: 3), limits: [("maxSteps", .int(3))])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "limit_exceeded"))
        #expect(run.verification?.status == "contradicted")
        #expect(await h.executor.executed.isEmpty)
        // Each finish was followed by a newer observation.
        #expect(await h.observation.count == 1 + 3)
    }

    // unit.run limits only narrow the profile's.
    @Test func runLimitsNarrowTheProfile() async throws {
        let h = try GuiHarness(Array(repeating: finish, count: 5))
        try await h.setUpProfile()
        let runId = try await h.start(h.startParams().setting("limits", .obj([("maxSteps", .int(2))])))
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "limit_exceeded"))
        #expect(h.ai.callCount == 2)
    }

    @Test func gui003_backendWithoutStaticTextIsCapabilityMismatch() async throws {
        let h = try GuiHarness([finish])
        try await h.setUpProfile()
        await h.observation.set(elementsAvailable: false)
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "capability_mismatch"))
    }

    // GUI-005: a disabled action is refused before input.
    @Test func gui005_forbiddenActionNeverReachesTheExecutor() async throws {
        let h = try GuiHarness([typeText("Ada")])
        try await h.setUpProfile()
        let runId = try await h.start(h.startParams(actions: ["click"]))
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "forbidden"))
        #expect(run.count("unit.step.rejected") == 1)
        #expect(await h.executor.executed.isEmpty)
        #expect(h.form.name.isEmpty)
        #expect(unitEventsClean(run.events))
    }

    // GUI-006: the 21st step never starts; attempts per step and in total are capped.
    @Test func gui006_stepBudget() async throws {
        let h = try GuiHarness(Array(repeating: click(600, 600), count: 25))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "limit_exceeded"))
        #expect(h.ai.callCount == 20)
        #expect(run.steps == 20)
        #expect(await h.executor.executed.count == 20)
    }

    @Test func gui006_attemptBudgetPerStepAndTotal() async throws {
        let transient = StubAiService.Reply.error(ContractError(.upstreamUnavailable, "503"))
        let h = try GuiHarness(Array(repeating: transient, count: 10))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "upstream_unavailable"))
        #expect(h.ai.callCount == 2, "one step: first try plus one retry, never more")
        #expect(await h.executor.executed.isEmpty)
    }

    @Test func gui006_totalAttemptsCapped() async throws {
        let h = try GuiHarness(Array(repeating: click(600, 600), count: 40),
                               limits: [("maxTotalModelAttempts", .int(5))])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "limit_exceeded"))
        #expect(h.ai.callCount == 5)
        #expect(run.modelAttempts == 5)
    }

    @Test func gui006_wallDeadlineStopsNewWork() async throws {
        let clock = ManualClock(autoAdvance: true)
        let h = try GuiHarness([.text("{\"kind\":\"wait\",\"waitMs\":1000}"), .text("{\"kind\":\"wait\",\"waitMs\":1000}"),
                                .text("{\"kind\":\"wait\",\"waitMs\":1000}")],
                               limits: [("maxWallTimeMs", .int(2000)), ("maxWaitMs", .int(1000))], fixture: true, clock: clock)
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "deadline_exceeded"))
        #expect(h.ai.callCount == 2, "no model call starts at or after the deadline")
    }

    // GUI-007: wait bounds and a cancellable wait.
    @Test(arguments: [(0, true), (5000, true), (5001, false), (-1, false)])
    func gui007_waitBounds(ms: Int, accepted: Bool) async throws {
        let h = try GuiHarness([.text("{\"kind\":\"wait\",\"waitMs\":\(ms)}"), .text("{\"kind\":\"needs_user\",\"reasonCode\":\"stop\",\"message\":\"stop here\"}")],
                               fixture: true)
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(await h.executor.executed.isEmpty, "wait is not input")
        if accepted {
            #expect(run.ending == .needsInput(reason: "stop"))
            #expect(run.steps == 2, "a wait consumes a step")
            #expect(await h.observation.count == 2, "a new observation after the wait")
        } else {
            #expect([UnitRunEnding.failed(reason: "limit_exceeded"), .failed(reason: "invalid_action")].contains(run.ending))
        }
    }

    @Test func gui007_cancelDuringWait() async throws {
        let clock = ManualClock(autoAdvance: false)
        let h = try GuiHarness([.text("{\"kind\":\"wait\",\"waitMs\":5000}")], fixture: true, clock: clock)
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the wait") { clock.pendingSleeps == 1 }
        clock.advance(ms: 1000)
        h.cancel(runId)
        await h.finished(runId)
        #expect(clock.pendingSleeps == 0, "the timer was withdrawn")
        #expect(h.run(runId).ending == .cancelled)
        #expect(await h.observation.count == 1, "no observation after the cancelled wait")
    }

    // GUI-008: needs_user waits for a person; there is no resume.
    @Test func gui008_needsUserWaits() async throws {
        let h = try GuiHarness([.text("Thought: login.\nAction: call_user(content='please log in')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .needsInput(reason: "model_requested_user"))
        #expect(await h.executor.executed.isEmpty)
    }

    // RET-004 / GUI-008: an unknown outcome is never sent again.
    @Test func ret004_unknownOutcomeIsNotRetried() async throws {
        let h = try GuiHarness([click(200, 300), click(200, 300), click(200, 300)])
        try await h.setUpProfile()
        await h.executor.set(mode: .unknown)
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "action_outcome_unknown"))
        #expect(h.form.submissions == 1)
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
        #expect(run.lastDelivery == "unknown")
    }

    // CAN-002: cancel while the model is thinking; the late answer is no input.
    @Test func can002_cancelDuringInference() async throws {
        let h = try GuiHarness([.hang("Thought: x\nAction: click(start_box='(200,300)')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the model call") { h.ai.isHanging }
        h.cancel(runId)
        await h.finished(runId)
        #expect(h.run(runId).ending == .cancelled)
        #expect(await h.executor.executed.isEmpty)
        #expect(h.form.submissions == 0)
    }

    // CAN-002: an answer that arrives after cancel is recorded as discarded
    // and never becomes input.
    @Test func can002_lateAnswerIsDiscarded() async throws {
        let h = try GuiHarness([.late("Thought: x\nAction: click(start_box='(200,300)')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the model call") { h.ai.isLate }
        h.cancel(runId)
        await eventually("the cancel took") { await h.units!.task(for: runId) != nil }
        try await Task.sleep(nanoseconds: 20_000_000)
        h.ai.releaseLate()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .cancelled)
        #expect(await h.executor.executed.isEmpty)
        #expect(h.form.submissions == 0)
        let attempts = run.events.filter { $0["type"]?.stringValue == "unit.inference.attempt" }
        #expect(attempts.contains { $0["data"]?["discarded"]?.boolValue == true })
        #expect(await h.audit.inferences.isEmpty, "a discarded answer is not recorded as a usable inference")
    }

    // CAN-003: cancel during input waits for the executor's verdict.
    @Test func can003_cancelDuringInputWaitsForTheReceipt() async throws {
        let h = try GuiHarness([click(200, 300), click(200, 300)])
        try await h.setUpProfile()
        await h.executor.set(mode: .hang)
        let runId = try await h.start()
        await eventually("the input") { await h.executor.isHanging }
        h.cancel(runId)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(h.run(runId).ending == nil, "the explorer still holds the Run while its input is out")
        await h.executor.release()
        await h.finished(runId)
        #expect(h.run(runId).ending == .cancelled)
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
    }

    // A record the Runtime could not write stops the explorer before the
    // next input (GX-11).
    @Test func aFailedRecordStopsBeforeInput() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let runId = try await h.start()
        h.sink(runId).failWrites = true
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "audit_unavailable"))
        #expect(await h.executor.executed.count <= 1)
    }

    // Audit records come before model calls and input (§09.3).
    @Test func auditFailureStopsBeforeTheModel() async throws {
        let h = try GuiHarness([click(200, 300)])
        try await h.setUpProfile()
        await h.audit.set(failInference: true)
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "audit_unavailable"))
        #expect(h.ai.callCount == 0)
    }

    @Test func auditFailureStopsBeforeInput() async throws {
        let h = try GuiHarness([click(200, 300)])
        try await h.setUpProfile()
        await h.audit.set(failAction: true)
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "audit_unavailable"))
        #expect(await h.executor.executed.isEmpty)
    }

    // GUI-001/TRN-007: a malformed reply never becomes a proposal or input,
    // and its call stays on record.
    @Test func gui001_malformedReplyIsRefused() async throws {
        let h = try GuiHarness([.text("Action: click(start_box='(1,1)')\nAction: click(start_box='(2,2)')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "invalid_action"))
        #expect(await h.executor.executed.isEmpty)
        #expect(run.modelAttempts == 1 && run.count("unit.step.proposed") == 0)
        #expect(unitEventsClean(run.events))
    }

    @Test func noBackendKeepsRealInputOff() async throws {
        let h = try GuiHarness([], backend: false)
        try await h.setUpProfile()
        #expect(h.units == nil)
        let caps = GuiCapabilities.capabilities(features: h.features, codecs: h.codecs)
        #expect(try schemaClean(caps, "GuiCapabilities", domain: false))
        #expect(caps["verificationPredicates"]?.arrayValue?.isEmpty == true)
        #expect(caps["features"]?["nativeIsolationEvidence"]?.stringValue == "NOT_RUN")
        #expect(caps["guiAdapters"] == .array([.string("uitars_v1")]))
    }
}

@Suite("unit.run admission")
struct UnitRunAdmissionTests {
    func refusal(_ r: Result<any UnitRunPlan, RuntimeError>) -> (String, String?)? {
        if case let .failure(e) = r { return (e.code, e.details?["reason"]?.stringValue) }
        return nil
    }

    // F40-06 rows 7–15 for the executor's part.
    @Test func refusalsNameTheirReason() async throws {
        let h = try GuiHarness([])
        #expect(refusal(await h.admit())! == ("not_found", "no_default_gui_profile"))
        let gui = try await h.setUpProfile()
        let unknown = h.startParams().setting("guiProfileId", .string("gp_missing")).setting("expectedProfileRevision", .int(1))
        #expect(refusal(await h.admit(unknown))?.1 == "gui_profile_not_found")
        let stale = h.startParams().setting("guiProfileId", gui["guiProfileId"]!).setting("expectedProfileRevision", .int(9))
        #expect(refusal(await h.admit(stale))! == ("conflict", "profile_revision_changed"))
        #expect(refusal(await h.admit(h.startParams().setting("mode", .string("replay_only"))))!
                == ("capability_missing", "replay_not_available"))
        let predicate = h.startParams().setting("verification", .obj([("all", .array([.obj([("kind", .string("element_present")),
                                                                                            ("role", .string("button"))])]))]))
        #expect(refusal(await h.admit(predicate))! == ("capability_mismatch", "predicate_unsupported"))
        _ = try await h.ok("ai.profiles.disable", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!)]),
                           key: "disable-001")
        let disabled = h.startParams().setting("guiProfileId", gui["guiProfileId"]!).setting("expectedProfileRevision", .int(2))
        #expect(refusal(await h.admit(disabled))! == ("conflict", "disabled"))
        #expect(h.ai.callCount == 0)
    }

    // F40-06 row 12: a profile that has not passed the GUI contract test is
    // refused after the profile checks and before the action checks.
    @Test func row12_guiContractNotPassedIsRefused() async throws {
        let h = try GuiHarness([])
        let gui = try await h.setUpProfile()
        h.evidence.passed = false
        let r = await h.admit(h.startParams().setting("allowedActions", .array([.string("click")])))
        #expect(refusal(r)! == ("capability_mismatch", "gui_contract_not_passed"))
        if case let .failure(e) = r { #expect(e.details?["guiProfileId"] == gui["guiProfileId"]) }
        #expect(refusal(await h.admit(h.startParams().setting("mode", .string("replay_only"))))?.1 == "gui_contract_not_passed",
                "row 12 comes before row 15")
        h.evidence.passed = true
        #expect(refusal(await h.admit()) == nil)
    }

    // Codex on 817221a: GUI contract evidence holds for the coordinate
    // protocol (and adapter) it was tested with only.
    @Test func row12_evidenceIsBoundToTheCoordinateProtocol() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()   // uitars_v1 with image_pixels
        let c = try await ConfigBindingResolver(store: h.store, codecs: h.codecs)
            .resolve(guiProfileId: nil, expectedProfileRevision: nil, callerScope: "owner").primary
        let model = c.resolvedModel.model
        let pixels = try h.codecs.codec(adapterId: "uitars_v1", coordinateProtocol: "image_pixels").provenance
        let normalized = try h.codecs.codec(adapterId: "uitars_v1", coordinateProtocol: "normalized_1000").provenance
        func record(_ p: AdapterProvenance?) async throws {
            try await h.store.recordCapabilityEvidence(
                modelProfileId: model.modelProfileId, revision: Int(model.revision), layer: .guiContract, status: "verified",
                operationId: nil, reasonCode: nil,
                adapter: (p ?? pixels).map { ($0.adapterVersion, $0.promptVersion, $0.parserVersion) },
                gui: p.map { ($0.adapterId.rawValue, $0.coordinateProtocol.rawValue) })
        }
        #expect(try await h.store.guiContractPassed(c, provenance: pixels) == false, "never tested")
        try await record(normalized)
        #expect(try await h.store.guiContractPassed(c, provenance: pixels) == false, "tested with another coordinate protocol")
        try await record(nil)
        #expect(try await h.store.guiContractPassed(c, provenance: pixels) == false, "evidence that does not say which protocol")
        try await record(pixels)
        #expect(try await h.store.guiContractPassed(c, provenance: pixels) == true)
        // Codex on bedbff7: testing another scope on the same model profile
        // revision (a fallback with another protocol) keeps this one.
        try await record(normalized)
        #expect(try await h.store.guiContractPassed(c, provenance: pixels) == true)
    }

    // Codex on 89d4596: a profile declaring versions other than its codec's
    // is judged by the codec the run uses, as the capability test records.
    @Test func row12_usesTheCodecsProvenanceNotTheDeclaredVersions() async throws {
        let h = try GuiHarness([])
        let first = try await h.setUpProfile()
        // The same model profile, a profile that declares other versions.
        let model0 = try await h.ok("ai.modelProfiles.get", .obj([("modelProfileId", first["modelProfileId"]!)]))
        let odd = try await h.ok("ai.profiles.create", .obj([
            ("name", .string("Odd")), ("modelProfileId", model0["modelProfileId"]!), ("modelProfileRevision", model0["revision"]!),
            ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("9.9.9")), ("promptVersion", .string("other-prompt")),
            ("parserVersion", .string("other-parser")), ("coordinateProtocol", .string("image_pixels")), ("limits", GuiLimits.ceiling.json),
            ("allowedFallbackProfileRefs", .array([]))]), key: "odd-profile-1")
        let c = try await ConfigBindingResolver(store: h.store, codecs: h.codecs)
            .resolve(guiProfileId: odd["guiProfileId"]!.stringValue!, expectedProfileRevision: odd["revision"]!.intValue!,
                     callerScope: "owner").primary
        let real = try h.codecs.codec(adapterId: c.adapterId, coordinateProtocol: c.coordinateProtocol).provenance
        #expect(c.guiProfile["adapterVersion"]?.stringValue != real.adapterVersion
                || c.guiProfile["promptVersion"]?.stringValue != real.promptVersion, "the harness profile declares other versions")
        let model = c.resolvedModel.model
        try await h.store.recordCapabilityEvidence(
            modelProfileId: model.modelProfileId, revision: Int(model.revision), layer: .guiContract, status: "verified",
            operationId: nil, reasonCode: nil, adapter: (real.adapterVersion, real.promptVersion, real.parserVersion),
            gui: (real.adapterId.rawValue, real.coordinateProtocol.rawValue))
        #expect(try await h.store.guiContractPassed(c, provenance: real) == true)
    }

    @Test func anActionTheBackendCannotExecuteIsRefused() async throws {
        let h = try GuiHarness([])
        try await h.setUpProfile()
        let clicksOnly = UnitRunService(resolver: ConfigBindingResolver(store: h.store, codecs: h.codecs), evidence: h.evidence,
                                        ports: GuiExplorerPorts(observation: h.observation, execution: h.executor, audit: h.audit),
                                        features: GuiBackendFeatures(actions: [.click], verificationPredicates: ["element_text_equals"]),
                                        aiService: h.ai, codecs: h.codecs, clock: h.clock)
        let typing = await clicksOnly.admit(params: h.startParams(actions: ["click", "type"]), callerScope: "owner")
        #expect(refusal(typing)! == ("capability_mismatch", "action_unsupported"))
        #expect(refusal(await clicksOnly.admit(params: h.startParams(actions: ["click", "wait"]), callerScope: "owner")) == nil,
                "wait is the explorer's own")
    }

    // D07 / CFG-004 (run part): the binding is fixed at admission.
    @Test func bindingIsFixedAtAdmission() async throws {
        let h = try GuiHarness([.hang("x")])
        let gui = try await h.setUpProfile()
        let plan = try await h.admit().get()
        let other = try await h.setUpProfile(name: "Other")
        #expect(other["guiProfileId"] != gui["guiProfileId"])
        #expect(plan.guiProfileId == gui["guiProfileId"]?.stringValue)
        let next = try await h.admit().get()
        #expect(next.guiProfileId == other["guiProfileId"]?.stringValue)
    }

    // CFG-005: what a live unit Run pinned cannot be deleted under it.
    @Test func cfg005_aLiveRunPinsItsProfile() async throws {
        let h = try GuiHarness([.hang("x")])
        let gui = try await h.setUpProfile()
        let units = try #require(h.units)
        await h.store.setActiveRunCheck { kind, id in units.pins(kind, id) }
        let runId = try await h.start()
        await eventually("the model call") { h.ai.isHanging }
        #expect(units.pins(.guiProfile, gui["guiProfileId"]!.stringValue!))
        // Make it not the default first, so only the Run holds it.
        let def = try await h.ok("ai.profiles.default.get")
        _ = try await h.ok("ai.profiles.setDefault", .obj([("guiProfileId", .null), ("expectedDefaultRevision", def["default"]!["revision"]!)]),
                           key: "def-clear-1")
        let del = try await h.call("ai.profiles.delete", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!)]),
                                   key: "del-pinned-1")
        #expect(del["error"]?["code"]?.stringValue == "RESOURCE_IN_USE")
        h.cancel(runId)
        await h.finished(runId)
        #expect(!units.pins(.guiProfile, gui["guiProfileId"]!.stringValue!))
    }

    // Codex on ed056dc: admission pins what it resolved, so nothing it will
    // use can be deleted before the Run starts; a plan never started gives
    // its pins back.
    @Test func admissionPinsUntilStartedOrDiscarded() async throws {
        let h = try GuiHarness([])
        let gui = try await h.setUpProfile()
        let units = try #require(h.units)
        let id = try #require(gui["guiProfileId"]?.stringValue)
        let plan = try await h.admit().get()
        #expect(units.pins(.guiProfile, id), "pinned at admission")
        units.discard(plan)
        #expect(!units.pins(.guiProfile, id), "given back")
        let kept = try await h.admit().get()
        let stop = UnitRunStopHandle()
        units.start(kept, context: UnitRunContext(runId: "run-pin-1", sessionId: "sess-a", desktopId: "desk-a", bindingEpoch: 1,
                                                  callerScope: "owner", params: h.startParams()),
                    sink: RecordingSink(runId: "run-pin-1"), stop: stop)
        units.discard(kept)
        #expect(units.pins(.guiProfile, id), "a started plan's pins belong to its Run")
        stop.stop()
        await units.task(for: "run-pin-1")?.value
        #expect(!units.pins(.guiProfile, id), "freed when the Run ends")
    }

    // A change that slips in between resolving and pinning is caught.
    @Test func admissionResolvesAgainAfterPinning() async throws {
        final class ChangingResolver: GuiBindingResolver, @unchecked Sendable {
            let inner: GuiBindingResolver
            let lock = NSLock()
            var calls = 0
            init(_ inner: GuiBindingResolver) { self.inner = inner }
            func resolve(guiProfileId: String?, expectedProfileRevision: Int?, callerScope: String) async throws
                -> (primary: GuiCandidate, fallback: [GuiCandidate], policyRevision: Int) {
                let n = lock.withLock { calls += 1; return calls }
                if n == 2 { throw ContractError(.notFound, "the GUI profile was deleted") }
                return try await inner.resolve(guiProfileId: guiProfileId, expectedProfileRevision: expectedProfileRevision,
                                               callerScope: callerScope)
            }
        }
        let h = try GuiHarness([])
        let gui = try await h.setUpProfile()
        let units = UnitRunService(resolver: ChangingResolver(ConfigBindingResolver(store: h.store, codecs: h.codecs)),
                                   evidence: h.evidence,
                                   ports: GuiExplorerPorts(observation: h.observation, execution: h.executor, audit: h.audit),
                                   features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]),
                                   aiService: h.ai, codecs: h.codecs, clock: h.clock)
        let r = await units.admit(params: h.startParams(), callerScope: "owner")
        #expect(refusal(r)?.0 == "not_found")
        #expect(!units.pins(.guiProfile, gui["guiProfileId"]!.stringValue!), "nothing stays pinned")
    }

    // Codex on 89d4596: a stop accepted while an input is out keeps the
    // pins until the driver exits; nothing it uses can be deleted under it.
    @Test func aStoppedRunKeepsItsPinsUntilItsDriverExits() async throws {
        let h = try GuiHarness([click(200, 300), click(200, 300)])
        let gui = try await h.setUpProfile()
        let units = try #require(h.units)
        let id = try #require(gui["guiProfileId"]?.stringValue)
        await h.executor.set(mode: .hang)
        let runId = try await h.start()
        await eventually("the input") { await h.executor.isHanging }
        h.cancel(runId)
        #expect(units.pins(.guiProfile, id), "the driver still runs: pinned")
        await h.executor.release()
        await h.finished(runId)
        #expect(!units.pins(.guiProfile, id))
    }

    // Codex on c702a5f: a Run waiting for a person keeps its pins until it
    // is stopped, then frees them.
    @Test func aWaitingRunFreesItsPinsWhenStopped() async throws {
        let h = try GuiHarness([.text("Thought: login.\nAction: call_user(content='please log in')")])
        let gui = try await h.setUpProfile()
        let units = try #require(h.units)
        let id = try #require(gui["guiProfileId"]?.stringValue)
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .needsInput(reason: "model_requested_user"))
        #expect(units.pins(.guiProfile, id), "still waiting: pinned")
        h.cancel(runId)
        #expect(!units.pins(.guiProfile, id), "stopped: free")
    }
}
