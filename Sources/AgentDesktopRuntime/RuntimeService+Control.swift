import AgentDesktopProtocol
import Foundation

// A5: who controls one Desktop's input, and the owner's stop, takeover and
// handback of it (docs/plan/03 §3.3–3.4, Design P12–P16). Each acts on one
// Desktop only; the others keep running. Nothing here is persisted: the
// state is derived from the lease, the Desktop's gate and its last Run.
extension RuntimeService {
    /// Runs ended for one of these reasons leave their Desktop `stopped`.
    static let stopReasons: Set<String> = ["stopped", "global_stop", "client_stop", "desktop_stop", "takeover"]

    /// Desktop.control. A paired app learns who controls a Desktop only
    /// when that is itself (#153 parity: no other client's ids).
    func controlJSON(_ d: DesktopRecord, for c: ConnectionState?) -> JSONValue {
        let facts = execution.controlFacts(d.desktopId)
        let state: String
        var run: RunRecord?
        var since = d.createdAt
        if let h = facts.holder {
            run = h
            state = h.phase == .stopping ? "stopping" : (h.origin == .user ? "manual" : "running")
            since = h.createdAt
        } else if facts.gate != nil {
            // Closed by the owner and held by no Run (a takeover still
            // waiting holds the agent's stopping Run, shown above): no one
            // controls it and agents may not.
            state = "stopped"
            since = facts.gatedAt.map(Timestamp.string) ?? since
        } else if facts.admission != .enabled {
            state = "stopped"
        } else {
            // The last Run colours the state until a new one starts or the
            // owner hands the Desktop back.
            var f = RunStore.ListFilter()
            f.desktopId = d.desktopId
            let last = runs.list(f, after: nil, limit: 1).runs.first.flatMap { r -> RunRecord? in
                guard let cleared = facts.clearedAt, let ended = r.endedAt.flatMap(Timestamp.date) else { return r }
                return ended > cleared ? r : nil
            }
            if let last, last.outcome == .unknown { state = "unknown" }
            else if let last, last.closingReason == "owner_lost" { state = "disconnected" }
            else if let last, Self.stopReasons.contains(last.closingReason ?? "") { state = "stopped" }
            else { state = "ready" }
            if let last {
                if state != "ready" { run = last }
                since = last.endedAt ?? last.createdAt
            } else if let cleared = facts.clearedAt {
                since = Timestamp.string(cleared)
            }
        }
        var m: [(String, JSONValue)] = [("state", .string(state)), ("since", .string(since)),
                                        ("actionCount", .int(run?.receipts.count ?? 0))]
        if let run, c?.role != .paired || run.clientId == c?.clientId {
            m.append(("controllerRunId", .string(run.runId)))
            if let id = run.clientId {
                m.append(("clientId", .string(id)))
                if let name = hub.client(id)?.agentName { m.append(("clientName", .string(name))) }
            }
        }
        return .obj(m)
    }

    static func stopState(_ r: RunRecord) -> JSONValue {
        .obj([("runId", .string(r.runId)), ("phase", .string(r.phase.rawValue)), ("quiescence", .string(r.quiescence.rawValue)),
              ("outcome", r.outcome.map { .string($0.rawValue) } ?? .null)])
    }

