import AgentDesktopProtocol
import CommonCrypto
import Foundation

// Lane UI-E (Explorer 页; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.
//
// What it models (A6, docs/ai-gui/a6-unit-run-draft.md; X1-1, X1-2):
// - Delegated unit Runs (what a connection's `unit.run` makes: agent_hub /
//   external_client / connection_scoped) for sample history, through
//   `addUnitRun(durable: false)`. `unit.run` itself is not offered on the
//   mock's wire: the main window never calls it, and the shared mock tests
//   keep it among the methods the mock does not model.
// - The main window's in-process entry, `startDurableUnitRun(params:)`, the
//   same shape as `RuntimeService.startDurableUnitRun`: a Durable Run
//   (gui_explorer / platform / platform_durable). It is not a runtime/1
//   method, so it never appears in `runtime.capabilities`.
// - The unit's own events (UnitRunEvent): ids, enums, codes and numbers
//   only; never a screenshot, typed text, goal or parameter value.
// Every Run and every unit event is checked against the contract.

/// What a mock unit Run goes through once it is started.
public enum MockExplorerScenario: String, CaseIterable, Sendable {
    /// Two inputs, four model attempts, a model `finish`, then the goal is
    /// matched on a new observation (P29).
    case verified
    /// The same input twice without change: one bounded recovery
    /// (repeated_action), then a further stall ends it with no_progress.
    case stalled
    /// The element read stays partial: verification inconclusive
    /// (elements_partial), until the steps run out.
    case inconclusive
    /// An input whose delivery is unknown: the Run ends unknown.
    case unknownAction
}

/// Lane UI-E's mock state (read and written with the MockRuntime's lock held).
final class MockExplorerLane: @unchecked Sendable {
    /// The events still to come per unit Run, one batch per step.
    var scripts: [String: [[(String, JSONValue)]]] = [:]
    /// How each unit Run ends once its script is done.
    var endings: [String: (outcome: String, reason: String, verification: String)] = [:]
    /// Calls of the in-process entry, in order (tests read it).
    var durableStarts: [JSONValue] = []
    /// False: the Runtime has no GUI executor (unsupported_backend).
    var guiExecution = true
    /// What the next started Run goes through.
    var nextScenario: MockExplorerScenario = .verified
    var units = 0
    /// Unit events this lane tried to record that broke UnitRunEvent.
    var violations: [String] = []
    init() {}
}

extension MockRuntime {
    /// Methods lane UI-E models (each must be in RuntimeCatalog.implemented).
    static let explorerLaneMethods: [String] = []

