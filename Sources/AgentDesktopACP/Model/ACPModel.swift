import AgentDesktopContracts
import Foundation

// Version-neutral ACP model (docs/acp/README.md §3).
//
// Every lane codes against these types, never against one wire version of
// the Agent Client Protocol. A wire adapter (Wire/, lane T) is the only code
// that knows method names and field spellings of a given ACP version; it
// turns frames into `ACPIncoming` and `ACPOutgoing` into frames.
//
// FROZEN for the parallel lanes: change this file only through the
// coordinator (docs/acp/03-lanes.md §Change rule).

/// The ACP versions this build can speak. Lane T decides which ones are
/// real (docs/acp/02-protocol-version.md); a version is listed only after a
/// real client spoke it.
public enum ACPVersion: String, Sendable, CaseIterable {
    case v1
    case v2
}

public struct ACPImplementationInfo: Equatable, Sendable {
    public var name: String
    public var version: String
    public init(name: String, version: String) { self.name = name; self.version = version }
}

/// What the editor said it can do in `initialize`.
public struct ACPClientCapabilities: Equatable, Sendable {
    public var readTextFile = false
    public var writeTextFile = false
    public var terminal = false
    /// `elicitation/create` (structured questions).
    public var elicitation = false
    public init() {}
}

/// What we answer in `initialize`. Never claim what is not implemented.
public struct ACPAgentCapabilities: Equatable, Sendable {
    public var resumeSessions = false
    public var listSessions = false
    public var closeSessions = false
    public var promptImages = false
    public var promptEmbeddedContext = false
    public init() {}
}

public enum ACPContentBlock: Equatable, Sendable {
    case text(String)
    /// Image bytes stay in the adapter; the model sees an opaque handle.
    case image(mimeType: String, handle: String)
    /// An embedded resource or a link the editor attached.
    case resource(uri: String, mimeType: String?, text: String?)
}

/// A session config option and its value (mode, desktop, …).
public struct ACPConfigOption: Equatable, Sendable {
    public var id: String
    public var name: String
    public var value: String
    public var choices: [String]
    public init(id: String, name: String, value: String, choices: [String]) {
        self.id = id; self.name = name; self.value = value; self.choices = choices
    }
}

/// One request or notification from the editor, already decoded.
public enum ACPIncoming: Equatable, Sendable {
    case initialize(client: ACPImplementationInfo?, capabilities: ACPClientCapabilities, requested: String)
    case newSession(cwd: String)
    case listSessions
    /// v1 `session/load` and v2 `session/resume` both arrive here.
    case resumeSession(sessionId: String)
    case closeSession(sessionId: String)
    case prompt(sessionId: String, content: [ACPContentBlock])
    case cancel(sessionId: String)
    case setConfigOption(sessionId: String, optionId: String, value: String)
}

/// The id of the editor's request, so the answer goes back to it.
public struct ACPRequestId: Hashable, Sendable {
    public var raw: JSONValue
    public init(_ raw: JSONValue) { self.raw = raw }
    public static func == (a: ACPRequestId, b: ACPRequestId) -> Bool { a.raw == b.raw }
    /// Consistent with `==`, which compares JSON numbers by value (1 == 1.0).
    public func hash(into h: inout Hasher) {
        switch raw {
        case let .number(_, value): h.combine(0); h.combine(value)
        case let .string(s): h.combine(1); h.combine(s)
        case .null: h.combine(2)
        default: h.combine(3); h.combine(String(describing: raw))
        }
    }
}

public enum ACPStopReason: String, Sendable {
    case endTurn = "end_turn"
    case cancelled
    case refusal
    case maxTurnRequests = "max_turn_requests"
}

/// Answers to the editor's requests.
public enum ACPReply: Equatable, Sendable {
    case initialized(version: ACPVersion, agent: ACPImplementationInfo, capabilities: ACPAgentCapabilities)
    case sessionCreated(sessionId: String, options: [ACPConfigOption])
    case sessions([ACPSessionSummary])
    case resumed(options: [ACPConfigOption])
    case closed
    /// v1: the turn's end. v2: acceptance of the prompt; the end comes as an update.
    case promptFinished(ACPStopReason)
    case configSet(options: [ACPConfigOption])
    case error(ACPError)
}

