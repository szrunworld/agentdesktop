import AgentDesktopAI
import AgentDesktopProtocol
import Foundation

/// What the Runtime hands the explorer: observation, the one execution
/// path for real input, and the durable audit records.
public struct GuiExplorerPorts: Sendable {
    public let observation: GuiObservationPort
    public let execution: GuiExecutionPort
    public let audit: GuiAuditPort

    public init(observation: GuiObservationPort, execution: GuiExecutionPort, audit: GuiAuditPort) {
        self.observation = observation
        self.execution = execution
        self.audit = audit
    }
}

/// A stop the Runtime accepted, visible at once (codex on 8bcb18c): the
/// lifecycle actor learns of it a moment later, but no model call or input
/// may start in between. An input already handed to the Runtime is let
/// finish; the stop then waits for its receipt.
public final class UnitStopSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var inputOut = false

    public init() {}

    public var isStopped: Bool { lock.withLock { stopped } }

    /// Accept the stop. True when an input is out right now (the caller
    /// must not cancel the task under it).
    @discardableResult
    public func stop() -> Bool { lock.withLock { stopped = true; return inputOut } }

    /// Before handing an input to the Runtime: false once stopped.
    func beginInput() -> Bool {
        lock.withLock {
            guard !stopped else { return false }
            inputOut = true
            return true
        }
    }

    func endInput() { lock.withLock { inputOut = false } }
}

/// The bounded local loop of one run (spec §06.3, §07, §09.1):
///
///     observe → already done? → [suggest → validate → act | wait | finish | needs_user → observe → verify]*
///
/// - Every round first checks cancellation, the generation, the deadline
///   and the budgets; none of them is renewed by a retry.
/// - Steps ≤ maxSteps (wait, finish and needs_user count as steps), model
///   attempts ≤ 2 per step and ≤ 30 per run, one wall-clock deadline.
/// - A model's `finish` only asks for a new observation and the verifier;
///   success needs the bound predicate to hold on that newer observation.
/// - An input whose outcome is unknown stops the run in waiting_user (or
///   keeps a cancel pending) and is never sent again.
/// - A result that arrives after the generation moved on is recorded as
///   discarded and never becomes input.
public final class GuiRunDriver: Sendable {
    public let binding: GuiRunBinding
    public let lifecycle: RunLifecycle
    public let recorder: any GuiRunRecording
    let ports: GuiExplorerPorts
    let provider: GuiAiProvider
    let verifier: GoalVerifier
    let clock: MonotonicClock
    let budget: AttemptBudget
    let callerScope: String
    let deadlineNs: UInt64
    let stopSignal: UnitStopSignal?

    public init(binding: GuiRunBinding, lifecycle: RunLifecycle, recorder: any GuiRunRecording, ports: GuiExplorerPorts,
                provider: GuiAiProvider, budget: AttemptBudget, clock: MonotonicClock, callerScope: String,
                startedAtNs: UInt64, verifier: GoalVerifier = GoalVerifier(), stopSignal: UnitStopSignal? = nil) {
        self.stopSignal = stopSignal
        self.binding = binding
        self.lifecycle = lifecycle
        self.recorder = recorder
        self.ports = ports
        self.provider = provider
        self.verifier = verifier
        self.clock = clock
        self.budget = budget
        self.callerScope = callerScope
        self.deadlineNs = startedAtNs &+ UInt64(binding.limits.maxWallTimeMs) * 1_000_000
    }

    var generation: UInt64 { binding.runGeneration }
    var limits: GuiLimits { binding.limits }

    /// Run to an end state (or to waiting_user / a pending cancel). Never throws.
    public func run() async {
        do {
            try await loop()
        } catch let e as ContractError {
            await stop(e)
        } catch is CancellationError {
            // Cancellation already moved the lifecycle; nothing to add.
        } catch {
            await stop(ContractError(.internalError, "internal error"))
        }
        await recorder.sync()
    }

    private func stop(_ error: ContractError) async {
        let state = await lifecycle.state
        guard !state.isTerminal, state != .waitingUser, state != .cancelling,
              await !lifecycle.cancelRequested else { return }
        try? await lifecycle.fail(error, generation: generation)
    }

    private func move(_ next: RunLifecycle.State, _ summary: String) async throws {
        try await lifecycle.transition(to: next, generation: generation, summary: summary)
        await recorder.sync()
    }

