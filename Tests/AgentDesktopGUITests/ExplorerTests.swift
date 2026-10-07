import AgentDesktopAI
import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopGUI

// Case IDs from docs/ai-gui/tests/cases.csv. The executor and observation
// are spies over a simulated neutral form: these prove the GUI layer's
// loop, budgets, cancellation and verification, not native input
// isolation (G0, T01).

let contract = ContractBundle.shared

func schemaClean(_ v: JSONValue, _ def: String, domain: Bool = true) throws -> Bool {
    let violations = domain ? try contract.validateDomain(v, def) : try contract.validateRpc(v, def)
    if !violations.isEmpty { Issue.record("\(def): \(violations.prefix(6))") }
    return violations.isEmpty
}

@Suite("Explorer and runs")
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
        let run = try await h.run(runId)

        #expect(run["state"]?.stringValue == "succeeded")
        #expect(h.form.status == GuiHarness.expected)
        #expect(await h.executor.executed.count == 3, "click name, type Ada, click Apply")
        #expect(h.form.submissions == 1)
        #expect(h.ai.callCount == 4)
        #expect(run["modelAttemptCount"]?.intValue == 4)
        #expect(run["stepCount"]?.intValue == 4)
        let gv = run["goalVerification"]!
        #expect(gv["status"]?.stringValue == "passed")
        #expect(gv["verifierId"]?.stringValue == GoalVerifier.verifierId)
        // The verifier read an observation taken after the finish proposal.
        let finishSnapshot = h.ai.contexts.last.map { ctx -> String in
            if case let .guiStep(p) = ctx.purpose { return p.snapshotId }; return ""
        }
        let verifiedObs = gv["observationId"]!.stringValue!
        #expect(Int(verifiedObs.dropFirst(4))! > Int(finishSnapshot!.dropFirst(5))!)
        #expect(try schemaClean(run, "gui_runs_get_result", domain: false))
        #expect(run["latestActionReceipt"]?["deliveryState"]?.stringValue == "confirmed")
        #expect(await h.audit.actions.count == 3)
        #expect(await h.audit.inferences.count == 4)

        let events = try await h.events(runId)
        let seq = events.compactMap { $0["sequence"]?.intValue }
        #expect(seq == Array(1...seq.count))
        #expect(events.last?["state"]?.stringValue == "succeeded")
        for e in events { #expect(try schemaClean(e, "RunEvent")) }
        #expect(!events.map { $0.encoded() }.joined().contains("Ada"), "typed text never appears in events")
        #expect(!run.encoded().contains("sk-canary-gui"))
    }

    @Test func verifiedRightAfterTheLastInputNeedsNoFinish() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "succeeded")
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
        #expect(try await h.run(runId)["state"]?.stringValue == "succeeded")
        #expect(h.ai.callCount == 0)
        #expect(await h.executor.executed.isEmpty)
    }

    // GUI-003: finish alone never succeeds; the bound text decides.
    @Test func gui003_finishWithoutTheTextDoesNotSucceed() async throws {
        let h = try GuiHarness(Array(repeating: finish, count: 3), limits: [("maxSteps", .int(3))])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "LIMIT_EXCEEDED")
        #expect(run["goalVerification"]?["status"]?.stringValue == "failed")
        #expect(await h.executor.executed.isEmpty)
        // Each finish was followed by a newer observation.
        #expect(await h.observation.count == 1 + 3)
    }

    @Test func gui003_backendWithoutStaticTextIsCapabilityMismatch() async throws {
        let h = try GuiHarness([finish])
        try await h.setUpProfile()
        await h.observation.set(elementsAvailable: false)
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "CAPABILITY_MISMATCH")
    }

    // GUI-005: a disabled action is refused before input.
    @Test func gui005_forbiddenActionNeverReachesTheExecutor() async throws {
        let h = try GuiHarness([typeText("Ada")])
        try await h.setUpProfile()
        let runId = try await h.start(h.startParams(actions: ["click"]))
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "FORBIDDEN")
        #expect(await h.executor.executed.isEmpty)
        #expect(h.form.name.isEmpty)
    }

    // GUI-006: the 21st step never starts; attempts per step and in total are capped.
    @Test func gui006_stepBudget() async throws {
        let h = try GuiHarness(Array(repeating: click(600, 600), count: 25))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "LIMIT_EXCEEDED")
        #expect(h.ai.callCount == 20)
        #expect(run["stepCount"]?.intValue == 20)
        #expect(await h.executor.executed.count == 20)
    }

    @Test func gui006_attemptBudgetPerStepAndTotal() async throws {
        let transient = StubAiService.Reply.error(ContractError(.upstreamUnavailable, "503"))
        let h = try GuiHarness(Array(repeating: transient, count: 10))
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "UPSTREAM_UNAVAILABLE")
        #expect(h.ai.callCount == 2, "one step: first try plus one retry, never more")
        #expect(await h.executor.executed.isEmpty)
    }

    @Test func gui006_totalAttemptsCapped() async throws {
        let h = try GuiHarness(Array(repeating: click(600, 600), count: 40),
                               limits: [("maxTotalModelAttempts", .int(5))])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["error"]?["code"]?.stringValue == "LIMIT_EXCEEDED")
        #expect(h.ai.callCount == 5)
        #expect(run["modelAttemptCount"]?.intValue == 5)
    }

    @Test func gui006_wallDeadlineStopsNewWork() async throws {
        let clock = ManualClock(autoAdvance: true)
        let h = try GuiHarness([.text("{\"kind\":\"wait\",\"waitMs\":1000}"), .text("{\"kind\":\"wait\",\"waitMs\":1000}"),
                                .text("{\"kind\":\"wait\",\"waitMs\":1000}")],
                               limits: [("maxWallTimeMs", .int(2000)), ("maxWaitMs", .int(1000))], fixture: true, clock: clock)
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "DEADLINE_EXCEEDED")
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
        let run = try await h.run(runId)
        #expect(await h.executor.executed.isEmpty, "wait is not input")
        if accepted {
            #expect(run["state"]?.stringValue == "waiting_user")
            #expect(run["stepCount"]?.intValue == 2, "a wait consumes a step")
            #expect(await h.observation.count == 2, "a new observation after the wait")
        } else {
            #expect(run["state"]?.stringValue == "failed")
            #expect(["LIMIT_EXCEEDED", "INVALID_ACTION"].contains(run["error"]?["code"]?.stringValue ?? ""))
        }
    }

    @Test func gui007_cancelDuringWait() async throws {
        let clock = ManualClock(autoAdvance: false)
        let h = try GuiHarness([.text("{\"kind\":\"wait\",\"waitMs\":5000}")], fixture: true, clock: clock)
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the wait") { clock.pendingSleeps == 1 }
        clock.advance(ms: 1000)
        let c = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-0001")
        #expect(c["accepted"]?.boolValue == true)
        await h.finished(runId)
        #expect(clock.pendingSleeps == 0, "the timer was withdrawn")
        #expect(try await h.run(runId)["state"]?.stringValue == "cancelled")
        #expect(await h.observation.count == 1, "no observation after the cancelled wait")
    }

    // GUI-008: needs_user and unknown both wait; there is no resume.
    @Test func gui008_needsUserWaits() async throws {
        let h = try GuiHarness([.text("Thought: login.\nAction: call_user(content='please log in')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "waiting_user")
        #expect(run["waitingReasonCode"]?.stringValue == "model_requested_user")
        #expect(try await h.err("gui.runs.resume", .obj([("runId", .string(runId))])) == "UNSUPPORTED_COMMAND")
    }

    // RET-004 / GUI-008: an unknown outcome is never sent again.
    @Test func ret004_unknownOutcomeIsNotRetried() async throws {
        let h = try GuiHarness([click(200, 300), click(200, 300), click(200, 300)])
        try await h.setUpProfile()
        await h.executor.set(mode: .unknown)
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "waiting_user")
        #expect(run["waitingReasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
        #expect(h.form.submissions == 1)
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
        #expect(run["latestActionReceipt"]?["deliveryState"]?.stringValue == "unknown")
    }

    // CAN-002: cancel while the model is thinking; the late answer is no input.
    @Test func can002_cancelDuringInference() async throws {
        let h = try GuiHarness([.hang("Thought: x\nAction: click(start_box='(200,300)')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the model call") { h.ai.isHanging }
        let c = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-0002")
        #expect(c["accepted"]?.boolValue == true)
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "cancelled")
        #expect(run["currentGeneration"]?.intValue == 2)
        #expect(run["binding"]?["runGeneration"]?.intValue == 1)
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
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-late1")
        h.ai.releaseLate()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["state"]?.stringValue == "cancelled")
        #expect(await h.executor.executed.isEmpty)
        #expect(h.form.submissions == 0)
        let summaries = try await h.events(runId).compactMap { $0["summary"]?.stringValue }
        #expect(summaries.contains { $0.contains("discarded") })
        #expect(await h.audit.inferences.isEmpty, "a discarded answer is not recorded as a usable inference")
    }

    // CAN-003: cancel during input waits for the executor's verdict.
    @Test func can003_cancelDuringInputWaitsForTheReceipt() async throws {
        let h = try GuiHarness([click(200, 300), click(200, 300)])
        try await h.setUpProfile()
        await h.executor.set(mode: .hang)
        let runId = try await h.start()
        await eventually("the input") { await h.executor.isHanging }
        let c = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-0003")
        #expect(c["state"]?.stringValue == "cancelling")
        #expect(c["terminal"]?.boolValue == false)
        await h.executor.release()
        await h.finished(runId)
        #expect(try await h.run(runId)["state"]?.stringValue == "cancelled")
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
    }

    // CAN-004: repeated cancels on finished runs change nothing.
    @Test func can004_repeatedCancelAfterTheEnd() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let before = try await h.events(runId).count
        for i in 0..<3 {
            let c = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-rep-\(i)000")
            #expect(c["accepted"]?.boolValue == false)
            #expect(c["state"]?.stringValue == "succeeded")
            #expect(c["terminal"]?.boolValue == true)
        }
        #expect(try await h.events(runId).count == before)
        #expect(h.ai.callCount == 3)
    }

    // Audit records come before model calls and input (§09.3).
    @Test func auditFailureStopsBeforeTheModel() async throws {
        let h = try GuiHarness([click(200, 300)])
        try await h.setUpProfile()
        await h.audit.set(failInference: true)
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["error"]?["code"]?.stringValue == "AUDIT_UNAVAILABLE")
        #expect(h.ai.callCount == 0)
    }

    @Test func auditFailureStopsBeforeInput() async throws {
        let h = try GuiHarness([click(200, 300)])
        try await h.setUpProfile()
        await h.audit.set(failAction: true)
        let runId = try await h.start()
        await h.finished(runId)
        #expect(try await h.run(runId)["error"]?["code"]?.stringValue == "AUDIT_UNAVAILABLE")
        #expect(await h.executor.executed.isEmpty)
    }

    // GUI-001/TRN-007: a malformed reply never becomes a proposal or input,
    // and its call stays on record.
    @Test func gui001_malformedReplyIsRefused() async throws {
        let h = try GuiHarness([.text("Action: click(start_box='(1,1)')\nAction: click(start_box='(2,2)')")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(run["error"]?["code"]?.stringValue == "INVALID_ACTION")
        #expect(await h.executor.executed.isEmpty)
        #expect(run["latestInferenceReceipt"]?["proposalId"]?.isNull == true)
        #expect(try schemaClean(run["latestInferenceReceipt"]!, "InferenceReceipt"))
    }

    @Test func noBackendKeepsRealInputOff() async throws {
        let h = try GuiHarness([], backend: false)
        try await h.setUpProfile()
        #expect(try await h.err("gui.runs.start", h.startParams(), key: "run-key-nob1") == "CAPABILITY_MISMATCH")
        let caps = try await h.ok("runtime.capabilities")
        #expect(try schemaClean(caps, "runtime_capabilities_result", domain: false))
        #expect(caps["verificationPredicates"]?.arrayValue?.isEmpty == true)
        #expect(caps["features"]?["nativeIsolationEvidence"]?.stringValue == "NOT_RUN")
        #expect(caps["guiAdapters"] == .array([.string("uitars_v1")]))
    }
}

@Suite("Run service")
struct RunServiceTests {
    // RPC-006: ten concurrent starts with one key make one run.
    @Test func rpc006_concurrentStartsMakeOneRun() async throws {
        let h = try GuiHarness([.hang("x")])
        try await h.setUpProfile()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await h.start(key: "same-key-0001") } }
            var out: [String] = []
            for try await id in group { out.append(id) }
            return out
        }
        #expect(Set(ids).count == 1)
        await eventually("the single model call") { h.ai.isHanging }
        #expect(h.ai.callCount == 1)
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(ids[0]))]), key: "cancel-r006")
        await h.finished(ids[0])
    }

    // RPC-007: different request, same key → conflict; other callers see nothing.
    @Test func rpc007_keyConflictsAndCallerIsolation() async throws {
        let h = try GuiHarness([.hang("x")])
        try await h.setUpProfile()
        let runId = try await h.start(key: "key-conflict-1")
        #expect(try await h.err("gui.runs.start", h.startParams(actions: ["click"]), key: "key-conflict-1") == "IDEMPOTENCY_CONFLICT")
        #expect(try await h.err("gui.runs.get", .obj([("runId", .string(runId))]), router: h.stranger) == "NOT_FOUND")
        #expect(try await h.err("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-strange", router: h.stranger) == "NOT_FOUND")
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-r007")
        await h.finished(runId)
    }

    // RPC-005 (service part): omitting sessionId is for the owner only.
    @Test func rpc005_sessionRules() async throws {
        let h = try GuiHarness([.hang("x"), .hang("y")])
        try await h.setUpProfile()
        #expect(try await h.err("gui.runs.start", h.startParams(), key: "stranger-key-1", router: h.stranger) == "FORBIDDEN")
        #expect(try await h.err("gui.runs.start", h.startParams(session: "sess-forged"), key: "forged-key-1") == "FORBIDDEN")
        let runId = try await h.start(h.startParams(session: "sess-a"), key: "explicit-key-1")
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-r005")
        await h.finished(runId)
    }

    // RPC-008: start, poll, events with cursors, expiry, unknown id.
    @Test func rpc008_eventsCursor() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let all = try await h.events(runId)
        let last = all.last!["sequence"]!.intValue!
        #expect(all.count == last)
        let after2 = try await h.events(runId, after: 2)
        #expect(after2.first?["sequence"]?.intValue == 3)
        #expect(try await h.events(runId, after: 2) == after2, "re-reading gives the same events")
        #expect(try await h.events(runId, after: last).isEmpty)
        let page = try await h.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0)), ("limit", .int(3))]))
        #expect(page["nextAfterSequence"]?.intValue == 3)
        #expect(page["hasMore"]?.boolValue == true)
        #expect(try schemaClean(page, "gui_runs_events_result", domain: false))
        #expect(try await h.run(runId)["lastSequence"]?.intValue == last)

        await h.repository.prune(runId: runId, keepFrom: 5)
        #expect(try await h.err("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(2))])) == "EVENTS_CURSOR_EXPIRED")
        #expect(try await h.events(runId, after: 4).first?["sequence"]?.intValue == 5)
        #expect(try await h.err("gui.runs.get", .obj([("runId", .string("run-unknown"))])) == "NOT_FOUND")
        #expect(try await h.err("gui.runs.events", .obj([("runId", .string("run-unknown")), ("afterSequence", .int(0))])) == "NOT_FOUND")
    }

    // D07 / CFG-004 (run part): the binding is fixed at start.
    @Test func bindingIsFixedAtStart() async throws {
        let h = try GuiHarness([.hang("x")])
        let gui = try await h.setUpProfile()
        let runId = try await h.start(key: "fixed-key-001")
        let before = try await h.run(runId)["binding"]!
        let other = try await h.setUpProfile(name: "Other")
        #expect(other["guiProfileId"] != gui["guiProfileId"])
        #expect(try await h.run(runId)["binding"]! == before)
        #expect(before["primary"]?["guiProfile"]?["guiProfileId"] == gui["guiProfileId"])
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-fixed")
        await h.finished(runId)
        let next = try await h.ok("gui.runs.start", h.startParams(), key: "fixed-key-002")
        #expect(next["binding"]?["primary"]?["guiProfile"]?["guiProfileId"] == other["guiProfileId"])
        #expect(try schemaClean(next, "gui_runs_start_result", domain: false))
        let nextId = next["runId"]!.stringValue!
        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(nextId))]), key: "cancel-fixed2")
        await h.finished(nextId)
    }

    @Test func disabledProfileCannotBind() async throws {
        let h = try GuiHarness([])
        let gui = try await h.setUpProfile()
        _ = try await h.ok("ai.profiles.disable", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!)]),
                           key: "disable-001")
        let p = h.startParams().setting("guiProfileId", gui["guiProfileId"]!).setting("expectedProfileRevision", .int(2))
        #expect(try await h.err("gui.runs.start", p, key: "disabled-key-1") == "RESOURCE_DISABLED")
        let stale = h.startParams().setting("guiProfileId", gui["guiProfileId"]!).setting("expectedProfileRevision", .int(1))
        #expect(try await h.err("gui.runs.start", stale, key: "stale-key-1") == "CONFIG_CONFLICT")
        #expect(h.ai.callCount == 0)
    }
}
