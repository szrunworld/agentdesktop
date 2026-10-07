import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopGUI

// State machine parts of CAN-001..004, RET-004, GUI-008 and EXE-003
// (spec §07). The executor, provider and timers that feed it arrive with
// T01/T05/T07; these tests drive the lifecycle directly.

typealias S = RunLifecycle.State

func lifecycle(to state: S) async throws -> RunLifecycle {
    let r = RunLifecycle(runId: "run-1")
    let path: [S] = [.observing, .inferencing, .validating, .executing, .verifying]
    if state == .queued { return r }
    for s in path {
        try await r.transition(to: s, generation: 1, summary: s.rawValue)
        if s == state { return r }
    }
    Issue.record("no path to \(state)")
    return r
}

@Suite("Run lifecycle")
struct RunLifecycleTests {
    @Test func stateNamesMatchTheContract() throws {
        let schema = try ContractBundle.shared.registry.schema(documentId: ContractBundle.domainSchemaId, pointer: "/$defs/GuiRunState")
        #expect(Set(schema["enum"]?.arrayValue?.compactMap(\.stringValue) ?? []) == Set(S.allCases.map(\.rawValue)))
    }

    @Test func onlyTheEdgesOfTheSpecAreAllowed() async throws {
        let allowed: [S: Set<S>] = [
            .queued: [.observing, .failed],
            .observing: [.inferencing, .verifying, .failed],
            .inferencing: [.validating, .waitingUser, .failed],
            .validating: [.executing, .observing, .verifying, .waitingUser, .failed],
            .executing: [.observing, .verifying, .waitingUser, .failed],
            .verifying: [.succeeded, .observing, .waitingUser, .failed],
        ]
        for (from, targets) in allowed {
            for to in S.allCases {
                let r = try await lifecycle(to: from)
                let ok = (try? await r.transition(to: to, generation: 1, summary: "t")) != nil
                #expect(ok == targets.contains(to), "\(from.rawValue) → \(to.rawValue)")
            }
        }
    }

    // CAN-001: cancel before any provider call voids the generation at once.
    @Test func cancelBeforeWorkVoidsTheGeneration() async throws {
        for start in [S.queued, .observing] {
            let r = try await lifecycle(to: start)
            let receipt = await r.requestCancel()
            #expect(receipt.accepted)
            #expect(receipt.state == .cancelled)
            #expect(await r.currentGeneration == 2)
            #expect(await r.initialGeneration == 1)
            #expect(await r.mayProceed(generation: 1) == false)
            await #expect(throws: ContractError.self) { try await r.transition(to: .inferencing, generation: 1, summary: "late") }
            let kinds = await r.events.map(\.kind)
            #expect(kinds.contains(.cancelRequested))
            #expect(await r.events.last?.state == .cancelled)
        }
    }

    // CAN-002 (state part): a late inference result cannot become input.
    @Test func lateProposalAfterCancelCannotStartAnAction() async throws {
        let r = try await lifecycle(to: .inferencing)
        _ = await r.requestCancel()
        await #expect(throws: ContractError.self) { try await r.transition(to: .validating, generation: 1, summary: "late") }
        await #expect(throws: ContractError.self) { try await r.actionStarted("a-1", generation: 1) }
        #expect(await r.inFlightActionId == nil)
    }

    // CAN-003: cancel during input waits for the executor's verdict.
    @Test func cancelDuringConfirmedInputEndsCancelled() async throws {
        let r = try await lifecycle(to: .executing)
        try await r.actionStarted("a-1", generation: 1)
        let receipt = await r.requestCancel()
        #expect(receipt.state == .cancelling)
        #expect(!receipt.terminal)
        try await r.actionResolved("a-1", delivery: .confirmed)
        #expect(await r.state == .cancelled)
    }

