import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// Test doubles for the explorer: a manual monotonic clock, a scripted model
// service, and a simulated neutral form (fixtures/neutral-form.html,
// MAC-001-A) behind spy observation and execution ports. Nothing here
// touches a real desktop, network or key.

final class ManualClock: MonotonicClock, @unchecked Sendable {
    private let lock = NSLock()
    private var now: UInt64 = 10_000_000_000
    private var nextId = 0
    private var sleepers: [Int: (deadline: UInt64, c: CheckedContinuation<Void, Error>)] = [:]
    /// When true, a sleep moves time to its deadline at once.
    var autoAdvance: Bool

    init(autoAdvance: Bool = true) { self.autoAdvance = autoAdvance }

    func nowNanoseconds() -> UInt64 { lock.lock(); defer { lock.unlock() }; return now }
    func wallNow() -> Date { Date(timeIntervalSince1970: 1_791_000_000 + Double(nowNanoseconds()) / 1e9) }

    var pendingSleeps: Int { lock.lock(); defer { lock.unlock() }; return sleepers.count }

    func sleep(untilNanoseconds deadline: UInt64) async throws {
        try Task.checkCancellation()
        let id: Int? = lock.withLock {
            if autoAdvance || now >= deadline {
                now = max(now, deadline)
                return nil
            }
            nextId += 1
            return nextId - 1
        }
        guard let id else { return }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    c.resume(throwing: CancellationError())
                    return
                }
                sleepers[id] = (deadline, c)
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let s = sleepers.removeValue(forKey: id)
            lock.unlock()
            s?.c.resume(throwing: CancellationError())
        }
    }

    func advance(ms: Int) {
        lock.lock()
        now += UInt64(ms) * 1_000_000
        let due = sleepers.filter { $0.value.deadline <= now }
        for id in due.keys { sleepers.removeValue(forKey: id) }
        lock.unlock()
        for s in due.values { s.c.resume() }
    }
}

/// Scripted model replies. `.hang` blocks until released or cancelled.
final class StubAiService: AiService, @unchecked Sendable {
    /// `.late` ignores cancellation and answers once released, like an
    /// upstream that replies after the run moved on.
    enum Reply { case text(String), error(ContractError), hang(String), late(String) }
    private let lock = NSLock()
    private var replies: [Reply]
    private(set) var requests: [AiInferenceRequest] = []
    private(set) var contexts: [AiCallContext] = []
    private var hung: CheckedContinuation<String, Error>?
    private var lateWaiter: CheckedContinuation<Void, Never>?
    var isLate: Bool { lock.withLock { lateWaiter != nil } }
    func releaseLate() { let c: CheckedContinuation<Void, Never>? = lock.withLock { let c = lateWaiter; lateWaiter = nil; return c }; c?.resume() }
    var usage: UsageTokens? = UsageTokens(inputTokens: 900, outputTokens: 40, totalTokens: 940)

    init(_ replies: [Reply]) { self.replies = replies }

    var callCount: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    var isHanging: Bool { lock.lock(); defer { lock.unlock() }; return hung != nil }

    func release() {
        lock.lock(); let c = hung; hung = nil; lock.unlock()
        c?.resume(returning: "LATE")
    }

    func infer(_ request: AiInferenceRequest, resolvedModel: AiResolvedModel, context: AiCallContext) async throws -> AiInferenceResult {
        let reply: Reply = lock.withLock {
            requests.append(request)
            contexts.append(context)
            return replies.isEmpty ? Reply.error(ContractError(.upstreamProtocolError, "script ran out")) : replies.removeFirst()
        }
        let started = Date(timeIntervalSince1970: 1_791_000_000)
        func record(_ state: InferenceState, _ error: ContractError?) -> AiCallRecord {
            AiCallRecord(reservationId: "res-\(context.inferenceAttemptId)", context: context, target: resolvedModel,
                         requestedModelId: resolvedModel.model.modelId, actualModelId: resolvedModel.model.modelId,
                         upstreamRequestId: "up-1", httpStatus: 200, finishReason: "stop", startedAt: started,
                         endedAt: started.addingTimeInterval(0.4), latencyMs: 400, state: state,
                         usage: state == .succeeded ? usage : nil, cost: nil, error: error, discarded: false)
        }
        switch reply {
        case let .text(t):
            return AiInferenceResult(outputText: t, finishReason: "stop", record: record(.succeeded, nil))
        case let .error(e):
            throw e
        case let .hang(late):
            let text: String = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { c in
                    lock.lock(); hung = c; lock.unlock()
                }
            } onCancel: { [self] in
                lock.lock(); let c = hung; hung = nil; lock.unlock()
                c?.resume(throwing: CancellationError())
            }
            _ = text
            return AiInferenceResult(outputText: late, finishReason: "stop", record: record(.succeeded, nil))
        case let .late(text):
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                lock.withLock { lateWaiter = c }
            }
            return AiInferenceResult(outputText: text, finishReason: "stop", record: record(.succeeded, nil))
        }
    }
}

