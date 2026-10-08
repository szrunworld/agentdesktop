import AgentDesktopAI
import AgentDesktopContracts
import Foundation

/// Keeps a run's public record in step with its lifecycle: every lifecycle
/// event becomes a RunEvent, and the GuiRun snapshot is saved after each
/// change. Events carry controlled fields only: no screenshot bytes, no
/// typed text, no secrets.
public actor RunRecorder {
    public let binding: GuiRunBinding
    let lifecycle: RunLifecycle
    let repository: GuiRunRepository
    let budget: AttemptBudget
    let clock: MonotonicClock
    let createdAt: Date

    private var syncedLifecycleEvents = 0
    private var lastSequence = 0
    private var stepCount = 0
    private var latestObservationId: String?
    private var latestInference: JSONValue = .null
    private var latestAction: JSONValue = .null
    private var verification = GoalVerification.notRun
    /// Set when an event or the snapshot could not be written. The run's
    /// public record is then incomplete, so no further model call or input
    /// may start (the explorer checks this before each one).
    public private(set) var writeFailed = false

    public init(binding: GuiRunBinding, lifecycle: RunLifecycle, repository: GuiRunRepository,
                budget: AttemptBudget, clock: MonotonicClock, createdAt: Date) {
        self.binding = binding
        self.lifecycle = lifecycle
        self.repository = repository
        self.budget = budget
        self.clock = clock
        self.createdAt = createdAt
    }

    public enum EventType: String, Sendable {
        case observationReady = "observation_ready", inferenceStarted = "inference_started"
        case inferenceFinished = "inference_finished", proposalValidated = "proposal_validated"
        case actionReceipt = "action_receipt", verificationFinished = "verification_finished"
    }

    func stepStarted() { stepCount += 1 }

    func observation(_ o: Observation) async {
        latestObservationId = o.observationId
        await append(.observationReady, "observation \(o.observationId)", extra: [("observationId", .string(o.observationId))])
    }

    func inference(_ r: GuiInferenceReceipt, discarded: Bool = false) async {
        latestInference = r.json
        let summary = "step \(r.stepIndex) \(r.record.state.rawValue)\(discarded ? " (discarded)" : "")"
        await append(.inferenceFinished, summary, extra: [("inferenceReceipt", r.json)])
    }

    func action(_ r: GuiActionReceipt) async {
        latestAction = r.json
        await append(.actionReceipt, "\(r.actionType.rawValue) \(r.deliveryState.rawValue)", extra: [("actionReceipt", r.json)])
    }

    func verified(_ v: GoalVerification) async {
        verification = v
        var extra: [(String, JSONValue)] = []
        if let id = v.observationId { extra.append(("observationId", .string(id))) }
        await append(.verificationFinished, "verification \(v.status.rawValue)", extra: extra)
    }

    func note(_ type: EventType, _ summary: String) async {
        await append(type, summary, extra: [])
    }

    private func append(_ type: EventType, _ summary: String, extra: [(String, JSONValue)]) async {
        let generation = await lifecycle.currentGeneration
        await write(type: type.rawValue, summary: summary, generation: generation, state: nil, extra: extra)
        await save()
    }

    /// Mirror new lifecycle events and save the snapshot.
    public func sync() async {
        let events = await lifecycle.events
        for e in events.dropFirst(syncedLifecycleEvents) {
            await write(type: e.kind.rawValue, summary: e.summary, generation: e.generation, state: e.state, extra: [])
        }
        syncedLifecycleEvents = events.count
        await save()
    }

    private func write(type: String, summary: String, generation: UInt64, state: RunLifecycle.State?,
                       extra: [(String, JSONValue)]) async {
        let runId = binding.runId
        let epoch = binding.bindingEpoch
        let at = GuiTime.iso(clock.wallNow())
        let text = String((summary.isEmpty ? type : summary).prefix(512))
        let built: @Sendable (Int) -> JSONValue = { seq in
            var m: [(String, JSONValue)] = [
                ("sequence", .int(seq)), ("runId", .string(runId)), ("occurredAt", .string(at)),
                ("type", .string(type)), ("bindingEpoch", .int(Int(epoch))), ("runGeneration", .int(Int(generation))),
                ("summary", .string(text)),
            ]
            if let state { m.append(("state", .string(state.rawValue))) }
            return .obj(m + extra)
        }
        do {
            lastSequence = try await repository.appendEvent(runId: runId, built)
        } catch {
            writeFailed = true
        }
    }

    private func save() async {
        do {
            try await repository.saveSnapshot(runId: binding.runId, snapshot: await snapshot())
        } catch {
            writeFailed = true
        }
    }

    public func snapshot() async -> JSONValue {
        let state = await lifecycle.state
        let error: JSONValue = await lifecycle.failure.map {
            ContractError($0.code, $0.message.isEmpty ? $0.code.rawValue : String($0.message.prefix(512)), retryable: $0.retryable).json
        } ?? .null
        return .obj([
            ("runId", .string(binding.runId)), ("state", .string(state.rawValue)),
            ("currentGeneration", .int(Int(await lifecycle.currentGeneration))), ("binding", binding.json),
            ("createdAt", .string(GuiTime.iso(createdAt))), ("updatedAt", .string(GuiTime.iso(clock.wallNow()))),
            ("stepCount", .int(stepCount)), ("modelAttemptCount", .int(await budget.totalAttempts)),
            ("lastSequence", .int(lastSequence)),
            ("latestObservationId", latestObservationId.map(JSONValue.string) ?? .null),
            ("latestInferenceReceipt", latestInference), ("latestActionReceipt", latestAction),
            ("waitingReasonCode", await lifecycle.waitingReasonCode.map(JSONValue.string) ?? .null),
            ("goalVerification", verification.json), ("error", error),
        ])
    }
}
