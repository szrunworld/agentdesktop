import AgentDesktopProtocol
import Foundation

// The seams between the parallel ACP lanes (docs/acp/03-lanes.md).
//
//   editor ⇄ [T: Transport + Wire] ⇄ ACPPeer / ACPIncoming
//                                        │
//                               [S: Inbound server] ── ACPSessionStore (S)
//                                 │              │
//            [R: RuntimeBridge] ACPRuntimePort   ACPEventProjector [E: Events + Privacy]
//                     │
//              RuntimeClient (runtime/1) ── the one Runtime
//
// Each lane implements its own protocol(s) below and tests against fakes of
// the others. FROZEN for the parallel lanes: change only through the
// coordinator.

// MARK: Lane T — the editor side

/// One connected editor, as the server sees it. Lane T implements it over
/// stdio JSON-RPC for one negotiated ACP version.
public protocol ACPPeer: AnyObject, Sendable {
    var version: ACPVersion { get }
    var clientCapabilities: ACPClientCapabilities { get }
    /// Answer one request of the editor.
    func reply(to id: ACPRequestId, _ reply: ACPReply) async
    /// `session/update` notification.
    func send(sessionId: String, _ update: ACPSessionUpdate) async
    /// `session/request_permission`. Must return `.unavailable` rather than
    /// throw when the editor is gone or cannot ask.
    func requestPermission(_ request: ACPPermissionRequest) async -> ACPPermissionOutcome
    /// `elicitation/create` when the editor supports it, else `.unavailable`.
    func ask(_ question: ACPQuestion) async -> ACPAnswer
}

/// What a connection delivers to the server, in order.
public enum ACPConnectionEvent: Equatable, Sendable {
    case request(ACPRequestId, ACPIncoming)
    case notification(ACPIncoming)
    /// stdin closed or the framing broke: the control connection is lost.
    case closed(reason: String)
}

/// Lane T: a stdio connection after `initialize` was negotiated.
public protocol ACPConnection: ACPPeer {
    var events: AsyncStream<ACPConnectionEvent> { get }
}

// MARK: Lane R — the Runtime side

/// Who is calling, as the Runtime authenticated it. Never taken from a
/// field the editor sent.
public struct ACPCaller: Equatable, Sendable {
    public var principalId: String
    public var clientId: String
    public var connectionId: String
    /// True only when the Runtime authenticated the principal (A4). Until
    /// then the bridge reports a local-owner placeholder with `false`.
    public var verified: Bool
    public init(principalId: String, clientId: String, connectionId: String, verified: Bool = false) {
        self.principalId = principalId; self.clientId = clientId; self.connectionId = connectionId
        self.verified = verified
    }
}

/// A task the caller may start, from a registered source (never hard-coded
/// business). docs/acp/README.md §4.5.
public struct ACPExposedTask: Equatable, Sendable {
    public var taskType: String
    public var displayName: String
    public var description: String
    public var inputSchema: JSONValue
    public var allowFreeText: Bool
    public var requiresApproval: Bool
    public var dataClassification: String
    public init(taskType: String, displayName: String, description: String, inputSchema: JSONValue,
                allowFreeText: Bool, requiresApproval: Bool, dataClassification: String) {
        self.taskType = taskType; self.displayName = displayName; self.description = description
        self.inputSchema = inputSchema; self.allowFreeText = allowFreeText
        self.requiresApproval = requiresApproval; self.dataClassification = dataClassification
    }
}

/// One prompt turned into a task request. `submissionKey` is stable across
/// editor retries of the same prompt; the Runtime's request ledger keys on it.
public struct ACPSubmission: Equatable, Sendable {
    public var submissionKey: String
    public var acpSessionId: String
    public var taskType: String
    public var input: JSONValue
    public var desktopId: String?
    public init(submissionKey: String, acpSessionId: String, taskType: String, input: JSONValue, desktopId: String?) {
        self.submissionKey = submissionKey; self.acpSessionId = acpSessionId
        self.taskType = taskType; self.input = input; self.desktopId = desktopId
    }
}

/// ADR v2.2 run axes, as the Runtime reports them.
public struct ACPRunSnapshot: Equatable, Sendable {
    public var runId: String
    /// queued / running / waiting_approval / waiting_input / stopping / ended
    public var phase: String
    /// success / failed / cancelled / unknown, when ended
    public var outcome: String?
    /// not_confirmed / pending / confirmed
    public var quiescence: String
    /// connection_scoped / platform_durable — read only, never requested.
    public var lifetime: String
    /// The newest event cursor of the Run when the snapshot was taken, so a
    /// resumed session can tell replayed history from live events. Nil when
    /// the Runtime does not report it.
    public var lastCursor: Int?
    public init(runId: String, phase: String, outcome: String?, quiescence: String, lifetime: String,
                lastCursor: Int? = nil) {
        self.runId = runId; self.phase = phase; self.outcome = outcome
        self.quiescence = quiescence; self.lifetime = lifetime; self.lastCursor = lastCursor
    }
}

