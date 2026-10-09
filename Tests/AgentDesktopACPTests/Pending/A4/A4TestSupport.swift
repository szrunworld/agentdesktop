import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// A4 (client identity) helper workpack — docs/acp/10-a4-identity.md.
//
// Layers, stated in every test's name and tag:
//   [Mock]          runs today against the fakes in this file; it checks
//                   ACP's own side only. Passing it is NOT A4 acceptance.
//   [Real·not run]  written against a real Runtime test copy, disabled
//                   until A4 (PR3) lands; see A4RealRuntimeTests.swift.

extension Tag {
    /// ACP side against a fake Runtime. Never evidence that A4 is done.
    @Tag static var a4Mock: Self
    /// Real Runtime; disabled until A4 lands.
    @Tag static var a4Real: Self
}

/// Credential-shaped strings an auth failure must never carry to the
/// editor, a log or a store. They look like what a Runtime might issue.
enum A4TestSecrets {
    static let credential = "adt_cred_7f3a9c2e5b1d4f6a8c0e2b4d6f8a1c3e"
    static let bearer = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhcHA6ZXZpbCJ9.c2lnbmF0dXJlLXNpZ25hdHVyZQ"
    static var all: [String] { [credential, bearer] }
    /// A Runtime error message that (wrongly) echoes the credential.
    static var leakyMessage: String {
        "credential token=\(credential) was revoked; Authorization: Bearer \(bearer)"
    }

    static func leaked(in text: String) -> [String] { all.filter { text.contains($0) } }
}

// MARK: Fake ACPRuntimePort (for the inbound server, lane S)

/// A scripted `ACPRuntimePort`. Every call is counted so tests can prove
/// what ACP did NOT do (no resubmission, no foreign Run lookup).
final class A4TestPort: ACPRuntimePort, @unchecked Sendable {
    let callerResult = STestLocked<Result<ACPCaller, ACPError>>(
        .success(ACPCaller(principalId: "local:501", clientId: "local:501", connectionId: "conn_a4", verified: false)))
    let callerCalls = STestLocked(0)
    let taskList = STestLocked<[ACPExposedTask]>([STestHarness.task("work", freeText: true)])
    /// nil: accept with an already ended, successful Run.
    let submitScript = STestLocked<(@Sendable (ACPSubmission) -> ACPSubmissionReceipt)?>(nil)
    let submissions = STestLocked<[ACPSubmission]>([])
    let runs = STestLocked<[String: ACPRunSnapshot]>([:])
    let snapshotCalls = STestLocked<[String]>([])
    let cancels = STestLocked<[(String, String)]>([])
    let eventCalls = STestLocked<[String]>([])
    let connectionLostCount = STestLocked(0)
    private let counter = STestLocked(0)

    func caller() async throws -> ACPCaller {
        callerCalls.with { $0 += 1 }
        return try callerResult.get().get()
    }

    func tasks() async throws -> [ACPExposedTask] { taskList.get() }

    func submit(_ s: ACPSubmission) async throws -> ACPSubmissionReceipt {
        submissions.with { $0.append(s) }
        if let script = submitScript.get() { return script(s) }
        let id = "run_a4_\(counter.with { $0 += 1; return $0 })"
        let snap = ACPRunSnapshot(runId: id, phase: "ended", outcome: "success", quiescence: "confirmed",
                                  lifetime: "connection_scoped")
        runs.with { $0[id] = snap }
        return .accepted(snap)
    }

    func snapshot(runId: String) async throws -> ACPRunSnapshot {
        snapshotCalls.with { $0.append(runId) }
        guard let s = runs.get()[runId] else { throw ACPError(code: -32000, reason: "not_found", message: "no run") }
        return s
    }

    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        cancels.with { $0.append((runId, requestId)) }
        guard let s = runs.get()[runId] else { throw ACPError(code: -32000, reason: "not_found", message: "no run") }
        return s
    }

    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        eventCalls.with { $0.append(runId) }
        let (stream, cont) = AsyncThrowingStream.makeStream(of: ACPRuntimeEvent.self, throwing: Error.self)
        cont.finish()
        return stream
    }

    func pending(runId: String) async throws -> [ACPPendingDecision] {
        throw ACPError(code: -32000, reason: "capability_missing", message: "no inbox")
    }

    func decide(approvalId: String, allow: Bool) async throws {
        throw ACPError(code: -32000, reason: "capability_missing", message: "no inbox")
    }

    func answer(questionId: String, text: String) async throws {
        throw ACPError(code: -32000, reason: "capability_missing", message: "no inbox")
    }

    func connectionLost() async { connectionLostCount.with { $0 += 1 } }

    var submitCount: Int { submissions.get().count }
}

