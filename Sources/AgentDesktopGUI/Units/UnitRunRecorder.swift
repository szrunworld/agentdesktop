import AgentDesktopAI
import AgentDesktopProtocol
import Foundation

/// The explorer's record of a unit Run (A6): `unit.*` events on the
/// Runtime's Run (runtime.schema.json UnitRunEvent). Ids, enums, codes and
/// numbers only: no screenshot, typed text, window title, goal, model reply
/// or secret. The Runtime keeps the Run's lifecycle; nothing here mirrors it.
public actor UnitRunRecorder: GuiRunRecording {
    let sink: UnitRunSink
    let budget: AttemptBudget
    let clock: MonotonicClock
    let maxSteps: Int
    let deadlineNs: UInt64
    public private(set) var writeFailed = false
    /// Model calls of each step already reported.
    private var reportedAttempts: [Int: Int] = [:]

    public init(sink: UnitRunSink, budget: AttemptBudget, clock: MonotonicClock, maxSteps: Int, deadlineNs: UInt64) {
        self.sink = sink
        self.budget = budget
        self.clock = clock
        self.maxSteps = maxSteps
        self.deadlineNs = deadlineNs
    }

    private func record(_ type: String, _ data: [(String, JSONValue)]) {
        guard !writeFailed else { return }
        if !sink.record(type, .obj(data)) { writeFailed = true }
    }

    public func sync() async {}

    public func stepStarted(stepIndex: Int) async {
        let now = clock.nowNanoseconds()
        let seconds = now < deadlineNs ? Int((deadlineNs - now) / 1_000_000_000) : 0
        let attemptsLeft = max(0, budget.maxTotalAttempts - (await budget.totalAttempts))
        record("unit.progress", [("stepIndex", .int(stepIndex)), ("stepsLeft", .int(max(0, maxSteps - stepIndex))),
                                 ("attemptsLeft", .int(attemptsLeft)), ("secondsLeft", .int(seconds))])
    }

    public func observation(_ o: Observation) async {
        record("unit.observation", [("observationId", .string(o.observationId))])
    }

    public func inferenceStarted(stepIndex: Int) async {}

    /// Model calls of a step that ended in an error with no receipt: the
    /// budget knows how many went out; there is no attempt id to name.
    public func inferenceFailed(stepIndex: Int, error: Error) async {
        let total = await budget.attempts(step: stepIndex)
        let attempts = total - reportedAttempts[stepIndex, default: 0]
        guard attempts > 0 else { return }
        reportedAttempts[stepIndex] = total
        let code = (error as? ContractError).map { Self.code($0.code.rawValue) } ?? "internal_error"
        record("unit.inference.attempt", [("stepIndex", .int(stepIndex)), ("attempts", .int(attempts)), ("state", .string("failed")),
                                          ("discarded", .bool(false)), ("errorCode", .string(code))])
    }

    public func inference(_ r: GuiInferenceReceipt, discarded: Bool) async {
        // A step's inference may make more than one call (a transient
        // failure moves to the fallback); the budget counts them all.
        let total = await budget.attempts(step: r.stepIndex)
        let attempts = max(1, total - reportedAttempts[r.stepIndex, default: 0])
        reportedAttempts[r.stepIndex] = max(total, reportedAttempts[r.stepIndex, default: 0] + 1)
        record("unit.inference.attempt", [
            ("stepIndex", .int(r.stepIndex)), ("inferenceAttemptId", .string(r.inferenceAttemptId)), ("attempts", .int(attempts)),
            ("state", .string(r.record.state.rawValue)), ("discarded", .bool(discarded)),
            ("errorCode", r.record.error.map { .string(Self.code($0.code.rawValue)) } ?? .null),
        ])
    }

    public func proposed(_ p: GuiProposal) async {
        var data: [(String, JSONValue)] = [("stepIndex", .int(p.stepIndex)), ("proposalId", .string(p.proposalId)),
                                           ("inferenceAttemptId", .string(p.inferenceAttemptId))]
        switch p.body {
        case let .action(a):
            data += [("kind", .string("action")), ("actionKind", .string(a.kind.rawValue))]
        case .wait: data.append(("kind", .string("wait")))
        case .finish: data.append(("kind", .string("finish")))
        case .needsUser: data.append(("kind", .string("needs_user")))
        }
        record("unit.step.proposed", data)
    }

    public func rejected(stepIndex: Int, reason: String) async {
        record("unit.step.rejected", [("stepIndex", .int(stepIndex)), ("reason", .string(Self.code(reason)))])
    }

    public func recovered(stepIndex: Int) async {
        record("unit.recovery", [("stepIndex", .int(stepIndex)), ("kind", .string("reobserve_after_empty_reply")),
                                 ("count", .int(1))])
    }

    public func action(_ r: GuiActionReceipt, stepIndex: Int) async {
        record("unit.action", [("stepIndex", .int(stepIndex)), ("actionId", .string(r.actionId)),
                               ("proposalId", .string(r.proposalId)), ("requestId", .string(UnitRun.actRequestId(for: r.actionId))),
                               ("deliveryState", .string(r.deliveryState.rawValue))])
    }

    public func verified(_ v: GoalVerification) async {
        guard v.status != .notRun, let observationId = v.observationId, let checkedAt = v.checkedAt else { return }
        let status: String
        switch v.status {
        case .passed: status = "matched"
        case .inconclusive: status = "inconclusive"
        case .failed, .notRun: status = "contradicted"
        }
        var data: [(String, JSONValue)] = [("status", .string(status)), ("verifierId", .string(v.verifierId ?? GoalVerifier.verifierId)),
                                           ("observationId", .string(observationId)), ("checkedAt", .string(Timestamp.string(checkedAt)))]
        if let reason = v.reason { data.append(("reason", .string(reason.rawValue))) }
        record("unit.verification", data)
        sink.verified(status: status, observationId: observationId, checkedAt: checkedAt)
    }

    /// A service code as an event code: lowercase snake case, ≤ 64.
    static func code(_ raw: String) -> String {
        let lowered = raw.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "_" }
        let s = String(lowered.prefix(64))
        return s.first?.isLetter == true ? s : "error"
    }
}
