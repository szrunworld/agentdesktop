import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    func ownRun(_ p: JSONValue, _ c: ConnectionState) -> Result<RunRecord, RuntimeError> {
        let id = p["runId"]?.stringValue ?? ""
        guard let r = runs.find(id), r.caller == c.peerUID else { return .failure(.notFound("no run \(id)")) }
        return .success(r)
    }

    /// Start an exec Run on the session's Desktop; this connection owns it.
    func startRun(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
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

    /// The shell is done: no new input, and the Run ends once quiescent.
    func finishRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            guard c.ownedRuns.contains(r.runId) else {
                return .failure(RuntimeError("permission_denied", "only the connection that started run \(r.runId) finishes it", phase: .handler))
            }
            let reason = p["exitCode"]?.intValue.map { "exit \($0)" } ?? "finished"
            switch execution.stop(runId: r.runId, reason: reason, endAs: .completed) {
            case let .accepted(now), let .alreadyTerminal(now): return .success(now.json)
            case .notFound: return .failure(.notFound("no run \(r.runId)"))
            }
        }.map { v in runs.find(p["runId"]?.stringValue ?? "")?.json ?? v }
    }

    func showRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).map(\.json)
    }

    func runEvents(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).map { r in
            let after = p["after"]?.intValue ?? 0
            let events = runs.events(r.runId, after: after, limit: p["limit"]?.intValue ?? 100)
            let next = events.last?["sequence"]?.intValue ?? after
            let ended = runs.find(r.runId)?.state.terminal ?? true
            return .obj([("events", .array(events)), ("next", .int(next)), ("ended", .bool(ended))])
        }
    }

    /// Observe the Run until it ends (or is quiescent); never changes it.
    func waitRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            let untilQuiescent = p["until"]?.stringValue == "quiescent"
            let deadline = Date().addingTimeInterval(Double(p["timeoutMs"]?.intValue ?? 0) / 1000)
            let last = runs.wait(r.runId, until: deadline) { untilQuiescent ? $0.quiescent : $0.state.terminal } ?? r
            if untilQuiescent ? last.quiescent : last.state.terminal { return .success(last.json) }
            return .failure(RuntimeError("wait_timeout", "run \(r.runId) is still \(last.state.rawValue)", phase: .handler,
                                         details: .obj([("state", .string(last.state.rawValue)), ("quiescent", .bool(last.quiescent))])))
        }
    }

    /// Accept a cancel: no new input from now on. Quiescence follows once
    /// no action is in flight; an ended Run keeps its own ending.
    func cancelRun(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ownRun(p, c).flatMap { r in
            func receipt(_ now: RunRecord, terminal: Bool) -> JSONValue {
                var m: [(String, JSONValue)] = [
                    ("cancelRequest", .obj([("accepted", .bool(true)),
                                            ("scope", .obj([("kind", .string("run")), ("id", .string(r.runId))]))])),
                    ("execution", .obj([("state", .string(now.state.rawValue)), ("quiescent", .bool(now.quiescent))])),
                ]
                if terminal { m.append(("alreadyTerminal", .bool(true))) }
                return .obj(m)
            }
            switch execution.stop(runId: r.runId, reason: "cancelled", endAs: .cancelled) {
            case .accepted:
                return .success(receipt(runs.find(r.runId) ?? r, terminal: false))
            case let .alreadyTerminal(now):
                return .success(receipt(now, terminal: true))
            case .notFound:
                return .failure(.notFound("no run \(r.runId)"))
            }
        }
    }
}