/// One inbound server (lane S) over `A4TestPort`, the real file store and
/// the shared S-lane fake editor connection.
final class A4TestServer: @unchecked Sendable {
    let dir: URL
    let connection = STestConnection(version: .v1)
    let port: A4TestPort
    let store: ACPFileSessionStore
    let server: ACPAgentServer
    let runTask: Task<Void, Never>
    private let nextId = STestLocked(100)

    init(port: A4TestPort = A4TestPort(), dir: URL? = nil) {
        self.dir = dir ?? ACPTestScratch.dir("acp-a4-tests")
        self.port = port
        store = ACPFileSessionStore(directory: self.dir)
        var config = ACPAgentServerConfig()
        config.pollInterval = .milliseconds(5)
        config.holdTime = .seconds(5)
        config.drainTimeout = .milliseconds(300)
        server = ACPAgentServer(connection: connection, runtime: port, projector: STestProjector(), store: store,
                                config: config)
        let s = server
        runTask = Task { await s.run() }
    }

    func id() -> Int { nextId.with { $0 += 1; return $0 } }

    /// session/new; nil when the server answered with an error.
    func newSession(cwd: String = "/tmp/a4-project") async -> (sid: String?, reply: ACPReply?) {
        let i = id()
        connection.request(i, .newSession(cwd: cwd))
        let r = await connection.waitReply(i)
        if case let .sessionCreated(sid, _)? = r { return (sid, r) }
        return (nil, r)
    }

    /// Send a prompt and wait for the end of its turn.
    func prompt(_ sid: String, _ text: String) async -> ACPReply? {
        let i = id()
        connection.request(i, .prompt(sessionId: sid, content: [.text(text)]))
        return await connection.waitReply(i)
    }

    func request(_ incoming: ACPIncoming) async -> ACPReply? {
        let i = id()
        connection.request(i, incoming)
        return await connection.waitReply(i)
    }