    /// Throws when no new model call, input or timer may start.
    private func checkProceed() async throws {
        guard stopSignal?.isStopped != true else { throw CancellationError() }
        guard await lifecycle.mayProceed(generation: generation) else { throw CancellationError() }
        guard await !recorder.writeFailed else {
            throw ContractError(.auditUnavailable, "the run's record could not be written")
        }
        guard clock.nowNanoseconds() < deadlineNs else {
            throw ContractError(.deadlineExceeded, "the run's \(limits.maxWallTimeMs) ms ran out")
        }
    }

    private func observe() async throws -> ObservationBundle {
        try await checkProceed()
        let bundle = try await ports.observation.observe(runId: binding.runId, expectedGeneration: generation)
        let stamp = bundle.observation.stamp
        guard stamp.desktopId == binding.desktopId, stamp.sessionId == binding.sessionId,
              stamp.bindingEpoch == binding.bindingEpoch else {
            throw ContractError(.staleObservation, "the observation is not of the run's bound target")
        }
        guard stamp.runGeneration == (await lifecycle.currentGeneration) else {
            throw ContractError(.staleGeneration, "the observation belongs to another generation")
        }
        await recorder.observation(bundle.observation)
        return bundle
    }

    /// In `observing` with a fresh bundle: verify it. True when the run
    /// succeeded; otherwise the run is back in `observing`.
    private func verifyFresh(_ bundle: ObservationBundle) async throws -> Bool {
        try await move(.verifying, "verifying")
        return try await settle(bundle)
    }

    /// In `verifying`: judge `bundle` and finish or go back to observing.
    private func settle(_ bundle: ObservationBundle) async throws -> Bool {
        let v = try verifier.evaluate(bundle, binding: binding, checkedAt: clock.wallNow())
        await recorder.verified(v)
        if v.status == .passed {
            try await move(.succeeded, "goal verified on observation \(bundle.observation.observationId)")
            return true
        }
        try await move(.observing, "goal not reached yet")
        return false
    }

    private func audited<T>(_ body: () async throws -> T) async throws -> T {
        do { return try await body() } catch {
            throw ContractError(.auditUnavailable, "the run's audit record could not be written")
        }
    }

