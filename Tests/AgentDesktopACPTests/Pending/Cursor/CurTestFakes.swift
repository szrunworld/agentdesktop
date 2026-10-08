import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Fakes for the Run event cursor workpack (docs/acp/11-run-cursor.md).
//
// Layer rule: everything here is a FAKE. A test that passes against these
// proves ACP's own side (bridge de-dup, replay boundary, error mapping, no
// resubmission) only. It never proves that the Runtime cursor
// (Run.lastEventSequence, per-Run cursor errors) exists or works.

// MARK: Bridge level: a scripted Runtime behind fake RuntimeClients

/// A scripted runtime/1 server for `ACPBridgeRuntimePort`. It can misbehave
/// on purpose (ignore `after`, repeat frames, push frames of another Run,
/// drop a subscription) so the bridge's own de-dup is what keeps the stream
/// exact.
final class CurTestWire: @unchecked Sendable {
    struct Call: Equatable {
        var connection: Int
        var method: String
        var after: Int?
    }

    let lock = NSLock()
    var runs: [String: (phase: String, lifetime: String)] = [:]
    var events: [String: [JSONValue]] = [:]
    /// Put `lastEventSequence` on Runs (07 R10). nil: absent (today's Runtime).
    var lastEventSequenceOverride: [String: Int] = [:]
    var exposeLastEventSequence = false
    /// Thrown by `events.subscribe` (e.g. events_cursor_expired, not_found).
    var subscribeError: RuntimeError?
    /// A broken server that streams from sequence 1 whatever `after` said.
    var ignoreAfter = false
    /// Send every frame twice.
    var repeatFrames = false
    /// Frames naming another Run, pushed first on every subscription.
    var foreignFrames: [JSONValue] = []
    /// Close a subscription after this many frames, `dropsLeft` times.
    var dropAfterFrames: Int?
    var dropsLeft = 0
    var calls: [Call] = []
    var connections = 0

    func with<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try body()
    }

    var factory: ACPBridgeClientFactory { { [self] _ in CurTestClient(wire: self) } }

    func addRun(_ id: String, phase: String = "running", lifetime: String = "connection_scoped") {
        with {
            runs[id] = (phase, lifetime)
            if events[id] == nil { events[id] = [] }
        }
    }

    func emit(_ runId: String, _ type: String = "action.accepted") {
        with { emitLocked(runId, type) }
    }

    func emitLocked(_ runId: String, _ type: String) {
        let seq = (events[runId]?.count ?? 0) + 1
        events[runId, default: []].append(Self.event(runId, seq, type))
    }

    func end(_ runId: String) { with { runs[runId]?.phase = "ended" } }

    static func event(_ runId: String, _ seq: Int, _ type: String = "action.accepted") -> JSONValue {
        .obj([("runId", .string(runId)), ("sequence", .int(seq)), ("at", .string("2026-10-08T00:00:00Z")),
              ("type", .string(type)), ("data", .obj([]))])
    }

    func methods() -> [String] { with { calls.map(\.method) } }
    func subscribeAfters() -> [Int?] { with { calls.filter { $0.method == "events.subscribe" }.map(\.after) } }

    func runJSON(_ id: String) -> JSONValue {
        let r = runs[id]!
        var m: [(String, JSONValue)] = [
            ("runId", .string(id)), ("kind", .string("unit")), ("origin", .string("agent_hub")),
            ("ownership", .string("external_client")), ("lifetime", .string(r.lifetime)),
            ("phase", .string(r.phase)), ("quiescence", .string(r.phase == "ended" ? "confirmed" : "not_confirmed")),
            ("outcome", r.phase == "ended" ? .string("cancelled") : .null),
        ]
        if let v = lastEventSequenceOverride[id] {
            m.append(("lastEventSequence", .int(v)))
        } else if exposeLastEventSequence {
            m.append(("lastEventSequence", .int(events[id]?.count ?? 0)))
        }
        return .obj(m)
    }

    func handle(_ conn: Int, _ r: RuntimeRequest) throws -> JSONValue {
        lock.lock(); defer { lock.unlock() }
        let p = r.params
        calls.append(Call(connection: conn, method: r.method, after: p["after"]?.intValue))
        switch r.method {
        case "runtime.status":
            return .obj([("instanceId", .string("inst_cur")), ("state", .string("running"))])
        case "runtime.capabilities":
            return .obj([("apiVersion", .string(RuntimeAPI.version)), ("interface", .obj([("methods", .array([]))]))])
        case "run.show":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run \(id)") }
            return runJSON(id)
        case "run.events":
            let id = p["runId"]?.stringValue ?? ""
            guard runs[id] != nil else { throw RuntimeError.notFound("no run \(id)") }
            let after = p["after"]?.intValue ?? 0
            let list = (events[id] ?? []).filter { ($0["sequence"]?.intValue ?? 0) > after }
            return .obj([("events", .array(list)), ("next", .int(list.last?["sequence"]?.intValue ?? after)),
                         ("ended", .bool(runs[id]?.phase == "ended"))])
        default:
            throw RuntimeError.capabilityMissing("not scripted: \(r.method)")
        }
    }
}