func click(_ x: Int, _ y: Int) -> StubAiService.Reply { .text("Thought: click.\nAction: click(start_box='(\(x),\(y))')") }
func typeText(_ s: String) -> StubAiService.Reply { .text("Thought: type.\nAction: type(content='\(s)')") }
let finish: StubAiService.Reply = .text("Thought: done.\nAction: finished(content='saved')")

/// The neutral form of fixtures/neutral-form.html as state: a name field,
/// an Apply button, a status line.
final class NeutralForm: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var name = ""
    private(set) var submissions = 0
    private var focused = false
    static let nameField = (x: 100.0...400.0, y: 80.0...120.0)
    static let applyButton = (x: 100.0...300.0, y: 280.0...320.0)

    var status: String {
        lock.lock(); defer { lock.unlock() }
        return submissions == 0 ? "未提交" : "已保存：\(name) / MAC-001-A / 提交次数 \(submissions)"
    }

    func apply(_ action: GuiAction) {
        lock.lock(); defer { lock.unlock() }
        switch action {
        case let .click(p):
            if Self.nameField.x.contains(p.x), Self.nameField.y.contains(p.y) { focused = true }
            else if Self.applyButton.x.contains(p.x), Self.applyButton.y.contains(p.y) { submissions += 1; focused = false }
            else { focused = false }
        case let .type(t): if focused { name += t }
        default: break
        }
    }
}

let target = TargetIdentity(appId: "com.agentdesktop.neutral-form", processId: 4242, processStartId: "ps-1", windowId: "win-1",
                            windowGeometryRevision: 1, backendId: "spy",
                            windowFrameDesktopLogical: GuiRect(x: 0, y: 0, width: 500, height: 400))

actor SpyObservation: GuiObservationPort {
    let form: NeutralForm
    var desktopId = "desk-a"
    var sessionId = "sess-a"
    var epoch: UInt64 = 1
    var elementsAvailable = true
    var imageBytes = 1000
    /// Observations that still show the old status after a submission (a
    /// slow page): the result becomes visible only after that many looks.
    var statusLag = 0
    private(set) var count = 0
    private var seenSubmissions = 0
    private var lagLeft = 0
    private var shownStatus = "未提交"

    init(form: NeutralForm) { self.form = form }

    func set(session: String) { sessionId = session }
    func set(elementsAvailable v: Bool) { elementsAvailable = v }
    func set(imageBytes v: Int) { imageBytes = v }
    func set(statusLag v: Int) { statusLag = v }

    private func visibleStatus() -> String {
        if form.submissions != seenSubmissions {
            seenSubmissions = form.submissions
            lagLeft = statusLag
        }
        if lagLeft > 0 { lagLeft -= 1 } else { shownStatus = form.status }
        return shownStatus
    }

    func observe(runId: String, expectedGeneration: UInt64) throws -> ObservationBundle {
        count += 1
        let shot = try ScreenshotDescriptor(screenshotId: "shot-\(count)", artifactRef: "art-\(count)", sha256: String(repeating: "a", count: 64),
                                            mimeType: "image/png", transformVersion: "t1", sourceToDesktop: .scale(0.5, 0.5),
                                            transform: .pipeline(sourceSize: Size(width: 1000, height: 800)))
        let obs = Observation(observationId: "obs-\(count)",
                              stamp: ObservationStamp(sessionId: sessionId, desktopId: desktopId, snapshotId: "snap-\(count)",
                                                      bindingEpoch: epoch, runGeneration: expectedGeneration),
                              target: target, observedAt: Date(timeIntervalSince1970: 1_791_000_000 + Double(count)),
                              screenshots: [shot])
        let image = AiImageContent(screenshotId: shot.screenshotId, mimeType: "image/png",
                                   bytes: Data(repeating: UInt8(count % 251), count: imageBytes))
        let elements: [ObservedElement]? = elementsAvailable
            ? [ObservedElement(role: "static_text", text: visibleStatus()), ObservedElement(role: "text_field", text: form.name)]
            : nil
        return ObservationBundle(observation: obs, authorizedImages: [image], elements: elements)
    }
}

