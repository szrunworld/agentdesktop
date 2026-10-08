import AgentDesktopAI
import AgentDesktopProtocol
import CryptoKit
import Foundation

/// What the Runtime's execution backend can do, reported as is by
/// runtime.capabilities. Nothing is claimed that has no evidence.
public struct GuiBackendFeatures: Sendable {
    public var actions: [GuiActionKind]
    /// ["element_text_equals"] only when the backend reads static text of
    /// the bound window.
    public var verificationPredicates: [String]
    public var directApiWithoutAi: Bool
    public var deterministicReplayWithoutAi: Bool
    public var independentDesktopConcurrency: Bool
    /// "NOT_RUN", "VERIFIED" or "FAILED" (G0 evidence for this backend).
    public var nativeIsolationEvidence: String

    public init(actions: [GuiActionKind], verificationPredicates: [String], directApiWithoutAi: Bool = false,
                deterministicReplayWithoutAi: Bool = false, independentDesktopConcurrency: Bool = false,
                nativeIsolationEvidence: String = "NOT_RUN") {
        self.actions = actions; self.verificationPredicates = verificationPredicates
        self.directApiWithoutAi = directApiWithoutAi; self.deterministicReplayWithoutAi = deterministicReplayWithoutAi
        self.independentDesktopConcurrency = independentDesktopConcurrency
        self.nativeIsolationEvidence = nativeIsolationEvidence
    }
}

/// The Runtime's execution boundary as the run service sees it. Without
/// one, real GUI input stays off: gui.runs.start refuses.
public struct GuiExecutionBackend: Sendable {
    public let ports: GuiExplorerPorts
    public let sessions: GuiSessionAuthority
    public let features: GuiBackendFeatures

    public init(ports: GuiExplorerPorts, sessions: GuiSessionAuthority, features: GuiBackendFeatures) {
        self.ports = ports
        self.sessions = sessions
        self.features = features
    }
}