    /// Lane UI-E's answer to one of `explorerLaneMethods` (lock held).
    func explorerLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        throw RuntimeError.capabilityMissing("the mock does not model \(method)")
    }

    /// A connection's unit Run (Delegated), as `unit.run` on the wire makes
    /// it; for tests and sample history.
    public func startDelegatedUnitRun(params: JSONValue) -> Result<JSONValue, RuntimeError> {
        lock.withLock {
            let violations = contract.validate(params, "unit_run_params")
            guard violations.isEmpty else {
                return .failure(RuntimeError.schemaInvalid("params break unit_run_params", violations: violations))
            }
            return beginUnitRunLocked(params, durable: false)
        }
    }

    // MARK: In-process entry and scenario control

    /// The main window's in-process start (as `RuntimeService.startDurableUnitRun`):
    /// a Durable Run owned by the platform. The params are the wire's
    /// `unit_run_params`; origin / lifetime / ownership in them are refused.
    public func startDurableUnitRun(params: JSONValue) -> Result<JSONValue, RuntimeError> {
        lock.withLock {
            lanes.explorer.durableStarts.append(params)
            if _offline { return .failure(RuntimeError.runtimeOffline("mock runtime is offline", endpoint: "mock")) }
            let violations = contract.validate(params, "unit_run_params")
            guard violations.isEmpty else {
                return .failure(RuntimeError.schemaInvalid("params break unit_run_params", violations: violations))
            }
            return beginUnitRunLocked(params, durable: true)
        }
    }

    /// Params the in-process entry received, in order.
    public var durableStartCalls: [JSONValue] { lock.withLock { lanes.explorer.durableStarts } }

    /// Unit events that broke the contract (must stay empty).
    public var explorerContractViolations: [String] { lock.withLock { lanes.explorer.violations } }

    /// What the next started unit Run goes through.
    public var explorerScenario: MockExplorerScenario {
        get { lock.withLock { lanes.explorer.nextScenario } }
        set { lock.withLock { lanes.explorer.nextScenario = newValue } }
    }

    /// False: no GUI executor is registered (unit.run answers
    /// unsupported_backend / gui_execution_off).
    public var guiExecutionAvailable: Bool {
        get { lock.withLock { lanes.explorer.guiExecution } }
        set { lock.withLock { lanes.explorer.guiExecution = newValue } }
    }

    /// The executor takes `steps` more steps of a unit Run; after the last
    /// one the Run ends as its scenario says. A stopping Run only settles.
    public func advanceUnitRun(_ runId: String, steps: Int = 1) {
        lock.withLock {
            for _ in 0..<steps { advanceUnitRunLocked(runId) }
        }
    }

    /// Runs a unit Run to its end.
    public func finishUnitRun(_ runId: String) {
        lock.withLock {
            var guardSteps = 0
            while runs.first(where: { $0["runId"]?.stringValue == runId })?["phase"]?.stringValue != "ended", guardSteps < 64 {
                advanceUnitRunLocked(runId)
                guardSteps += 1
            }
        }
    }

    /// A unit Run for sample history: started Durable (main window) or
    /// Delegated (an external Agent), advanced `steps` steps, or to its end
    /// when `steps` is nil. Returns its runId.
    @discardableResult
    public func addUnitRun(desktopId: String, durable: Bool = true, scenario: MockExplorerScenario = .verified,
                           steps: Int? = nil, description: String = "在本地表单的名称中填写 Ada，点击 Apply，并确认保存结果。") -> String? {
        let previous = explorerScenario
        explorerScenario = scenario
        defer { explorerScenario = previous }
        let params = Self.sampleUnitParams(desktopId: desktopId, description: description)
        let started: Result<JSONValue, RuntimeError> = durable ? startDurableUnitRun(params: params)
            : startDelegatedUnitRun(params: params)
        guard case let .success(run) = started, let runId = run["runId"]?.stringValue else { return nil }
        if let steps { advanceUnitRun(runId, steps: steps) } else { finishUnitRun(runId) }
        return runId
    }

    /// Neutral unit_run_params (the local diagnostic form, no business app).
    public static func sampleUnitParams(desktopId: String, description: String = "在本地表单的名称中填写 Ada，点击 Apply，并确认保存结果。")
        -> JSONValue {
        .obj([
            ("desktopId", .string(desktopId)), ("mode", .string("auto")),
            ("goal", .obj([("description", .string(description))])),
            ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                                         ("text", .string("已保存：Ada / MAC-001-A / 提交次数 1"))])]))])),
            ("allowedActions", .array([.string("click"), .string("type"), .string("key")])),
            ("limits", .obj([("maxSteps", .int(20)), ("maxSeconds", .int(120))])),
        ])
    }

    /// The Explorer sample: the general sample plus unit Runs from the main
    /// window and from an external Agent, ended in each way, and one running.
    public static func explorerSample() -> MockRuntime {
        let m = MockRuntime.sample()
        let desks = m.lock.withLock { m.desktops.compactMap { $0["desktopId"]?.stringValue } }
        // The third Desktop (计算器) has no active Run: free for P27.
        let calc = desks[2]
        m.addUnitRun(desktopId: calc, scenario: .verified)
        m.addUnitRun(desktopId: calc, durable: false, scenario: .stalled)
        m.addUnitRun(desktopId: calc, scenario: .inconclusive)
        m.addUnitRun(desktopId: calc, durable: false, scenario: .unknownAction)
        return m
    }

    // MARK: Admission and script (lock held)

    /// F40-06 in the Runtime's order; every refusal comes before the Run.
    func beginUnitRunLocked(_ p: JSONValue, durable: Bool) -> Result<JSONValue, RuntimeError> {
        func refuse(_ code: String, _ message: String, _ reason: String? = nil, retryable: Bool = false,
                    details: [(String, JSONValue)] = []) -> Result<JSONValue, RuntimeError> {
            var d = details
            if let reason { d.insert(("reason", .string(reason)), at: 0) }
            return .failure(RuntimeError(code, message, phase: .handler, retryable: retryable, notSent: true,
                                         details: d.isEmpty ? nil : .obj(d)))
        }
        if ["origin", "lifetime", "ownership"].contains(where: { p[$0] != nil }) {
            return refuse("ownership_escalation_denied",
                          "origin, lifetime and ownership follow from who starts the Run", "ownership_from_params")
        }
        guard lanes.explorer.guiExecution else {
            return refuse("unsupported_backend", "real GUI input is off here", "gui_execution_off")
        }
        if admission != "enabled" { return refuse("input_disabled", "input is stopped for all Runs (runtime.stopAll)") }
        let desktopId = p["desktopId"]?.stringValue ?? ""
        guard let d = desktops.first(where: { $0["desktopId"]?.stringValue == desktopId }) else {
            return refuse("not_found", "no desktop \(desktopId)", "desktop_not_found")
        }
        if let holder = runs.first(where: { $0["desktopId"]?.stringValue == desktopId && $0["phase"]?.stringValue != "ended" }) {
            return refuse("control_busy", "desktop \(desktopId) is controlled by run \(holder["runId"]?.stringValue ?? "")",
                          retryable: true, details: [("desktopId", .string(desktopId)), ("holderRunId", holder["runId"]!)])
        }
        guard let b = d["binding"], !b.isNull else {
            return refuse("invalid_target", "desktop \(desktopId) has no bound window", "no_bound_window")
        }
        lanes.explorer.units += 1
        let runId = "run_" + String(format: "%03d", runs.count + 1)
        let origin = durable ? "gui_explorer" : "agent_hub"
        let unit: JSONValue = .obj([
            ("mode", p["mode"] ?? .string("auto")),
            ("goalHash", .string(Self.goalHash(p["goal"]?["description"]?.stringValue ?? ""))),
            ("guiProfileId", p["guiProfileId"] ?? .string("gp_default")),
            ("guiProfileRevision", p["expectedProfileRevision"] ?? .int(7)),
            ("verification", .obj([("status", .string("not_run"))])),
        ])
        let run: JSONValue = .obj([
            ("runId", .string(runId)), ("kind", .string("unit")), ("origin", .string(origin)),
            ("ownership", .string(durable ? "platform" : "external_client")),
            ("lifetime", .string(durable ? "platform_durable" : "connection_scoped")),
            ("clientId", durable ? .null : .string("app:mock-001")),
            ("connectionId", durable ? .null : .string("conn_\(runId)")),
            ("sessionId", .string("ses_\(runId)")), ("desktopId", .string(desktopId)),
            ("phase", .string("running")), ("outcome", .null), ("quiescence", .string("not_confirmed")),
            ("closingReason", .null), ("revision", .int(1)), ("createdAt", .string(stamp())),
            ("receipts", .array([])), ("unknownActions", .int(0)), ("unit", unit),
        ])
        let broken = contract.validate(run, "Run")
        guard broken.isEmpty else {
            return .failure(RuntimeError("internal_error", "mock unit Run breaks Run: \(broken.joined(separator: "; "))", phase: .handler))
        }
        runs.append(run)
        appendEventLocked(runId, "run.started", .obj([("kind", .string("unit")), ("origin", .string(origin)),
            ("ownership", .string(durable ? "platform" : "external_client")),
            ("lifetime", .string(durable ? "platform_durable" : "connection_scoped")),
            ("desktopId", .string(desktopId)), ("sessionId", .string("ses_\(runId)"))]))
        let maxSteps = p["limits"]?["maxSteps"]?.intValue ?? 20
        let maxSeconds = p["limits"]?["maxSeconds"]?.intValue ?? 120
        let (script, ending) = Self.script(lanes.explorer.nextScenario, unit: lanes.explorer.units,
                                           maxSteps: maxSteps, maxSeconds: maxSeconds)
        lanes.explorer.scripts[runId] = script
        lanes.explorer.endings[runId] = ending
        return .success(run)
    }

    /// One step of a unit Run: its next batch of events, or its ending.
    func advanceUnitRunLocked(_ runId: String) {
        guard let run = runs.first(where: { $0["runId"]?.stringValue == runId }), run["kind"]?.stringValue == "unit" else { return }
        switch run["phase"]?.stringValue {
        case "ended":
            return
        case "stopping":
            // The executor saw the stop: in-flight input is quiet; late
            // model proposals are dropped (nothing more is recorded).
            lanes.explorer.scripts[runId] = nil
            confirmQuiescenceLocked(runId, outcome: "cancelled")
            return
        default:
            break
        }
        var script = lanes.explorer.scripts[runId] ?? []
        guard !script.isEmpty else {
            let end = lanes.explorer.endings[runId] ?? (outcome: "failed", reason: "internal_error", verification: "not_run")
            updateRunLocked(runId) { r in
                r.setting("phase", .string("stopping")).setting("quiescence", .string("pending"))
                    .setting("closingReason", .string(end.reason))
            }
            appendEventLocked(runId, "run.finishing", .obj([("reason", .string(end.reason)), ("inFlight", .bool(false)),
                                                           ("revision", revisionLocked(runId))]))
            confirmQuiescenceLocked(runId, outcome: end.outcome)
            lanes.explorer.endings[runId] = nil
            return
        }
        let batch = script.removeFirst()
        lanes.explorer.scripts[runId] = script
        for (type, data) in batch { recordUnitEventLocked(runId, type, data) }
    }

    /// Records one unit event, with what it means for the Run record
    /// (verification on Run.unit; an action's request, receipt and unknowns).
    func recordUnitEventLocked(_ runId: String, _ type: String, _ raw: JSONValue) {
        var data = raw
        switch type {
        case "unit.action":
            let delivery = data["deliveryState"]?.stringValue ?? "unknown"
            let requestId = "req_" + String(format: "%03d", requests.count + 1)
            data = data.setting("requestId", .string(requestId))
            if let run = runs.first(where: { $0["runId"]?.stringValue == runId }), delivery != "rejected", delivery != "not_sent" {
                let wire = delivery == "unknown" ? ("unknown", "unknown") : delivery == "submitted" ? ("dispatched", "unknown") : ("dispatched", "completed")
                let accepted = stamp()
                let receipt = receiptJSON(run: run, requestId: requestId, delivery: wire.0, execution: wire.1, acceptedAt: accepted)
                requests[requestId] = .obj([
                    ("requestId", .string(requestId)), ("method", .string("act")),
                    ("state", .string(wire.1 == "completed" ? "completed" : "unknown")),
                    ("acceptedAt", .string(accepted)), ("finishedAt", .string(stamp())), ("outcome", receipt),
                ])
                updateRunLocked(runId) { r in
                    let ids = (r["receipts"]?.arrayValue ?? []) + [receipt["receiptId"]!]
                    let unknowns = (r["unknownActions"]?.intValue ?? 0) + (delivery == "unknown" ? 1 : 0)
                    return r.setting("receipts", .array(ids)).setting("unknownActions", .int(unknowns))
                }
            } else {
                requests[requestId] = .obj([
                    ("requestId", .string(requestId)), ("method", .string("act")), ("state", .string("failed")),
                    ("acceptedAt", .string(stamp())), ("finishedAt", .string(stamp())),
                    ("outcome", .obj([("error", RuntimeError("invalid_target", Self.mockMessage("invalid_target"), phase: .handler,
                                                            notSent: true).json)])),
                ])
            }
        case "unit.verification":
            let checked = stamp()
            data = data.setting("checkedAt", .string(checked))
            updateRunLocked(runId) { r in
                guard var unit = r["unit"] else { return r }
                unit = unit.setting("verification", .obj([("status", data["status"]!), ("observationId", data["observationId"]!),
                                                          ("checkedAt", .string(checked))]))
                return r.setting("unit", unit)
            }
        default:
            break
        }
        let broken = contract.validate(.obj([("runId", .string(runId)), ("sequence", .int(1)), ("at", .string(Timestamp.string(base))),
                                             ("type", .string(type)), ("data", data)]), "UnitRunEvent")
        if !broken.isEmpty { lanes.explorer.violations.append("\(type): \(broken.joined(separator: "; "))") }
        appendEventLocked(runId, type, data)
    }

    /// As `confirmQuiescence`, with the lock already held.
    func confirmQuiescenceLocked(_ runId: String, outcome: String) {
        updateRunLocked(runId) { r in
            r.setting("phase", .string("ended")).setting("quiescence", .string("confirmed"))
                .setting("outcome", .string((r["unknownActions"]?.intValue ?? 0) > 0 ? "unknown" : outcome))
                .setting("closingReason", r["closingReason"].flatMap { $0 == .null ? nil : $0 } ?? .string("stopped"))
                .setting("endedAt", .string(stamp()))
        }
        let ended = runs.first(where: { $0["runId"]?.stringValue == runId })
        appendEventLocked(runId, "run.quiescent", .obj([("revision", ended?["revision"] ?? .int(1))]))
        appendEventLocked(runId, "run.ended", .obj([("phase", .string("ended")), ("outcome", ended?["outcome"] ?? .string(outcome)),
                                                   ("reason", ended?["closingReason"] ?? .string("stopped"))]))
    }

    /// `sha256:` of the goal description, as UnitRun.goalHash (no params).
    static func goalHash(_ description: String) -> String {
        let data = Data(description.utf8)
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return "sha256:" + digest.map { String(format: "%02x", $0) }.joined()
    }

    /// The scripted steps of a scenario and how it ends. `checkedAt` and an
    /// action's `requestId` are filled in when the event is recorded.
    static func script(_ s: MockExplorerScenario, unit n: Int, maxSteps: Int, maxSeconds: Int)
        -> ([[(String, JSONValue)]], (outcome: String, reason: String, verification: String)) {
        var obs = 0
        var steps: [[(String, JSONValue)]] = []
        func observation() -> (String, JSONValue) {
            obs += 1
            return ("unit.observation", .obj([("observationId", .string("obs_u\(n)_\(obs)"))]))
        }
        func verify(_ status: String, _ reason: String? = nil) -> (String, JSONValue) {
            var m: [(String, JSONValue)] = [("status", .string(status)), ("verifierId", .string("goal")),
                                            ("observationId", .string("obs_u\(n)_\(obs)")), ("checkedAt", .string("1970-01-01T00:00:00Z"))]
            if let reason { m.append(("reason", .string(reason))) }
            return ("unit.verification", .obj(m))
        }
        func progress(_ i: Int, attemptsUsed: Int) -> (String, JSONValue) {
            ("unit.progress", .obj([("stepIndex", .int(i)), ("stepsLeft", .int(max(0, maxSteps - i))),
                                    ("attemptsLeft", .int(max(0, 30 - attemptsUsed))), ("secondsLeft", .int(max(0, maxSeconds - i * 16)))]))
        }
        func attempt(_ i: Int, _ count: Int) -> (String, JSONValue) {
            ("unit.inference.attempt", .obj([("stepIndex", .int(i)), ("inferenceAttemptId", .string("inf_u\(n)_\(i)")),
                                             ("attempts", .int(count)), ("state", .string("succeeded")),
                                             ("discarded", .bool(false)), ("errorCode", .null)]))
        }
        func propose(_ i: Int, _ kind: String, _ action: String? = nil) -> (String, JSONValue) {
            var m: [(String, JSONValue)] = [("stepIndex", .int(i)), ("proposalId", .string("prop_u\(n)_\(i)")),
                                            ("inferenceAttemptId", .string("inf_u\(n)_\(i)")), ("kind", .string(kind))]
            if let action { m.append(("actionKind", .string(action))) }
            return ("unit.step.proposed", .obj(m))
        }
        func act(_ i: Int, _ delivery: String) -> (String, JSONValue) {
            ("unit.action", .obj([("stepIndex", .int(i)), ("actionId", .string("act_u\(n)_\(i)")),
                                  ("proposalId", .string("prop_u\(n)_\(i)")), ("requestId", .string("req_pending")),
                                  ("deliveryState", .string(delivery))]))
        }
        // Step 0 always starts with an observation and the check whether the
        // goal already holds.
        switch s {
        case .verified:
            steps.append([progress(0, attemptsUsed: 0), observation(), verify("contradicted"), attempt(0, 2),
                          propose(0, "action", "click"), act(0, "confirmed")])
            steps.append([observation(), verify("contradicted"), progress(1, attemptsUsed: 2), attempt(1, 1),
                          propose(1, "action", "type"), act(1, "confirmed")])
            steps.append([observation(), verify("contradicted"), progress(2, attemptsUsed: 3), attempt(2, 1), propose(2, "finish")])
            steps.append([observation(), verify("matched")])
            return (steps, ("success", "goal_verified", "matched"))
        case .stalled:
            steps.append([progress(0, attemptsUsed: 0), observation(), verify("contradicted"), attempt(0, 1),
                          propose(0, "action", "click"), act(0, "confirmed")])
            steps.append([observation(), verify("contradicted"), progress(1, attemptsUsed: 1), attempt(1, 1),
                          propose(1, "action", "click"), act(1, "confirmed")])
            steps.append([observation(), verify("contradicted"),
                          ("unit.recovery", .obj([("stepIndex", .int(2)), ("kind", .string("repeated_action")), ("count", .int(1))])),
                          observation(), verify("contradicted")])
            steps.append([progress(2, attemptsUsed: 2), attempt(2, 1), propose(2, "action", "click"), act(2, "confirmed")])
            steps.append([observation(), verify("contradicted"), progress(3, attemptsUsed: 3), attempt(3, 1),
                          propose(3, "action", "click"), act(3, "confirmed"), observation(), verify("contradicted")])
            return (steps, ("failed", "no_progress", "contradicted"))
        case .inconclusive:
            steps.append([progress(0, attemptsUsed: 0), observation(), verify("inconclusive", "elements_partial"), attempt(0, 1),
                          propose(0, "action", "click"), act(0, "confirmed")])
            steps.append([observation(), verify("inconclusive", "elements_partial"), progress(1, attemptsUsed: 1), attempt(1, 1),
                          propose(1, "finish")])
            steps.append([observation(), verify("inconclusive", "elements_partial"), progress(2, attemptsUsed: 2), attempt(2, 1),
                          ("unit.step.rejected", .obj([("stepIndex", .int(2)), ("reason", .string("stale_observation"))]))])
            return (steps, ("failed", "deadline_exceeded", "inconclusive"))
        case .unknownAction:
            steps.append([progress(0, attemptsUsed: 0), observation(), verify("contradicted"), attempt(0, 1),
                          propose(0, "action", "type"), act(0, "unknown")])
            return (steps, ("failed", "action_outcome_unknown", "contradicted"))
        }
    }
}
