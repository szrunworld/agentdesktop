import AgentDesktopAI
import AgentDesktopAIUI
import AgentDesktopProtocol
import AgentDesktopGUI
import AgentDesktopService
import Foundation

// Stand-ins adapted from Tests/AgentDesktopServiceTests (vertical slice):
// a scripted OpenAI-compatible upstream and the neutral form in place of a
// desktop. Real native input and a real model are not exercised here.

let canary = "sk-canary-ui-pages"
let neutralExpected = RunStartModel.neutralExpected

final class NeutralForm: @unchecked Sendable {
    private let lock = NSLock()
    private var name = ""
    private var focused = false
    private(set) var submissions = 0
    private(set) var inputs = 0
    static let nameField = (x: 200.0...800.0, y: 160.0...240.0)
    static let applyButton = (x: 200.0...600.0, y: 560.0...640.0)

    var status: String { lock.withLock { submissions == 0 ? "未提交" : "已保存：\(name) / MAC-001-A / 提交次数 \(submissions)" } }
    var fieldText: String { lock.withLock { name } }
    var inputCount: Int { lock.withLock { inputs } }

    func apply(_ action: GuiAction) {
        lock.withLock {
            inputs += 1
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
}

let formTarget = TargetIdentity(appId: "com.agentdesktop.neutral-form", processId: 4242, processStartId: "ps-1",
                                windowId: "win-1", windowGeometryRevision: 1, backendId: "stand-in",
                                windowFrameDesktopLogical: GuiRect(x: 0, y: 0, width: 500, height: 400))

actor FormObservation: GuiObservationPort {
    let form: NeutralForm
    private(set) var count = 0
    init(form: NeutralForm) { self.form = form }

    func observe(runId: String, expectedGeneration: UInt64) throws -> ObservationBundle {
        count += 1
        let shot = try ScreenshotDescriptor(screenshotId: "shot-\(count)", artifactRef: "art-\(count)",
                                            sha256: String(repeating: "b", count: 64), mimeType: "image/png",
                                            transformVersion: "t1", sourceToDesktop: .scale(0.5, 0.5),
                                            transform: .pipeline(sourceSize: Size(width: 1000, height: 800),
                                                                 resizedSize: Size(width: 500, height: 400)))
        let obs = Observation(observationId: "obs-\(count)",
                              stamp: ObservationStamp(sessionId: "sess-a", desktopId: "desk-a", snapshotId: "snap-\(count)",
                                                      bindingEpoch: 1, runGeneration: expectedGeneration),
                              target: formTarget, observedAt: Date(), screenshots: [shot])
        return ObservationBundle(observation: obs,
                                 authorizedImages: [AiImageContent(screenshotId: shot.screenshotId, mimeType: "image/png",
                                                                   bytes: Data(repeating: 7, count: 2048))],
                                 elements: [ObservedElement(role: "static_text", text: form.status),
                                            ObservedElement(role: "text_field", text: form.fieldText)])
    }
}

actor FormExecutor: GuiExecutionPort {
    enum Mode { case confirm, unknown, hang }
    let form: NeutralForm
    var mode: Mode = .confirm
    private(set) var executed = 0
    private var hung: CheckedContinuation<Void, Never>?
    init(form: NeutralForm) { self.form = form }

    func set(mode: Mode) { self.mode = mode }
    var isHanging: Bool { hung != nil }
    func release() { hung?.resume(); hung = nil }

    func execute(_ proposal: GuiProposal, actionId: String) async throws -> GuiActionReceipt {
        executed += 1
        guard case let .action(action) = proposal.body else { throw ContractError(.invalidAction, "not an action") }
        if mode == .hang { await withCheckedContinuation { hung = $0 } }
        form.apply(action)
        let t = Date()
        let state: DeliveryState = mode == .unknown ? .unknown : .confirmed
        return GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                                actionType: action.kind, deliveryState: state, executionTarget: formTarget,
                                inputPath: "stand-in.event", startedAt: t, endedAt: state == .confirmed ? t : nil,
                                evidenceRefs: state == .confirmed ? ["ev-\(actionId)"] : [],
                                createdAt: t, updatedAt: t,
                                confirmationObservationId: state == .confirmed ? "conf-\(actionId)" : nil, reasonCode: nil)
    }
}

actor NoAudit: GuiAuditPort {
    private var n = 0
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) {}
    func reserveAction(_ proposal: GuiProposal) -> String { n += 1; return "act-\(n)" }
    func recordAction(_ receipt: GuiActionReceipt) {}
}

