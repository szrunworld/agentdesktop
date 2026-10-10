import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A6: unit.run on the RunStore, with a scripted executor. The handler waits
// for the executor's admission off the cooperative pool, as the server's
// threads do; these tests call it from a dispatch thread for the same reason.

final class FakeUnitExecutor: UnitRunExecutor, @unchecked Sendable {
    struct Plan: UnitRunPlan {
        var guiProfileId: String? = "gp_1"
        var guiProfileRevision: Int? = 3
    }

    private let lock = NSLock()
    var refusal: RuntimeError?
    private(set) var admitted: [JSONValue] = []
    private(set) var contexts: [UnitRunContext] = []
    private(set) var sinks: [UnitRunSink] = []
    private(set) var stops = 0
    /// Runs on start, with the context and sink (drive the Run from here).
    var onStart: (@Sendable (UnitRunContext, UnitRunSink) -> Void)?

    /// Runs inside admit (a slow profile read).
    var duringAdmit: (@Sendable () async -> Void)?

    func admit(params: JSONValue, callerScope: String) async -> Result<any UnitRunPlan, RuntimeError> {
        lock.withLock { admitted.append(params) }
        await duringAdmit?()
        if let refusal { return .failure(refusal) }
        return .success(Plan())
    }

    func start(_ plan: any UnitRunPlan, context: UnitRunContext, sink: UnitRunSink, stop: UnitRunStopHandle) {
        lock.withLock { contexts.append(context); sinks.append(sink); handles.append(stop) }
        stop.arm { [weak self] in self?.lock.withLock { self?.stops += 1 } }
        onStart?(context, sink)
    }
    private(set) var handles: [UnitRunStopHandle] = []

    var lastSink: UnitRunSink? { lock.withLock { sinks.last } }
    var lastContext: UnitRunContext? { lock.withLock { contexts.last } }
    var stopCount: Int { lock.withLock { stops } }
    var admitCount: Int { lock.withLock { admitted.count } }
}

/// Answer off the cooperative pool.
func offPool(_ s: RuntimeService, _ c: ConnectionState, _ method: String, id: String = RuntimeRequest.newId(),
             params: String = "{}", context: String? = nil) async -> RuntimeResponse {
    await withCheckedContinuation { cont in
        DispatchQueue.global().async { cont.resume(returning: call(s, c, method, id: id, params: params, context: context)) }
    }
}

func unitParams(_ desktopId: String, extra: String = "") -> String {
    #"{"desktopId":"\#(desktopId)","mode":"explore","goal":{"description":"Open the report","params":{"name":"Ada"}},"verification":{"all":[{"kind":"element_text_equals","role":"static_text","text":"Done"}]},"allowedActions":["click","wait"]\#(extra)}"#
}

func unitScene(executor: FakeUnitExecutor? = FakeUnitExecutor()) throws -> (FakePlatform, RuntimeService, ConnectionState, String, RuntimeGuiPorts) {
    let platform = FakePlatform()
    platform.realImages = true
    let s = platformService(platform)
    let c = handshaken(s)
    let d = try created(s, c)
    _ = call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101}"#)
    let ports = RuntimeGuiPorts(service: s)
    if let executor { s.registerUnitExecutor(executor, ports: ports) }
    return (platform, s, c, d, ports)
}

/// A Durable unit Run on `d` for the GUI ports to observe and act in (A6),
/// driven by a scripted executor that does nothing on its own.
func guiRun(_ s: RuntimeService, _ ports: RuntimeGuiPorts, _ d: String) async throws -> String {
    s.registerUnitExecutor(FakeUnitExecutor(), ports: ports)
    let params = try StrictJSON.parse(unitParams(d))
    let r: Result<JSONValue, RuntimeError> = await withCheckedContinuation { cont in
        DispatchQueue.global().async { cont.resume(returning: s.startDurableUnitRun(params: params)) }
    }
    return try #require(try r.get()["runId"]?.stringValue)
}

func runCount(_ s: RuntimeService, _ c: ConnectionState) -> Int {
    data(call(s, c, "run.list"))?["runs"]?.arrayValue?.count ?? -1
}