actor SpyExecutor: GuiExecutionPort {
    enum Mode { case confirm, unknown, reject, hang }
    let form: NeutralForm
    var mode: Mode = .confirm
    private(set) var executed: [GuiProposal] = []
    private var hung: CheckedContinuation<Void, Never>?

    init(form: NeutralForm) { self.form = form }

    func set(mode m: Mode) { mode = m }
    var isHanging: Bool { hung != nil }
    func release() { hung?.resume(); hung = nil }

    func execute(_ proposal: GuiProposal, actionId: String) async throws -> GuiActionReceipt {
        executed.append(proposal)
        guard case let .action(action) = proposal.body else { throw ContractError(.invalidAction, "not an action") }
        let t = Date(timeIntervalSince1970: 1_791_000_100)
        if mode == .hang { await withCheckedContinuation { hung = $0 } }
        let state: DeliveryState
        switch mode {
        case .confirm, .hang: form.apply(action); state = .confirmed
        case .unknown: form.apply(action); state = .unknown
        case .reject: state = .rejected
        }
        let sent = state != .rejected
        return GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                                actionType: action.kind, deliveryState: state, executionTarget: sent ? target : nil,
                                inputPath: sent ? "spy.event" : nil, startedAt: sent ? t : nil,
                                endedAt: state == .confirmed ? t : nil, evidenceRefs: state == .confirmed ? ["ev-\(actionId)"] : [],
                                createdAt: t, updatedAt: t,
                                confirmationObservationId: state == .confirmed ? "conf-\(actionId)" : nil,
                                reasonCode: state == .rejected ? "STALE_OBSERVATION" : nil)
    }
}

actor SpyAudit: GuiAuditPort {
    var failInference = false
    var failAction = false
    private(set) var inferences: [GuiInferenceReceipt] = []
    private(set) var actions: [GuiActionReceipt] = []
    private var nextAction = 0

    func set(failInference v: Bool) { failInference = v }
    func set(failAction v: Bool) { failAction = v }

    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) throws {
        if failInference { throw ContractError(.internalError, "disk full") }
    }
    func recordInference(_ receipt: GuiInferenceReceipt) { inferences.append(receipt) }
    func reserveAction(_ proposal: GuiProposal) throws -> String {
        if failAction { throw ContractError(.internalError, "disk full") }
        nextAction += 1
        return "act-\(nextAction)"
    }
    func recordAction(_ receipt: GuiActionReceipt) { actions.append(receipt) }
}

final class IdCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// F40-06 row 12 for these tests: whether each candidate "passed" the GUI
/// contract test is set here; the store-backed check is exercised end to
/// end in UnitRunOnRuntimeTests.
final class ContractEvidenceStub: GuiContractEvidence, @unchecked Sendable {
    private let lock = NSLock()
    private var passing = true
    var passed: Bool {
        get { lock.withLock { passing } }
        set { lock.withLock { passing = newValue } }
    }
    func guiContractPassed(_ candidate: GuiCandidate, provenance: AdapterProvenance) -> Bool { passed }
}

/// The Runtime's side of one unit Run, recorded (A6): the events the
/// explorer wrote, the verification it reported, how it ended.
final class RecordingSink: UnitRunSink, @unchecked Sendable {
    let runId: String
    private let lock = NSLock()
    private var recorded: [JSONValue] = []
    private var ended: UnitRunEnding?
    private var lastVerification: (status: String, observationId: String?)?
    /// Make every write fail from now on (a full audit store).
    var failWrites = false

    init(runId: String) { self.runId = runId }

    func record(_ type: String, _ data: JSONValue) -> Bool {
        lock.withLock {
            guard !failWrites, ended == nil else { return false }
            recorded.append(.obj([("runId", .string(runId)), ("sequence", .int(recorded.count + 1)),
                                  ("at", .string("2026-10-10T00:00:00Z")), ("type", .string(type)), ("data", data)]))
            return true
        }
    }

