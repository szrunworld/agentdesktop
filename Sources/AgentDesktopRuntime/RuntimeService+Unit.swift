import AgentDesktopProtocol
import Foundation

/// A6 (PR2d): `unit.run` on the RunStore. The Runtime admits the Run, owns
/// its lifecycle and records it; the GUI executor the host registers drives
/// it through the Runtime's own observe and act, as the Run's principal and
/// inside the Run (runtime-api-v1-freeze §3, a6-unit-run-draft.md).
final class UnitRunRegistry: @unchecked Sendable {
    struct Entry {
        let stop: UnitRunStopHandle
        let sessionId: String
    }

    private let lock = NSLock()
    private var executor: UnitRunExecutor?
    private var ports: RuntimeGuiPorts?
    private var live: [String: Entry] = [:]
    /// Stops accepted for Runs whose entry did not exist yet.
    private var stoppedEarly: Set<String> = []

    func register(_ executor: UnitRunExecutor, ports: RuntimeGuiPorts) {
        lock.withLock { self.executor = executor; self.ports = ports }
    }

    var current: (executor: UnitRunExecutor, ports: RuntimeGuiPorts)? {
        lock.withLock { executor.flatMap { e in ports.map { (e, $0) } } }
    }

    /// The Run's stop handle, created before its executor starts; already
    /// fired when a stop came first.
    func track(_ runId: String, sessionId: String) -> UnitRunStopHandle {
        let handle = UnitRunStopHandle()
        let early: Bool = lock.withLock {
            live[runId] = Entry(stop: handle, sessionId: sessionId)
            return stoppedEarly.remove(runId) != nil
        }
        if early { handle.stop() }
        return handle
    }

    func stopRequested(_ runId: String) {
        let handle: UnitRunStopHandle? = lock.withLock {
            if let e = live[runId] { return e.stop }
            stoppedEarly.insert(runId)
            return nil
        }
        handle?.stop()
    }

    func ended(_ runId: String) -> Entry? {
        lock.withLock {
            stoppedEarly.remove(runId)
            return live.removeValue(forKey: runId)
        }
    }
}

/// The Runtime's side of one unit Run, handed to its executor.
final class RuntimeUnitSink: UnitRunSink, @unchecked Sendable {
    let runId: String
    weak var service: RuntimeService?
    private let lock = NSLock()
    private var done = false

    init(runId: String, service: RuntimeService) {
        self.runId = runId
        self.service = service
    }

    func record(_ type: String, _ data: JSONValue) -> Bool {
        guard let service, type.hasPrefix("unit."), lock.withLock({ !done }), service.execution.isLive(runId) else { return false }
        guard service.runs.appendEvent(runId, type, data) > 0 else {
            service.execution.auditStorageFailed()
            return false
        }
        return true
    }

    func verified(status: String, observationId: String?, checkedAt: Date) {
        guard let service, let s = RunUnit.Verification(rawValue: status) else { return }
        service.execution.unitVerified(runId: runId, s, observationId: observationId, checkedAt: Timestamp.string(checkedAt))
    }

    func finished(_ ending: UnitRunEnding) {
        guard let service, lock.withLock({ () -> Bool in
            defer { done = true }
            return !done
        }) else { return }
        service.unitExecutorFinished(runId, ending)
    }
}

extension RuntimeService {
    /// The GUI executor for unit.run, and the ports it drives Runs through.
    /// Until one is registered unit.run answers unsupported_backend and
    /// runtime.capabilities does not list it.
    public func registerUnitExecutor(_ executor: UnitRunExecutor, ports: RuntimeGuiPorts) {
        units.register(executor, ports: ports)
    }

    var unitRunAvailable: Bool { units.current != nil }

    /// Wire unit.run: always a Delegated Run of this connection.
    func unitRun(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        beginUnitRun(request.params, principal: c, durable: false)
    }

    /// The main window's GUI Explorer: a Durable Run (platform /
    /// platform_durable / gui_explorer), started in this process only. No
    /// wire request reaches it.
    public func startDurableUnitRun(params: JSONValue) -> Result<JSONValue, RuntimeError> {
        let violations = contract.validate(params, "unit_run_params")
        guard violations.isEmpty else { return .failure(.schemaInvalid("params break unit_run_params", violations: violations)) }
        guard let ports = units.current?.ports else { return .failure(Self.guiExecutionOff()) }
        return beginUnitRun(params, principal: ports.ownerConnection, durable: true)
    }