func eventTypes(_ s: RuntimeService, _ runId: String) -> [String] {
    s.runs.events(runId, after: 0, limit: 1000).compactMap { $0["type"]?.stringValue }
}

@Test func withoutAnExecutorUnitRunIsOffAndUnlisted() async throws {
    let (_, s, c, d, _) = try unitScene(executor: nil)
    let caps = try #require(data(call(s, c, "runtime.capabilities")))
    #expect(caps["interface"]?["methods"]?.arrayValue?.contains { $0["method"]?.stringValue == "unit.run" } == false)
    let r = await offPool(s, c, "unit.run", params: unitParams(d))
    guard case let .failure(e) = r.result else { Issue.record("must refuse"); return }
    #expect(e.code == "unsupported_backend" && e.details?["reason"]?.stringValue == "gui_execution_off")
    #expect(runCount(s, c) == 0)
}

@Test func withAnExecutorUnitRunIsListed() throws {
    let (_, s, c, _, _) = try unitScene()
    let caps = try #require(data(call(s, c, "runtime.capabilities")))
    let entry = caps["interface"]?["methods"]?.arrayValue?.first { $0["method"]?.stringValue == "unit.run" }
    #expect(entry?["mutation"]?.boolValue == true)
}

@Test func escalationFieldsAreRefusedBeforeAnyRunAndReplayed() async throws {
    let (_, s, c, d, _) = try unitScene()
    for (k, v) in [("origin", "gui_explorer"), ("lifetime", "platform_durable"), ("ownership", "platform")] {
        let id = "esc-\(k)"
        let r = await offPool(s, c, "unit.run", id: id, params: unitParams(d, extra: #","\#(k)":"\#(v)""#))
        guard case let .failure(e) = r.result else { Issue.record("\(k) must be refused"); continue }
        #expect(e.code == "ownership_escalation_denied" && e.details?["reason"]?.stringValue == "ownership_from_params")
        #expect(e.notSent == true)
        // The ledger replays the refusal for the same requestId.
        let again = await offPool(s, c, "unit.run", id: id, params: unitParams(d, extra: #","\#(k)":"\#(v)""#))
        #expect(code(again) == "ownership_escalation_denied")
    }
    #expect(runCount(s, c) == 0)
}

@Test func aWireUnitRunIsDelegatedAndEndsVerified() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let r = await offPool(s, c, "unit.run", id: "unit-1", params: unitParams(d))
    let run = try #require(data(r))
    #expect(contract.validate(run, "Run").isEmpty, "\(run.encoded())")
    #expect(run["kind"]?.stringValue == "unit" && run["origin"]?.stringValue == "agent_hub")
    #expect(run["ownership"]?.stringValue == "external_client" && run["lifetime"]?.stringValue == "connection_scoped")
    #expect(run["clientId"]?.stringValue == c.clientId && run["connectionId"]?.stringValue == c.connectionId)
    #expect(run["unit"]?["goalHash"]?.stringValue == UnitRun.goalHash("Open the report"))
    #expect(run["unit"]?["guiProfileId"]?.stringValue == "gp_1" && run["unit"]?["guiProfileRevision"]?.intValue == 3)
    #expect(run["unit"]?["verification"]?["status"]?.stringValue == "not_run")
    let runId = try #require(run["runId"]?.stringValue)
    let ctx = try #require(executor.lastContext)
    #expect(ctx.runId == runId && ctx.desktopId == d && ctx.callerScope == "uid:\(getuid())")
    #expect(ctx.sessionId == run["sessionId"]?.stringValue)

    // The same requestId is the same Run, never a second one.
    let again = try #require(data(await offPool(s, c, "unit.run", id: "unit-1", params: unitParams(d))))
    #expect(again["runId"]?.stringValue == runId)
    #expect(executor.admitCount == 1)

    let sink = try #require(executor.lastSink)
    #expect(sink.record("unit.observation", .obj([("observationId", .string("obs_1"))])))
    #expect(!sink.record("action.completed", .obj([])), "only unit.* events")
    let at = Date()
    sink.verified(status: "matched", observationId: "obs_1", checkedAt: at)
    sink.finished(.verified)
    sink.finished(.failed(reason: "late"))  // once only

    let ended = try #require(s.runs.find(runId))
    #expect(ended.phase == .ended && ended.outcome == .success && ended.closingReason == "goal_verified")
    #expect(ended.unit?.verification == .matched && ended.unit?.observationId == "obs_1")
    #expect(contract.validate(ended.json, "Run").isEmpty, "\(ended.json.encoded())")
    #expect(eventTypes(s, runId) == ["run.started", "unit.observation", "run.finishing", "run.quiescent", "run.ended"])
    for e in s.runs.events(runId, after: 0, limit: 100) where e["type"]?.stringValue?.hasPrefix("unit.") == true {
        #expect(contract.validate(e, "UnitRunEvent").isEmpty, "\(e.encoded())")
    }
    // Nothing more is written once it ended; its session closed with it.
    #expect(!sink.record("unit.observation", .obj([("observationId", .string("obs_2"))])))
    #expect(s.sessions.find(ctx.sessionId, caller: c.clientId)?.state == "closed")
    #expect(s.execution.holder(of: d) == nil)
}

@Test func admissionRefusalsComeInOrderAndCreateNoRun() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    // 5. No such Desktop.
    let missing = await offPool(s, c, "unit.run", params: unitParams("d_missing"))
    if case let .failure(e) = missing.result { #expect(e.code == "not_found" && e.details?["reason"]?.stringValue == "desktop_not_found") }
    else { Issue.record("a missing Desktop must be refused") }
    // No bound window.
    let bare = try created(s, c)
    let unbound = await offPool(s, c, "unit.run", params: unitParams(bare))
    if case let .failure(e) = unbound.result { #expect(e.code == "invalid_target" && e.details?["reason"]?.stringValue == "no_bound_window") }
    else { Issue.record("a Desktop without a bound window must be refused") }
    // 7–15: the executor's refusal goes out as it is.
    executor.refusal = RuntimeError("conflict", "the GUI profile changed", phase: .handler, notSent: true,
                                    details: .obj([("reason", .string("profile_revision_changed"))]))
    let changed = await offPool(s, c, "unit.run", params: unitParams(d))
    if case let .failure(e) = changed.result { #expect(e.code == "conflict" && e.details?["reason"]?.stringValue == "profile_revision_changed") }
    else { Issue.record("the executor's refusal must stand") }
    #expect(runCount(s, c) == 0)
    executor.refusal = nil

    // 6. A second unit Run on the same Desktop: control_busy.
    #expect(data(await offPool(s, c, "unit.run", params: unitParams(d))) != nil)
    let busy = await offPool(s, c, "unit.run", params: unitParams(d))
    #expect(code(busy) == "control_busy")
    // 4. Input stopped.
    #expect(data(call(s, c, "runtime.stopAll", params: #"{"scope":"all_platform_runs"}"#)) != nil)
    let stopped = await offPool(s, c, "unit.run", params: unitParams(d))
    #expect(code(stopped) == "input_disabled")
    #expect(runCount(s, c) == 1)
}

@Test func cancelReachesTheExecutorAndEndsOnceItReportsBack() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let runId = try #require(data(await offPool(s, c, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    let receipt = try #require(data(call(s, c, "run.cancel", params: #"{"runId":"\#(runId)"}"#)))
    #expect(receipt["execution"]?["phase"]?.stringValue == "stopping")
    #expect(executor.stopCount == 1)
    // Still stopping: the executor has not reported yet; its events still land.
    #expect(s.runs.find(runId)?.phase == .stopping)
    let sink = try #require(executor.lastSink)
    #expect(sink.record("unit.progress", .obj([("stepIndex", .int(1)), ("stepsLeft", .int(2)), ("attemptsLeft", .int(3)),
                                               ("secondsLeft", .int(4))])))
    sink.finished(.failed(reason: "stale_observation"))
    let ended = try #require(s.runs.find(runId))
    #expect(ended.outcome == .cancelled && ended.closingReason == "stopped")
    #expect(eventTypes(s, runId) == ["run.started", "stop.accepted", "unit.progress", "run.quiescent", "run.ended"])
}

