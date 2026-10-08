import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
@testable import AgentDesktopACP

/// A scripted Runtime behind fake `RuntimeClient`s: a request ledger keyed by
/// requestId, Runs owned by the connection that submitted them (lost with
/// it, ADR v2.2), per-Run events, and a log of every request on every
/// connection. Only what the bridge uses.
final class RTestRuntime: @unchecked Sendable {
    enum UnitRunBehavior {
        case accept
        /// The Runtime accepts and records it, the answer never arrives.
        case loseAnswer
        /// The connection breaks before the request reached the Runtime.
        case loseBeforeArrival
        case refuse(code: String)
        /// Nothing listens: certain not sent.
        case offline
    }

    struct Call: Equatable { var connection: Int; var method: String; var requestId: String }

    let lock = NSLock()
    let instanceId = "inst_test"
    var methods: [String] = RuntimeMethod.allCases.map(\.rawValue)
    var profiles: [JSONValue]?
    var unitRun: UnitRunBehavior = .accept
    var requestShowFails = false
    var calls: [Call] = []
    var handshakes = 0
    var connections = 0
    var closed: Set<Int> = []
    var runs: [String: [String: String]] = [:]
    var runOwner: [String: Int] = [:]
    var events: [String: [JSONValue]] = [:]
    var ledger: [String: (method: String, state: String, outcome: JSONValue?)] = [:]
    var supportsPush = true
    /// Put `lastEventSequence` on Runs (07 R10).
    var exposeLastCursor = false
    /// Close a subscription after this many frames (simulated drop).
    var dropAfterFrames: Int?
    var dropsLeft = 0
    private var nextRun = 1

    func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var factory: ACPBridgeClientFactory {
        { [self] role in RTestClient(server: self, role: role) }
    }

    func methodCalls(_ m: String) -> [Call] { with { calls.filter { $0.method == m } } }

    // MARK: Scripting

    func addRun(_ id: String, phase: String = "running", owner: Int? = nil) {
        with {
            runs[id] = ["phase": phase, "quiescence": phase == "ended" ? "confirmed" : "not_confirmed",
                        "lifetime": "connection_scoped", "connectionId": "conn_\(owner ?? 0)"]
            if let owner { runOwner[id] = owner }
            if events[id] == nil { events[id] = [] }
        }
    }

    func emit(_ runId: String, _ type: String) {
        with {
            let seq = (events[runId]?.count ?? 0) + 1
            events[runId, default: []].append(.obj([
                ("runId", .string(runId)), ("sequence", .int(seq)), ("at", .string("2026-10-08T00:00:00Z")),
                ("type", .string(type)), ("data", .obj([("n", .int(seq))]))]))
        }
    }

    func end(_ runId: String, outcome: String) {
        with {
            runs[runId]?["phase"] = "ended"
            runs[runId]?["quiescence"] = "confirmed"
            runs[runId]?["outcome"] = outcome
        }
    }

    // MARK: Server side

    func runJSON(_ id: String) -> JSONValue {
        let r = runs[id] ?? [:]
        return .obj([("runId", .string(id)), ("kind", .string("unit")), ("origin", .string("agent_hub")),
                     ("ownership", .string("external_client")), ("lifetime", .string(r["lifetime"] ?? "")),
                     ("connectionId", .string(r["connectionId"] ?? "")), ("phase", .string(r["phase"] ?? "")),
                     ("outcome", r["outcome"].map(JSONValue.string) ?? .null), ("quiescence", .string(r["quiescence"] ?? ""))])
            .setting("lastEventSequence", exposeLastCursor ? .int(events[id]?.count ?? 0) : .null)
            .dropNull("lastEventSequence")
    }

    func connectionClosed(_ conn: Int) {
        with {
            guard !closed.contains(conn) else { return }
            closed.insert(conn)
            // ADR v2.2: Delegated Runs of a lost control connection stop.
            for (id, owner) in runOwner where owner == conn && runs[id]?["phase"] != "ended" {
                runs[id]?["phase"] = "stopping"
                runs[id]?["quiescence"] = "pending"
                runs[id]?["closingReason"] = "owner_lost"
            }
        }
    }

