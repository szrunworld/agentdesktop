import AgentDesktopProtocol
import CryptoKit
import Foundation

/// Who may send input where, and the stop path (Architecture Decision v2.2).
///
/// Two kinds of Run share one admission path and one executor:
/// - Delegated (external_client / connection_scoped): started by a client
///   connection; losing that control connection blocks its input and stops it.
/// - Durable (platform / platform_durable): started by the Runtime itself
///   (GUI Explorer, workflow replay, the user in the app); no connection
///   ends it — only stop, a revoked grant, global stop or a restart.
/// The ownership/lifetime pair is fixed by how the Run is created; no
/// request parameter can turn one into the other.
///
/// Each Desktop has at most one control lease, held by one live Run. A stop
/// closes the Run's admission at once; it becomes quiescent, and frees its
/// Desktop, only when no action of it is in flight.
public final class ExecutionCoordinator: @unchecked Sendable {
    /// Global input admission (runtime.stopAll / runtime.enableInput).
    public enum Admission: String, Sendable { case enabled, stopping, stopped }

    struct Live {
        var record: RunRecord
        var inFlight = 0
        /// SHA-256 of the attach token, for exec Runs.
        var tokenDigest: String?
        /// The control connection of a connection_scoped Run.
        var owner: ObjectIdentifier?
        /// The outcome once quiescent, unless an action is unknown.
        var endAs: RunRecord.Outcome = .success
    }

    let runs: RunStore
    private let lock = NSLock()
    private var leases: [String: String] = [:]
    private var live: [String: Live] = [:]
    private var admission: Admission = .enabled
    /// Per-Desktop admission (A5): desktop.stop and desktop.takeover.
    private var gates: [String: DesktopGate] = [:]
    /// When each gate closed, and when the owner last handed a Desktop back.
    private var gatedAt: [String: Date] = [:]
    private var cleared: [String: Date] = [:]
    /// Grows whenever a Desktop's gate changes (stop, takeover, handback,
    /// restore): a takeover that waited for the Desktop's lock checks that
    /// the gate it closed is still the one in place (Codex on 2aaf935).
    private var gateSerial: [String: Int] = [:]
    private var auditFailed = false

    var auditUnavailable: Bool { lock.withLock { auditFailed } }

    static func auditError(notSent: Bool? = nil) -> RuntimeError {
        RuntimeError("audit_unavailable", "Audit storage failed; input is disabled until the Runtime restarts with healthy storage",
                     phase: .handler, notSent: notSent)
    }

    func auditStorageFailed() {
        let first = lock.withLock {
            guard !auditFailed else { return false }
            auditFailed = true
            return true
        }
        if first { _ = stopAll() }
    }
    private let now: @Sendable () -> Date
    /// Called once a stop of a live Run is accepted (outside the lock): a
    /// unit Run's executor must stop starting model calls and input.
    var onStopAccepted: (@Sendable (String) -> Void)?
    /// Called once a Run ended (outside the lock).
    var onEnded: (@Sendable (RunRecord) -> Void)?

    init(runs: RunStore, now: @escaping @Sendable () -> Date) {
        self.runs = runs
        self.now = now
    }

    var activeCount: Int { lock.withLock { live.count } }
    public var inputAdmission: Admission { lock.withLock { admission } }

    private func inputDisabled() -> RuntimeError {
        RuntimeError("input_disabled", "input is stopped for all Runs (runtime.stopAll); an owner must enable it again",
                     phase: .handler, notSent: true)
    }

    /// A Delegated Run for a client connection, on the session's Desktop.
    func start(kind: String, session: RuntimeSession, owner: ConnectionState) -> Result<(RunRecord, token: String?), RuntimeError> {
        let result = begin(kind: kind, session: session, origin: .agentHub, ownership: .externalClient,
                           lifetime: .connectionScoped, clientId: owner.clientId, connectionId: owner.connectionId,
                           owner: ObjectIdentifier(owner), withToken: kind == "exec")
        if case let .success((r, _)) = result { owner.ownedRuns.insert(r.runId) }
        return result
    }

    /// A Durable Run owned by the platform. Not reachable from the wire:
    /// only Runtime components (GUI Explorer, replay, the app) call it.
    public func startDurable(kind: String, session: RuntimeSession, origin: RunRecord.Origin) -> Result<RunRecord, RuntimeError> {
        startDurable(kind: kind, session: session, origin: origin, unit: nil)
    }