    @Test func cancelDuringUnknownInputHoldsTheDomain() async throws {
        let r = try await lifecycle(to: .executing)
        try await r.actionStarted("a-1", generation: 1)
        _ = await r.requestCancel()
        try await r.actionResolved("a-1", delivery: .unknown)
        #expect(await r.state == .cancelling)
        #expect(await r.waitingReasonCode == "ACTION_OUTCOME_UNKNOWN")
        #expect(await r.quarantinedActionId == "a-1")
        // A repeated cancel neither ends it nor bumps the generation.
        #expect(await r.requestCancel() == RunLifecycle.CancelReceipt(accepted: true, state: .cancelling))
        #expect(await r.currentGeneration == 2)
        try await r.reconciled(actionId: "a-1")
        #expect(await r.state == .cancelled)
        #expect(await r.quarantinedActionId == nil)
    }

    // RET-004 / EXE-003 / GUI-008: unknown without cancel waits for a
    // person; nothing resends it and the run cannot resume.
    @Test func unknownOutcomeWaitsAndNeverResumes() async throws {
        let r = try await lifecycle(to: .executing)
        try await r.actionStarted("a-1", generation: 1)
        try await r.actionResolved("a-1", delivery: .unknown)
        #expect(await r.state == .waitingUser)
        #expect(await r.waitingReasonCode == "ACTION_OUTCOME_UNKNOWN")
        #expect(await r.mayProceed(generation: 1) == false)
        for next in S.allCases {
            await #expect(throws: ContractError.self) { try await r.transition(to: next, generation: 1, summary: "resume") }
        }
        await #expect(throws: ContractError.self) { try await r.actionStarted("a-2", generation: 1) }
        try await r.reconciled(actionId: "a-1")
        #expect(await r.state == .failed)
        #expect(await r.failure?.code == .actionOutcomeUnknown)
    }

    @Test func submittedWithoutConfirmationIsTreatedAsUnknown() async throws {
        let r = try await lifecycle(to: .executing)
        try await r.actionStarted("a-1", generation: 1)
        try await r.actionResolved("a-1", delivery: .submitted)
        #expect(await r.state == .waitingUser)
        #expect(await r.quarantinedActionId == "a-1")
    }

    @Test func needsUserThenCancel() async throws {
        let r = try await lifecycle(to: .inferencing)
        try await r.waitForUser(reasonCode: "login_required", generation: 1)
        #expect(await r.state == .waitingUser)
        #expect(await r.requestCancel().state == .cancelled)
    }

    // CAN-004: terminal states never change; repeated cancels are harmless.
    @Test func repeatedCancelOnEveryOutcome() async throws {
        let succeeded = try await lifecycle(to: .verifying)
        try await succeeded.transition(to: .succeeded, generation: 1, summary: "verified")
        let failed = try await lifecycle(to: .observing)
        try await failed.fail(ContractError(.limitExceeded, "steps"), generation: 1)
        let cancelled = try await lifecycle(to: .queued)
        _ = await cancelled.requestCancel()

        for (r, end, accepted) in [(succeeded, S.succeeded, false), (failed, .failed, false), (cancelled, .cancelled, true)] {
            let before = await r.events.count
            let generation = await r.currentGeneration
            for _ in 0..<3 {
                let receipt = await r.requestCancel()
                #expect(receipt.state == end)
                #expect(receipt.accepted == accepted)
                #expect(receipt.terminal)
            }
            #expect(await r.events.count == before)
            #expect(await r.currentGeneration == generation)
        }
    }

    @Test func cannotFinishWithAnUnresolvedInput() async throws {
        let r = try await lifecycle(to: .executing)
        try await r.actionStarted("a-1", generation: 1)
        await #expect(throws: ContractError.self) { try await r.fail(ContractError(.limitExceeded, "x"), generation: 1) }
        await #expect(throws: ContractError.self) { try await r.actionStarted("a-2", generation: 1) }
    }

    @Test func eventSequencesAreStrictlyIncreasing() async throws {
        let r = try await lifecycle(to: .verifying)
        try await r.transition(to: .succeeded, generation: 1, summary: "ok")
        let seq = await r.events.map(\.sequence)
        #expect(seq == Array(1...seq.count))
    }
}
