import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

// Lane S's own fakes of the other lanes' ports (docs/acp/03-lanes.md).

/// Polls `cond` until true or the timeout passes. The timeout is generous
/// on purpose: under the full parallel suite other tests block threads of
/// the cooperative pool, and a 3 s budget once ran out before a reply
/// (concurrentSessionsDoNotCrossStream). Polling returns as soon as `cond`
/// holds, so the budget costs nothing when things are fast.
func sEventually(_ timeout: Duration = .seconds(20), _ cond: @Sendable () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if cond() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return cond()
}

final class STestLocked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}

// MARK: Editor

final class STestConnection: ACPConnection, @unchecked Sendable {
    let version: ACPVersion
    let clientCapabilities: ACPClientCapabilities
    let events: AsyncStream<ACPConnectionEvent>
    private let continuation: AsyncStream<ACPConnectionEvent>.Continuation

    let replies = STestLocked<[(ACPRequestId, ACPReply)]>([])
    let updates = STestLocked<[(String, ACPSessionUpdate)]>([])
    let permissionRequests = STestLocked<[ACPPermissionRequest]>([])
    let questions = STestLocked<[ACPQuestion]>([])
    /// Replies and updates in the order they were sent ("reply:<id>", "update").
    let order = STestLocked<[String]>([])
    let permissionAnswer = STestLocked<@Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome>({ _ in .unavailable })
    let askAnswer = STestLocked<@Sendable (ACPQuestion) async -> ACPAnswer>({ _ in .unavailable })

    init(version: ACPVersion = .v1) {
        self.version = version
        clientCapabilities = ACPClientCapabilities()
        (events, continuation) = AsyncStream.makeStream(of: ACPConnectionEvent.self)
    }

    func reply(to id: ACPRequestId, _ reply: ACPReply) async {
        order.with { $0.append("reply:\(id.raw.intValue ?? -1)") }
        replies.with { $0.append((id, reply)) }
    }
    func send(sessionId: String, _ update: ACPSessionUpdate) async {
        order.with { $0.append("update") }
        updates.with { $0.append((sessionId, update)) }
    }

    /// Updates of `sid` sent before the answer to request `id`.
    func updatesBeforeReply(_ id: Int, _ sid: String) -> [ACPSessionUpdate] {
        let o = order.get()
        guard let cut = o.firstIndex(of: "reply:\(id)") else { return [] }
        let n = o[..<cut].filter { $0 == "update" }.count
        return Array(updates.get().prefix(n)).filter { $0.0 == sid }.map(\.1)
    }
    func requestPermission(_ request: ACPPermissionRequest) async -> ACPPermissionOutcome {
        permissionRequests.with { $0.append(request) }
        return await permissionAnswer.get()(request)
    }
    func ask(_ question: ACPQuestion) async -> ACPAnswer {
        questions.with { $0.append(question) }
        return await askAnswer.get()(question)
    }

    // Driving
    func request(_ id: Int, _ incoming: ACPIncoming) { continuation.yield(.request(ACPRequestId(.int(id)), incoming)) }
    func notify(_ incoming: ACPIncoming) { continuation.yield(.notification(incoming)) }
    func close(_ reason: String = "stdin closed") { continuation.yield(.closed(reason: reason)) }

    func replyFor(_ id: Int) -> ACPReply? {
        replies.get().first(where: { $0.0 == ACPRequestId(.int(id)) })?.1
    }

    func waitReply(_ id: Int, _ timeout: Duration = .seconds(20)) async -> ACPReply? {
        _ = await sEventually(timeout) { self.replyFor(id) != nil }
        return replyFor(id)
    }

    func messages(_ sid: String) -> [String] {
        updates.get().compactMap { $0.0 == sid ? { if case let .agentMessage(t) = $0.1 { return t }; return nil }($0) : nil }
    }

    func allText(_ sid: String) -> String { messages(sid).joined(separator: "\n") }

    func updatesFor(_ sid: String) -> [ACPSessionUpdate] { updates.get().filter { $0.0 == sid }.map(\.1) }
}

// MARK: Runtime

struct STestError: Error {}

final class STestRuntime: ACPRuntimePort, @unchecked Sendable {
    struct Run {
        var snapshot: ACPRunSnapshot
        var events: [ACPRuntimeEvent] = []
        var finished = false
        var conts: [AsyncThrowingStream<ACPRuntimeEvent, Error>.Continuation] = []
    }