    func startDurable(kind: String, session: RuntimeSession, origin: RunRecord.Origin, unit: RunUnit?) -> Result<RunRecord, RuntimeError> {
        guard origin != .agentHub else {
            return .failure(RuntimeError("ownership_escalation_denied", "an AgentHub client cannot own a durable Run", phase: .handler))
        }
        return begin(kind: kind, session: session, origin: origin, ownership: .platform, lifetime: .platformDurable,
                     clientId: nil, connectionId: nil, owner: nil, withToken: false, unit: unit).map(\.0)
    }

    /// A Delegated unit Run (A6) for a client connection. Its executor holds
    /// the Run like an action in flight: a stop makes it quiescent only once
    /// the executor reported back, so every unit event precedes run.ended.
    func startUnit(session: RuntimeSession, owner: ConnectionState, unit: RunUnit) -> Result<RunRecord, RuntimeError> {
        let result = begin(kind: "unit", session: session, origin: .agentHub, ownership: .externalClient,
                           lifetime: .connectionScoped, clientId: owner.clientId, connectionId: owner.connectionId,
                           owner: ObjectIdentifier(owner), withToken: false, unit: unit)
        if case let .success((r, _)) = result { owner.ownedRuns.insert(r.runId) }
        return result.map(\.0)
    }

    private func begin(kind: String, session: RuntimeSession, origin: RunRecord.Origin, ownership: RunRecord.Ownership,
                       lifetime: RunRecord.Lifetime, clientId: String?, connectionId: String?, owner: ObjectIdentifier?,
                       withToken: Bool, unit: RunUnit? = nil, takeoverSerial: Int? = nil) -> Result<(RunRecord, token: String?), RuntimeError> {
        let runId = DesktopRegistry.newId(prefix: "run")
        var token: String?
        let result: Result<RunRecord, RuntimeError> = lock.withLock {
            guard !auditFailed else { return .failure(Self.auditError(notSent: true)) }
            do { try runs.checkWritable() } catch { return .failure(Self.auditError(notSent: true)) }
            guard admission == .enabled else { return .failure(inputDisabled()) }
            // A takeover's Run starts only if the manual gate it closed still
            // stands, checked with the start under this one lock: a stop or
            // handback cannot slip in between (Codex P1 on 6d39332).
            if let serial = takeoverSerial,
               gates[session.desktopId] != .manual || gateSerial[session.desktopId, default: 0] != serial {
                return .failure(Self.superseded(session.desktopId))
            }
            switch gates[session.desktopId] {
            case .stopped?:
                return .failure(RuntimeError(
                    "input_disabled", "input on desktop \(session.desktopId) was stopped by its owner (desktop.stop); it is admitted again after desktop.handback",
                    phase: .handler, notSent: true,
                    details: .obj([("desktopId", .string(session.desktopId)), ("reason", .string("desktop_stopped"))])))
            case .manual? where origin != .user:
                return .failure(RuntimeError(
                    "control_busy", "the user took over desktop \(session.desktopId) (desktop.takeover); it is admitted again after desktop.handback",
                    phase: .handler, retryable: true, notSent: true,
                    details: .obj([("desktopId", .string(session.desktopId)), ("reason", .string("manual_control"))])))
            default: break
            }
            if let holder = leases[session.desktopId], live[holder] != nil {
                return .failure(RuntimeError(
                    "control_busy", "desktop \(session.desktopId) is controlled by run \(holder)", phase: .handler,
                    retryable: true, notSent: true,
                    details: .obj([("desktopId", .string(session.desktopId)), ("holderRunId", .string(holder))])))
            }
            let record = RunRecord(runId: runId, kind: kind, origin: origin, ownership: ownership, lifetime: lifetime,
                                   clientId: clientId, connectionId: connectionId, sessionId: session.sessionId,
                                   desktopId: session.desktopId, phase: .running, outcome: nil, quiescence: .notConfirmed,
                                   closingReason: nil, revision: 1, createdAt: Timestamp.string(now()), endedAt: nil,
                                   receipts: [], unknownActions: 0, unit: unit)
            // A unit Run's executor counts as in flight until it reports back.
            var l = Live(record: record, inFlight: unit == nil ? 0 : 1, owner: owner)
            if withToken {
                let t = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
                token = t
                l.tokenDigest = Self.digest(t)
            }
            live[runId] = l
            leases[session.desktopId] = runId
            return .success(record)
        }
        return result.map { r in
            runs.create(r)
            return (r, token)
        }
    }

