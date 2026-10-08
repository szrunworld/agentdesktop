import Foundation
import AgentDesktopProtocol

/// Model-attempt accounting for one run or one capability-test operation
/// (spec §07.3, §09.1). Reservations are atomic: two concurrent steps cannot
/// both take the last attempt. A started attempt counts whether it
/// succeeds, fails or is cancelled.
public actor AttemptBudget {
    public nonisolated let maxAttemptsPerStep: Int
    public nonisolated let maxTotalAttempts: Int
    public nonisolated let requireReportedUsage: Bool

    private var perStep: [Int: Int] = [:]
    private(set) public var totalAttempts = 0
    private var missingUsage = false

    public init(maxAttemptsPerStep: Int = 2, maxTotalAttempts: Int = 30, requireReportedUsage: Bool = false) {
        // A profile may tighten the ceiling, never raise it.
        self.maxAttemptsPerStep = max(1, min(maxAttemptsPerStep, 2))
        self.maxTotalAttempts = max(1, min(maxTotalAttempts, 30))
        self.requireReportedUsage = requireReportedUsage
    }

    /// Take one attempt for `step`, or throw LIMIT_EXCEEDED (or
    /// USAGE_UNAVAILABLE when usage is required and an earlier attempt
    /// reported none).
    public func reserve(step: Int) throws {
        if requireReportedUsage && missingUsage {
            throw ContractError(.usageUnavailable, "an earlier model call reported no usage; this profile requires it")
        }
        guard totalAttempts < maxTotalAttempts else {
            throw ContractError(.limitExceeded, "the run used all \(maxTotalAttempts) model attempts")
        }
        let used = perStep[step, default: 0]
        guard used < maxAttemptsPerStep else {
            throw ContractError(.limitExceeded, "step \(step) used all \(maxAttemptsPerStep) model attempts")
        }
        perStep[step] = used + 1
        totalAttempts += 1
    }

    public func attempts(step: Int) -> Int { perStep[step, default: 0] }

    /// Note what a finished attempt reported.
    public func noteUsage(_ usage: UsageTokens?) {
        if usage == nil || usage?.isComplete == false { missingUsage = true }
    }
}

/// Runs one decision step's inference with bounded retries (spec §07.3):
///
/// - The step's attempts, first try and every retry or fallback together,
///   never exceed the budget (2): "two retries" and "two candidates" do not
///   multiply into four.
/// - 429 waits for Retry-After, but only if a new attempt can still start
///   before the deadline; 5xx/network may move to the next candidate.
/// - Auth, protocol, capability and validation errors are not retried.
/// - Candidates are the run's frozen list; nothing is re-read from defaults.
public struct StepInference: Sendable {
    public let service: AiService
    public let budget: AttemptBudget
    public let clock: MonotonicClock

    public init(service: AiService, budget: AttemptBudget, clock: MonotonicClock) {
        self.service = service
        self.budget = budget
        self.clock = clock
    }

    /// - Parameters:
    ///   - candidates: primary first, then at most one fallback.
    ///   - makeContext: a fresh context (new inferenceAttemptId) per attempt.
    public func run(_ request: AiInferenceRequest, step: Int, candidates: [AiResolvedModel],
                    deadlineNs: UInt64, makeContext: @Sendable (Int, AiResolvedModel) -> AiCallContext) async throws -> AiInferenceResult {
        guard !candidates.isEmpty, candidates.count <= 2 else {
            throw ContractError(.validationError, "a step has one primary and at most one fallback candidate")
        }
        var index = 0
        var attempt = 0
        var lastError: ContractError?
        while true {
            try Task.checkCancellation()
            guard clock.nowNanoseconds() < deadlineNs else {
                throw lastError ?? ContractError(.deadlineExceeded, "the deadline passed")
            }
            do {
                try await budget.reserve(step: step)
            } catch let e as ContractError {
                throw lastError ?? e
            }
            let candidate = candidates[index]
            attempt += 1
            do {
                let result = try await service.infer(request, resolvedModel: candidate, context: makeContext(attempt, candidate))
                await budget.noteUsage(result.record.usage)
                return result
            } catch let e as ContractError {
                lastError = e
                switch e.code {
                case .rateLimited:
                    let waitMs = e.details?["retryAfterMs"]?.intValue ?? 0
                    let resumeAt = clock.nowNanoseconds() &+ UInt64(waitMs) * 1_000_000
                    // Do not start a retry that could only begin after the deadline.
                    guard resumeAt < deadlineNs, await budget.attempts(step: step) < budget.maxAttemptsPerStep else { throw e }
                    try await clock.sleep(untilNanoseconds: resumeAt)
                    if candidates.count > 1 { index = (index + 1) % candidates.count }
                case .upstreamUnavailable:
                    guard await budget.attempts(step: step) < budget.maxAttemptsPerStep else { throw e }
                    if candidates.count > 1 { index = (index + 1) % candidates.count }
                default:
                    throw e
                }
            }
        }
    }
}