    let callerValue = STestLocked<ACPCaller?>(ACPCaller(principalId: "alice", clientId: "editor-1", connectionId: "c1"))
    let taskList = STestLocked<[ACPExposedTask]>([])
    let runs = STestLocked<[String: Run]>([:])
    let submissions = STestLocked<[ACPSubmission]>([])
    let keyToRun = STestLocked<[String: String]>([:])
    /// nil: the default ledger behaviour (new key → accepted, seen key → duplicate).
    let submitOverride = STestLocked<(@Sendable (ACPSubmission) -> ACPSubmissionReceipt)?>(nil)
    let cancels = STestLocked<[(String, String)]>([])
    let pendingByRun = STestLocked<[String: [ACPPendingDecision]]>([:])
    let pendingFails = STestLocked(false)
    let pendingError = STestLocked<ACPError?>(nil)
    let submitError = STestLocked<Error?>(nil)
    let declines = STestLocked<[String]>([])
    let declineSupported = STestLocked(false)
    let decisions = STestLocked<[(String, Bool)]>([])
    let answers = STestLocked<[(String, String)]>([])
    let connectionLostCount = STestLocked(0)
    let eventsCalls = STestLocked<[(String, Int?)]>([])
    private let counter = STestLocked(0)

    func caller() async throws -> ACPCaller {
        guard let c = callerValue.get() else { throw STestError() }
        return c
    }

    func tasks() async throws -> [ACPExposedTask] { taskList.get() }

    func submit(_ s: ACPSubmission) async throws -> ACPSubmissionReceipt {
        submissions.with { $0.append(s) }
        if let e = submitError.get() { throw e }
        if let o = submitOverride.get() { return o(s) }
        if let existing = keyToRun.get()[s.submissionKey], let run = runs.get()[existing] {
            return .duplicate(run.snapshot)
        }
        let id = "run-\(counter.with { $0 += 1; return $0 })"
        addRun(id)
        keyToRun.with { $0[s.submissionKey] = id }
        return .accepted(runs.get()[id]!.snapshot)
    }

    func snapshot(runId: String) async throws -> ACPRunSnapshot {
        guard let r = runs.get()[runId] else { throw ACPError(code: -32000, reason: "not_found", message: "no run") }
        var snap = r.snapshot
        snap.lastCursor = r.events.last?.cursor
        return snap
    }

    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        cancels.with { $0.append((runId, requestId)) }
        return runs.with { all -> ACPRunSnapshot in
            if all[runId]?.snapshot.phase != "ended" {
                all[runId]?.snapshot.phase = "stopping"
                all[runId]?.snapshot.quiescence = "pending"
            }
            return all[runId]?.snapshot ?? ACPRunSnapshot(runId: runId, phase: "ended", outcome: "unknown",
                                                         quiescence: "not_confirmed", lifetime: "connection_scoped")
        }
    }

    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        eventsCalls.with { $0.append((runId, cursor)) }
        let (stream, cont) = AsyncThrowingStream.makeStream(of: ACPRuntimeEvent.self, throwing: Error.self)
        runs.with { all in
            guard var r = all[runId] else { cont.finish(throwing: STestError()); return }
            for e in r.events where cursor == nil || e.cursor > cursor! { cont.yield(e) }
            if r.finished { cont.finish() } else { r.conts.append(cont) }
            all[runId] = r
        }
        return stream
    }

    func pending(runId: String) async throws -> [ACPPendingDecision] {
        if pendingFails.get() { throw ACPError(code: -32000, reason: "capability_missing", message: "no approvals yet") }
        if let e = pendingError.get() { throw e }
        return pendingByRun.get()[runId] ?? []
    }

    func decide(approvalId: String, allow: Bool) async throws {
        decisions.with { $0.append((approvalId, allow)) }
        pendingByRun.with { all in for k in all.keys { all[k]?.removeAll { if case let .approval(id, _, _, _) = $0 { return id == approvalId }; return false } } }
    }

    func answer(questionId: String, text: String) async throws {
        answers.with { $0.append((questionId, text)) }
    }

    func decline(questionId: String) async throws {
        guard declineSupported.get() else {
            throw ACPError(code: -32000, reason: "capability_missing", message: "no decline yet")
        }
        declines.with { $0.append(questionId) }
    }

    func connectionLost() async { connectionLostCount.with { $0 += 1 } }

    // Scripting
    func addRun(_ id: String, phase: String = "running", lifetime: String = "connection_scoped") {
        runs.with {
            $0[id] = Run(snapshot: ACPRunSnapshot(runId: id, phase: phase, outcome: nil, quiescence: "not_confirmed",
                                                 lifetime: lifetime))
        }
    }

    func emit(_ runId: String, cursor: Int, type: String = "text", text: String = "") {
        let e = ACPRuntimeEvent(runId: runId, cursor: cursor, type: type, payload: .obj([("text", .string(text))]))
        runs.with { all in
            all[runId]?.events.append(e)
            all[runId]?.conts.forEach { $0.yield(e) }
        }
    }

    /// Deliver an event on a run's live streams without recording it (to
    /// test that a session drops events naming another run).
    func injectForeign(into runId: String, event: ACPRuntimeEvent) {
        runs.with { all in all[runId]?.conts.forEach { $0.yield(event) } }
    }

    func setPhase(_ runId: String, _ phase: String, outcome: String? = nil, quiescence: String? = nil) {
        runs.with { all in
            all[runId]?.snapshot.phase = phase
            if let outcome { all[runId]?.snapshot.outcome = outcome }
            if let quiescence { all[runId]?.snapshot.quiescence = quiescence }
        }
    }

    func end(_ runId: String, outcome: String = "success") {
        runs.with { all in
            all[runId]?.snapshot.phase = "ended"
            all[runId]?.snapshot.outcome = outcome
            all[runId]?.snapshot.quiescence = "confirmed"
            all[runId]?.finished = true
            all[runId]?.conts.forEach { $0.finish() }
            all[runId]?.conts = []
        }
    }

    var submitCount: Int { submissions.get().count }
}