public struct ACPSessionSummary: Equatable, Sendable {
    public var sessionId: String
    public var title: String
    public var updatedAt: String
    public init(sessionId: String, title: String, updatedAt: String) {
        self.sessionId = sessionId; self.title = title; self.updatedAt = updatedAt
    }
}

/// JSON-RPC level error with a stable, non-sensitive code.
public struct ACPError: Error, Equatable, Sendable {
    public var code: Int
    public var reason: String
    public var message: String
    public init(code: Int, reason: String, message: String) {
        self.code = code; self.reason = reason; self.message = message
    }
}

// MARK: Session updates (agent → editor)

public enum ACPToolKind: String, Sendable {
    case read, execute, other, think, fetch, search
}

public enum ACPToolStatus: String, Sendable {
    case pending, inProgress = "in_progress", completed, failed
}

/// The three levels of an action result (docs/plan/06 §6.4). An executed
/// action is never shown as verified unless the Runtime verified it.
public enum ACPActionLevel: Equatable, Sendable {
    case accepted
    case dispatched
    case executed
    case verified
    case contradicted
    /// The Runtime cannot tell; never retried, shown as "待核实".
    case unknown
    case refused(code: String)
    /// Dispatched, then the execution failed (receipt execution=failed).
    case failed(code: String)
}

public struct ACPToolCall: Equatable, Sendable {
    public var toolCallId: String
    public var title: String
    public var kind: ACPToolKind
    public var status: ACPToolStatus
    public var level: ACPActionLevel?
    /// Redacted, display-safe lines only (Privacy/ decides).
    public var detail: [String]
    public init(toolCallId: String, title: String, kind: ACPToolKind, status: ACPToolStatus,
                level: ACPActionLevel? = nil, detail: [String] = []) {
        self.toolCallId = toolCallId; self.title = title; self.kind = kind
        self.status = status; self.level = level; self.detail = detail
    }
}

public struct ACPPlanEntry: Equatable, Sendable {
    public enum Status: String, Sendable { case pending, inProgress = "in_progress", completed }
    public var content: String
    public var status: Status
    public init(content: String, status: Status) { self.content = content; self.status = status }
}

public enum ACPSessionUpdate: Equatable, Sendable {
    case agentMessage(String)
    case agentThought(String)
    case plan([ACPPlanEntry])
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCall)
    case availableCommands([ACPCommandInfo])
    case configOptions([ACPConfigOption])
    case sessionInfo(title: String)
    case usage(inputTokens: Int?, outputTokens: Int?)
    /// v2 only: the end of a turn as an update.
    case turnEnded(ACPStopReason)
}

public struct ACPCommandInfo: Equatable, Sendable {
    public var name: String
    public var description: String
    public var inputHint: String?
    public init(name: String, description: String, inputHint: String? = nil) {
        self.name = name; self.description = description; self.inputHint = inputHint
    }
}

// MARK: Agent → editor requests

public enum ACPPermissionOptionKind: String, Sendable {
    case allowOnce = "allow_once"
    case rejectOnce = "reject_once"
    // allow_always / reject_always are never offered (docs/acp/README.md §6.2).
}

public struct ACPPermissionRequest: Equatable, Sendable {
    public var sessionId: String
    public var toolCall: ACPToolCall
    /// Consequence summary built by the Runtime side, already redacted.
    public var summary: [String]
    public var options: [ACPPermissionOptionKind]
    public init(sessionId: String, toolCall: ACPToolCall, summary: [String],
                options: [ACPPermissionOptionKind] = [.allowOnce, .rejectOnce]) {
        self.sessionId = sessionId; self.toolCall = toolCall; self.summary = summary; self.options = options
    }
}

public enum ACPPermissionOutcome: Equatable, Sendable {
    case selected(ACPPermissionOptionKind)
    case cancelled
    /// The editor cannot ask (no capability, disconnected): never an allow.
    case unavailable
}

public struct ACPQuestion: Equatable, Sendable {
    public var sessionId: String
    public var message: String
    public var choices: [String]
    public init(sessionId: String, message: String, choices: [String] = []) {
        self.sessionId = sessionId; self.message = message; self.choices = choices
    }
}

public enum ACPAnswer: Equatable, Sendable {
    case answered(String)
    case declined
    case unavailable
}