    static func digest(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Let another connection of the same principal act within an exec Run.
    func attach(runId: String, token: String, connection: ConnectionState) -> Result<RunRecord, RuntimeError> {
        let r: RunRecord? = lock.withLock {
            guard let l = live[runId], l.record.clientId == connection.clientId,
                  let d = l.tokenDigest, d == Self.digest(token) else { return nil }
            return l.record
        }
        guard let r else { return .failure(RuntimeError("permission_denied", "cannot attach to run \(runId)", phase: .handler)) }
        connection.attachedRuns.insert(runId)
        return .success(r)
    }

    /// The Run this connection may act in, if it is still running. Every
    /// refusal comes before anything is sent or captured: notSent, like the
    /// same refusal from `beginAction` (2ndscreen-af's L2 asserts it).
    func authorized(runId: String, connection: ConnectionState) -> Result<RunRecord, RuntimeError> {
        guard connection.ownedRuns.contains(runId) || connection.attachedRuns.contains(runId) else {
            return .failure(RuntimeError("permission_denied", "this connection does not own or attach to run \(runId)",
                                         phase: .handler, notSent: true))
        }
        return lock.withLock {
            guard let l = live[runId] else {
                return .failure(RuntimeError("run_not_active", "run \(runId) has ended", phase: .handler, notSent: true))
            }
            guard l.record.phase == .running else {
                return .failure(RuntimeError("run_not_active", "run \(runId) is \(l.record.phase.rawValue); it takes no new input",
                                             phase: .handler, notSent: true))
            }
            return .success(l.record)
        }
    }

    /// Right before dispatch: input enabled, the Run still running and
    /// holding its Desktop. Counts the action as in flight.
    func beginAction(runId: String) -> RuntimeError? {
        lock.withLock {
            guard !auditFailed else { return Self.auditError(notSent: true) }
            do { try runs.checkWritable() } catch { return Self.auditError(notSent: true) }
            guard admission == .enabled else { return inputDisabled() }
            guard var l = live[runId], l.record.phase == .running, leases[l.record.desktopId] == runId else {
                return RuntimeError("run_not_active", "run \(runId) was stopped before this action was dispatched",
                                    phase: .handler, notSent: true)
            }
            l.inFlight += 1
            live[runId] = l
            return nil
        }
    }

    /// An action of the Run finished, with or without a receipt.
    func endAction(runId: String, receiptId: String?, deliveryUnknown: Bool) {
        let (record, quiesce): (RunRecord?, Bool) = lock.withLock {
            guard var l = live[runId] else { return (nil, false) }
            l.inFlight -= 1
            if let receiptId { l.record.receipts.append(receiptId) }
            if deliveryUnknown { l.record.unknownActions += 1 }
            l.record.revision += 1
            live[runId] = l
            return (l.record, l.record.phase == .stopping && l.inFlight == 0)
        }
        if let record { runs.update(record) }
        if quiesce { settle(runId) }
    }

    public enum StopOutcome {
        case accepted(RunRecord)
        case alreadyTerminal(RunRecord)
        case notFound
    }

    /// Close the Run's admission now; end it once quiescent. `endAs` is the
    /// outcome then (success for finish, cancelled for stop), unless an
    /// action of it is unknown — unknown is never overwritten.
    @discardableResult
    func stop(runId: String, reason: String, endAs: RunRecord.Outcome, finishing: Bool? = nil) -> StopOutcome {
        stop(runId: runId, reason: reason, endAs: endAs, finishing: finishing, onlyIf: nil)!
    }

    /// Stop the Run only if `holds` is true of it, checked under the same
    /// lock as the stop (inbox.resolve's compare-and-stop: two decisions on
    /// one revision never both succeed). nil: the Run is live and it did not
    /// hold, or the Run is no longer live; nothing was changed.
    func stop(runId: String, reason: String, endAs: RunRecord.Outcome, onlyIf holds: @escaping (RunRecord) -> Bool) -> StopOutcome? {
        stop(runId: runId, reason: reason, endAs: endAs, finishing: nil, onlyIf: Optional(holds))
    }

    private func stop(runId: String, reason: String, endAs: RunRecord.Outcome, finishing: Bool?,
                      onlyIf holds: ((RunRecord) -> Bool)?) -> StopOutcome? {
        let checked: (StopOutcome, quiesceNow: Bool, first: Bool)? = lock.withLock {
            guard var l = live[runId] else {
                if holds != nil { return nil }
                return (runs.find(runId).map { .alreadyTerminal($0) } ?? .notFound, false, false)
            }
            if let holds, !holds(l.record) { return nil }
            let first = l.record.phase != .stopping
            if first {
                l.record.phase = .stopping
                l.record.quiescence = .pending
                l.record.closingReason = reason
                l.record.revision += 1
                l.endAs = endAs
                live[runId] = l
            }
            return (.accepted(l.record), l.inFlight == 0, first)
        }
        guard let outcome = checked else { return nil }
        if case let .accepted(r) = outcome.0 {
            runs.update(r)
            let finish = finishing ?? (["finished", "completed"].contains(reason) || reason.hasPrefix("exit"))
            runs.appendEvent(runId, finish ? "run.finishing" : "stop.accepted",
                             .obj([("reason", .string(reason)), ("inFlight", .bool(!outcome.quiesceNow)), ("revision", .int(r.revision))]))
            if outcome.first, !finish { onStopAccepted?(runId) }
            if outcome.quiesceNow { settle(runId) }
        }
        return outcome.0
    }

    /// A unit executor's own ending: the Run finishes with it unless a stop
    /// was accepted first (that stop's reason and outcome stand), then the
    /// executor lets go of it.
    func finishUnit(runId: String, reason: String, endAs: RunRecord.Outcome) {
        let running = lock.withLock { live[runId].map { $0.record.phase != .stopping } ?? false }
        if running { stop(runId: runId, reason: reason, endAs: endAs, finishing: true) }
        releaseExecutor(runId: runId)
    }

    /// The unit executor reported back: it no longer holds the Run. A Run
    /// already stopping becomes quiescent now if nothing else is in flight.
    func releaseExecutor(runId: String) {
        let quiesce: Bool = lock.withLock {
            guard var l = live[runId], l.record.kind == "unit", l.inFlight > 0 else { return false }
            l.inFlight -= 1
            live[runId] = l
            return l.record.phase == .stopping && l.inFlight == 0
        }
        if quiesce { settle(runId) }
    }

    /// A unit Run waits for a person (needs_user): no input is admitted
    /// (beginAction needs running); only a stop ends it.
    func waitForInput(runId: String) {
        let r: RunRecord? = lock.withLock {
            guard var l = live[runId], l.record.phase == .running else { return nil }
            l.record.phase = .waitingInput
            l.record.revision += 1
            live[runId] = l
            return l.record
        }
        if let r { runs.update(r) }
    }

    /// The latest verification of a live unit Run (Run.unit.verification).
    func unitVerified(runId: String, _ status: RunUnit.Verification, observationId: String?, checkedAt: String) {
        let r: RunRecord? = lock.withLock {
            guard var l = live[runId], l.record.unit != nil else { return nil }
            l.record.unit?.verification = status
            l.record.unit?.observationId = observationId
            l.record.unit?.checkedAt = checkedAt
            l.record.revision += 1
            live[runId] = l
            return l.record
        }
        if let r { runs.update(r) }
    }

    /// Whether the Run is live (not ended).
    func isLive(_ runId: String) -> Bool { lock.withLock { live[runId] != nil } }

    /// No input of the Run can follow: free the Desktop and end the Run.
    private func settle(_ runId: String) {
        let (ended, globallyQuiet): (RunRecord?, Bool) = lock.withLock {
            guard var l = live.removeValue(forKey: runId) else { return (nil, false) }
            l.record.phase = .ended
            l.record.quiescence = .confirmed
            l.record.outcome = l.record.unknownActions > 0 ? .unknown : l.endAs
            l.record.endedAt = Timestamp.string(now())
            l.record.revision += 1
            if leases[l.record.desktopId] == runId { leases.removeValue(forKey: l.record.desktopId) }
            if admission == .stopping, live.isEmpty { admission = .stopped }
            return (l.record, admission == .stopped)
        }
        guard let ended else { return }
        _ = globallyQuiet
        runs.update(ended)
        runs.appendEvent(runId, "run.quiescent", .obj([("revision", .int(ended.revision))]))
        runs.appendEvent(runId, "run.ended", .obj([("phase", .string("ended")), ("outcome", .string(ended.outcome?.rawValue ?? "")),
                                                   ("reason", .string(ended.closingReason ?? ""))]))
        onEnded?(ended)
    }

    /// The control connection is gone: its connection_scoped Runs take no
    /// further input. Durable Runs never depend on a connection.
    func ownerLost(_ connection: ConnectionState) {
        let owned: [String] = lock.withLock {
            live.filter { $0.value.owner == ObjectIdentifier(connection) && $0.value.record.lifetime == .connectionScoped }.map(\.key)
        }
        for id in owned { stop(runId: id, reason: "owner_lost", endAs: .cancelled) }
    }

    /// A client's access is gone (revoked, expired): every live Run it owns
    /// stops, whatever its lifetime; no further input of it is admitted.
    func stopRuns(ofClient clientId: String, reason: String) {
        let owned: [String] = lock.withLock { live.filter { $0.value.record.clientId == clientId }.map(\.key) }
        for id in owned { stop(runId: id, reason: reason, endAs: .cancelled) }
    }

    /// Close input admission for every Run (Delegated and Durable) and stop
    /// them all. Returns each Run's stop state; global admission becomes
    /// `stopped` only once every Run is quiescent.
    func stopAll() -> (admission: Admission, runs: [RunRecord]) {
        let ids: [String] = lock.withLock {
            if admission == .enabled { admission = live.isEmpty ? .stopped : .stopping }
            return Array(live.keys)
        }
        var stopped: [RunRecord] = []
        for id in ids {
            switch stop(runId: id, reason: "global_stop", endAs: .cancelled) {
            case let .accepted(r): stopped.append(runs.find(id) ?? r)
            case let .alreadyTerminal(r): stopped.append(r)
            case .notFound: break
            }
        }
        return (inputAdmission, stopped)
    }

    /// Reopen admission for new Runs. Old Runs are not resumed; reopening
    /// while a stop is still draining is refused.
    func enableInput() -> Result<Admission, RuntimeError> {
        lock.withLock {
            guard !auditFailed else { return .failure(Self.auditError(notSent: true)) }
            do { try runs.checkWritable() } catch { return .failure(Self.auditError(notSent: true)) }
            switch admission {
            case .enabled, .stopped:
                admission = .enabled
                return .success(.enabled)
            case .stopping:
                return .failure(RuntimeError("stop_pending", "Runs are still stopping; input can be enabled once all are quiescent",
                                             phase: .handler, retryable: true))
            }
        }
    }

    /// Whether a live Run holds the Desktop (destroy refuses then).
    func holder(of desktopId: String) -> String? { lock.withLock { leases[desktopId] } }

    // MARK: One Desktop's admission (A5)

    /// Why a Desktop admits no new Run beside global admission: the owner
    /// stopped it (desktop.stop), or took it over (desktop.takeover), which
    /// admits only the user's own Run. Gone with desktop.handback.
    public enum DesktopGate: String, Sendable { case stopped, manual }

    /// What Desktop.control is derived from, read in one step.
    struct ControlFacts {
        var holder: RunRecord?
        var gate: DesktopGate?
        var gatedAt: Date?
        var admission: Admission
        /// When the owner last handed the Desktop back: a Run that ended
        /// before then no longer colours its control state.
        var clearedAt: Date?
    }

    func controlFacts(_ desktopId: String) -> ControlFacts {
        lock.withLock {
            ControlFacts(holder: leases[desktopId].flatMap { live[$0]?.record }, gate: gates[desktopId],
                         gatedAt: gatedAt[desktopId], admission: admission, clearedAt: cleared[desktopId])
        }
    }

    /// desktop.stop: close the Desktop's admission now and stop the Run
    /// holding it, whatever its origin. Returns that Run's stop, if any.
    func stopDesktop(_ desktopId: String) -> RunRecord? {
        let holder: String? = lock.withLock {
            if gates[desktopId] != .stopped { gatedAt[desktopId] = now(); gateSerial[desktopId, default: 0] += 1 }
            gates[desktopId] = .stopped
            return leases[desktopId]
        }
        guard let holder else { return nil }
        switch stop(runId: holder, reason: "desktop_stop", endAs: .cancelled) {
        case let .accepted(r): return runs.find(holder) ?? r
        case let .alreadyTerminal(r): return r
        case .notFound: return nil
        }
    }

    /// desktop.takeover, first step: from now on only the user's Run is
    /// admitted on the Desktop; the agent's Run holding it is stopped.
    /// Returns that Run's stop, if any, and the gate as it was.
    func closeForTakeover(_ desktopId: String) -> (stopped: RunRecord?, previous: DesktopGate?, serial: Int) {
        let (holder, previous, serial): (RunRecord?, DesktopGate?, Int) = lock.withLock {
            let previous = gates[desktopId]
            if previous != .manual { gatedAt[desktopId] = now(); gateSerial[desktopId, default: 0] += 1 }
            gates[desktopId] = .manual
            return (leases[desktopId].flatMap { live[$0]?.record }, previous, gateSerial[desktopId, default: 0])
        }
        guard let holder, holder.origin != .user else { return (nil, previous, serial) }
        switch stop(runId: holder.runId, reason: "takeover", endAs: .cancelled) {
        case let .accepted(r): return (runs.find(holder.runId) ?? r, previous, serial)
        case let .alreadyTerminal(r): return (r, previous, serial)
        case .notFound: return (nil, previous, serial)
        }
    }

    static func superseded(_ desktopId: String) -> RuntimeError {
        RuntimeError("conflict", "desktop \(desktopId) was handed back or stopped while this takeover waited; nothing was taken over",
                     phase: .handler, notSent: true,
                     details: .obj([("desktopId", .string(desktopId)), ("reason", .string("superseded"))]))
    }

    /// Whether the manual gate a takeover closed (its `serial`) still stands.
    /// A read for choosing the answer only; startTakeover checks it again
    /// atomically with the Run's start.
    func takeoverStands(_ desktopId: String, serial: Int) -> Bool {
        lock.withLock { gates[desktopId] == .manual && gateSerial[desktopId, default: 0] == serial }
    }

    /// desktop.takeover, last step: the user's Run, started only while the
    /// manual gate the takeover closed (its `serial`) still stands.
    func startTakeover(session: RuntimeSession, serial: Int) -> Result<RunRecord, RuntimeError> {
        begin(kind: "exec", session: session, origin: .user, ownership: .platform, lifetime: .platformDurable,
              clientId: nil, connectionId: nil, owner: nil, withToken: false, takeoverSerial: serial).map(\.0)
    }

    /// Put a gate back as it was (a takeover that could not start the
    /// user's Run).
    /// Only while the gate is still the takeover's own (`serial`): a stop or
    /// handback made meanwhile stands (Codex P1 on 6d39332).
    func restoreGate(_ desktopId: String, _ gate: DesktopGate?, ifSerial serial: Int) {
        lock.withLock {
            guard gates[desktopId] == .manual, gateSerial[desktopId, default: 0] == serial else { return }
            if gates[desktopId] != gate { gateSerial[desktopId, default: 0] += 1 }
            gates[desktopId] = gate
            if gate == nil { gatedAt.removeValue(forKey: desktopId) }
        }
    }

    /// desktop.handback: the Desktop admits Runs again.
    func openDesktop(_ desktopId: String) {
        lock.withLock {
            if gates.removeValue(forKey: desktopId) != nil { gateSerial[desktopId, default: 0] += 1 }
            gatedAt.removeValue(forKey: desktopId)
            cleared[desktopId] = now()
        }
    }

    /// The Desktop is gone: nothing of it is kept.
    func forgetDesktop(_ desktopId: String) {
        lock.withLock {
            gates.removeValue(forKey: desktopId)
            gatedAt.removeValue(forKey: desktopId)
            cleared.removeValue(forKey: desktopId)
            gateSerial.removeValue(forKey: desktopId)
        }
    }

    /// Live Runs, for status and diagnostics.
    func liveRuns() -> [RunRecord] { lock.withLock { live.values.map(\.record) } }
}
