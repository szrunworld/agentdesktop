import AgentDesktopClient
import AgentDesktopProtocol
import CryptoKit
import Foundation
@testable import AgentDesktopACP

// Layer: Mock. A fake runtime/1 that answers `unit.run` in the shapes frozen
// by #102 (contracts/runtime/v1: unit_run_params, Run + RunUnit,
// PlatformRunEvent, RequestRecord, CancelReceipt). What is validated
// against the embedded contract (violations collected in `violations`):
// the params of every request whose method runtime/1 defines (methods.json,
// plus unit.run from the frozen catalog), every success result against the
// method's result def, every error against `Error`, every stored RunEvent
// (`RunEvent`, and `PlatformRunEvent` for run./action./stop.), every pushed
// `EventFrame`. Not validated: the handshake (RuntimeIdentity is built by
// the client type, no request params pass through it), methods outside
// runtime/1 (ai.profiles.list, listed in `unvalidated`), and `unit.*`
// event data (not frozen). It is NOT the Runtime: passing tests here never mean A6 is
// done (docs/acp/12-unit-run.md §五).

/// One scenario fixture (Pending/UnitRun/Fixtures/ur-*.json).
struct URTestScenario: @unchecked Sendable {
    let raw: JSONValue
    var name: String { raw["name"]?.stringValue ?? "" }
    var e2eClass: String { raw["e2eClass"]?.stringValue ?? "" }
    var desktopId: String { raw["desktopId"]?.stringValue ?? "desk_A" }
    var input: JSONValue { raw["input"] ?? .obj([]) }
    var runtime: JSONValue { raw["runtime"] ?? .obj([]) }
    var expect: JSONValue { raw["expect"] ?? .obj([]) }
    var phaseAfterAccept: String { runtime["phaseAfterAccept"]?.stringValue ?? "running" }
    var onAccept: [JSONValue] { runtime["onAccept"]?.arrayValue ?? [] }
    var onTrigger: [JSONValue] { runtime["onTrigger"]?.arrayValue ?? [] }
    var cancelAfter: String? { runtime["trigger"]?["cancelAfter"]?.stringValue }
    var disconnectAfter: String? { runtime["trigger"]?["disconnectAfter"]?.stringValue }
    var endsAtAccept: Bool { runtime["trigger"]?.stringValue == "none" }
    var final: JSONValue { runtime["final"] ?? .obj([]) }

    static let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")

    static func load(_ name: String) throws -> URTestScenario {
        let data = try Data(contentsOf: directory.appendingPathComponent("\(name).json"))
        return URTestScenario(raw: try StrictJSON.parse(data))
    }

    static func json(_ name: String) throws -> JSONValue {
        try StrictJSON.parse(Data(contentsOf: directory.appendingPathComponent("\(name).json")))
    }

    /// The five E2E classes plus the time limit, in a stable order.
    static let flowNames = ["ur-normal", "ur-cancel", "ur-disconnect", "ur-approval-rejected", "ur-unknown", "ur-limit-exhausted"]
}

final class URTestRuntime: @unchecked Sendable {
    enum Answer {
        /// Accept and play the scenario.
        case scenario
        /// F40-06 precheck failure: no Run, a failed RequestRecord.
        case refuse(code: String, reason: String?, details: [(String, JSONValue)])
        /// Accept and record; the answer is lost on the way back.
        case loseAnswer
        /// Accept after `seconds` (longer than the caller waits).
        case hang(seconds: Double)
    }

    struct Call: Equatable { var connection: Int; var method: String; var requestId: String }

    struct RunState {
        var id: String
        var owner: Int
        var phase: String
        var outcome: String?
        var quiescence: String
        var closingReason: String?
        var revision: Int
        var unknownActions: Int
        var verification: String
        var params: JSONValue
        var createdAt: String
        var endedAt: String?
    }

    let lock = NSLock()
    let contract = RuntimeContract.shared
    let instanceId = "inst_ur"
    let uid: UInt32 = 501
    var scenario: URTestScenario
    var answer: Answer = .scenario
    var methods: Set<String> = URTestRuntime.withUnitRun
    var profiles: [JSONValue]?
    var calls: [Call] = []
    var violations: [String] = []
    var connections = 0
    var closed: Set<Int> = []
    var runs: [String: RunState] = [:]
    var events: [String: [JSONValue]] = [:]
    var ledger: [String: JSONValue] = [:]
    var unitRunParams: [JSONValue] = []
    private var nextRun = 1