// MARK: Projector

/// Projects "text" events to agent messages and anything else to a thought
/// naming the type. Redaction hides the word "secret" so tests can tell
/// redacted text from raw text.
final class STestProjector: ACPEventProjector, @unchecked Sendable {
    let policies = STestLocked<[ACPPrivacyPolicy]>([])

    func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy) -> [ACPSessionUpdate] {
        policies.with { $0.append(policy) }
        if event.type == "text" {
            return [.agentMessage(redact("[\(event.runId)#\(event.cursor)] " + (event.payload["text"]?.stringValue ?? ""),
                                         policy: policy))]
        }
        return [.agentThought(event.type)]
    }

    func redact(_ text: String, policy: ACPPrivacyPolicy) -> String {
        text.replacingOccurrences(of: "secret", with: "•••")
    }
}

// MARK: Harness

final class STestHarness: @unchecked Sendable {
    let dir: URL
    let connection: STestConnection
    let runtime: STestRuntime
    let projector = STestProjector()
    let store: ACPFileSessionStore
    let server: ACPAgentServer
    let runTask: Task<Void, Never>
    private let nextId = STestLocked(100)

    init(version: ACPVersion = .v1, runtime: STestRuntime = STestRuntime(), dir: URL? = nil,
         holdTime: Duration = .seconds(5), realProjector: (any ACPEventProjector)? = nil) {
        self.dir = dir ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("acp-s-tests-\(UUID().uuidString)", isDirectory: true)
        connection = STestConnection(version: version)
        self.runtime = runtime
        store = ACPFileSessionStore(directory: self.dir)
        var config = ACPAgentServerConfig()
        config.pollInterval = .milliseconds(5)
        config.holdTime = holdTime
        config.drainTimeout = .milliseconds(500)
        server = ACPAgentServer(connection: connection, runtime: runtime, projector: realProjector ?? projector, store: store,
                                config: config)
        let s = server
        runTask = Task { await s.run() }
    }

    func id() -> Int { nextId.with { $0 += 1; return $0 } }

    func newSession() async -> String {
        let i = id()
        connection.request(i, .newSession(cwd: "/tmp/project"))
        let r = await connection.waitReply(i)
        guard case let .sessionCreated(sid, _)? = r else {
            Issue.record("session/new got \(String(describing: r))")
            return "acps_missing"
        }
        return sid
    }

    /// Send a prompt; returns its request id.
    @discardableResult
    func prompt(_ sid: String, _ text: String) -> Int {
        let i = id()
        connection.request(i, .prompt(sessionId: sid, content: [.text(text)]))
        return i
    }

    func cleanup() {
        connection.close()
        try? FileManager.default.removeItem(at: dir)
    }

    static func task(_ type: String, freeText: Bool = false, approval: Bool = false,
                     schema: JSONValue = .obj([("type", .string("object")),
                                               ("properties", .obj([("text", .obj([("type", .string("string"))]))]))]))
        -> ACPExposedTask {
        ACPExposedTask(taskType: type, displayName: "Task \(type)", description: "does \(type)", inputSchema: schema,
                       allowFreeText: freeText, requiresApproval: approval, dataClassification: "internal")
    }
}
