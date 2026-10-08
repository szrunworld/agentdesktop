import AgentDesktopContracts
import Foundation

public struct ACPAgentServerConfig: Sendable {
    public var agentInfo = ACPImplementationInfo(name: "agentdesktop", version: "0.1.0-dev")
    /// How long a prompt turn stays open on a running task before it ends
    /// with "updates continue out of turn" (plan §5.4). Default 600 s.
    public var holdTime: Duration = .seconds(600)
    /// How often the turn asks the Runtime for the Run's snapshot.
    public var pollInterval: Duration = .seconds(1)
    /// How long the end of a turn waits for the event stream to deliver its
    /// last events.
    public var drainTimeout: Duration = .seconds(2)
    public var now: @Sendable () -> Date = { Date() }
    public var makeSessionId: @Sendable () -> String = { "acps_" + UUID().uuidString.lowercased() }
    public init() {}
}

/// The inbound ACP server (lane S): one editor connection, sessions bound
/// to Runtime Runs, prompt / cancel / approval / question flows.
///
/// It owns no Run state. A binding only references runIds; phase, outcome
/// and quiescence are always read from the Runtime (`ACPRuntimePort`).
/// Every editor-visible text that came from the Runtime passes through the
/// projector's redaction first.
public actor ACPAgentServer {
    public static let defaultTitle = "AgentDesktop 会话"

    let connection: any ACPConnection
    let runtime: any ACPRuntimePort
    let projector: any ACPEventProjector
    let store: any ACPSessionStore
    let config: ACPAgentServerConfig

    var live: [String: LiveSession] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    var cachedCaller: ACPCaller?
    var closed = false

    public init(connection: any ACPConnection, runtime: any ACPRuntimePort, projector: any ACPEventProjector,
                store: any ACPSessionStore, config: ACPAgentServerConfig = ACPAgentServerConfig()) {
        self.connection = connection
        self.runtime = runtime
        self.projector = projector
        self.store = store
        self.config = config
    }

    /// Serve until the connection closes. Returns after the Runtime was told
    /// the connection is gone and all turn and stream tasks were stopped.
    public func run() async {
        for await event in connection.events {
            if closed { break }
            switch event {
            case let .request(id, incoming): dispatch(id: id, incoming)
            case let .notification(incoming): notify(incoming)
            case let .closed(reason): await connectionClosed(reason: reason)
            }
        }
        await connectionClosed(reason: "event stream ended")
    }

    // MARK: Dispatch

    private func dispatch(id: ACPRequestId, _ incoming: ACPIncoming) {
        switch incoming {
        case let .prompt(sid, content):
            // The turn is registered before anything else can run, so a
            // cancel that follows the prompt always finds it.
            guard live[sid] != nil else { spawn { await self.reply(id, .error(ACPAgentServerErrors.sessionNotOpen)) }; return }
            guard live[sid]?.turn == nil else { spawn { await self.reply(id, .error(ACPAgentServerErrors.turnInProgress)) }; return }
            let turn = ACPPromptTurn(requestId: id)
            live[sid]?.turn = turn
            spawn { await self.runTurn(sessionId: sid, turn: turn, content: content) }
        case let .cancel(sid):
            // `session/cancel` is a notification in every ACP version; a
            // request form has no answer shape in the model, so none is sent.
            cancelTurn(sessionId: sid)
        default:
            spawn { await self.handle(id: id, incoming) }
        }
    }

    private func notify(_ incoming: ACPIncoming) {
        if case let .cancel(sid) = incoming { cancelTurn(sessionId: sid) }
        // Other notifications carry nothing the server acts on.
    }

    private func handle(id: ACPRequestId, _ incoming: ACPIncoming) async {
        let answer: ACPReply
        do {
            switch incoming {
            case .initialize:
                var caps = ACPAgentCapabilities()
                caps.resumeSessions = true
                caps.listSessions = true
                caps.closeSessions = true
                answer = .initialized(version: connection.version, agent: config.agentInfo, capabilities: caps)
            case let .newSession(cwd):
                answer = try await newSession(cwd: cwd)
            case .listSessions:  // TODO(lane S): filter by cwd
                answer = try await listSessions()
            case let .resumeSession(sid, _, _):  // TODO(lane S): honour replay=false and cwd
                try await resumeSession(id: id, sessionId: sid)
                return
            case let .closeSession(sid):
                answer = try await closeSession(sid)
            case let .setConfigOption(sid, optionId, value):
                answer = try setConfigOption(sid, optionId: optionId, value: value)
            case .prompt, .cancel:
                return // handled in dispatch
            }
        } catch let e as ACPError {
            answer = .error(e)
        } catch {
            answer = .error(ACPAgentServerErrors.storeFailed)
        }
        await reply(id, answer)
        if case let .sessionCreated(sid, _) = answer { await sendCommands(sid) }
    }

    // MARK: Sessions

    func caller() async throws -> ACPCaller {
        if let c = cachedCaller { return c }
        do {
            let c = try await runtime.caller()
            cachedCaller = c
            return c
        } catch {
            throw ACPAgentServerErrors.callerUnavailable
        }
    }

    private func newSession(cwd: String) async throws -> ACPReply {
        let c = try await caller()
        let sid = config.makeSessionId()
        let ts = timestamp()
        let binding = ACPSessionBinding(acpSessionId: sid, principalId: c.principalId, clientId: c.clientId, cwd: cwd,
                                        title: Self.defaultTitle, runIds: [], lastCursor: [:],
                                        options: ACPSessionManagerOptions.defaults,
                                        createdAt: ts, updatedAt: ts, revision: 1)
        do { try store.save(binding) } catch { throw ACPAgentServerErrors.storeFailed }
        live[sid] = LiveSession(binding: binding)
        return .sessionCreated(sessionId: sid, options: binding.options)
    }

    private func listSessions() async throws -> ACPReply {
        let c = try await caller()
        let all: [ACPSessionBinding]
        do { all = try store.list(principalId: c.principalId) } catch { throw ACPAgentServerErrors.storeFailed }
        // The store filters already; filter again so a store bug cannot
        // show another principal's session.
        let mine = all.filter { $0.principalId == c.principalId }
            .sorted { $0.updatedAt > $1.updatedAt }
        return .sessions(mine.map { ACPSessionSummary(sessionId: $0.acpSessionId, title: $0.title, updatedAt: $0.updatedAt, cwd: $0.cwd) })
    }

    /// Rebind a stored session to this connection and replay its visible
    /// history from the Runtime's events. Never submits, never restarts a
    /// Run: a connection-scoped Run stopped with its old connection stays
    /// stopped.
    private func resumeSession(id: ACPRequestId, sessionId sid: String) async throws {
        let c = try await caller()
        let stored: ACPSessionBinding?
        do { stored = try store.load(sessionId: sid) } catch { stored = nil }
        guard let binding = stored, binding.principalId == c.principalId else {
            throw ACPAgentServerErrors.sessionNotFound
        }
        if let old = live[sid] {
            old.followers.values.forEach { $0.task.cancel() }
            old.turn?.cancelRequested = true
        }
        live[sid] = LiveSession(binding: binding)
        try persist(sid) { $0.clientId = c.clientId }

        // Ended Runs replay fully before the answer (v1 `session/load`
        // streams history first); live Runs follow after it.
        var following: [(String, ACPRunSnapshot?)] = []
        for runId in binding.runIds {
            let snap = try? await runtime.snapshot(runId: runId)
            if snap?.phase == "ended" {
                startFollower(sid, runId)
                await drain(sid, runId, timeout: nil)
            } else {
                following.append((runId, snap))
            }
        }
        await reply(id, .resumed(options: live[sid]?.binding.options ?? binding.options))
        await sendCommands(sid)
        for (runId, snap) in following {
            if let snap {
                await say(sid, "任务 \(runId)：\(Self.describe(snap))")
            } else {
                await say(sid, "任务 \(runId)：状态待核实（不会自动重试）")
            }
            startFollower(sid, runId)
        }
    }

    private func closeSession(_ sid: String) async throws -> ACPReply {
        let c = try await caller()
        guard let s = live[sid] else {
            let stored = try? store.load(sessionId: sid)
            guard let b = stored ?? nil, b.principalId == c.principalId else { throw ACPAgentServerErrors.sessionNotFound }
            return .closed
        }
        guard s.binding.principalId == c.principalId else { throw ACPAgentServerErrors.sessionNotFound }
        s.turn?.closing = true
        // A connection-scoped Run belongs to this editor session; closing
        // the session stops it. A durable Run is only observed here.
        for runId in s.binding.runIds {
            guard let snap = try? await runtime.snapshot(runId: runId),
                  snap.phase != "ended", snap.lifetime == "connection_scoped" else { continue }
            _ = try? await runtime.cancel(runId: runId, requestId: "acp-close-\(sid)-\(runId)")
        }
        live[sid]?.followers.values.forEach { $0.task.cancel() }
        try? flushCursors(sid)
        live[sid] = nil
        return .closed
    }

    private func setConfigOption(_ sid: String, optionId: String, value: String) throws -> ACPReply {
        guard let s = live[sid] else { throw ACPAgentServerErrors.sessionNotOpen }
        let next = try ACPSessionManagerOptions.setting(s.binding.options, id: optionId, value: value)
        try persist(sid) { $0.options = next }
        return .configSet(options: next)
    }

    func sendCommands(_ sid: String) async {
        let list = (try? await runtime.tasks()) ?? []
        await send(sid, .availableCommands(ACPCommandCatalog(tasks: list).commands))
    }

    // MARK: Binding persistence

    /// Apply `mutate` and save with the next revision. On a conflict the
    /// stored binding is reloaded and the (idempotent) mutation reapplied
    /// once.
    func persist(_ sid: String, _ mutate: (inout ACPSessionBinding) -> Void) throws {
        guard let s = live[sid] else { return }
        var b = s.binding
        mutate(&b)
        b.revision += 1
        b.updatedAt = timestamp()
        do {
            try store.save(b)
        } catch {
            guard let current = try? store.load(sessionId: sid), current.principalId == s.binding.principalId else {
                throw ACPAgentServerErrors.storeFailed
            }
            var m = current
            m.lastCursor.merge(s.binding.lastCursor) { max($0, $1) }
            mutate(&m)
            m.revision = current.revision + 1
            m.updatedAt = b.updatedAt
            do { try store.save(m) } catch { throw ACPAgentServerErrors.storeFailed }
            b = m
        }
        live[sid]?.binding = b
        live[sid]?.cursorsDirty = false
    }

    func flushCursors(_ sid: String) throws {
        guard live[sid]?.cursorsDirty == true else { return }
        try persist(sid) { _ in }
    }

    // MARK: Event streams

    /// Follow one Run's events for one session. Events are de-duplicated by
    /// cursor and dropped when they name another Run, so sessions never
    /// cross-stream.
    func startFollower(_ sid: String, _ runId: String) {
        guard !closed, let s = live[sid], s.followers[runId] == nil else { return }
        let token = UUID()
        let stream = runtime.events(runId: runId, after: s.seen[runId])
        let task = Task {
            do {
                for try await event in stream {
                    if Task.isCancelled { break }
                    await self.deliver(sid, runId, event)
                }
            } catch {
                // A broken stream ends the follower; the turn keeps reading
                // snapshots, and a resume starts a new one after the cursor.
            }
            self.followerEnded(sid, runId, token)
        }
        live[sid]?.followers[runId] = LiveSession.Follower(token: token, task: task)
    }

    private func deliver(_ sid: String, _ runId: String, _ event: ACPRuntimeEvent) async {
        guard event.runId == runId, let s = live[sid] else { return }
        if let seen = s.seen[runId], event.cursor <= seen { return }
        live[sid]?.seen[runId] = event.cursor
        if (s.binding.lastCursor[runId] ?? Int.min) < event.cursor {
            live[sid]?.binding.lastCursor[runId] = event.cursor
            live[sid]?.cursorsDirty = true
        }
        let policy = ACPSessionManagerOptions.policy(s.binding.options)
        for update in projector.project(event, policy: policy) {
            await send(sid, update)
        }
    }

    private func followerEnded(_ sid: String, _ runId: String, _ token: UUID) {
        if live[sid]?.followers[runId]?.token == token { live[sid]?.followers[runId] = nil }
        // A finished stream is a natural point to record how far it got.
        try? flushCursors(sid)
    }

    /// Wait until the Run's follower has finished (bounded by `timeout`).
    func drain(_ sid: String, _ runId: String, timeout: Duration?) async {
        let clock = ContinuousClock()
        let deadline = timeout.map { clock.now + $0 }
        while live[sid]?.followers[runId] != nil, !closed {
            if let deadline, clock.now >= deadline { return }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }

    // MARK: Connection

    private func connectionClosed(reason: String) async {
        guard !closed else { return }
        closed = true
        // ADR v2.2: Delegated Runs stop taking input when their control
        // connection is gone. Told once; never resumed on reconnect.
        await runtime.connectionLost()
        for sid in Array(live.keys) {
            live[sid]?.turn?.cancelRequested = true
            live[sid]?.followers.values.forEach { $0.task.cancel() }
            try? flushCursors(sid)
        }
        live.removeAll()
        tasks.values.forEach { $0.cancel() }
    }

    // MARK: Helpers

    func spawn(_ op: @escaping @Sendable () async -> Void) {
        let key = UUID()
        let task = Task {
            await op()
            self.taskDone(key)
        }
        tasks[key] = task
    }

    private func taskDone(_ key: UUID) { tasks[key] = nil }

    func reply(_ id: ACPRequestId, _ r: ACPReply) async {
        guard !closed else { return }
        await connection.reply(to: id, r)
    }

    func send(_ sid: String, _ update: ACPSessionUpdate) async {
        guard !closed else { return }
        await connection.send(sessionId: sid, update)
    }

    func say(_ sid: String, _ text: String) async {
        await send(sid, .agentMessage(text))
    }

    func redact(_ sid: String, _ text: String) -> String {
        projector.redact(text, policy: ACPSessionManagerOptions.policy(live[sid]?.binding.options ?? []))
    }

    func timestamp() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: config.now())
    }

    static func describe(_ s: ACPRunSnapshot) -> String {
        var parts = ["阶段 \(s.phase)"]
        if let o = s.outcome { parts.append(o == "unknown" ? "结果待核实（不会自动重试）" : "结果 \(o)") }
        if s.phase == "stopping" || s.quiescence != "not_confirmed" { parts.append("输入静止 \(s.quiescence)") }
        return parts.joined(separator: "，")
    }
}