public enum ACPSubmissionReceipt: Equatable, Sendable {
    case accepted(ACPRunSnapshot)
    /// Same submissionKey seen before: the original Run, not a new one.
    case duplicate(ACPRunSnapshot)
    case refused(code: String, message: String)
    /// Sent but the answer was lost: query, never resend.
    case unconfirmed
}

/// One raw Runtime event (events.subscribe frame), not yet projected.
public struct ACPRuntimeEvent: Equatable, Sendable {
    public var runId: String
    public var cursor: Int
    public var type: String
    public var payload: JSONValue
    public init(runId: String, cursor: Int, type: String, payload: JSONValue) {
        self.runId = runId; self.cursor = cursor; self.type = type; self.payload = payload
    }
}

/// A Runtime-side approval or question waiting on a person.
public enum ACPPendingDecision: Equatable, Sendable {
    case approval(id: String, runId: String, toolCall: ACPToolCall, summary: [String])
    case question(id: String, runId: String, message: String, choices: [String])
}

/// Error rule for `ACPRuntimePort`: methods throw `ACPError` whose `reason`
/// is the runtime/1 error code (contracts/runtime/v1/errors.json), e.g.
/// `capability_missing` (the Runtime does not offer it yet: degrade, never
/// treat as allow), `not_found`, or `timeout` / `connection_lost` (state
/// unknown: query again). Any other thrown error counts as `timeout`.
/// Lane R implements this over `RuntimeClient` (runtime/1) only. It owns no
/// run state of its own beyond the submission records needed for retries.
public protocol ACPRuntimePort: AnyObject, Sendable {
    func caller() async throws -> ACPCaller
    func tasks() async throws -> [ACPExposedTask]
    func submit(_ submission: ACPSubmission) async throws -> ACPSubmissionReceipt
    func snapshot(runId: String) async throws -> ACPRunSnapshot
    /// Cancel intent; the receipt is the Runtime's, quiescence comes later.
    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot
    /// Events after `cursor` (nil: from the start), until the Run's stream ends.
    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error>
    func pending(runId: String) async throws -> [ACPPendingDecision]
    /// An editor decision; the Runtime rechecks the target before acting.
    func decide(approvalId: String, allow: Bool) async throws
    func answer(questionId: String, text: String) async throws
    /// The person declined to answer a question.
    func decline(questionId: String) async throws
    /// The editor's control connection is gone (ADR v2.2 Delegated runs).
    func connectionLost() async
}

extension ACPRuntimePort {
    public func decline(questionId: String) async throws {
        throw ACPError(code: -32000, reason: "capability_missing", message: "the Runtime cannot record a declined question yet")
    }
}

// MARK: Lane E — projection and privacy

public enum ACPDisclosure: String, Sendable {
    case off, onSubmit = "submit", all
}

/// Per session display policy. Defaults are the strictest.
public struct ACPPrivacyPolicy: Equatable, Sendable {
    public var screenshots: ACPDisclosure = .off
    public var pageText = false
    public init() {}
}

/// Lane E: Runtime events → editor updates. Pure and deterministic; all
/// redaction happens here, before anything reaches a peer, a log or a store.
public protocol ACPEventProjector: Sendable {
    func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy) -> [ACPSessionUpdate]
    /// Redact any free text (titles, errors, summaries) before display.
    func redact(_ text: String, policy: ACPPrivacyPolicy) -> String
}

// MARK: Lane S — the server's own state

/// ACP-only binding (docs/acp/README.md §4.3). It references Runtime Runs;
/// it is never the authority for a Run's state.
public struct ACPSessionBinding: Equatable, Sendable {
    public var acpSessionId: String
    public var principalId: String
    public var clientId: String
    public var cwd: String
    public var title: String
    public var runIds: [String]
    public var lastCursor: [String: Int]
    public var options: [ACPConfigOption]
    public var createdAt: String
    public var updatedAt: String
    public var revision: Int
    /// The submissionKey of a prompt whose answer was not yet seen, so a
    /// retry after a process restart reuses it instead of creating a new Run.
    public var pendingSubmissionKey: String?
    public init(acpSessionId: String, principalId: String, clientId: String, cwd: String, title: String,
                runIds: [String], lastCursor: [String: Int], options: [ACPConfigOption],
                createdAt: String, updatedAt: String, revision: Int, pendingSubmissionKey: String? = nil) {
        self.acpSessionId = acpSessionId; self.principalId = principalId; self.clientId = clientId
        self.cwd = cwd; self.title = title; self.runIds = runIds; self.lastCursor = lastCursor
        self.options = options; self.createdAt = createdAt; self.updatedAt = updatedAt; self.revision = revision
        self.pendingSubmissionKey = pendingSubmissionKey
    }
}

public protocol ACPSessionStore: AnyObject, Sendable {
    func load(sessionId: String) throws -> ACPSessionBinding?
    func list(principalId: String) throws -> [ACPSessionBinding]
    /// Fails with a conflict when `binding.revision` is not current + 1.
    func save(_ binding: ACPSessionBinding) throws
    /// Forget a session (`session/close`). Removing a missing session is not an error.
    func remove(sessionId: String) throws
}
