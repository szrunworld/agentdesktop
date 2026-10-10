import AgentDesktopAI
import AgentDesktopProtocol
import Foundation

/// Cancels a task that may not exist yet: a cancel before `set` cancels it
/// as soon as it is set.
final class TaskGate: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func set(_ t: Task<Void, Never>) {
        let now: Bool = lock.withLock { task = t; return cancelled }
        if now { t.cancel() }
    }

    func cancel() {
        let t: Task<Void, Never>? = lock.withLock { cancelled = true; return task }
        t?.cancel()
    }
}

/// The GUI executor of `unit.run` (A6, PR2d). The Runtime admits the Run
/// and owns it; this resolves the GUI profile at admission (F40-06 rows
/// 7–15) and then drives the bounded explorer loop through the Runtime's
/// ports, inside the Run and as its principal. It keeps no run table of its
/// own: progress goes to the Run's `unit.*` events and `Run.unit`.
public final class UnitRunService: UnitRunExecutor, @unchecked Sendable {
    struct Plan: UnitRunPlan {
        let primary: GuiCandidate
        let fallback: [GuiCandidate]
        let policyRevision: Int
        let goal: String
        let verifications: [GuiVerification]
        let allowedActions: [GuiActionKind]
        let limits: GuiLimits

        var guiProfileId: String? { primary.guiProfileId }
        var guiProfileRevision: Int? { primary.guiProfileRevision }
    }

    let resolver: GuiBindingResolver
    let ports: GuiExplorerPorts
    let features: GuiBackendFeatures
    let aiService: AiService
    let codecs: GuiCodecRegistry
    let clock: MonotonicClock
    private let lock = NSLock()
    private var tasks: [String: Task<Void, Never>] = [:]

    public init(resolver: GuiBindingResolver, ports: GuiExplorerPorts, features: GuiBackendFeatures, aiService: AiService,
                codecs: GuiCodecRegistry = GuiCodecRegistry(), clock: MonotonicClock = SystemMonotonicClock()) {
        self.resolver = resolver
        self.ports = ports
        self.features = features
        self.aiService = aiService
        self.codecs = codecs
        self.clock = clock
    }

    static func refusal(_ code: String, _ message: String, _ reason: String, details: [(String, JSONValue)] = []) -> RuntimeError {
        RuntimeError(code, message, phase: .handler, notSent: true, details: .obj([("reason", .string(reason))] + details))
    }

    public func admit(params p: JSONValue, callerScope: String) async -> Result<any UnitRunPlan, RuntimeError> {
        // 7–12 first (F40-06 order): the GUI profile, its model and credential.
        let profileId = p["guiProfileId"]?.stringValue
        let resolved: (primary: GuiCandidate, fallback: [GuiCandidate], policyRevision: Int)
        do {
            resolved = try await resolver.resolve(guiProfileId: profileId, expectedProfileRevision: p["expectedProfileRevision"]?.intValue,
                                                  callerScope: callerScope)
        } catch let e as ContractError {
            return .failure(Self.admissionError(e, explicitProfile: profileId != nil))
        } catch {
            return .failure(RuntimeError("internal_error", "the GUI profile could not be read", phase: .handler, notSent: true))
        }
        // 13. Every allowed action is one the backend executes ("wait" is
        // the explorer's own and always available).
        var allowed: [GuiActionKind] = []
        for v in p["allowedActions"]?.arrayValue ?? [] {
            guard let name = v.stringValue, name != "wait" else { continue }
            guard let kind = GuiActionKind(rawValue: name), features.actions.contains(kind) else {
                return .failure(Self.refusal("capability_mismatch", "this backend does not execute \(name)", "action_unsupported",
                                             details: [("action", .string(name))]))
            }
            allowed.append(kind)
        }
        // 14. Every predicate is one the backend can verify.
        var verifications: [GuiVerification] = []
        for predicate in p["verification"]?["all"]?.arrayValue ?? [] {
            let kind = predicate["kind"]?.stringValue ?? ""
            guard features.verificationPredicates.contains(kind), let v = try? GuiVerification(json: predicate) else {
                return .failure(Self.refusal("capability_mismatch", "this backend cannot verify \(kind)", "predicate_unsupported"))
            }
            verifications.append(v)
        }
        guard !verifications.isEmpty else {
            return .failure(Self.refusal("capability_mismatch", "unit.run needs a predicate this backend verifies", "predicate_unsupported"))
        }
        // 15. Replay needs a learned flow; there is none before L3.
        if p["mode"]?.stringValue == "replay_only" {
            return .failure(Self.refusal("capability_missing", "no replayable flow exists for this goal", "replay_not_available"))
        }
        // The Run's limits: the profile's, narrowed by the caller's.
        var limits = resolved.primary.limits
        if let steps = p["limits"]?["maxSteps"]?.intValue { limits.maxSteps = min(limits.maxSteps, steps) }
        if let seconds = p["limits"]?["maxSeconds"]?.intValue { limits.maxWallTimeMs = min(limits.maxWallTimeMs, seconds * 1000) }
        return .success(Plan(primary: resolved.primary, fallback: resolved.fallback, policyRevision: resolved.policyRevision,
                             goal: Self.goalText(p["goal"] ?? .null), verifications: verifications, allowedActions: allowed,
                             limits: limits))
    }

    /// The goal as the model reads it: the description, then the parameter
    /// values (kept out of goalHash).
    static func goalText(_ goal: JSONValue) -> String {
        let description = goal["description"]?.stringValue ?? ""
        guard let params = goal["params"], params.objectMembers?.isEmpty == false else { return description }
        return description + "\n\nParameters (JSON): " + GuiRunService.canonical(params).encoded()
    }