/// A scripted Runtime for the run pages (A6): it starts unit Runs with the
/// service's executor and keeps each Run the way the Runtime writes it —
/// phase, outcome, closingReason, Run.unit, and events with the action.*
/// receipts beside the explorer's unit.* events. It is a stand-in: the real
/// Runtime is exercised in AgentDesktopRuntimeTests and the integration tests.
final class ScriptedRuntime: @unchecked Sendable {
    final class Run: UnitRunSink, @unchecked Sendable {
        let runId: String
        let lock = NSLock()
        var phase = "running"
        var outcome: String?
        var closingReason: String?
        var unknownActions = 0
        var verification: JSONValue = .obj([("status", .string("not_run"))])
        var events: [JSONValue] = []
        var stop: UnitRunStopHandle?
        var executorDone = false
        let profile: (String?, Int?)

        init(runId: String, profile: (String?, Int?)) { self.runId = runId; self.profile = profile }

        func append(_ type: String, _ data: JSONValue) {
            events.append(.obj([("runId", .string(runId)), ("sequence", .int(events.count + 1)),
                                ("at", .string(Timestamp.string(Date()))), ("type", .string(type)), ("data", data)]))
        }

        func record(_ type: String, _ data: JSONValue) -> Bool {
            lock.withLock {
                guard phase != "ended" else { return false }
                if type == "unit.action", let requestId = data["requestId"]?.stringValue {
                    let delivery = data["deliveryState"]?.stringValue ?? ""
                    append("action.accepted", .obj([("requestId", .string(requestId)), ("kind", .string("click"))]))
                    let receipt = JSONValue.obj([("requestId", .string(requestId)), ("snapshotId", .string("snap")),
                                                 ("delivery", .string(delivery == "not_sent" ? "not_dispatched" : "dispatched"))])
                    switch delivery {
                    case "confirmed": append("action.completed", .obj([("receipt", receipt)]))
                    case "unknown", "submitted": unknownActions += 1; append("action.unknown", .obj([("receipt", receipt)]))
                    default: append("action.failed", .obj([("receipt", receipt)]))
                    }
                }
                append(type, data)
                return true
            }
        }

        func verified(status: String, observationId: String?, checkedAt: Date) {
            lock.withLock {
                verification = .obj([("status", .string(status)), ("observationId", observationId.map(JSONValue.string) ?? .null),
                                     ("checkedAt", .string(Timestamp.string(checkedAt)))])
            }
        }

        func finished(_ ending: UnitRunEnding) {
            lock.withLock {
                executorDone = true
                switch ending {
                case .needsInput(let reason):
                    if phase == "running" { phase = "waiting_input"; append("unit.needs_input", .obj([("reason", .string(reason))])) }
                    else { end(outcome: "cancelled", reason: closingReason ?? "stopped") }
                case .verified: end(outcome: "success", reason: "goal_verified")
                case .failed(let reason): end(outcome: phase == "stopping" ? "cancelled" : "failed", reason: phase == "stopping" ? closingReason! : reason)
                case .cancelled: end(outcome: "cancelled", reason: closingReason ?? "stopped")
                }
            }
        }

        /// Under the lock.
        func end(outcome: String, reason: String) {
            phase = "ended"
            self.outcome = unknownActions > 0 ? "unknown" : outcome
            closingReason = closingReason ?? reason
            append("run.ended", .obj([("phase", .string("ended")), ("outcome", .string(self.outcome!)), ("reason", .string(closingReason!))]))
        }

        var json: JSONValue {
            lock.withLock {
                .obj([("runId", .string(runId)), ("kind", .string("unit")), ("origin", .string("gui_explorer")),
                      ("ownership", .string("platform")), ("lifetime", .string("platform_durable")),
                      ("desktopId", .string("desk-a")), ("sessionId", .string("sess-a")), ("phase", .string(phase)),
                      ("outcome", outcome.map(JSONValue.string) ?? .null), ("closingReason", closingReason.map(JSONValue.string) ?? .null),
                      ("createdAt", .string("2026-10-10T00:00:00Z")), ("unknownActions", .int(unknownActions)),
                      ("unit", .obj([("mode", .string("explore")), ("goalHash", .string("sha256:" + String(repeating: "0", count: 64))),
                                     ("guiProfileId", profile.0.map(JSONValue.string) ?? .null),
                                     ("guiProfileRevision", profile.1.map(JSONValue.int) ?? .null),
                                     ("verification", verification)]))])
            }
        }
    }

    private let lock = NSLock()
    private var runs: [String: Run] = [:]
    var units: UnitRunService?

