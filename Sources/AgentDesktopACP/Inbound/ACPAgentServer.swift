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
    /// Upper bound for streaming one ended Run's history on `session/load`.
    public var replayTimeout: Duration = .seconds(15)
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
    /// Conversation text for `session/load` replay; nil: nothing to replay
    /// but Run events.
    let history: (any ACPSessionManagerHistoryStore)?
    let config: ACPAgentServerConfig

    var live: [String: LiveSession] = [:]
    var tasks: [UUID: Task<Void, Never>] = [:]
    var cachedCaller: ACPCaller?
    var closed = false

    public init(connection: any ACPConnection, runtime: any ACPRuntimePort, projector: any ACPEventProjector,
                store: any ACPSessionStore, config: ACPAgentServerConfig = ACPAgentServerConfig(),
                history: (any ACPSessionManagerHistoryStore)? = nil) {
        self.connection = connection
        self.runtime = runtime
        self.projector = projector
        self.store = store
        self.history = history ?? (store as? any ACPSessionManagerHistoryStore)
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
            case let .closed(reason):
                // The connection is gone; a stream that is never finished
                // must not keep the server alive.
                await connectionClosed(reason: reason)
                return
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
            case let .listSessions(cwd):
                answer = try await listSessions(cwd: cwd)
            case let .resumeSession(sid, cwd, replay):
                try await resumeSession(id: id, sessionId: sid, cwd: cwd, replay: replay)
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
        if case let .sessionCreated(sid, _) = answer {
            await sendCommands(sid)
            await sayIdentity(sid)
        }
    }

    /// Until A4 the Runtime does not authenticate the caller; the session is
    /// owned by a local-owner placeholder. Say so instead of implying more.
    static let identityNoticePrefix = "身份说明："

    /// Describes the current connection, so it is never stored in the
    /// conversation: a load regenerates it once, for the connection it is on.
    func sayIdentity(_ sid: String) async {
        guard let c = cachedCaller, !c.verified else { return }
        await notice(sid, Self.identityNoticePrefix
            + "Runtime 尚未认证调用方身份，本会话暂按本机所有者占位身份（\(redact(sid, c.principalId))）归属。")
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
        live[sid] = LiveSession(binding: binding, projector: projector)
        return .sessionCreated(sessionId: sid, options: binding.options)
    }

    private func listSessions(cwd: String?) async throws -> ACPReply {
        let c = try await caller()
        let all: [ACPSessionBinding]
        do { all = try store.list(principalId: c.principalId) } catch { throw ACPAgentServerErrors.storeFailed }
        // The store filters already; filter again so a store bug cannot
        // show another principal's session.
        let mine = all.filter { $0.principalId == c.principalId && (cwd == nil || $0.cwd == cwd) }
            .sorted { $0.updatedAt > $1.updatedAt }
        return .sessions(mine.map { ACPSessionSummary(sessionId: $0.acpSessionId, title: $0.title, updatedAt: $0.updatedAt, cwd: $0.cwd) })
    }

    /// Rebind a stored session to this connection; with `replay`, stream
    /// its visible history from the Runtime's events first. Never submits,
    /// never restarts a Run: a connection-scoped Run stopped with its old
    /// connection stays stopped (K1). Session resume is not Run resume.
    private func resumeSession(id: ACPRequestId, sessionId sid: String, cwd: String?, replay: Bool) async throws {
        let c = try await caller()
        let stored: ACPSessionBinding?
        do { stored = try store.load(sessionId: sid) } catch { stored = nil }
        guard let binding = stored, binding.principalId == c.principalId,
              cwd == nil || binding.cwd == cwd else {
            throw ACPAgentServerErrors.sessionNotFound
        }
        if let old = live[sid] {
            old.followers.values.forEach { $0.task.cancel() }
            old.turn?.cancelRequested = true
        }
        live[sid] = LiveSession(binding: binding, projector: projector)
        try persist(sid) { $0.clientId = c.clientId }

        guard replay else {
            // session/resume: nothing historical. Rebound; open Runs are
            // followed from their current cursor on, after the answer.
            var open: [(String, ACPRunSnapshot?)] = []
            for runId in binding.runIds {
                let snap = try? await runtime.snapshot(runId: runId)
                if snap?.phase == "ended" { continue }
                if let base = snap?.lastCursor ?? binding.lastCursor[runId] { live[sid]?.seen[runId] = base }
                open.append((runId, snap))
            }
            await reply(id, .resumed(options: live[sid]?.binding.options ?? binding.options))
            await sendCommands(sid)
            await sayIdentity(sid)
            await sayPendingSubmission(sid)
            for (runId, snap) in open {
                await notice(sid, Self.runStatusLine(runId, snap))
                startFollower(sid, runId)
            }
            return
        }

        // session/load (ACP v1 Loading Sessions): the whole visible history
        // goes out as session/update first, each send awaited, and only then
        // the answer. Order: commands, the conversation (user prompts and
        // agent lines, redacted when stored) with each Run's events replayed
        // right after the line that announced it, Runs no line mentions,
        // then the current state of open Runs. Live events that arrive while
        // this runs are delivered too (cursor de-dup keeps them single).
        await sendCommands(sid)
        await sayIdentity(sid)
        let lines = (try? history?.history(sessionId: sid)) ?? []
        var replayed = Set<String>()
        var open: [(String, ACPRunSnapshot?)] = []
        for line in lines {
            // Histories written before notices stopped being recorded may
            // hold an identity line; it was just regenerated above.
            if line.kind == .agent, line.text.hasPrefix(Self.identityNoticePrefix) { continue }
            await send(sid, Self.replayUpdate(line))
            if let runId = line.runId, binding.runIds.contains(runId), !replayed.contains(runId) {
                replayed.insert(runId)
                if let state = await replayRun(sid, runId) { open.append(state) }
            }
        }
        for runId in binding.runIds where !replayed.contains(runId) {
            if let state = await replayRun(sid, runId) { open.append(state) }
        }
        await sayPendingSubmission(sid)
        for (runId, snap) in open { await notice(sid, Self.runStatusLine(runId, snap)) }
        await reply(id, .resumed(options: live[sid]?.binding.options ?? binding.options))
    }

    /// Replay one Run's events up to now. Returns the Run when it is still
    /// open (its follower keeps running after the answer).
    private func replayRun(_ sid: String, _ runId: String) async -> (String, ACPRunSnapshot?)? {
        let snap = try? await runtime.snapshot(runId: runId)
        startFollower(sid, runId)
        if snap?.phase == "ended" {
            await drain(sid, runId, timeout: config.replayTimeout)
            return nil
        }
        if let last = snap?.lastCursor { await waitSeen(sid, runId, upTo: last, timeout: config.drainTimeout) }
        return (runId, snap)
    }

    private func sayPendingSubmission(_ sid: String) async {
        guard live[sid]?.binding.pendingSubmissionKey != nil else { return }
        await notice(sid, "上次有一条提交没有收到 Runtime 的确认，结果待核实；原样重发那条 prompt 只会查询原请求，不会重复执行。")
    }

    static func runStatusLine(_ runId: String, _ snap: ACPRunSnapshot?) -> String {
        guard let snap else { return "任务 \(runId)：状态待核实（不会自动重试）" }
        return "任务 \(runId)：\(describe(snap))"
    }

    /// Wait until events up to `cursor` were delivered (bounded).
    func waitSeen(_ sid: String, _ runId: String, upTo cursor: Int, timeout: Duration) async {
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        while !closed, let s = live[sid], (s.seen[runId] ?? Int.min) < cursor, s.followers[runId] != nil {
            if clock.now >= deadline { return }
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
        }
    }

    private func closeSession(_ sid: String) async throws -> ACPReply {
        let c = try await caller()
        guard let s = live[sid] else {
            let stored = try? store.load(sessionId: sid)
            guard let b = stored ?? nil, b.principalId == c.principalId else { throw ACPAgentServerErrors.sessionNotFound }
            do { try store.remove(sessionId: sid) } catch { throw ACPAgentServerErrors.storeFailed }
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
        live[sid] = nil
        // A closed session leaves the list; its Runs stay in the Runtime.
        do { try store.remove(sessionId: sid) } catch { throw ACPAgentServerErrors.storeFailed }
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
        let updates: [ACPSessionUpdate]
        if var ps = live[sid]?.projectorSession {
            // One projector session per ACP session, fed in arrival order
            // (cursor order per Run), so later events know earlier ones.
            updates = ps.project(event, policy: policy)
            live[sid]?.projectorSession = ps
        } else {
            updates = projector.project(event, policy: policy)
        }
        for update in updates {
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

    /// An agent message. Inside a prompt turn it is also part of the
    /// conversation and is recorded (redacted) for `session/load` replay.
    func say(_ sid: String, _ text: String, runId: String? = nil) async {
        if live[sid]?.turn != nil { record(sid, .agent, text, runId: runId) }
        await send(sid, .agentMessage(text))
    }

    /// A message about the current connection or state (identity, status on
    /// load). Never recorded, even when a turn happens to be open: the next
    /// load regenerates what is still true.
    func notice(_ sid: String, _ text: String) async {
        await send(sid, .agentMessage(text))
    }

    func record(_ sid: String, _ kind: ACPSessionManagerHistoryEntry.Kind, _ text: String, runId: String? = nil) {
        guard let history, !text.isEmpty else { return }
        // Best effort: a lost history line must not fail a turn.
        try? history.appendHistory(sessionId: sid, [ACPSessionManagerHistoryEntry(
            kind: kind, text: redact(sid, text), runId: runId, at: timestamp())])
    }

    /// How a stored line is shown again: the user's words as
    /// `user_message_chunk`, the server's as agent messages.
    static func replayUpdate(_ e: ACPSessionManagerHistoryEntry) -> ACPSessionUpdate {
        switch e.kind {
        case .user: return .userMessage(e.text)
        case .agent: return .agentMessage(e.text)
        }
    }

    /// Every editor-visible or stored text that did not come out of the
    /// projector's `project`: the projector's redaction, then lane E's
    /// `ACPRedactor` (docs/acp/08-event-mapping.md: summaries, questions).
    func redact(_ sid: String, _ text: String) -> String {
        let policy = ACPSessionManagerOptions.policy(live[sid]?.binding.options ?? [])
        return ACPRedactor.redact(projector.redact(text, policy: policy), policy: policy)
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

    /// Lane E's stateful projection, when the server runs with `ACPProjector`.
    var projectorSession: ACPProjectorSession?

    init(binding: ACPSessionBinding, projector: any ACPEventProjector) {
        var b = binding
        b.options = ACPSessionManagerOptions.normalized(binding.options)
        self.binding = b
        projectorSession = projector is ACPProjector ? ACPProjectorSession() : nil
    }
}

/// One prompt turn; confined to the server actor.
final class ACPPromptTurn: @unchecked Sendable {
    let requestId: ACPRequestId
    var runId: String?
    var cancelRequested = false
    var cancelSent = false
    var pendingUnknownSaid = false
    var closing = false
    var stopAnnounced = false
    /// Approvals currently shown to the editor.
    var inFlightApprovals: Set<String> = []
    /// Approvals already decided (a cancel decides deny first).
    var decided: Set<String> = []

    init(requestId: ACPRequestId) { self.requestId = requestId }
}