    func handle(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(connection: conn, method: r.method, requestId: r.requestId))
        guard methods.contains(r.method) else { throw RuntimeError.capabilityMissing("method \(r.method) is not available") }
        let p = r.params
        switch r.method {
        case "runtime.status":
            return .obj([("instanceId", .string(instanceId)), ("state", .string("running"))])
        case "runtime.capabilities":
            return .obj([("apiVersion", .string(RuntimeAPI.version)),
                         ("interface", .obj([("methods", .array(methods.map { .obj([("method", .string($0))]) }))]))])
        case "ai.profiles.list":
            return .obj([("items", .array(profiles ?? [])), ("nextCursor", .null)])
        case "unit.run":
            if let prior = ledger[r.requestId] {
                if case let .object(o)? = prior.outcome, let d = o.first(where: { $0.key == "data" }) { return d.value }
                throw RuntimeError("request_acceptance_unknown", "unknown", phase: .handler)
            }
            switch unitRun {
            case .offline:
                throw RuntimeError.runtimeOffline("nothing listens", endpoint: "/tmp/x")
            case .loseBeforeArrival:
                throw RuntimeError.connectionLost("broken before arrival")
            case let .refuse(code):
                let e = RuntimeError(code, "refused by test", phase: .handler)
                ledger[r.requestId] = ("unit.run", "failed", .obj([("error", e.json)]))
                throw e
            case .accept, .loseAnswer:
                let id = "run_\(nextRun)"; nextRun += 1
                runs[id] = ["phase": "running", "quiescence": "not_confirmed", "lifetime": "connection_scoped",
                            "connectionId": "conn_\(conn)"]
                runOwner[id] = conn
                events[id] = []
                let run = runJSON(id)
                ledger[r.requestId] = ("unit.run", "completed", .obj([("data", run)]))
                if case .loseAnswer = unitRun { throw RuntimeError.connectionLost("answer lost") }
                return run
            }
        case "request.show":
            if requestShowFails { throw RuntimeError.connectionLost("lost again") }
            guard let rec = ledger[p["requestId"]?.stringValue ?? ""] else { throw RuntimeError.notFound("no request") }
            var m: [(String, JSONValue)] = [("requestId", p["requestId"]!), ("method", .string(rec.method)),
                                            ("state", .string(rec.state)), ("acceptedAt", .string("2026-10-08T00:00:00Z"))]
            if let o = rec.outcome { m.append(("outcome", o)) }
            return .obj(m)
        case "events.subscribe":
            // The Runtime refuses a stream on a connection that controls a live Run.
            if runOwner.contains(where: { $0.value == conn && runs[$0.key]?["phase"] != "ended" }) {
                throw RuntimeError("conflict", "this connection controls a live Run", phase: .handler,
                                   details: .obj([("reason", .string("control_connection"))]))
            }
            return .obj([("subscribed", .bool(true))])
        case "run.show":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run \(id)") }
            return runJSON(id)
        case "run.cancel":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run \(id)") }
            if ledger[r.requestId] == nil {
                if runs[id]?["phase"] != "ended" {
                    runs[id]?["phase"] = "stopping"
                    runs[id]?["quiescence"] = "pending"
                }
                ledger[r.requestId] = ("run.cancel", "completed", nil)
            }
            let run = runs[id]!
            return .obj([("cancelRequest", .obj([("accepted", .bool(true))])),
                         ("execution", .obj([("phase", .string(run["phase"]!)), ("quiescence", .string(run["quiescence"]!)),
                                             ("outcome", run["outcome"].map(JSONValue.string) ?? .null), ("revision", .int(2))]))])
        case "run.events":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run \(id)") }
            let after = p["after"]?.intValue ?? 0
            let list = (events[id] ?? []).filter { ($0["sequence"]?.intValue ?? 0) > after }
            return .obj([("events", .array(list)), ("next", .int(list.last?["sequence"]?.intValue ?? after)),
                         ("ended", .bool(runs[id]?["phase"] == "ended"))])
        default:
            throw RuntimeError.capabilityMissing("not scripted: \(r.method)")
        }
    }
}