    func run(_ id: String) -> Run? { lock.withLock { runs[id] } }

    func start(_ params: JSONValue) async -> Result<JSONValue, RuntimeError> {
        guard let units else {
            return .failure(RuntimeError("unsupported_backend", "off", phase: .handler, details: .obj([("reason", .string("gui_execution_off"))])))
        }
        if lock.withLock({ runs.values.contains { r in r.lock.withLock { r.phase != "ended" } } }) {
            return .failure(RuntimeError("control_busy", "desk-a is controlled", phase: .handler))
        }
        let plan: any UnitRunPlan
        switch await units.admit(params: params, callerScope: "owner") {
        case let .failure(e): return .failure(e)
        case let .success(p): plan = p
        }
        let r = Run(runId: "run_\(UUID().uuidString.prefix(8).lowercased())", profile: (plan.guiProfileId, plan.guiProfileRevision))
        lock.withLock { runs[r.runId] = r }
        let stop = UnitRunStopHandle()
        r.lock.withLock { r.stop = stop }
        units.start(plan, context: UnitRunContext(runId: r.runId, sessionId: "sess-a", desktopId: "desk-a", bindingEpoch: 1,
                                                  callerScope: "owner", params: params), sink: r, stop: stop)
        return .success(r.json)
    }

    func call(_ method: String, _ params: JSONValue) -> Result<JSONValue, RuntimeError> {
        guard let r = run(params["runId"]?.stringValue ?? "") else { return .failure(.notFound("no run")) }
        switch method {
        case "run.show": return .success(r.json)
        case "run.events":
            let after = params["after"]?.intValue ?? 0, limit = params["limit"]?.intValue ?? 100
            let page = r.lock.withLock { Array(r.events.dropFirst(after).prefix(limit)) }
            return .success(.obj([("events", .array(page)), ("next", .int(after + page.count)),
                                  ("ended", .bool(r.lock.withLock { r.phase == "ended" }))]))
        case "run.cancel":
            let stop: UnitRunStopHandle? = r.lock.withLock {
                guard r.phase != "ended", r.phase != "stopping" else { return nil }
                r.closingReason = "stopped"
                if r.executorDone { r.end(outcome: "cancelled", reason: "stopped"); return nil }
                r.phase = "stopping"
                r.append("stop.accepted", .obj([("reason", .string("stopped"))]))
                return r.stop
            }
            stop?.stop()
            let j = r.json
            return .success(.obj([("execution", .obj([("phase", j["phase"]!), ("outcome", j["outcome"]!)]))]))
        default: return .failure(.notFound("no method"))
        }
    }

    /// Inputs of these Runs, as the host answers ai.usage.summary.
    func outcomes(_ ids: [String]) -> (confirmed: Int, unknown: Int) {
        var c = 0, u = 0
        for id in ids {
            guard let r = run(id) else { continue }
            r.lock.withLock {
                c += r.events.filter { $0["type"]?.stringValue == "action.completed" }.count
                u += r.events.filter { $0["type"]?.stringValue == "action.unknown" }.count
            }
        }
        return (c, u)
    }

    var port: RuntimeRunsPort {
        RuntimeRunsPort(start: { await self.start($0) }, call: { m, p, _ in self.call(m, p) })
    }
}

final class ScriptedUpstream: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var runStep = 0
    var colorAnswer = SyntheticGuiFixture.colorAnswer
    var usageReported = true
    var delayMs = 0
    /// Run steps ask for a person instead (call_user).
    var callUser = false

    static let runReplies = [
        "Thought: focus the name field.\nAction: click(start_box='(500,250)')",
        "Thought: type the name.\nAction: type(content='Ada')",
        "Thought: apply.\nAction: click(start_box='(400,750)')",
        "Thought: the form shows the saved state.\nAction: finished(content='saved')",
    ]

    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let delay = lock.withLock { delayMs }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
        if request.url?.path.hasSuffix("/models") == true {
            return HTTPResult(status: 200, body: Data(#"{"object":"list","data":[{"id":"doubao-seed-2-1-lite-260915","object":"model"}]}"#.utf8))
        }
        let reply: String
        if body.contains(SyntheticGuiFixture.authPrompt) {
            reply = "OK"
        } else if body.contains(SyntheticGuiFixture.colorQuestion) {
            reply = lock.withLock { colorAnswer }
        } else if body.contains(SyntheticGuiFixture.guiTask) {
            reply = "Thought: the blue button.\nAction: click(start_box='(750,780)')"
        } else if body.contains("Ada"), lock.withLock({ callUser }) {
            reply = "Thought: a login prompt.\nAction: call_user(content='please log in')"
        } else if body.contains("Ada") {
            reply = lock.withLock {
                defer { runStep += 1 }
                return Self.runReplies[min(runStep, Self.runReplies.count - 1)]
            }
        } else {
            return HTTPResult(status: 400, body: Data(#"{"error":{"message":"unexpected prompt"}}"#.utf8))
        }
        var m: [(String, JSONValue)] = [
            ("id", .string("up-1")), ("model", .string("doubao-seed-2-1-lite-260915")),
            ("choices", .array([.obj([("index", .int(0)),
                                      ("message", .obj([("role", .string("assistant")), ("content", .string(reply))])),
                                      ("finish_reason", .string("stop"))])])),
        ]
        if lock.withLock({ usageReported }) {
            m.append(("usage", .obj([("prompt_tokens", .int(900)), ("completion_tokens", .int(20)), ("total_tokens", .int(920))])))
        }
        return HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: JSONValue.obj(m).encodedData())
    }
}

struct FastClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 2_000_000) }
}