/// gui.runs.start/get/cancel/events and runtime.capabilities (spec §05.3,
/// §05.4, §07.2). Runs are scoped to their caller; start is idempotent per
/// (caller, key) and binds the configuration once.
public actor GuiRunService {
    public static let commands = ["gui.runs.start", "gui.runs.get", "gui.runs.cancel", "gui.runs.events"]

    let repository: GuiRunRepository
    let resolver: GuiBindingResolver
    let backend: GuiExecutionBackend?
    let aiService: AiService
    let codecs: GuiCodecRegistry
    let clock: MonotonicClock
    let newId: @Sendable (String) -> String
    private var drivers: [String: (driver: GuiRunDriver, task: Task<Void, Never>)] = [:]

    public init(repository: GuiRunRepository, resolver: GuiBindingResolver, backend: GuiExecutionBackend?,
                aiService: AiService, codecs: GuiCodecRegistry = GuiCodecRegistry(),
                clock: MonotonicClock = SystemMonotonicClock(),
                newId: @escaping @Sendable (String) -> String = { $0 + "-" + UUID().uuidString.lowercased() }) {
        self.repository = repository
        self.resolver = resolver
        self.backend = backend
        self.aiService = aiService
        self.codecs = codecs
        self.clock = clock
        self.newId = newId
    }

    /// Handlers for one caller. `trustedOwner` is the owner UI/CLI, the only
    /// caller that may omit sessionId.
    public nonisolated func handlers(callerScope: String, trustedOwner: Bool) -> [String: ServiceHandler] {
        var out: [String: ServiceHandler] = [:]
        for command in Self.commands {
            out[command] = { req in try await self.handle(req, callerScope: callerScope, trustedOwner: trustedOwner) }
        }
        return out
    }

    public func handle(_ req: ServiceRequest, callerScope: String, trustedOwner: Bool) async throws -> JSONValue {
        let p = req.params
        switch req.method {
        case "gui.runs.start": return try await start(p, key: req.idempotencyKey, callerScope: callerScope, trustedOwner: trustedOwner)
        case "gui.runs.get": return try await get(p["runId"]?.stringValue ?? "", callerScope: callerScope)
        case "gui.runs.cancel": return try await cancel(p["runId"]?.stringValue ?? "", callerScope: callerScope)
        case "gui.runs.events":
            return try await events(p["runId"]?.stringValue ?? "", after: p["afterSequence"]?.intValue ?? 0,
                                    limit: p["limit"]?.intValue ?? 100, callerScope: callerScope)
        default: throw ContractError(.unsupportedCommand, "command is not implemented in this build")
        }
    }

    public nonisolated func capabilities() -> JSONValue {
        let f = backend?.features
        return .obj([
            ("implementedAiProtocols", .array([.string(AiProtocol.openaiChat.rawValue)])),
            ("verificationPredicates", .array((f?.verificationPredicates ?? []).map(JSONValue.string))),
            ("guiAdapters", .array(codecs.availableAdapters.map { .string($0.rawValue) })),
            // What the codecs can propose; with no backend nothing is executed
            // (verificationPredicates is empty and start refuses).
            ("actions", .array((f?.actions ?? GuiActionKind.allCases).map { .string($0.rawValue) })),
            ("limits", GuiLimits.ceiling.json),
            ("features", .obj([
                ("directApiWithoutAi", .bool(f?.directApiWithoutAi ?? false)),
                ("deterministicReplayWithoutAi", .bool(f?.deterministicReplayWithoutAi ?? false)),
                ("fixtureAdapterEnabled", .bool(codecs.fixtureAdapterEnabled)),
                ("independentDesktopConcurrency", .bool(f?.independentDesktopConcurrency ?? false)),
                ("nativeIsolationEvidence", .string(f?.nativeIsolationEvidence ?? "NOT_RUN")),
            ])),
        ])
    }

    func start(_ p: JSONValue, key: String?, callerScope: String, trustedOwner: Bool) async throws -> JSONValue {
        guard let backend else {
            throw ContractError(.capabilityMismatch, "no native execution backend has passed G0 here; real GUI input stays off")
        }
        guard let key else { throw ContractError(.validationError, "gui.runs.start needs an idempotencyKey") }
        let verification = try GuiVerification(json: p["verification"] ?? .null)
        guard backend.features.verificationPredicates.contains("element_text_equals") else {
            throw ContractError(.capabilityMismatch, "this backend cannot verify element_text_equals")
        }
        let allowed = try (p["allowedActions"]?.arrayValue ?? []).map { v -> GuiActionKind in
            guard let k = v.stringValue.flatMap(GuiActionKind.init(rawValue:)) else {
                throw ContractError(.validationError, "unknown action in allowedActions")
            }
            return k
        }
        guard !allowed.isEmpty, allowed.allSatisfy(backend.features.actions.contains) else {
            throw ContractError(.capabilityMismatch, "the backend does not support every allowed action")
        }
        guard let desktopId = p["desktopId"]?.stringValue, let goal = p["goal"]?.stringValue else {
            throw ContractError(.validationError, "desktopId and goal are required")
        }
        let explicitSession = p["sessionId"]?.stringValue
        if explicitSession == nil && !trustedOwner {
            throw ContractError(.forbidden, "only the owner may start a run without a session")
        }
        let digest = Self.digest(p)

        let resolved = try await resolver.resolve(guiProfileId: p["guiProfileId"]?.stringValue,
                                                  expectedProfileRevision: p["expectedProfileRevision"]?.intValue,
                                                  callerScope: callerScope)
        let runId = newId("run")
        let session = try await backend.sessions.authorize(sessionId: explicitSession, desktopId: desktopId,
                                                           callerScope: callerScope, trustedOwner: trustedOwner, runId: runId)
        let now = clock.wallNow()
        let binding = GuiRunBinding(runId: runId, sessionId: session.sessionId, desktopId: desktopId, goal: goal,
                                    bindingEpoch: session.bindingEpoch, runGeneration: 1,
                                    policyRevision: resolved.policyRevision, boundAt: now, primary: resolved.primary,
                                    fallbackCandidates: resolved.fallback, verification: verification, allowedActions: allowed)
        let startResult = JSONValue.obj([("runId", .string(runId)), ("state", .string("queued")), ("binding", binding.json)])
        let lifecycle = RunLifecycle(runId: runId, initialGeneration: binding.runGeneration)
        let limits = binding.limits
        let budget = AttemptBudget(maxAttemptsPerStep: limits.maxModelAttemptsPerStep,
                                   maxTotalAttempts: limits.maxTotalModelAttempts,
                                   requireReportedUsage: limits.requireReportedUsage)
        let recorder = RunRecorder(binding: binding, lifecycle: lifecycle, repository: repository, budget: budget,
                                   clock: clock, createdAt: now)
        let stored = StoredGuiRun(runId: runId, callerScope: callerScope, binding: binding.json,
                                  startResult: startResult, snapshot: await recorder.snapshot())

        switch try await repository.create(stored, idempotencyKey: key, digest: digest) {
        case let .existing(run):
            return run.startResult
        case .created:
            let provider = GuiAiProvider(service: aiService, codecs: codecs, clock: clock)
            let driver = GuiRunDriver(binding: binding, lifecycle: lifecycle, recorder: recorder, ports: backend.ports,
                                      provider: provider, budget: budget, clock: clock, callerScope: callerScope,
                                      startedAtNs: clock.nowNanoseconds())
            let task = Task.detached { await driver.run() }
            drivers[runId] = (driver, task)
            return startResult
        }
    }

    func get(_ runId: String, callerScope: String) async throws -> JSONValue {
        guard let run = try await repository.load(runId: runId, callerScope: callerScope) else {
            throw ContractError(.notFound, "run not found")
        }
        return run.snapshot
    }

    func cancel(_ runId: String, callerScope: String) async throws -> JSONValue {
        guard let run = try await repository.load(runId: runId, callerScope: callerScope) else {
            throw ContractError(.notFound, "run not found")
        }
        guard let entry = drivers[runId] else {
            // A run this process does not drive can only be in an end state.
            let state = run.snapshot["state"]?.stringValue ?? "failed"
            return .obj([("runId", .string(runId)), ("accepted", .bool(state == "cancelled")),
                         ("state", .string(state)), ("terminal", .bool(true))])
        }
        let receipt = await entry.driver.lifecycle.requestCancel()
        // Stop model calls and timers at once; an input already handed to the
        // executor is left to finish and report.
        if await entry.driver.lifecycle.inFlightActionId == nil { entry.task.cancel() }
        await entry.driver.recorder.sync()
        return .obj([("runId", .string(runId)), ("accepted", .bool(receipt.accepted)),
                     ("state", .string(receipt.state.rawValue)), ("terminal", .bool(receipt.terminal))])
    }

    func events(_ runId: String, after: Int, limit: Int, callerScope: String) async throws -> JSONValue {
        guard try await repository.load(runId: runId, callerScope: callerScope) != nil else {
            throw ContractError(.notFound, "run not found")
        }
        let stored = try await repository.events(runId: runId, afterSequence: after, limit: limit)
        if let oldest = stored.oldestRetained, after < oldest - 1 {
            throw ContractError(.eventsCursorExpired, "events before \(oldest) are no longer kept; read the run, then continue from its lastSequence",
                                details: .obj([("runId", .string(runId))]))
        }
        let next = stored.events.last?["sequence"]?.intValue ?? after
        return .obj([("runId", .string(runId)), ("events", .array(stored.events)),
                     ("nextAfterSequence", .int(next)), ("hasMore", .bool(stored.lastSequence > next))])
    }

    /// The task driving a run, for callers that need to await its end.
    public func task(for runId: String) -> Task<Void, Never>? { drivers[runId]?.task }

    /// The semantic digest of a start request: the params only (requestId and
    /// deadline are not part of it). Run params carry no secret.
    static func digest(_ params: JSONValue) -> String {
        let data = Data(canonical(params).encoded().utf8)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func canonical(_ v: JSONValue) -> JSONValue {
        switch v {
        case let .object(m): return .object(m.sorted { $0.key < $1.key }.map { (key: $0.key, value: canonical($0.value)) })
        case let .array(a): return .array(a.map(canonical))
        default: return v
        }
    }
}