    /// The methods a Runtime with A6 would list (runtime/1 today plus unit.run).
    static let withUnitRun: Set<String> = Set(RuntimeMethod.allCases.map(\.rawValue)).union(["unit.run"])
    static let withoutUnitRun: Set<String> = Set(RuntimeMethod.allCases.map(\.rawValue))

    init(_ scenario: URTestScenario) { self.scenario = scenario }

    func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var factory: ACPBridgeClientFactory { { [self] role in URTestClient(server: self, role: role) } }

    func count(_ method: String) -> Int { with { calls.filter { $0.method == method }.count } }
    var allViolations: [String] { with { violations } }
    func run(_ id: String) -> RunState? { with { runs[id] } }
    var onlyRun: RunState? { with { runs.values.first } }

    // MARK: Shapes

    static func at(_ i: Int) -> String { String(format: "2026-10-08T12:%02d:%02d.000Z", (i / 60) % 60, i % 60) }

    private func check(_ v: JSONValue, _ def: String, _ what: String) {
        for p in contract.validate(v, def) { violations.append("\(what) ✗ \(def): \(p)") }
    }

    static func goalHash(_ params: JSONValue) -> String {
        let d = params["goal"]?["description"]?.stringValue ?? ""
        return "sha256:" + SHA256.hash(data: Data(d.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func runJSON(_ r: RunState) -> JSONValue {
        var unit: [(String, JSONValue)] = [
            ("mode", r.params["mode"] ?? .string("auto")), ("goalHash", .string(Self.goalHash(r.params))),
            ("guiProfileId", r.params["guiProfileId"] ?? .null),
            ("guiProfileRevision", r.params["expectedProfileRevision"] ?? .null),
        ]
        unit.append(("verification", .obj([("status", .string(r.verification))])))
        var m: [(String, JSONValue)] = [
            ("runId", .string(r.id)), ("kind", .string("unit")), ("origin", .string("agent_hub")),
            ("ownership", .string("external_client")), ("lifetime", .string("connection_scoped")),
            ("clientId", .string("local:\(uid)")), ("connectionId", .string("conn_\(r.owner)")),
            ("sessionId", .string("sess_A")), ("desktopId", r.params["desktopId"] ?? .string("desk_A")),
            ("phase", .string(r.phase)), ("outcome", r.outcome.map(JSONValue.string) ?? .null),
            ("quiescence", .string(r.quiescence)), ("closingReason", r.closingReason.map(JSONValue.string) ?? .null),
            ("revision", .int(r.revision)), ("createdAt", .string(r.createdAt)),
        ]
        if let e = r.endedAt { m.append(("endedAt", .string(e))) }
        m += [("receipts", .array([])), ("unknownActions", .int(r.unknownActions)), ("unit", .obj(unit))]
        let v = JSONValue.obj(m)
        check(v, "Run", "Run \(r.id)")
        return v
    }

    static func substitute(_ v: JSONValue, runId: String) -> JSONValue {
        switch v {
        case let .string(s) where s == "$RUN": return .string(runId)
        case let .object(m): return .object(m.map { (key: $0.key, value: substitute($0.value, runId: runId)) })
        case let .array(a): return .array(a.map { substitute($0, runId: runId) })
        default: return v
        }
    }

    /// Append scenario events (`{type, data}`) to a Run's stream as RunEvents.
    private func append(_ runId: String, _ list: [JSONValue]) {
        for e in list {
            let seq = (events[runId]?.count ?? 0) + 1
            let type = e["type"]?.stringValue ?? ""
            let ev = JSONValue.obj([("runId", .string(runId)), ("sequence", .int(seq)), ("at", .string(Self.at(seq))),
                                    ("type", .string(type)), ("data", Self.substitute(e["data"] ?? .obj([]), runId: runId))])
            check(ev, "RunEvent", "event \(type)")
            if ["run.", "action.", "stop."].contains(where: { type.hasPrefix($0) }) {
                check(ev, "PlatformRunEvent", "event \(type)")
            }
            events[runId, default: []].append(ev)
        }
    }

    private func finish(_ runId: String) {
        guard var r = runs[runId] else { return }
        let f = scenario.final
        r.phase = "ended"
        r.quiescence = "confirmed"
        r.outcome = f["outcome"]?.stringValue ?? "unknown"
        r.closingReason = f["closingReason"]?.stringValue
        r.unknownActions = f["unknownActions"]?.intValue ?? 0
        r.verification = f["verification"]?.stringValue ?? "not_run"
        r.revision += 1
        r.endedAt = Self.at(events[runId]?.count ?? 0)
        runs[runId] = r
    }

    private func record(_ requestId: String, state: String, outcome: JSONValue) {
        let rec = JSONValue.obj([("requestId", .string(requestId)), ("method", .string("unit.run")), ("state", .string(state)),
                                 ("acceptedAt", .string(Self.at(0))), ("finishedAt", .string(Self.at(0))), ("outcome", outcome)])
        check(rec, "RequestRecord", "RequestRecord \(requestId)")
        ledger[requestId] = rec
    }

    private func refuse(_ requestId: String, _ e: RuntimeError) -> RuntimeError {
        record(requestId, state: "failed", outcome: .obj([("error", e.json)]))
        return e
    }

    // MARK: Server side

    /// A pushed event frame (events.subscribe stream) against `EventFrame`.
    func checkFrame(_ f: JSONValue) { with { check(f, "EventFrame", "pushed frame") } }

    func connectionClosed(_ conn: Int) {
        with {
            guard !closed.contains(conn) else { return }
            closed.insert(conn)
            // ADR v2.2: the Delegated Runs of a lost control connection stop.
            for (id, r) in runs where r.owner == conn && r.phase != "ended" {
                if scenario.disconnectAfter != nil {
                    append(id, scenario.onTrigger)
                } else {
                    append(id, [.obj([("type", .string("stop.accepted")), ("data", .obj([("reason", .string("owner_lost")),
                                                                                          ("inFlight", .bool(false)), ("revision", .int(r.revision + 1))]))]),
                                .obj([("type", .string("run.quiescent")), ("data", .obj([("revision", .int(r.revision + 2))]))]),
                                .obj([("type", .string("run.ended")), ("data", .obj([("phase", .string("ended")), ("outcome", .string("cancelled")),
                                                                                      ("reason", .string("owner_lost"))]))])])
                }
                finish(id)
                if scenario.disconnectAfter == nil { runs[id]?.outcome = "cancelled"; runs[id]?.closingReason = "owner_lost" }
            }
        }
    }

    var answerIsHang: Double? { with { if case let .hang(s) = answer { return s } else { return nil } } }

    /// The contract's params and result defs of a method: methods.json
    /// `methods`, plus the frozen catalog entry for unit.run. Nil for a
    /// method the runtime/1 contract does not define (ai.profiles.list is
    /// ai-gui/v1), which is then recorded in `unvalidated`.
    func defs(_ method: String) -> (params: String, result: String)? {
        if method == "unit.run" { return ("unit_run_params", "Run") }
        return contract.method(method).map { ($0.params, $0.result) }
    }

    /// Methods answered without a contract to check them against.
    var unvalidated: Set<String> = []

    /// Every request: params checked against the method's params def; every
    /// answer against its result def; every error against `Error`.
    func handle(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(connection: conn, method: r.method, requestId: r.requestId))
        let d = defs(r.method)
        if let d { check(r.params, d.params, "params of \(r.method)") } else { unvalidated.insert(r.method) }
        do {
            let v = try respond(conn, r)
            if let d { check(v, d.result, "result of \(r.method)") }
            return v
        } catch let e as RuntimeError {
            check(e.json, "Error", "error of \(r.method)")
            throw e
        }
    }

    private func respond(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        guard methods.contains(r.method) else { throw RuntimeError.capabilityMissing("method \(r.method) is not available") }
        let p = r.params
        switch r.method {
        case "runtime.status":
            return .obj([("instanceId", .string(instanceId)), ("state", .string("running")), ("startedAt", .string(Self.at(0))),
                         ("uptimeSeconds", .int(1)), ("connections", .int(connections)), ("desktops", .int(1)),
                         ("sessions", .int(1)), ("runs", .int(runs.count))])
        case "runtime.capabilities":
            let listed = methods.sorted().map { m -> JSONValue in
                let spec = contract.method(m)
                return .obj([("method", .string(m)), ("mutation", .bool(spec?.mutation ?? (m == "unit.run"))),
                             ("stage", .string(spec?.stage ?? "P0"))])
            }
            return .obj([("apiVersion", .string(RuntimeAPI.version)), ("interface", .obj([("methods", .array(listed))])),
                         ("backend", .obj([("platform", .obj([("os", .string("macos")), ("osVersion", .string("15.1")), ("arch", .string("arm64"))])),
                                           ("permissions", .obj([("screenRecording", .string("granted")), ("accessibility", .string("granted"))])),
                                           ("features", .array([]))]))])
        case "ai.profiles.list":
            return .obj([("items", .array(profiles ?? [])), ("nextCursor", .null)])
        case "unit.run":
            return try unitRun(conn, r)
        case "request.show":
            guard let rec = ledger[p["requestId"]?.stringValue ?? ""] else { throw RuntimeError.notFound("no request") }
            return rec
        case "run.show":
            guard let run = runs[p["runId"]?.stringValue ?? ""] else { throw RuntimeError.notFound("no run") }
            return runJSON(run)
        case "run.cancel":
            let id = p["runId"]?.stringValue ?? ""
            guard var run = runs[id] else { throw RuntimeError.notFound("no run") }
            let already = run.phase == "ended"
            if !already, ledger[r.requestId] == nil {
                run.phase = "stopping"; run.quiescence = "pending"; run.revision += 1
                runs[id] = run
                if scenario.cancelAfter != nil {
                    append(id, scenario.onTrigger)
                    finish(id)
                }
                ledger[r.requestId] = .obj([("requestId", .string(r.requestId)), ("method", .string("run.cancel")),
                                            ("state", .string("completed")), ("acceptedAt", .string(Self.at(0)))])
            }
            let now = runs[id]!
            let receipt = JSONValue.obj([
                ("cancelRequest", .obj([("accepted", .bool(true)), ("scope", .obj([("kind", .string("run")), ("id", .string(id))]))])),
                ("execution", .obj([("phase", .string(now.phase)), ("quiescence", .string(now.quiescence)),
                                    ("outcome", now.outcome.map(JSONValue.string) ?? .null), ("revision", .int(now.revision))])),
                ("alreadyTerminal", .bool(already)),
            ])
            check(receipt, "CancelReceipt", "CancelReceipt")
            return receipt
        case "events.subscribe":
            if runs.values.contains(where: { $0.owner == conn && $0.phase != "ended" }) {
                throw RuntimeError("conflict", "this connection controls a live Run", phase: .handler,
                                   details: .obj([("reason", .string("control_connection"))]))
            }
            var sub: [(String, JSONValue)] = [("subscribed", .bool(true))]
            if let id = p["runId"] { sub.append(("runId", id)) }
            sub.append(("next", .int(p["after"]?.intValue ?? 0)))
            return .obj(sub)
        case "run.events":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run") }
            let after = p["after"]?.intValue ?? 0
            let list = (events[id] ?? []).filter { ($0["sequence"]?.intValue ?? 0) > after }
            return .obj([("events", .array(list)), ("next", .int(list.last?["sequence"]?.intValue ?? after)),
                         ("ended", .bool(runs[id]?.phase == "ended"))])
        default:
            throw RuntimeError.capabilityMissing("not scripted: \(r.method)")
        }
    }

    /// The Runtime side of unit.run as the contract and the A6 draft describe
    /// it: ledger replay, schema, escalation (F40-06 row 1), prechecks, Run.
    private func unitRun(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        if let prior = ledger[r.requestId] {
            if let data = prior["outcome"]?["data"] { return data }
            if let e = prior["outcome"]?["error"].flatMap(RuntimeError.init(json:)) { throw e }
            throw RuntimeError("request_acceptance_unknown", "unknown", phase: .handler)
        }
        unitRunParams.append(r.params)
        let schema = contract.validate(r.params, "unit_run_params")
        if !schema.isEmpty {
            throw refuse(r.requestId, RuntimeError("schema_invalid", "unit_run_params", phase: .request,
                                                   details: .obj([("fieldErrors", .array(schema.map(JSONValue.string)))])))
        }
        if ["origin", "lifetime", "ownership"].contains(where: { r.params[$0] != nil }) {
            throw refuse(r.requestId, RuntimeError("ownership_escalation_denied", "run axes come from the connection",
                                                   phase: .request, details: .obj([("reason", .string("ownership_from_params"))])))
        }
        if case let .refuse(code, reason, details) = answer {
            var d = details
            if let reason { d.insert(("reason", .string(reason)), at: 0) }
            throw refuse(r.requestId, RuntimeError(code, "refused before the Run was created", phase: .handler,
                                                   details: d.isEmpty ? nil : .obj(d)))
        }
        let id = String(format: "run_ab%06x", nextRun)
        nextRun += 1
        runs[id] = RunState(id: id, owner: conn, phase: scenario.phaseAfterAccept, outcome: nil, quiescence: "not_confirmed",
                            closingReason: nil, revision: 1, unknownActions: 0, verification: "not_run", params: r.params,
                            createdAt: Self.at(0), endedAt: nil)
        events[id] = []
        append(id, scenario.onAccept)
        let accepted = runJSON(runs[id]!)
        record(r.requestId, state: "completed", outcome: .obj([("data", accepted)]))
        if scenario.endsAtAccept { finish(id) }
        if case .loseAnswer = answer { throw RuntimeError.connectionLost("answer lost") }
        return accepted
    }
}

/// One fake connection to `URTestRuntime`.
final class URTestClient: RuntimeClient {
    let endpoint = Endpoint(path: "/tmp/adt-urtest.sock", source: .option)
    let server: URTestRuntime
    let role: ACPBridgeConnectionRole
    private var conn: Int?
    private var subscription: (runId: String, cursor: Int)?

    init(server: URTestRuntime, role: ACPBridgeConnectionRole) {
        self.server = server
        self.role = role
    }

    func handshake() throws -> RuntimeIdentity {
        if conn == nil { conn = server.with { server.connections += 1; return server.connections } }
        return RuntimeIdentity(instanceId: server.instanceId, pid: 1, startedAt: URTestRuntime.at(0),
                               endpoint: endpoint.path, buildSource: "urtest")
    }

    func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        if request.method == "unit.run", let s = server.answerIsHang {
            // Blocks the bridge's control queue, never the cooperative pool.
            Thread.sleep(forTimeInterval: s)
        }
        do {
            return try server.handle(conn!, request)
        } catch let e as RuntimeError where e.code == "connection_lost" {
            close()
            throw e
        }
    }

    func subscribe(runId: String?, after: Int?) throws -> JSONValue {
        _ = try handshake()
        var params: [(String, JSONValue)] = []
        if let runId { params.append(("runId", .string(runId))) }
        if let after { params.append(("after", .int(after))) }
        let answer = try server.handle(conn!, RuntimeRequest(.eventsSubscribe, params: .obj(params)))
        subscription = (runId ?? "", after ?? 0)
        return answer
    }

    func nextEvent() throws -> PushedEvent {
        guard var sub = subscription, conn != nil else { return .closed }
        let (frame, ended): (JSONValue?, Bool) = server.with {
            ((server.events[sub.runId] ?? []).first { ($0["sequence"]?.intValue ?? 0) > sub.cursor },
             server.runs[sub.runId]?.phase == "ended")
        }
        if let frame {
            sub.cursor = frame["sequence"]?.intValue ?? sub.cursor
            subscription = sub
            let f = JSONValue.obj([("apiVersion", .string(RuntimeAPI.version)), ("event", frame), ("cursor", .int(sub.cursor))])
            server.checkFrame(f)
            return .frame(f)
        }
        if ended { close(); return .closed }
        Thread.sleep(forTimeInterval: 0.005)
        return .idle
    }

    func close() {
        if let c = conn { server.connectionClosed(c) }
        conn = nil
        subscription = nil
    }
}
