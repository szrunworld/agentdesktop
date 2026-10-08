import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// Until AgentHub pairing exists every local connection of the user is
    /// the owner: it sees and controls all Runs. A paired client will see
    /// only its own (clientId match).
    func isOwner(_ c: ConnectionState) -> Bool {
        c.clientId.hasPrefix("local:") || (c.origin == .socket && !socketsSeeOnlyTheirOwn)
    }

    func ownRun(_ p: JSONValue, _ c: ConnectionState) -> Result<RunRecord, RuntimeError> {
        let id = p["runId"]?.stringValue ?? ""
        guard let r = runs.find(id), isOwner(c) || r.clientId == c.clientId else { return .failure(.notFound("no run \(id)")) }
        return .success(r)
    }

    /// Start a Delegated exec Run on the session's Desktop; this connection
    /// owns it. Ownership and lifetime follow from the caller and cannot be
    /// requested (ADR v2.2 §3, ADR-05).
    func startRun(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let p = request.params
        if p["lifetime"]?.stringValue == "platform_durable" || p["ownership"]?.stringValue == "platform"
            || (p["origin"]?.stringValue).map({ $0 != "agent_hub" }) == true {
            return .failure(RuntimeError(
                "ownership_escalation_denied",
                "a client connection starts connection_scoped Runs only; durable platform Runs need a user-confirmed handover",
                phase: .request, notSent: true))
        }
        guard request.context.sessionId != nil else { return .failure(.schemaInvalid("run.start needs context.sessionId")) }
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((_, s)):
            return execution.start(kind: "exec", session: s!, owner: c).map { r, token in
                .obj([("run", r.json), ("attachToken", .string(token ?? ""))])
            }
        }
    }

    func attachRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        execution.attach(runId: p["runId"]?.stringValue ?? "", token: p["token"]?.stringValue ?? "", connection: c).map(\.json)
    }

    /// The shell is done: no new input; the Run ends successfully once
    /// quiescent, or unknown if an action of it is unknown.
    func finishRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            guard c.ownedRuns.contains(r.runId) else {
                return .failure(RuntimeError("permission_denied", "only the connection that started run \(r.runId) finishes it", phase: .handler))
            }
            let reason = p["exitCode"]?.intValue.map { "exit \($0)" } ?? "finished"
            switch execution.stop(runId: r.runId, reason: reason, endAs: .success) {
            case .accepted, .alreadyTerminal: return .success((runs.find(r.runId) ?? r).json)
            case .notFound: return .failure(.notFound("no run \(r.runId)"))
            }
        }
    }

    func showRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).map(\.json)
    }

    /// Delegated and Durable Runs in one list (the Runs page), newest first.
    func listRuns(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        var f = RunStore.ListFilter()
        f.clientId = isOwner(c) ? p["clientId"]?.stringValue : c.clientId
        f.origin = p["origin"]?.stringValue.flatMap(RunRecord.Origin.init(rawValue:))
        f.phase = p["phase"]?.stringValue.flatMap(RunRecord.Phase.init(rawValue:))
        f.desktopId = p["desktopId"]?.stringValue
        f.activeOnly = p["active"]?.boolValue ?? false
        let page = runs.list(f, after: p["cursor"]?.stringValue, limit: p["limit"]?.intValue ?? 50)
        return .success(.obj([("runs", .array(page.runs.map(\.json))), ("next", page.next.map(JSONValue.string) ?? .null)]))
    }

    func runEvents(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).map { r in
            let after = p["after"]?.intValue ?? 0
            let events = runs.events(r.runId, after: after, limit: p["limit"]?.intValue ?? 100)
            let next = events.last?["sequence"]?.intValue ?? after
            let ended = runs.find(r.runId)?.isEnded ?? true
            return .obj([("events", .array(events)), ("next", .int(next)), ("ended", .bool(ended))])
        }
    }

    /// Observe the Run until it ends (ended implies quiescence confirmed);
    /// never changes it.
    func waitRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            let deadline = Date().addingTimeInterval(Double(p["timeoutMs"]?.intValue ?? 0) / 1000)
            let last = runs.wait(r.runId, until: deadline) { $0.isEnded } ?? r
            if last.isEnded { return .success(last.json) }
            return .failure(RuntimeError("wait_timeout", "run \(r.runId) is still \(last.phase.rawValue)", phase: .handler,
                                         details: .obj([("phase", .string(last.phase.rawValue)),
                                                        ("quiescence", .string(last.quiescence.rawValue))])))
        }
    }

    static func stopReceipt(_ r: RunRecord, terminal: Bool) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("cancelRequest", .obj([("accepted", .bool(true)), ("scope", .obj([("kind", .string("run")), ("id", .string(r.runId))]))])),
            ("execution", .obj([("phase", .string(r.phase.rawValue)), ("quiescence", .string(r.quiescence.rawValue)),
                                ("outcome", r.outcome.map { .string($0.rawValue) } ?? .null), ("revision", .int(r.revision))])),
        ]
        if terminal { m.append(("alreadyTerminal", .bool(true))) }
        return .obj(m)
    }

    /// Accept a stop: no new input from now on. Quiescence follows once no
    /// action is in flight; an ended Run keeps its own ending.
    func cancelRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            switch execution.stop(runId: r.runId, reason: "stopped", endAs: .cancelled) {
            case .accepted: return .success(Self.stopReceipt(runs.find(r.runId) ?? r, terminal: false))
            case let .alreadyTerminal(now): return .success(Self.stopReceipt(now, terminal: true))
            case .notFound: return .failure(.notFound("no run \(r.runId)"))
            }
        }
    }

    /// Global stop (owner only): close input admission and stop every Run,
    /// Delegated and Durable, returning each one's stop state.
    func stopAll(_ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(RuntimeError("permission_denied", "only the owner stops all input", phase: .handler)) }
        let (admission, stopped) = execution.stopAll()
        let pending = stopped.filter { !$0.isEnded }.map(\.runId)
        return .success(.obj([
            ("admission", .string(admission.rawValue)),
            ("runs", .array(stopped.map { r in
                .obj([("runId", .string(r.runId)), ("accepted", .bool(true)), ("phase", .string(r.phase.rawValue)),
                      ("quiescence", .string(r.quiescence.rawValue)), ("outcome", r.outcome.map { .string($0.rawValue) } ?? .null)])
            })),
            ("pending", .array(pending.map(JSONValue.string))),
        ]))
    }

    func enableInput(_ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(RuntimeError("permission_denied", "only the owner enables input", phase: .handler)) }
        return execution.enableInput().map { .obj([("admission", .string($0.rawValue))]) }
    }
}