/// The composed service behind an in-process ContractClient.
/// Counts and optionally fails calls on the way to the real client.
final class SpyClient: ContractClient, @unchecked Sendable {
    let inner: ContractClient
    private let lock = NSLock()
    private var calls: [String] = []
    private var failing: Set<String> = []
    init(_ inner: ContractClient) { self.inner = inner }
    func fail(_ command: String, _ on: Bool = true) { lock.withLock { if on { failing.insert(command) } else { failing.remove(command) } } }
    var commands: [String] { lock.withLock { calls } }
    func count(_ command: String) -> Int { commands.filter { $0 == command }.count }
    func guiCapabilities() async throws -> JSONValue {
        let fails = lock.withLock { calls.append("runtime.capabilities"); return failing.contains("runtime.capabilities") }
        if fails { throw ContractError(.upstreamUnavailable, "spy failure", retryable: true) }
        return try await inner.guiCapabilities()
    }
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        let fails = lock.withLock { calls.append(command); return failing.contains(command) }
        if fails { throw ContractError(.upstreamUnavailable, "service unreachable", retryable: true) }
        return try await inner.send(command, params, idempotencyKey: idempotencyKey)
    }
    func startUnitRun(_ params: JSONValue) async throws -> JSONValue {
        let fails = lock.withLock { calls.append("unit.run"); return failing.contains("unit.run") }
        if fails { throw ContractError(.upstreamUnavailable, "runtime unreachable", retryable: true) }
        return try await inner.startUnitRun(params)
    }
    func runtime(_ method: String, _ params: JSONValue, requestId: String?) async throws -> JSONValue {
        let fails = lock.withLock { calls.append(method); return failing.contains(method) }
        if fails { throw ContractError(.upstreamUnavailable, "runtime unreachable", retryable: true) }
        return try await inner.runtime(method, params, requestId: requestId)
    }
}

final class Harness: @unchecked Sendable {
    let dir: URL
    let form = NeutralForm()
    let upstream = ScriptedUpstream()
    let observation: FormObservation
    let executor: FormExecutor
    let service: AgentDesktopService
    let router: ServiceRouter
    let client: InProcessContractClient
    let runtime = ScriptedRuntime()

    init(backend: Bool = true) async throws {
        dir = URL(fileURLWithPath: "/tmp/adui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        observation = FormObservation(form: form)
        executor = FormExecutor(form: form)
        let be = GuiExecutionBackend(
            ports: GuiExplorerPorts(observation: observation, execution: executor, audit: NoAudit()),
            features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]))
        let runtime = runtime
        service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
            databasePath: dir.appendingPathComponent("config.sqlite").path,
            credentials: InMemoryCredentialStore(), http: upstream, executionBackend: backend ? be : nil,
            actionOutcomes: { ids, _, _ in runtime.outcomes(ids) }))
        runtime.units = service.units
        router = service.router(callerScope: "owner")
        let service = service
        client = InProcessContractClient(router: router, guiCapabilities: { service.guiCapabilities() }, runs: runtime.port)
    }

    /// Every String reachable from a model's stored properties, to prove
    /// a secret does not linger anywhere in it.
    static func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        if let s = value as? String { return [s] }
        if let v = value as? JSONValue { return [v.encoded()] }
        var out: [String] = []
        for child in Mirror(reflecting: value).children {
            out += strings(in: child.value, depth: depth + 1)
        }
        return out
    }
}