@Test func losingTheControlConnectionStopsTheUnitRun() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let runId = try #require(data(await offPool(s, c, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    s.connectionClosed(c)
    #expect(executor.stopCount == 1)
    executor.lastSink?.finished(.cancelled)
    let ended = try #require(s.runs.find(runId))
    #expect(ended.phase == .ended && ended.outcome == .cancelled && ended.closingReason == "owner_lost")
}

// Codex on 8bcb18c: the control connection goes away while the executor
// admits. The Run that admission then creates is never driven: it ends at
// once as owner_lost, and its Desktop is free again.
@Test func aConnectionLostDuringAdmissionLeavesNoDrivenRun() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    executor.duringAdmit = { s.connectionClosed(c) }
    let r = await offPool(s, c, "unit.run", params: unitParams(d))
    let runId = try #require(data(r)?["runId"]?.stringValue)
    #expect(executor.contexts.isEmpty, "the executor never started it")
    let ended = try #require(s.runs.find(runId))
    #expect(ended.phase == .ended && ended.outcome == .cancelled && ended.closingReason == "owner_lost")
    #expect(s.execution.holder(of: d) == nil)
    #expect(s.sessions.find(ended.sessionId, caller: c.clientId)?.state == "closed")
}

@Test func needsInputWaitsWithoutInputUntilStopped() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let runId = try #require(data(await offPool(s, c, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    executor.lastSink?.finished(.needsInput(reason: "login_required"))
    let waiting = try #require(s.runs.find(runId))
    #expect(waiting.phase == .waitingInput && waiting.outcome == nil)
    #expect(s.execution.beginAction(runId: runId)?.code == "run_not_active")
    #expect(eventTypes(s, runId).last == "unit.needs_input")
    _ = call(s, c, "run.cancel", params: #"{"runId":"\#(runId)"}"#)
    let ended = try #require(s.runs.find(runId))
    #expect(ended.phase == .ended && ended.outcome == .cancelled)
    #expect(s.execution.holder(of: d) == nil)
}