/// One fake connection to `RTestRuntime`.
class RTestClient: RuntimeClient {
    let endpoint = Endpoint(path: "/tmp/rtest.sock", source: .option)
    let server: RTestRuntime
    let role: ACPBridgeConnectionRole
    private var conn: Int?
    private var subscription: (runId: String, cursor: Int, sent: Int)?

    init(server: RTestRuntime, role: ACPBridgeConnectionRole) {
        self.server = server
        self.role = role
    }

    func handshake() throws -> RuntimeIdentity {
        if conn == nil {
            conn = server.with { server.connections += 1; return server.connections }
        }
        server.with { server.handshakes += 1 }
        return RuntimeIdentity(instanceId: server.instanceId, pid: 1, startedAt: "2026-10-08T00:00:00Z",
                               endpoint: endpoint.path, buildSource: "test")
    }

    func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        do {
            return try server.handle(conn!, request)
        } catch let e as RuntimeError where e.code == "connection_lost" {
            close()
            throw e
        }
    }

    func subscribe(runId: String?, after: Int?) throws -> JSONValue {
        _ = try handshake()
        guard server.with({ server.supportsPush }) else {
            throw RuntimeError.capabilityMissing("no push")
        }
        let r = try server.handle(conn!, RuntimeRequest(.eventsSubscribe, params: .obj([])))
        _ = r
        subscription = (runId ?? "", after ?? 0, 0)
        return .obj([("subscribed", .bool(true)), ("next", .int(after ?? 0))])
    }

    func nextEvent() throws -> PushedEvent {
        guard var sub = subscription, conn != nil else { return .closed }
        let (frame, ended, drop): (JSONValue?, Bool, Bool) = server.with {
            if let limit = server.dropAfterFrames, server.dropsLeft > 0, sub.sent >= limit {
                server.dropsLeft -= 1
                return (nil, false, true)
            }
            let next = (server.events[sub.runId] ?? []).first { ($0["sequence"]?.intValue ?? 0) > sub.cursor }
            return (next, server.runs[sub.runId]?["phase"] == "ended", false)
        }
        if drop { close(); return .closed }
        if let frame {
            sub.cursor = frame["sequence"]?.intValue ?? sub.cursor
            sub.sent += 1
            subscription = sub
            return .frame(.obj([("apiVersion", .string(RuntimeAPI.version)), ("event", frame), ("cursor", .int(sub.cursor))]))
        }
        if ended { close(); return .closed }
        Thread.sleep(forTimeInterval: 0.01)
        return .idle
    }

    func close() {
        if let c = conn { server.connectionClosed(c) }
        conn = nil
        subscription = nil
    }
}

enum RTest {
    static func tempLogPath() -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rtest-\(UUID().uuidString)")
        return dir.appendingPathComponent("submissions.json").path
    }

    static func port(_ server: RTestRuntime, logPath: String = tempLogPath(), timeout: Double = 5) throws -> ACPBridgeRuntimePort {
        var config = ACPBridgeConfiguration()
        config.callTimeout = timeout
        config.pollInterval = 0.01
        config.uid = 501
        return ACPBridgeRuntimePort(makeClient: server.factory, log: try ACPSubmissionLog(path: logPath), config: config)
    }

    static let validInput = JSONValue.obj([
        ("mode", .string("explore")),
        ("goal", .obj([("description", .string("open the about window"))])),
        ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string("About"))])]))])),
        ("allowedActions", .array([.string("click")])),
    ])

    static func submission(_ key: String = "sess-1/prompt-1", task: String = "unit.run",
                           input: JSONValue = validInput, desktop: String? = "desk_A") -> ACPSubmission {
        ACPSubmission(submissionKey: key, acpSessionId: "sess-1", taskType: task, input: input, desktopId: desktop)
    }

    static func collect(_ s: AsyncThrowingStream<ACPRuntimeEvent, Error>, limit: Int = 100) async throws -> [ACPRuntimeEvent] {
        var out: [ACPRuntimeEvent] = []
        for try await e in s {
            out.append(e)
            if out.count >= limit { break }
        }
        return out
    }
}

extension JSONValue {
    func dropNull(_ key: String) -> JSONValue {
        guard case let .object(m) = self else { return self }
        return .object(m.filter { !($0.key == key && $0.value.isNull) })
    }
}