    /// A paired principal's access to unit.run on this Desktop as it is now:
    /// the refusal if it is gone (revoked, expired, narrowed, connection cut).
    func accessLost(_ c: ConnectionState, desktopId: String) -> RuntimeError? {
        guard c.role == .paired else { return nil }
        if let reason = c.cutReason { return Self.cutError(c, reason) }
        if let e = accessError(c, method: RuntimeMethod.unitRun.rawValue) { return e }
        if !desktopAllowed(c, desktopId) {
            return RuntimeError("grant_missing", "desktop \(desktopId) is no longer in the grant", phase: .handler, notSent: true,
                                details: .obj([("reason", .string("grant_narrowed"))]))
        }
        return nil
    }

    /// The Desktop gone, or its bound window not the one admission checked.
    func targetChanged(_ desktopId: String, _ binding: TargetBinding) -> RuntimeError? {
        guard let d = desktops.find(desktopId) else {
            return RuntimeError("not_found", "desktop \(desktopId) was destroyed", phase: .handler, notSent: true,
                                details: .obj([("reason", .string("desktop_not_found"))]))
        }
        guard let now = d.lock.withLock({ d.binding }), now.generation == binding.generation else {
            return RuntimeError("invalid_target", "the window bound on desktop \(desktopId) changed; bind it again and retry",
                                phase: .handler, notSent: true, details: .obj([("reason", .string("binding_changed"))]))
        }
        return nil
    }

    static func guiExecutionOff() -> RuntimeError {
        RuntimeError("unsupported_backend", "real GUI input is off here: no execution backend has passed G0", phase: .handler,
                     notSent: true, details: .obj([("reason", .string("gui_execution_off"))]))
    }

    /// F40-06, in order; every refusal comes before the Run exists.
    private func beginUnitRun(_ p: JSONValue, principal c: ConnectionState, durable: Bool) -> Result<JSONValue, RuntimeError> {
        func refuse(_ code: String, _ message: String, _ reason: String? = nil, retryable: Bool = false,
                    details: [(String, JSONValue)] = []) -> Result<JSONValue, RuntimeError> {
            var d = details
            if let reason { d.insert(("reason", .string(reason)), at: 0) }
            return .failure(RuntimeError(code, message, phase: .handler, retryable: retryable, notSent: true,
                                         details: d.isEmpty ? nil : .obj(d)))
        }
        // 1. Ownership comes from how the Run is started, never from params.
        if UnitRun.escalationFields.contains(where: { p[$0] != nil }) {
            return refuse("ownership_escalation_denied",
                          "origin, lifetime and ownership follow from who starts the Run; a connection starts connection_scoped Runs only",
                          "ownership_from_params")
        }
        // 3. A GUI execution backend that passed G0.
        guard let (executor, ports) = units.current else { return .failure(Self.guiExecutionOff()) }
        // 4. Input admission.
        if execution.inputAdmission != .enabled {
            return refuse("input_disabled", "input is stopped for all Runs (runtime.stopAll); an owner must enable it again")
        }
        // 5. The Desktop.
        let desktopId = p["desktopId"]?.stringValue ?? ""
        guard let d = desktops.find(desktopId) else { return refuse("not_found", "no desktop \(desktopId)", "desktop_not_found") }
        // 6. Its control lease.
        if let holder = execution.holder(of: desktopId) {
            return refuse("control_busy", "desktop \(desktopId) is controlled by run \(holder)", retryable: true,
                          details: [("desktopId", .string(desktopId)), ("holderRunId", .string(holder))])
        }
        // The window the unit works in, and the caller's right to observe
        // and act on it (a paired app: its window grant).
        guard let binding = d.lock.withLock({ d.binding }) else {
            return refuse("invalid_target", "desktop \(desktopId) has no bound window; bind one before unit.run", "no_bound_window")
        }
        do {
            _ = try windowUse(c, d, binding, "observe", method: "unit.run", audit: false)
            _ = try windowUse(c, d, binding, "act", method: "unit.run")
        } catch let e as RuntimeError {
            return .failure(e)
        } catch {
            return .failure(RuntimeError("internal_error", "\(error)", phase: .handler, notSent: true))
        }
        // 7–15. The executor's own checks: profile, model, credential,
        // actions, predicates, mode.
        let scope = c.clientId.hasPrefix("local:") ? "uid:" + c.clientId.dropFirst("local:".count) : c.clientId
        let plan: any UnitRunPlan
        switch Self.blocking({ await executor.admit(params: p, callerScope: scope) }) {
        case let .failure(e): return .failure(e)
        case let .success(x): plan = x
        }

        // Access may have been withdrawn while the executor admitted (codex
        // on 49111eb): the revocation's sweep found no Run to stop.
        if let lost = accessLost(c, desktopId: desktopId) { return .failure(lost) }
        // The Desktop and its window may have changed meanwhile too (codex on
        // 158d2a6): the Run binds what is there now, the window checked above.
        if let changed = targetChanged(desktopId, binding) { return .failure(changed) }
        let session = sessions.open(desktopId: desktopId, caller: c.clientId, at: nowString)
        let unit = RunUnit(mode: p["mode"]?.stringValue ?? "auto",
                           goalHash: UnitRun.goalHash(p["goal"]?["description"]?.stringValue ?? ""),
                           guiProfileId: plan.guiProfileId, guiProfileRevision: plan.guiProfileRevision)
        let started = durable ? execution.startDurable(kind: "unit", session: session, origin: .guiExplorer, unit: unit)
                              : execution.startUnit(session: session, owner: c, unit: unit)
        let record: RunRecord
        switch started {
        case let .failure(e):
            _ = sessions.close(session.sessionId, at: nowString)
            return .failure(e)
        case let .success(r): record = r
        }
        let runId = record.runId
        // Its stop exists before anything of it can run.
        let handle = units.track(runId, sessionId: session.sessionId)
        // The control connection went away while the executor admitted
        // (codex on 8bcb18c): its Delegated Run ends at once, never driven.
        // connectionClosed marks the connection before stopping its Runs, so
        // either that stop found this Run or this check sees the mark.
        // Likewise a revocation or a narrowed grant: the owner's change is
        // saved before its sweep, so either the sweep found this Run or
        // this check sees the change.
        let lostNow = !durable && c.isClosed ? "owner_lost"
            : accessLost(c, desktopId: desktopId).map { $0.details?["reason"]?.stringValue ?? $0.code }
            ?? targetChanged(desktopId, binding).map { $0.details?["reason"]?.stringValue ?? $0.code }
        if let reason = lostNow {
            execution.stop(runId: runId, reason: reason, endAs: .cancelled)
            execution.releaseExecutor(runId: runId)
            return .success((runs.find(runId) ?? record).json)
        }
        // The executor acts as the Run's principal (the owner's own GUI
        // connection for a Durable Run), inside the Run.
        let acting = durable ? ConnectionState(peerUID: c.peerUID) : ConnectionState(actingFor: c)
        if durable { acting.apiVersion = RuntimeAPI.version }
        ports.bindUnitRun(runId: runId, desktopId: desktopId, sessionId: session.sessionId,
                          bindingEpoch: UInt64(binding.generation), principal: acting)
        let context = UnitRunContext(runId: runId, sessionId: session.sessionId, desktopId: desktopId,
                                     bindingEpoch: UInt64(binding.generation), callerScope: scope, params: p)
        executor.start(plan, context: context, sink: RuntimeUnitSink(runId: runId, service: self), stop: handle)
        return .success((runs.find(runId) ?? record).json)
    }