/// One session open on this connection.
struct LiveSession {
    struct Follower {
        var token: UUID
        var task: Task<Void, Never>
    }

    var binding: ACPSessionBinding
    var followers: [String: Follower] = [:]
    /// Highest cursor delivered on this connection, per Run.
    var seen: [String: Int] = [:]
    var cursorsDirty = false
    var turn: ACPPromptTurn?
    /// A question the editor could not show; the next prompt answers it.
    var pendingQuestion: (id: String, runId: String)?
    /// Pending decisions already handled (asked or left to the main window).
    var handledDecisions: Set<String> = []
    /// The last submission of this session, so an editor retry of the same
    /// prompt reuses its key while the Run is still open or unconfirmed.
    var lastSubmission: (material: String, key: String, runId: String?)?

    init(binding: ACPSessionBinding) {
        var b = binding
        b.options = ACPSessionManagerOptions.normalized(binding.options)
        self.binding = b
    }
}

/// One prompt turn; confined to the server actor.
final class ACPPromptTurn: @unchecked Sendable {
    let requestId: ACPRequestId
    var runId: String?
    var cancelRequested = false
    var cancelSent = false
    var closing = false
    var stopAnnounced = false
    /// Approvals currently shown to the editor.
    var inFlightApprovals: Set<String> = []
    /// Approvals already decided (a cancel decides deny first).
    var decided: Set<String> = []

    init(requestId: ACPRequestId) { self.requestId = requestId }
}