/// One fake connection to `CurTestWire`.
final class CurTestClient: RuntimeClient {
    let endpoint = Endpoint(path: "/tmp/curtest.sock", source: .option)
    let wire: CurTestWire
    private var conn: Int?
    private var queue: [JSONValue] = []
    private var sub: (runId: String, cursor: Int, sent: Int)?

    init(wire: CurTestWire) { self.wire = wire }

    func handshake() throws -> RuntimeIdentity {
        if conn == nil { conn = wire.with { wire.connections += 1; return wire.connections } }
        return RuntimeIdentity(instanceId: "inst_cur", pid: 1, startedAt: "2026-10-08T00:00:00Z",
                               endpoint: endpoint.path, buildSource: "curtest")
    }

    func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        return try wire.handle(conn!, request)
    }

    func subscribe(runId: String?, after: Int?) throws -> JSONValue {
        _ = try handshake()
        try wire.with {
            wire.calls.append(CurTestWire.Call(connection: conn!, method: "events.subscribe", after: after))
            if let e = wire.subscribeError { throw e }
            guard let runId, wire.runs[runId] != nil else { throw RuntimeError.notFound("no run \(runId ?? "")") }
            queue = wire.foreignFrames
        }
        let start = wire.with { wire.ignoreAfter } ? 0 : (after ?? 0)
        sub = (runId ?? "", start, 0)
        return .obj([("subscribed", .bool(true)), ("next", .int(start))])
    }

    func nextEvent() throws -> PushedEvent {
        guard var s = sub, conn != nil else { return .closed }
        if !queue.isEmpty { return .frame(Self.frame(queue.removeFirst())) }
        let (next, ended, drop, repeatFrames): (JSONValue?, Bool, Bool, Bool) = wire.with {
            if let limit = wire.dropAfterFrames, wire.dropsLeft > 0, s.sent >= limit {
                wire.dropsLeft -= 1
                return (nil, false, true, false)
            }
            let n = (wire.events[s.runId] ?? []).first { ($0["sequence"]?.intValue ?? 0) > s.cursor }
            return (n, wire.runs[s.runId]?.phase == "ended", false, wire.repeatFrames)
        }
        if drop { close(); return .closed }
        if let next {
            s.cursor = next["sequence"]?.intValue ?? s.cursor
            s.sent += 1
            sub = s
            if repeatFrames { queue.append(next) }
            return .frame(Self.frame(next))
        }
        if ended { close(); return .closed }
        Thread.sleep(forTimeInterval: 0.005)
        return .idle
    }

    func close() {
        conn = nil
        sub = nil
        queue = []
    }

    static func frame(_ e: JSONValue) -> JSONValue {
        .obj([("apiVersion", .string(RuntimeAPI.version)), ("event", e), ("cursor", .int(e["sequence"]?.intValue ?? 0))])
    }
}

enum CurTestBridge {
    static func port(_ wire: CurTestWire) throws -> ACPBridgeRuntimePort {
        var config = ACPBridgeConfiguration()
        config.callTimeout = 5
        config.pollInterval = 0.005
        config.maxReconnects = 2
        config.uid = 501
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("curtest-\(UUID().uuidString)").appendingPathComponent("submissions.json").path
        return ACPBridgeRuntimePort(makeClient: wire.factory, log: try ACPSubmissionLog(path: path), config: config)
    }

    /// Collect a stream to its end (or `limit`), keeping a thrown error.
    static func drain(_ s: AsyncThrowingStream<ACPRuntimeEvent, Error>, limit: Int = 100)
        async -> (events: [ACPRuntimeEvent], error: Error?) {
        var out: [ACPRuntimeEvent] = []
        do {
            for try await e in s {
                out.append(e)
                if out.count >= limit { break }
            }
        } catch {
            return (out, error)
        }
        return (out, nil)
    }
}

// MARK: Server level: a scripted ACPRuntimePort

/// An `ACPRuntimePort` whose snapshot may or may not carry `lastCursor`
/// (07 R10), whose streams can repeat events, push foreign ones or fail with
/// a cursor error, and which records every mutation so tests can prove that
/// a resume never submits, cancels or restarts anything.
final class CurTestPort: ACPRuntimePort, @unchecked Sendable {
    struct Run {
        var snapshot: ACPRunSnapshot
        var events: [ACPRuntimeEvent] = []
        var conts: [AsyncThrowingStream<ACPRuntimeEvent, Error>.Continuation] = []
        /// Owned by the current editor connection (Delegated).
        var ownedByConnection = false
    }