    /// The executor reported its ending (once).
    func unitExecutorFinished(_ runId: String, _ ending: UnitRunEnding) {
        switch ending {
        case .verified:
            execution.finishUnit(runId: runId, reason: "goal_verified", endAs: .success)
        case let .failed(reason):
            execution.finishUnit(runId: runId, reason: reason, endAs: .failed)
        case .cancelled:
            execution.finishUnit(runId: runId, reason: "stopped", endAs: .cancelled)
        case let .needsInput(reason):
            runs.appendEvent(runId, "unit.needs_input", .obj([("reason", .string(reason))]))
            execution.waitForInput(runId: runId)
            execution.releaseExecutor(runId: runId)
        }
        units.current?.ports.unbind(runId: runId)
    }

    /// A unit Run ended: its session closes with it.
    func unitRunEnded(_ r: RunRecord) {
        guard r.kind == "unit" else { return }
        if let entry = units.ended(r.runId) { _ = sessions.close(entry.sessionId, at: nowString) }
        else { _ = sessions.close(r.sessionId, at: nowString) }
        units.current?.ports.unbind(runId: r.runId)
    }

    /// Inputs of these Runs in [from, to): executed, and those whose
    /// outcome is unknown. For ai.usage.summary (A6: the AI service no
    /// longer keeps action receipts of its own). Read from the RunStore's
    /// action outcomes, which outlive the Runs' retention.
    public func actionOutcomes(runIds: [String], from: Date, to: Date) -> (confirmed: Int, unknown: Int) {
        runs.actionOutcomes(runIds: runIds, from: from, to: to)
    }

    /// Wait for async work from a synchronous handler, off the cooperative
    /// pool (the server answers on its own threads).
    static func blocking<T: Sendable>(_ body: @escaping @Sendable () async -> T) -> T {
        let box = BlockingBox<T>()
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await body()
            done.signal()
        }
        done.wait()
        return box.value!
    }
}

private final class BlockingBox<T>: @unchecked Sendable { var value: T? }