    func verified(status: String, observationId: String?, checkedAt: Date) {
        lock.withLock { lastVerification = (status, observationId) }
    }

    func finished(_ ending: UnitRunEnding) {
        lock.withLock {
            if ended != nil { Issue.record("finished twice") }
            ended = ending
        }
    }

    var events: [JSONValue] { lock.withLock { recorded } }
    var ending: UnitRunEnding? { lock.withLock { ended } }
    var verification: (status: String, observationId: String?)? { lock.withLock { lastVerification } }
}

/// What a test reads of a unit Run.
struct UnitRunView {
    let ending: UnitRunEnding?
    let events: [JSONValue]
    let verification: (status: String, observationId: String?)?

    func count(_ type: String) -> Int { events.filter { $0["type"]?.stringValue == type }.count }
    var modelAttempts: Int {
        events.filter { $0["type"]?.stringValue == "unit.inference.attempt" }.compactMap { $0["data"]?["attempts"]?.intValue }.reduce(0, +)
    }
    var steps: Int { count("unit.progress") }
    var lastDelivery: String? { events.last { $0["type"]?.stringValue == "unit.action" }?["data"]?["deliveryState"]?.stringValue }
}

/// Config store + the unit.run executor with spy ports, the Runtime's part
/// played by RecordingSink (A6). Configuration goes through real routers.
final class GuiHarness: @unchecked Sendable {
    let form = NeutralForm()
    let store: ConfigStore
    let ai: StubAiService
    let clock: ManualClock
    let observation: SpyObservation
    let executor: SpyExecutor
    let audit = SpyAudit()
    let units: UnitRunService?
    let features: GuiBackendFeatures?
    let codecs: GuiCodecRegistry
    let owner: ServiceRouter
    let evidence = ContractEvidenceStub()
    var profile: JSONValue = .null
    private let lock = NSLock()
    private var sinks: [String: RecordingSink] = [:]
    private var stops: [String: UnitRunStopHandle] = [:]
    private let counter = IdCounter()