    let callerValue = STestLocked(ACPCaller(principalId: "alice", clientId: "editor-1", connectionId: "c1"))
    let runs = STestLocked<[String: Run]>([:])
    /// Report `lastCursor` on snapshots (the Runtime has R10).
    let exposeLastCursor = STestLocked(false)
    /// Each events() call: (runId, after).
    let eventsCalls = STestLocked<[(String, Int?)]>([])
    let snapshotCalls = STestLocked<[String]>([])
    let submissions = STestLocked<[ACPSubmission]>([])
    let cancels = STestLocked<[String]>([])
    let connectionLostCount = STestLocked(0)
    /// A stream for this Run fails right after its history with this error.
    let streamError = STestLocked<[String: ACPError]>([:])
    /// Streams repeat every history event and ignore `after` (a broken source).
    let sloppyStreams = STestLocked(false)
    /// Called after a snapshot was taken, before it is returned: lets a test
    /// emit an event exactly on the live/history boundary.
    let afterSnapshot = STestLocked<(@Sendable (String) -> Void)?>(nil)

    func caller() async throws -> ACPCaller { callerValue.get() }
    func tasks() async throws -> [ACPExposedTask] { [] }

    func submit(_ submission: ACPSubmission) async throws -> ACPSubmissionReceipt {
        submissions.with { $0.append(submission) }
        return .refused(code: "capability_missing", message: "cursor tests never submit")
    }

    func snapshot(runId: String) async throws -> ACPRunSnapshot {
        snapshotCalls.with { $0.append(runId) }
        guard let r = runs.get()[runId] else { throw ACPError(code: -32000, reason: "not_found", message: "no run") }
        var snap = r.snapshot
        snap.lastCursor = exposeLastCursor.get() ? (r.events.last?.cursor ?? 0) : nil
        afterSnapshot.get()?(runId)
        return snap
    }

    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        cancels.with { $0.append(runId) }
        guard let r = runs.get()[runId] else { throw ACPError(code: -32000, reason: "not_found", message: "no run") }
        return r.snapshot
    }

    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        eventsCalls.with { $0.append((runId, cursor)) }
        let (stream, cont) = AsyncThrowingStream.makeStream(of: ACPRuntimeEvent.self, throwing: Error.self)
        let sloppy = sloppyStreams.get()
        let failure = streamError.get()[runId]
        runs.with { all in
            guard var r = all[runId] else {
                cont.finish(throwing: ACPError(code: -32000, reason: "not_found", message: "no run"))
                return
            }
            for e in r.events where sloppy || cursor == nil || e.cursor > cursor! {
                cont.yield(e)
                if sloppy { cont.yield(e) }
            }
            if let failure { cont.finish(throwing: failure); return }
            if r.snapshot.phase == "ended" { cont.finish() } else { r.conts.append(cont) }
            all[runId] = r
        }
        return stream
    }

    func pending(runId: String) async throws -> [ACPPendingDecision] { [] }
    func decide(approvalId: String, allow: Bool) async throws {}
    func answer(questionId: String, text: String) async throws {}

    /// ADR v2.2 as the Runtime applies it: the Delegated Runs of the lost
    /// control connection end (owner_lost). Nothing is resumed later.
    func connectionLost() async {
        connectionLostCount.with { $0 += 1 }
        let owned = runs.get().filter { $0.value.ownedByConnection && $0.value.snapshot.phase != "ended" }.map(\.key)
        for id in owned { end(id, outcome: "cancelled") }
    }

    // Scripting

    func addRun(_ id: String, phase: String = "running", lifetime: String = "connection_scoped", owned: Bool = false) {
        runs.with {
            $0[id] = Run(snapshot: ACPRunSnapshot(runId: id, phase: phase, outcome: nil,
                                                  quiescence: phase == "ended" ? "confirmed" : "not_confirmed",
                                                  lifetime: lifetime),
                         ownedByConnection: owned)
        }
    }

    func emit(_ runId: String, cursor: Int, text: String? = nil) {
        let e = ACPRuntimeEvent(runId: runId, cursor: cursor, type: "text",
                                payload: .obj([("text", .string(text ?? "\(runId)-\(cursor)"))]))
        runs.with { all in
            all[runId]?.events.append(e)
            all[runId]?.conts.forEach { $0.yield(e) }
        }
    }

    /// Push an event on a Run's live streams without recording it.
    func inject(into runId: String, _ e: ACPRuntimeEvent) {
        runs.with { all in all[runId]?.conts.forEach { $0.yield(e) } }
    }

    func end(_ runId: String, outcome: String) {
        runs.with { all in
            all[runId]?.snapshot.phase = "ended"
            all[runId]?.snapshot.outcome = outcome
            all[runId]?.snapshot.quiescence = "confirmed"
            all[runId]?.conts.forEach { $0.finish() }
            all[runId]?.conts = []
        }
    }
}