@Test func theExecutorsInputGoesIntoTheUnitRun() async throws {
    let executor = FakeUnitExecutor()
    let (platform, s, c, d, ports) = try unitScene(executor: executor)
    let runId = try #require(data(await offPool(s, c, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    let ctx = try #require(executor.lastContext)
    let bundle = try await ports.observe(runId: runId, expectedGeneration: 1)
    #expect(bundle.observation.stamp.sessionId == ctx.sessionId && bundle.observation.stamp.bindingEpoch == ctx.bindingEpoch)
    let shot = bundle.observation.screenshots[0].screenshotId
    let p = proposal(.action(.click(sourcePixel: Point(x: 100, y: 100))), run: runId, stamp: bundle.observation.stamp, shot: shot)
    let r = try await ports.execute(p, actionId: "act-1")
    #expect(r.deliveryState == .confirmed && platform.performed.count == 1)
    // One Run: the action is the unit Run's, with its receipt.
    #expect(runCount(s, c) == 1)
    let types = eventTypes(s, runId)
    #expect(types.contains("action.accepted") && types.contains("action.dispatched") && types.contains("action.completed"))
    #expect(s.runs.find(runId)?.receipts.count == 1)

    // An unknown delivery makes the Run's outcome unknown, whatever the
    // executor reports.
    let again = try await ports.observe(runId: runId, expectedGeneration: 1)
    platform.failNext = PlatformError(.refused, "the app stopped answering", beforeDispatch: false)
    let q = proposal(.action(.click(sourcePixel: Point(x: 120, y: 120))), run: runId, stamp: again.observation.stamp,
                     shot: again.observation.screenshots[0].screenshotId)
    #expect(try await ports.execute(q, actionId: "act-2").deliveryState == .unknown)
    executor.lastSink?.finished(.failed(reason: "action_outcome_unknown"))
    let ended = try #require(s.runs.find(runId))
    #expect(ended.outcome == .unknown && ended.unknownActions == 1)
    // After the Run ended its ports are gone: no further input.
    await #expect(throws: ContractError.self) { _ = try await ports.observe(runId: runId, expectedGeneration: 1) }
}