    /// The resolver's refusal in F40-06 terms.
    static func admissionError(_ e: ContractError, explicitProfile: Bool) -> RuntimeError {
        switch e.code {
        case .notFound:
            return refusal("not_found", e.message, explicitProfile ? "gui_profile_not_found" : "no_default_gui_profile")
        case .configConflict:
            var extra: [(String, JSONValue)] = []
            if let current = e.details?["currentRevision"] { extra.append(("currentRevision", current)) }
            return refusal("conflict", e.message, "profile_revision_changed", details: extra)
        case .resourceDisabled:
            return refusal("conflict", e.message, "disabled")
        case .credentialRequired:
            return refusal("model_unavailable", e.message, "credential_required")
        case .credentialRevoked:
            return refusal("model_unavailable", e.message, "credential_revoked")
        case .capabilityMismatch, .unsupportedProtocol:
            return refusal("capability_mismatch", e.message, "gui_profile_unsupported")
        case .validationError:
            return refusal("invalid_argument", e.message, "gui_profile_incomplete")
        default:
            return RuntimeError("internal_error", "the GUI profile could not be resolved", phase: .handler, notSent: true)
        }
    }

    public func start(_ plan: any UnitRunPlan, context c: UnitRunContext, sink: UnitRunSink, stop: UnitRunStopHandle) {
        guard let plan = plan as? Plan else {
            sink.finished(.failed(reason: "internal_error"))
            return
        }
        let binding = GuiRunBinding(runId: c.runId, sessionId: c.sessionId, desktopId: c.desktopId, goal: plan.goal,
                                    bindingEpoch: c.bindingEpoch, runGeneration: 1, policyRevision: plan.policyRevision,
                                    boundAt: clock.wallNow(), primary: plan.primary, fallbackCandidates: plan.fallback,
                                    verification: plan.verifications[0], allowedActions: plan.allowedActions,
                                    moreVerifications: Array(plan.verifications.dropFirst()), narrowedLimits: plan.limits)
        let lifecycle = RunLifecycle(runId: c.runId, initialGeneration: binding.runGeneration)
        let budget = AttemptBudget(maxAttemptsPerStep: plan.limits.maxModelAttemptsPerStep,
                                   maxTotalAttempts: plan.limits.maxTotalModelAttempts,
                                   requireReportedUsage: plan.limits.requireReportedUsage)
        let startedAt = clock.nowNanoseconds()
        let recorder = UnitRunRecorder(sink: sink, budget: budget, clock: clock, maxSteps: plan.limits.maxSteps,
                                       deadlineNs: startedAt &+ UInt64(plan.limits.maxWallTimeMs) * 1_000_000)
        let signal = UnitStopSignal()
        let driver = GuiRunDriver(binding: binding, lifecycle: lifecycle, recorder: recorder, ports: ports,
                                  provider: GuiAiProvider(service: aiService, codecs: codecs, clock: clock), budget: budget,
                                  clock: clock, callerScope: c.callerScope, startedAtNs: startedAt, stopSignal: signal)
        let runId = c.runId
        // Armed before the driver can run: a stop accepted at any moment,
        // even before this, keeps the next model call and input from starting.
        let gate = TaskGate()
        stop.arm {
            // Visible before this returns: no model call or input starts
            // after the Runtime accepted the stop. A model call already out
            // is cancelled with the task; an input already handed to the
            // Runtime finishes and reports.
            let inputOut = signal.stop()
            if !inputOut { gate.cancel() }
            Task { _ = await lifecycle.requestCancel() }
        }
        // Made and registered under the lock, so its own cleanup (which
        // takes the lock) cannot run before it is registered (codex on
        // 073b96f: a fast Run left its finished task behind).
        let task: Task<Void, Never> = lock.withLock {
            let t = Task.detached { [weak self] in
                await driver.run()
                sink.finished(await Self.ending(of: lifecycle, stopped: signal.isStopped))
                self?.lock.withLock { _ = self?.tasks.removeValue(forKey: runId) }
            }
            tasks[runId] = t
            return t
        }
        gate.set(task)
    }

    /// The task driving a Run, for callers that await its end (tests).
    public func task(for runId: String) -> Task<Void, Never>? { lock.withLock { tasks[runId] } }

    /// How the explorer's part ended, as the Runtime records it.
    static func ending(of lifecycle: RunLifecycle, stopped: Bool = false) async -> UnitRunEnding {
        let state = await lifecycle.state
        // A stop the Runtime accepted ends it as cancelled, however the
        // loop noticed (its own failure included); a goal seen before stays.
        if stopped, state != .succeeded { return .cancelled }
        switch state {
        case .succeeded:
            return .verified
        case .cancelled, .cancelling:
            return .cancelled
        case .failed:
            return .failed(reason: closingReason(await lifecycle.failure))
        case .waitingUser:
            let code = await lifecycle.waitingReasonCode ?? "needs_user"
            if code == ErrorCode.actionOutcomeUnknown.rawValue { return .failed(reason: "action_outcome_unknown") }
            return .needsInput(reason: UnitRunRecorder.code(code))
        default:
            return .failed(reason: "internal_error")
        }
    }

    /// The Run's closingReason for a failed unit: the service code in
    /// lowercase, or the reason it carries (an empty model reply).
    static func closingReason(_ e: ContractError?) -> String {
        guard let e else { return "internal_error" }
        if let reason = e.details?["reasonCode"]?.stringValue { return UnitRunRecorder.code(reason) }
        return UnitRunRecorder.code(e.code.rawValue)
    }
}