    init(_ replies: [StubAiService.Reply], backend: Bool = true, limits: [(String, JSONValue)] = [],
         fixture: Bool = false, clock: ManualClock = ManualClock()) throws {
        let dir = ScratchDirectory.url("adgui")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ConfigStore(path: dir.appendingPathComponent("c.sqlite").path, credentials: InMemoryCredentialStore(),
                                digestKey: Data(repeating: 3, count: 32),
                                options: ConfigOptions(allowFixtureAdapter: fixture))
        ai = StubAiService(replies)
        self.clock = clock
        observation = SpyObservation(form: form)
        executor = SpyExecutor(form: form)
        codecs = GuiCodecRegistry(fixtureAdapterEnabled: fixture)
        let ports = GuiExplorerPorts(observation: observation, execution: executor, audit: audit)
        features = backend ? GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]) : nil
        let (store, ai, codecs, evidence) = (store, ai, codecs, evidence)
        units = features.map { f in
            UnitRunService(resolver: ConfigBindingResolver(store: store, codecs: codecs), evidence: evidence, ports: ports, features: f,
                           aiService: ai, codecs: codecs, clock: clock)
        }
        owner = ServiceRouter(handlers: ConfigApplicationService(store: store).handlers(callerScope: "owner"))
        self.limitOverrides = limits
        self.fixture = fixture
    }

    let limitOverrides: [(String, JSONValue)]
    let fixture: Bool

    /// One call through the router, as `{ok, result | error}` (test shape).
    func call(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil, router: ServiceRouter? = nil) async throws -> JSONValue {
        switch await (router ?? owner).answer(method: command, params: params, idempotencyKey: key) {
        case let .success(v): return .obj([("ok", .bool(true)), ("result", v)])
        case let .failure(e): return .obj([("ok", .bool(false)), ("error", e.json)])
        }
    }

    func ok(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil, router: ServiceRouter? = nil) async throws -> JSONValue {
        let r = try await call(command, params, key: key, router: router)
        guard r["ok"]?.boolValue == true, let result = r["result"] else {
            Issue.record("\(command) failed: \(r.encoded())")
            throw ContractError(.internalError, "call failed")
        }
        return result
    }

    /// Connection → model profile → GUI profile (image_pixels) → default.
    @discardableResult
    func setUpProfile(name: String = "UI-TARS", fallback: [JSONValue] = []) async throws -> JSONValue {
        let conn = try await ok("ai.connections.create", .obj([
            ("name", .string("Ark")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("https://ark.example.com/api/v3")), ("timeoutMs", .int(30000)),
            ("credential", .obj([("apiKey", .string("sk-canary-gui"))])),
        ]), key: "conn-\(UUID().uuidString.prefix(8))")
        let model = try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("Seed")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
            ("modelId", .string("doubao-seed-2-1-lite-260915")), ("requestOptions", .obj([("temperature", .double(0))])),
            ("maxOutputTokens", .int(1024)),
        ]), key: "model-\(UUID().uuidString.prefix(8))")
        var limits = GuiLimits.ceiling.json
        for (k, v) in limitOverrides { limits = limits.setting(k, v) }
        let gui = try await ok("ai.profiles.create", .obj([
            ("name", .string(name)), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
            ("adapterId", .string(fixture ? "fixture_json_v1" : "uitars_v1")), ("adapterVersion", .string("1.0.0")),
            ("promptVersion", .string("uitars-prompt-1")), ("parserVersion", .string("uitars-parser-1")),
            ("coordinateProtocol", .string("image_pixels")), ("limits", limits),
            ("allowedFallbackProfileRefs", .array(fallback)),
        ]), key: "gui-\(UUID().uuidString.prefix(8))")
        let def = try await ok("ai.profiles.default.get")
        _ = try await ok("ai.profiles.setDefault", .obj([
            ("guiProfileId", gui["guiProfileId"]!), ("expectedDefaultRevision", def["default"]!["revision"]!),
            ("expectedProfileRevision", gui["revision"]!),
        ]), key: "def-\(UUID().uuidString.prefix(8))")
        profile = gui
        return gui
    }

    static let goal = "在指定中立表单的姓名中输入 Ada，然后点击应用"
    static let expected = "已保存：Ada / MAC-001-A / 提交次数 1"

    /// unit_run_params for the neutral form.
    func startParams(actions: [String] = ["click", "type", "key"], text: String = GuiHarness.expected) -> JSONValue {
        .obj([
            ("desktopId", .string("desk-a")), ("mode", .string("explore")), ("goal", .obj([("description", .string(Self.goal))])),
            ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                                         ("text", .string(text))])]))])),
            ("allowedActions", .array(actions.map(JSONValue.string))),
        ])
    }

    /// Admission as the Runtime asks for it.
    func admit(_ params: JSONValue? = nil, scope: String = "owner") async -> Result<any UnitRunPlan, RuntimeError> {
        guard let units else { return .failure(RuntimeError("unsupported_backend", "off", phase: .handler)) }
        return await units.admit(params: params ?? startParams(), callerScope: scope)
    }

    /// Admit and start a unit Run on desk-a / sess-a; returns its runId.
    func start(_ params: JSONValue? = nil) async throws -> String {
        let p = params ?? startParams()
        let plan = try await admit(p).get()
        let runId = "run-\(counter.next())"
        let sink = RecordingSink(runId: runId)
        let stop = UnitRunStopHandle()
        units!.start(plan, context: UnitRunContext(runId: runId, sessionId: "sess-a", desktopId: "desk-a", bindingEpoch: 1,
                                                   callerScope: "owner", params: p), sink: sink, stop: stop)
        lock.withLock { sinks[runId] = sink; stops[runId] = stop }
        return runId
    }

    func sink(_ runId: String) -> RecordingSink { lock.withLock { sinks[runId]! } }
    /// The Runtime accepted a stop of the Run.
    func cancel(_ runId: String) { lock.withLock { stops[runId] }?.stop() }
    func finished(_ runId: String) async { await units?.task(for: runId)?.value }

    func run(_ runId: String) -> UnitRunView {
        let s = sink(runId)
        return UnitRunView(ending: s.ending, events: s.events, verification: s.verification)
    }
}

/// Wait (in real time, briefly) until a condition holds.
func eventually(_ what: String, _ condition: () async -> Bool) async {
    for _ in 0..<400 {
        if await condition() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}