@Test func aPairedClientNeedsTheUnitRunGrantAndTheDesktop() async throws {
    let (_, s, owner, d, _) = try unitScene()
    _ = owner
    let (noCap, _) = try pairedConnection(s, capabilities: ["observe", "act", "run"], desktops: [d])
    let r1 = await offPool(s, noCap, "unit.run", params: unitParams(d))
    #expect(code(r1) == "grant_missing")
    let (noDesk, _) = try pairedConnection(s, capabilities: ["observe", "act", "unit.run"], desktops: [], name: "other")
    let r2 = await offPool(s, noDesk, "unit.run", params: unitParams(d))
    #expect(code(r2) != nil && data(r2) == nil)
    // Granted the Desktop but not its bound window: the window grant decides.
    let (noWindow, _) = try pairedConnection(s, capabilities: ["observe", "act", "unit.run"], desktops: [d], name: "third")
    let r3 = await offPool(s, noWindow, "unit.run", params: unitParams(d))
    #expect(code(r3) == "grant_missing")
    #expect(s.runs.list(RunStore.ListFilter(), after: nil, limit: 10).runs.isEmpty)
}

@Test func theMainWindowStartsDurableUnitRuns() async throws {
    let executor = FakeUnitExecutor()
    let (_, s, c, d, _) = try unitScene(executor: executor)
    let params = try StrictJSON.parse(unitParams(d))
    let r: Result<JSONValue, RuntimeError> = await withCheckedContinuation { cont in
        DispatchQueue.global().async { cont.resume(returning: s.startDurableUnitRun(params: params)) }
    }
    let run = try r.get()
    #expect(run["origin"]?.stringValue == "gui_explorer" && run["ownership"]?.stringValue == "platform")
    #expect(run["lifetime"]?.stringValue == "platform_durable" && run["clientId"] == .null)
    let runId = try #require(run["runId"]?.stringValue)
    // No connection ends it.
    s.connectionClosed(c)
    #expect(executor.stopCount == 0 && s.runs.find(runId)?.phase == .running)
    // Escalation fields are refused here too.
    let esc = try StrictJSON.parse(unitParams(d, extra: #","origin":"gui_explorer""#))
    if case let .failure(e) = s.startDurableUnitRun(params: esc) { #expect(e.code == "ownership_escalation_denied") }
    else { Issue.record("escalation fields must be refused") }
}

// Codex on 70f4a4e: usage counts a unit Run's inputs from outcomes the
// RunStore keeps past its Runs' retention, and counts an input a restart
// lost as unknown (no action.unknown event is made up for it).
@Test func actionOutcomesOutliveRetentionAndCountRestartLosses() throws {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 1_791_000_000) }
    let clock = Clock()
    let dir = NSTemporaryDirectory() + "adt-outcomes-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runs.sqlite"
    func record(_ id: String) -> RunRecord {
        RunRecord(runId: id, kind: "unit", origin: .agentHub, ownership: .externalClient, lifetime: .connectionScoped,
                  clientId: "local:1", connectionId: "conn_1", sessionId: "s_1", desktopId: "d_1", phase: .running, outcome: nil,
                  quiescence: .notConfirmed, closingReason: nil, revision: 1, createdAt: Timestamp.string(clock.now), endedAt: nil,
                  receipts: [], unknownActions: 0)
    }
    func receipt(_ requestId: String) -> JSONValue { .obj([("receipt", .obj([("requestId", .string(requestId))]))]) }
    do {
        let store = try RunStore(path: path, now: { clock.now })
        store.create(record("run_a"))
        store.appendEvent("run_a", "action.dispatched", .obj([("requestId", .string("r1"))]))
        store.appendEvent("run_a", "action.completed", receipt("r1"))
        store.appendEvent("run_a", "action.dispatched", .obj([("requestId", .string("r2"))]))
        store.appendEvent("run_a", "action.unknown", receipt("r2"))
        store.appendEvent("run_a", "action.dispatched", .obj([("requestId", .string("r3"))]))
        store.appendEvent("run_a", "action.failed", receipt("r3"))
        var ended = record("run_a")
        ended.phase = .ended; ended.quiescence = .confirmed; ended.outcome = .unknown; ended.endedAt = Timestamp.string(clock.now)
        store.update(ended)
        // A second Run whose input was out when the host went away.
        store.create(record("run_b"))
        store.appendEvent("run_b", "action.dispatched", .obj([("requestId", .string("r4"))]))
        let all = store.actionOutcomes(runIds: ["run_a", "run_b"], from: .distantPast, to: .distantFuture)
        #expect(all.confirmed == 1 && all.unknown == 1, "a failed input is neither")
        #expect(store.actionOutcomes(runIds: ["run_a"], from: clock.now.addingTimeInterval(1), to: .distantFuture) == (0, 0))
    }
    // Eight days later, after a restart: the Runs are gone, their outcomes
    // stay, and run_b's lost input counts as unknown.
    clock.now = clock.now.addingTimeInterval(8 * 86400)
    let reopened = try RunStore(path: path, now: { clock.now })
    #expect(reopened.find("run_a") == nil, "retention removed the ended Run")
    let after = reopened.actionOutcomes(runIds: ["run_a", "run_b"], from: .distantPast, to: .distantFuture)
    #expect(after.confirmed == 1 && after.unknown == 2, "run_b's lost input counts, as of the restart")
}

/// A paired app with unit.run on its own Desktop, the Calculator window
/// bound under a window grant to observe and act.
func pairedUnitScene(_ capabilities: [String]) throws -> (RuntimeService, owner: ConnectionState, app: ConnectionState, clientId: String,
                                                          desk: String, FakeUnitExecutor) {
    let platform = FakePlatform()
    platform.realImages = true
    let s = platformService(platform)
    let owner = handshaken(s)
    let (c, id, _) = try pairedClient(s, capabilities: capabilities + ["desktop.manage"], desktops: ["created"],
                                      apps: ["com.apple.calculator"], name: "unit-agent")
    let d = try created(s, c)
    _ = try grantWindow(s, clientId: id, desktopId: d, permissions: ["observe", "act"])
    #expect(data(call(s, c, "window.bind", params: #"{"desktopId":"\#(d)","pid":101,"windowId":11}"#)) != nil)
    let executor = FakeUnitExecutor()
    s.registerUnitExecutor(executor, ports: RuntimeGuiPorts(service: s))
    return (s, owner, c, id, d, executor)
}

// Codex on 49111eb: the owner revokes the app while its unit.run is being
// admitted. No Run is created and nothing is started.
@Test func aRevocationDuringAdmissionCreatesNoRun() async throws {
    let (s, owner, app, id, d, executor) = try pairedUnitScene(["observe", "act", "unit.run"])
    executor.duringAdmit = { _ = call(s, owner, "hub.grants.revoke", params: #"{"clientId":"\#(id)"}"#) }
    let r = await offPool(s, app, "unit.run", params: unitParams(d))
    #expect(data(r) == nil, "\(r.json.encoded())")
    #expect(executor.contexts.isEmpty)
    #expect(s.runs.list(RunStore.ListFilter(), after: nil, limit: 10).runs.isEmpty)
}

// Codex on 49111eb: a grant change stops a unit Run when unit.run is taken
// away, and leaves it alone when only run is.
@Test func grantChangesStopUnitRunsByTheirOwnCapability() async throws {
    let (s, owner, app, id, d, executor) = try pairedUnitScene(["observe", "act", "run", "unit.run"])
    let runId = try #require(data(await offPool(s, app, "unit.run", params: unitParams(d)))?["runId"]?.stringValue)
    func setGrant(_ caps: [String]) {
        let list = (caps + ["desktop.manage"]).map { "\"\($0)\"" }.joined(separator: ",")
        let p = #"{"clientId":"\#(id)","capabilities":[\#(list)],"desktops":["created"],"apps":["com.apple.calculator"]}"#
        #expect(data(call(s, owner, "hub.grants.set", params: p)) != nil)
    }
    setGrant(["observe", "act", "unit.run"])
    #expect(s.runs.find(runId)?.phase == .running && executor.stopCount == 0, "run alone was taken away")
    setGrant(["observe", "act", "run"])
    #expect(executor.stopCount == 1, "unit.run was taken away")
    executor.lastSink?.finished(.cancelled)
    #expect(s.runs.find(runId)?.closingReason == "grant_narrowed")
}