    private func loop() async throws {
        try await move(.observing, "started")
        var bundle = try await observe()
        // Already satisfied: succeed without any model call (spec §06.3).
        if try await verifyFresh(bundle) { return }

        var history: [GuiHistoryTurn] = []
        var stepIndex = 0
        // The step whose empty reply was already recovered from once.
        var recoveredStep: Int?
        while true {
            try await checkProceed()
            guard stepIndex < limits.maxSteps else {
                throw ContractError(.limitExceeded, "the run used all \(limits.maxSteps) steps")
            }
            try await move(.inferencing, "step \(stepIndex)")
            if recoveredStep != stepIndex { await recorder.stepStarted(stepIndex: stepIndex) }
            let snapshotId = bundle.observation.stamp.snapshotId
            try await audited { try await ports.audit.reserveInference(runId: binding.runId, stepIndex: stepIndex, snapshotId: snapshotId) }
            await recorder.inferenceStarted(stepIndex: stepIndex)

            let input = GuiInferenceInput(binding: binding, bundle: bundle, history: history, stepIndex: stepIndex,
                                          budget: budget, deadlineNs: deadlineNs, callerScope: callerScope)
            // The last gate before a model call: a stop or a record that
            // could not be written since the step began ends it here.
            try await checkProceed()
            let output: GuiInferenceOutput
            do {
                output = try await provider.suggest(input)
            } catch let failure as GuiSuggestionFailure {
                await recorder.inference(failure.receipt, discarded: false)
                try await audited { try await ports.audit.recordInference(failure.receipt) }
                // An empty reply: once per step, observe the bound target
                // again and ask again on that new observation. Nothing the
                // run already sent is repeated; the second call is its own
                // attempt within the step's attempt limit. A target that is
                // no longer valid ends the run in observe() before any call.
                guard failure.isEmptyReply, recoveredStep != stepIndex,
                      await budget.attempts(step: stepIndex) < budget.maxAttemptsPerStep else {
                    throw failure.error
                }
                recoveredStep = stepIndex
                await recorder.recovered(stepIndex: stepIndex)
                try await move(.validating, "empty model reply")
                try await move(.observing, "observing again after an empty reply")
                bundle = try await observe()
                if try await verifyFresh(bundle) { return }
                continue
            }
            guard await lifecycle.mayProceed(generation: generation) else {
                await recorder.inference(output.receipt, discarded: true)
                throw CancellationError()
            }
            try await audited { try await ports.audit.recordInference(output.receipt) }
            await recorder.inference(output.receipt, discarded: false)
            history.append(GuiHistoryTurn(image: bundle.currentImage, reply: output.reply))
            stepIndex += 1

            try await move(.validating, "checking proposal")
            let proposal = output.proposal
            do {
                try validate(proposal, against: bundle)
            } catch let e as ContractError {
                await recorder.rejected(stepIndex: proposal.stepIndex, reason: e.code.rawValue.lowercased())
                throw e
            }
            await recorder.proposed(proposal)

            switch proposal.body {
            case .action:
                try await checkProceed()
                try await move(.executing, "executing")
                let actionId = try await audited { try await ports.audit.reserveAction(proposal, target: bundle.observation.target) }
                try await lifecycle.actionStarted(actionId, generation: generation)
                guard stopSignal?.beginInput() ?? true else {
                    try await lifecycle.actionResolved(actionId, delivery: .notSent)
                    throw CancellationError()
                }
                let receipt: GuiActionReceipt
                do {
                    defer { stopSignal?.endInput() }
                    receipt = try await ports.execution.execute(proposal, actionId: actionId)
                } catch {
                    // The executor could not say what happened: treat as unknown.
                    try await lifecycle.actionResolved(actionId, delivery: .unknown)
                    await recorder.sync()
                    return
                }
                let delivery: RunLifecycle.Delivery
                if receipt.actionId != actionId || receipt.proposalId != proposal.proposalId {
                    delivery = .unknown
                } else {
                    delivery = RunLifecycle.Delivery(rawValue: receipt.deliveryState.rawValue) ?? .unknown
                }
                try await lifecycle.actionResolved(actionId, delivery: delivery)
                await recorder.action(receipt, stepIndex: proposal.stepIndex)
                await recorder.sync()
                do { try await ports.audit.recordAction(receipt) } catch {
                    if delivery == .confirmed || delivery == .notSent || delivery == .rejected {
                        throw ContractError(.auditUnavailable, "the action receipt could not be written")
                    }
                }
                switch delivery {
                case .unknown, .submitted:
                    return
                case .confirmed, .notSent, .rejected:
                    let state = await lifecycle.state
                    if state.isTerminal || state == .cancelling { return }
                    try await move(.observing, "re-observing after input")
                    bundle = try await observe()
                    if try await verifyFresh(bundle) { return }
                }
            case let .wait(ms):
                guard ms >= 0, ms <= limits.maxWaitMs else {
                    throw ContractError(.limitExceeded, "wait is longer than \(limits.maxWaitMs) ms")
                }
                try await checkProceed()
                let until = min(clock.nowNanoseconds() &+ UInt64(ms) * 1_000_000, deadlineNs)
                try await clock.sleep(untilNanoseconds: until)
                try await move(.observing, "waited \(ms) ms")
                bundle = try await observe()
                if try await verifyFresh(bundle) { return }
            case .finish:
                try await move(.verifying, "model reports done; verifying")
                let previous = bundle.observation.observationId
                bundle = try await observe()
                guard bundle.observation.observationId != previous else {
                    throw ContractError(.staleObservation, "verification needs an observation newer than the proposal's")
                }
                if try await settle(bundle) { return }
            case let .needsUser(code, _):
                try await lifecycle.waitForUser(reasonCode: code, generation: generation)
                await recorder.sync()
                return
            }
        }
    }

    /// The Runtime rechecks everything again before input; this is the
    /// explorer's own gate so a stale or forbidden proposal never even
    /// reaches the executor.
    func validate(_ p: GuiProposal, against bundle: ObservationBundle) throws {
        guard p.runId == binding.runId else { throw ContractError(.forbidden, "the proposal belongs to another run") }
        guard p.stamp == bundle.observation.stamp else {
            throw ContractError(.staleObservation, "the proposal is not for the current observation")
        }
        guard bundle.observation.screenshot(p.screenshotId) != nil else {
            throw ContractError(.staleObservation, "the proposal's screenshot is not part of the observation")
        }
        if case let .action(a) = p.body, !binding.allowedActions.contains(a.kind) {
            throw ContractError(.forbidden, "\(a.kind.rawValue) is not allowed for this run")
        }
    }
}
