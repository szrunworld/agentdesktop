import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// Kevin's decision after MAC-001 (2026-10-08): an empty model reply is
// recovered from at most once per step by observing the bound target again
// and asking again on the new observation. No input is ever repeated; a
// second empty reply ends the unit Run failed, closingReason model_empty_response.

private let empty: StubAiService.Reply = .text(" \n ")

@Suite("Unusable model reply recovery")
struct EmptyReplyRecoveryTests {

    @Test func missingActionLineReobservesWithFixedCorrectionAndContinues() async throws {
        let h = try GuiHarness([.text("I should click the name field."), click(200, 100),
                                typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .verified)
        #expect(h.form.submissions == 1)
        #expect(await h.executor.executed.count == 3)
        #expect(h.ai.callCount == 4)
        #expect(run.modelAttempts == 4)
        #expect(run.steps == 3)
        #expect(await h.audit.inferences.count == 4)
        #expect(run.events.first { $0["type"]?.stringValue == "unit.recovery" }?["data"]?["kind"]?.stringValue
                == "reobserve_after_no_action_line")
        let snapshots = h.ai.contexts.prefix(2).map { ctx -> String in
            if case let .guiStep(p) = ctx.purpose { return p.snapshotId }; return ""
        }
        #expect(snapshots[0] != snapshots[1])
        let retryText = h.ai.requests[1].messages.last?.content.compactMap { part -> String? in
            if case let .text(text) = part { return text }; return nil
        }.joined(separator: "\n") ?? ""
        #expect(retryText.contains("previous reply had no Action: line"))
        #expect(!retryText.contains("I should click"), "raw model output is not fed back")
        #expect(unitEventsClean(run.events))
    }

    @Test func secondMissingActionLineFailsWithoutInput() async throws {
        let h = try GuiHarness([.text("click the name"), .text("still no call"), click(200, 100)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "invalid_action"))
        #expect(run.events.first { $0["type"]?.stringValue == "unit.step.rejected" }?["data"]?["reason"]?.stringValue
                == "no_action_line")
        #expect(h.ai.callCount == 2)
        #expect(await h.executor.executed.isEmpty)
        #expect(unitEventsClean(run.events))
    }

    @Test func missingActionLineDoesNotRetryAfterTheStepBudgetIsSpent() async throws {
        let h = try GuiHarness([.error(ContractError(.upstreamUnavailable, "503", retryable: true)),
                                .text("click the name"), click(200, 100)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "invalid_action"))
        #expect(h.ai.callCount == 2)
        #expect(await h.executor.executed.isEmpty)
    }

    @Test func missingActionLineReobservationRejectsChangedTarget() async throws {
        let h = try GuiHarness([.late("click the name"), click(200, 100)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the model call is out") { h.ai.isLate }
        await h.observation.set(session: "another-session")
        h.ai.releaseLate()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "stale_observation"))
        #expect(h.ai.callCount == 1)
        #expect(await h.executor.executed.isEmpty)
    }

    @Test func oneEmptyReplyObservesAgainAndContinues() async throws {
        let h = try GuiHarness([click(200, 100), empty, typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .verified, "\(String(describing: run.ending))")
        let executed = await h.executor.executed
        #expect(executed.count == 3, "click, type, click: the click before the empty reply is not repeated")
        #expect(h.form.submissions == 1)
        #expect(h.ai.callCount == 4)
        #expect(run.modelAttempts == 4, "both calls of the recovered step are counted")
        #expect(run.steps == 3, "the recovery stays in its step")
        #expect(run.count("unit.recovery") == 1)
        #expect(await h.audit.inferences.count == 4, "the empty reply's attempt is on record")
        // start, after click, recovery, after type, after Apply
        #expect(await h.observation.count == 5)
        // The second call of step 1 was asked on the newer observation.
        let snapshots = h.ai.contexts.map { ctx -> String in
            if case let .guiStep(p) = ctx.purpose { return p.snapshotId }; return ""
        }
        #expect(snapshots[1] != snapshots[2])
        #expect(Set(h.ai.contexts.map(\.inferenceAttemptId)).count == 4)
        #expect(unitEventsClean(run.events))
    }

    @Test func secondEmptyReplyInTheSameStepEndsTheRun() async throws {
        let h = try GuiHarness([click(200, 100), empty, empty, typeText("Ada")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .failed(reason: "model_empty_response"))
        #expect(run.events.first { $0["type"]?.stringValue == "unit.step.rejected" }?["data"]?["reason"]?.stringValue == "model_empty_response")
        #expect(await h.executor.executed.count == 1, "nothing after the first click; nothing repeated")
        #expect(h.ai.callCount == 3)
        #expect(unitEventsClean(run.events))
    }

    @Test func eachStepMayRecoverOnce() async throws {
        let h = try GuiHarness([empty, click(200, 100), empty, typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        let run = h.run(runId)
        #expect(run.ending == .verified, "\(String(describing: run.ending))")
        #expect(await h.executor.executed.count == 3)
        #expect(run.steps == 3)
        #expect(run.modelAttempts == 5)
    }

    // A target that is no longer the bound one ends the run on the new
    // observation, before any second model call.
    @Test func invalidTargetOnReobservationEndsWithoutAModelCall() async throws {
        let h = try GuiHarness([.late(" "), typeText("Ada")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await eventually("the model call is out") { h.ai.isLate }
        await h.observation.set(session: "another-session")
        h.ai.releaseLate()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "stale_observation"))
        #expect(h.ai.callCount == 1)
        #expect(await h.executor.executed.isEmpty)
    }

    // The recovery call is inside the step's attempt limit, never beyond it.
    @Test func noRecoveryWhenTheStepHasNoAttemptLeft() async throws {
        let h = try GuiHarness([.error(ContractError(.upstreamUnavailable, "503", retryable: true)), empty, typeText("Ada")])
        try await h.setUpProfile()
        let runId = try await h.start()
        await h.finished(runId)
        #expect(h.run(runId).ending == .failed(reason: "model_empty_response"))
        #expect(h.ai.callCount == 2)
        #expect(await h.executor.executed.isEmpty)
    }
}