    /// Every byte the server stored on disk, as text.
    func storedText() -> String {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return "" }
        var out = ""
        for case let url as URL in e {
            if let d = try? Data(contentsOf: url) { out += String(decoding: d, as: UTF8.self) + "\n" }
        }
        return out
    }

    /// Everything the editor received: replies and updates, as text.
    func editorText() -> String {
        let replies = connection.replies.get().map { String(describing: $0.1) }
        let updates = connection.updates.get().map { String(describing: $0.1) }
        return (replies + updates).joined(separator: "\n")
    }

    func cleanup() {
        connection.close()
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: Fake RuntimeClient (for the Runtime bridge, lane R)

/// A scripted Runtime with an A4-like identity model, behind fake
/// `RuntimeClient`s. The Runtime decides the principal of each connection;
/// nothing a client puts into params changes it. Only what the bridge uses.
final class A4TestRuntime: @unchecked Sendable {
    enum Credential: Equatable {
        case pairedValid
        case unpaired
        /// The handshake itself is refused with this code (proposed
        /// `credential_invalid` / `credential_expired`, existing
        /// `client_revoked` / `permission_denied`).
        case refusedAtHandshake(code: String)
    }

    struct Call: Equatable {
        var connection: Int
        var method: String
        var requestId: String
        var params: JSONValue
    }

    let lock = NSLock()
    let instanceId = "inst_a4"
    /// The principal the Runtime authenticated (never from params).
    var principal = "app:a4-editor"
    var credential: Credential = .pairedValid
    /// Revocation flips this; every later request on any open connection
    /// of the principal is refused with `client_revoked`.
    var revoked = false
    /// The message the Runtime puts on auth refusals (tests make it leaky).
    var refusalMessage = "the client is not authorized"
    var calls: [Call] = []
    var handshakes = 0
    var connections = 0
    /// runId → (owner principal, phase)
    var runs: [String: (owner: String, phase: String)] = [:]
    private var nextRun = 1

    func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var factory: ACPBridgeClientFactory { { [self] _ in A4TestClient(server: self) } }

    func count(_ method: String) -> Int { with { calls.filter { $0.method == method }.count } }
    func sent(_ method: String) -> [Call] { with { calls.filter { $0.method == method } } }

    func addForeignRun(_ id: String, owner: String = "app:someone-else") {
        with { runs[id] = (owner, "running") }
    }

    func handshake() throws {
        try with {
            handshakes += 1
            if case let .refusedAtHandshake(code) = credential {
                throw RuntimeError(code, refusalMessage, phase: .handshake)
            }
        }
    }

    func handle(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        lock.lock()
        defer { lock.unlock() }
        calls.append(Call(connection: conn, method: r.method, requestId: r.requestId, params: r.params))
        let p = r.params
        let openToAll: Set<String> = ["runtime.status", "runtime.capabilities"]
        if revoked, r.method != "runtime.status" {
            throw RuntimeError("client_revoked", refusalMessage, phase: .handler)
        }
        if credential == .unpaired, !openToAll.contains(r.method) {
            throw RuntimeError("pairing_required", refusalMessage, phase: .handler)
        }
        switch r.method {
        case "runtime.status":
            return .obj([("instanceId", .string(instanceId)), ("state", .string("running"))])
        case "runtime.capabilities":
            let methods = RuntimeMethod.allCases.map(\.rawValue) + ["unit.run"]
            return .obj([("apiVersion", .string(RuntimeAPI.version)),
                         ("interface", .obj([("methods", .array(methods.map { .obj([("method", .string($0))]) }))]))])
        case "unit.run":
            let id = "run_a4_\(nextRun)"; nextRun += 1
            runs[id] = (principal, "running")
            return runJSON(id, conn: conn)
        case "run.show":
            let id = p["runId"]?.stringValue ?? ""
            // Another principal's Run is indistinguishable from none.
            guard let run = runs[id], run.owner == principal else { throw RuntimeError.notFound("no run \(id)") }
            return runJSON(id, conn: conn)
        case "run.cancel":
            let id = p["runId"]?.stringValue ?? ""
            guard let run = runs[id], run.owner == principal else { throw RuntimeError.notFound("no run \(id)") }
            runs[id]?.phase = "stopping"
            return .obj([("cancelRequest", .obj([("accepted", .bool(true))])),
                         ("execution", .obj([("phase", .string("stopping")), ("quiescence", .string("pending")),
                                             ("outcome", .null), ("revision", .int(2))]))])
        case "request.show":
            throw RuntimeError.notFound("no request")
        default:
            throw RuntimeError.capabilityMissing("not scripted: \(r.method)")
        }
    }

    private func runJSON(_ id: String, conn: Int) -> JSONValue {
        .obj([("runId", .string(id)), ("kind", .string("unit")), ("origin", .string("agent_hub")),
              ("ownership", .string("external_client")), ("lifetime", .string("connection_scoped")),
              ("clientId", .string(runs[id]?.owner ?? "")), ("connectionId", .string("conn_\(conn)")),
              ("phase", .string(runs[id]?.phase ?? "")), ("outcome", .null), ("quiescence", .string("not_confirmed"))])
    }
}

final class A4TestClient: RuntimeClient {
    let endpoint = Endpoint(path: "/tmp/adt-a4-mock.sock", source: .option)
    let server: A4TestRuntime
    private var conn: Int?

    init(server: A4TestRuntime) { self.server = server }

    func handshake() throws -> RuntimeIdentity {
        try server.handshake()
        if conn == nil { conn = server.with { server.connections += 1; return server.connections } }
        // runtime/1 today: the identity is the Runtime's own, no principal.
        return RuntimeIdentity(instanceId: server.instanceId, pid: 1, startedAt: "2026-10-08T00:00:00Z",
                               endpoint: endpoint.path, buildSource: "test")
    }

    func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        return try server.handle(conn!, request)
    }

    func close() { conn = nil }
}

enum A4Test {
    static func port(_ server: A4TestRuntime, logPath: String? = nil) throws -> (ACPBridgeRuntimePort, String) {
        let path = logPath ?? ACPTestScratch.dir("acp-a4").appendingPathComponent("submissions.json").path
        var config = ACPBridgeConfiguration()
        config.callTimeout = 5
        config.pollInterval = 0.01
        config.uid = 501
        return (ACPBridgeRuntimePort(makeClient: server.factory, log: try ACPSubmissionLog(path: path), config: config), path)
    }

    static let validInput = JSONValue.obj([
        ("mode", .string("explore")),
        ("goal", .obj([("description", .string("open the about window"))])),
        ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")),
                                                     ("role", .string("static_text")), ("text", .string("About"))])]))])),
        ("allowedActions", .array([.string("click")])),
    ])

    static func submission(_ key: String = "a4-sess/prompt-1", input: JSONValue = validInput) -> ACPSubmission {
        ACPSubmission(submissionKey: key, acpSessionId: "a4-sess", taskType: "unit.run", input: input, desktopId: "desk_A")
    }

    static func input(adding key: String, _ value: JSONValue) -> JSONValue {
        guard case let .object(m) = validInput else { return validInput }
        return .object(m.filter { $0.key != key } + [(key: key, value: value)])
    }
}