    /// desktop.stop: no new input on this Desktop until the owner hands it
    /// back. The Run holding it stops now; the receipt says whether it is
    /// already quiescent or still finishing an action (P14–P15).
    func stopDesktop(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(Self.ownerOnly("desktop.stop")) }
        // Not under the Desktop's lock: an action in flight holds it, and
        // the stop is accepted before that action ends.
        return desktop(p["desktopId"]).map { d in
            let stopped = execution.stopDesktop(d.desktopId)
            return .obj([("desktopId", .string(d.desktopId)), ("accepted", .bool(true)),
                         ("run", stopped.map(Self.stopState) ?? .null), ("control", controlJSON(d, for: c))])
        }
    }

    /// desktop.takeover: the user controls the Desktop by hand. Agents'
    /// input is closed first and the Run holding it stopped; once nothing
    /// of it is in flight a platform Run of origin user holds the lease, and
    /// every other Run is refused (control_busy, reason manual_control).
    func takeover(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(Self.ownerOnly("desktop.takeover")) }
        let d: DesktopRecord
        switch desktop(request.params["desktopId"]) {
        case let .failure(e): return .failure(e)
        case let .success(x): d = x
        }
        if let h = execution.controlFacts(d.desktopId).holder, h.origin == .user, h.phase == .running {
            return .success(takeoverJSON(d, run: h, stopped: nil, c))
        }
        let (stopped, previous, serial) = execution.closeForTakeover(d.desktopId)
        func pending(_ holder: String) -> RuntimeError {
            RuntimeError("stop_pending",
                         "takeover accepted: run \(holder) is still finishing an action; agents' input on desktop \(d.desktopId) stays closed. Ask again with a new requestId once it is quiescent",
                         phase: .handler, retryable: true, notSent: false,
                         details: .obj([("desktopId", .string(d.desktopId)), ("holderRunId", .string(holder))]))
        }
        // An action of the stopped Run holds the Desktop's lock until it
        // ends (and ends that Run): waiting for the lock waits for it.
        let limit = request.deadline.flatMap(Timestamp.date) ?? now().addingTimeInterval(desktopLockWait)
        guard d.lock.lock(before: limit) else { return .failure(pending(stopped?.runId ?? "?")) }
        defer { d.lock.unlock() }
        guard d.state != "destroyed" else { return .failure(.notFound("no desktop \(d.desktopId)")) }
        // Another takeover got here first: this one answers its Run.
        if let h = execution.controlFacts(d.desktopId).holder, h.origin == .user, h.phase == .running {
            return .success(takeoverJSON(d, run: h, stopped: stopped, c))
        }
        // While this one waited, the owner handed the Desktop back or stopped
        // it: that later decision stands (Codex on 2aaf935).
        guard execution.takeoverStands(d.desktopId, serial: serial) else {
            return .failure(RuntimeError("conflict",
                                         "desktop \(d.desktopId) was handed back or stopped while this takeover waited; nothing was taken over",
                                         phase: .handler, notSent: true,
                                         details: .obj([("desktopId", .string(d.desktopId)), ("reason", .string("superseded"))])))
        }
        if let holder = execution.holder(of: d.desktopId) { return .failure(pending(holder)) }
        let session = sessions.open(desktopId: d.desktopId, caller: c.clientId, at: nowString)
        // The user's Run takes no input through the Runtime: its session
        // only names the Desktop.
        defer { _ = sessions.close(session.sessionId, at: nowString) }
        switch execution.startDurable(kind: "exec", session: session, origin: .user) {
        case let .failure(e):
            execution.restoreGate(d.desktopId, stopped != nil ? .stopped : previous)
            return .failure(e)
        case let .success(run):
            return .success(takeoverJSON(d, run: run, stopped: stopped, c))
        }
    }

    private func takeoverJSON(_ d: DesktopRecord, run: RunRecord, stopped: RunRecord?, _ c: ConnectionState) -> JSONValue {
        .obj([("desktopId", .string(d.desktopId)), ("run", (runs.find(run.runId) ?? run).json),
              ("stopped", stopped.map { Self.stopState(runs.find($0.runId) ?? $0) } ?? .null),
              ("control", controlJSON(d, for: c))])
    }

    /// desktop.handback: agents may act on the Desktop again. The user's
    /// Run ends; every observation of the Desktop is forgotten, so a new
    /// action needs a new observation and nothing queued before is replayed.
    func handback(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(Self.ownerOnly("desktop.handback")) }
        return withDesktop(p["desktopId"]) { d in
            let facts = execution.controlFacts(d.desktopId)
            // Stopped or taken over, or left stopped, disconnected or unknown
            // by its last Run: the owner's handback clears it (Codex on
            // 2aaf935: those states need no stop first).
            let state = controlJSON(d, for: c)["state"]?.stringValue ?? ""
            // A global stop is runtime.enableInput's to lift, not this.
            let settled = facts.holder == nil && facts.admission == .enabled
                && ["stopped", "disconnected", "unknown"].contains(state)
            guard facts.gate != nil || settled else {
                // Ready, or an agent's Run holds it: nothing to hand back, and
                // a running agent keeps its observations.
                return .obj([("desktopId", .string(d.desktopId)), ("handedBack", .bool(false)), ("endedRunId", .null),
                             ("observationsCleared", .bool(false)), ("control", controlJSON(d, for: c))])
            }
            var ended: String?
            if let h = facts.holder, h.origin == .user {
                execution.stop(runId: h.runId, reason: "handback", endAs: .success)
                ended = h.runId
            }
            execution.openDesktop(d.desktopId)
            observations.forget(desktopId: d.desktopId)
            return .obj([("desktopId", .string(d.desktopId)), ("handedBack", .bool(true)),
                         ("endedRunId", ended.map(JSONValue.string) ?? .null), ("observationsCleared", .bool(true)),
                         ("control", controlJSON(d, for: c))])
        }
    }
}