/// One editor connection served by `ACPAgentServer` over a `CurTestPort`,
/// with a session store that survives "reconnects" (new harness, same dir).
final class CurTestHarness: @unchecked Sendable {
    let dir: URL
    let connection = STestConnection()
    let port: CurTestPort
    let store: ACPFileSessionStore
    let server: ACPAgentServer
    let runTask: Task<Void, Never>

    init(port: CurTestPort, dir: URL? = nil) {
        self.dir = dir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-cur-tests-\(UUID().uuidString)", isDirectory: true)
        self.port = port
        store = ACPFileSessionStore(directory: self.dir)
        var config = ACPAgentServerConfig()
        config.pollInterval = .milliseconds(5)
        config.holdTime = .seconds(5)
        config.drainTimeout = .seconds(2)
        config.replayTimeout = .seconds(5)
        server = ACPAgentServer(connection: connection, runtime: port, projector: STestProjector(), store: store,
                                config: config)
        let s = server
        runTask = Task { await s.run() }
    }

    /// A stored session that references `runIds`, as a previous connection
    /// left it.
    func seed(_ sid: String, principal: String = "alice", runIds: [String], lastCursor: [String: Int] = [:]) throws {
        try store.save(ACPSessionBinding(acpSessionId: sid, principalId: principal, clientId: "editor-0", cwd: "/tmp/p",
                                         title: "t", runIds: runIds, lastCursor: lastCursor, options: [],
                                         createdAt: "2026-10-08T00:00:00Z", updatedAt: "2026-10-08T00:00:00Z",
                                         revision: 1))
    }

    /// The projected text lines of Run events ("[run#cursor] text").
    func eventLines(_ sid: String) -> [String] {
        connection.messages(sid).filter { $0.hasPrefix("[") }
    }

    func eventLinesBeforeReply(_ id: Int, _ sid: String) -> [String] {
        connection.updatesBeforeReply(id, sid).compactMap { u -> String? in
            if case let .agentMessage(t) = u, t.hasPrefix("[") { return t }
            return nil
        }
    }

    func disconnect() async {
        connection.close()
        await runTask.value
    }

    func cleanup() {
        connection.close()
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: Real Runtime (side instance only)

/// Real-Runtime cursor tests run only against a test copy's socket, never
/// the product endpoint, and only once the Runtime owner shipped the cursor
/// contract. Until then every Real test is `.disabled`.
enum CurTestReal {
    /// Real cursor tests run only against a Runtime this test process
    /// launched (ACPTestRuntimeChild); there is no endpoint to point them at.
    static var enabled: Bool { ACPTestRuntimeChild.binary != nil && endedRunId != nil }

    /// An ended Run on the launched Runtime with at least three events.
    /// Until the cursor contract lands the test cannot create one itself.
    static var endedRunId: String? {
        ProcessInfo.processInfo.environment["CURTEST_REAL_RUN_ID"].flatMap { $0.isEmpty ? nil : $0 }
    }

    typealias NotATestCopy = ACPTestEndpointGuard.NotATestCopy

    /// Shared allowlist (ACPTestEndpointGuard); kept as a name for the cursor tests.
    static func checkedEndpoint(_ raw: String) throws -> String { try ACPTestEndpointGuard.check(raw) }

    static func factory() throws -> ACPBridgeClientFactory {
        try ACPTestPinnedTransport.verifiedFactory(child: try ACPTestRuntimeChild.shared(),
                                                   name: "agentdesktop-acp-curtest")
    }

    static func port() throws -> ACPBridgeRuntimePort {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("curtest-real-\(UUID().uuidString)").appendingPathComponent("submissions.json").path
        return ACPBridgeRuntimePort(makeClient: try factory(), log: try ACPSubmissionLog(path: path))
    }

    /// Every event of a Run via run.events paging (the oracle).
    static func allEvents(_ client: RuntimeClient, _ runId: String) throws -> [JSONValue] {
        var out: [JSONValue] = []
        var after = 0
        while true {
            let page = try client.call(RuntimeRequest(.runEvents, params: .obj([
                ("runId", .string(runId)), ("after", .int(after)), ("limit", .int(500))])))
            let events = page["events"]?.arrayValue ?? []
            if events.isEmpty { return out }
            out += events
            after = events.last?["sequence"]?.intValue ?? after
        }
    }

    static let waiting = "waiting for Run.lastEventSequence / cursor contract: 07 R10 and 11-run-cursor §四 P1–P5 not in runtime/1 yet"
}
