import AgentDesktopProtocol
import Foundation

// The Runtime event types the projector knows (docs/acp/08-event-mapping.md §二、§三).
//
// `emitted`: the Runtime emits it today (Sources/AgentDesktopRuntime,
// RunStore / ExecutionCoordinator / RuntimeService+Act) and it is in the
// F1-01 catalogue. `provisional`: named by plan v1.0 §5.1 or the lead's
// list but not in runtime/1 yet; mapped so that the day it appears it is
// shown safely, and listed as an open question for f1.

public enum ACPEventType: String, Sendable, CaseIterable {
    // Run lifecycle
    case runAccepted = "run.accepted"
    case runQueued = "run.queued"
    case runStarted = "run.started"
    case runWaitingApproval = "run.waiting_approval"
    case runWaitingInput = "run.waiting_input"
    case runResumed = "run.resumed"
    case runFinishing = "run.finishing"
    case stopAccepted = "stop.accepted"
    case runQuiescent = "run.quiescent"
    case runEnded = "run.ended"
    // Units (unit.run, A6)
    case unitStarted = "unit.started"
    case unitEnded = "unit.ended"
    // Actions
    case actionAccepted = "action.accepted"
    case actionDispatched = "action.dispatched"
    case actionCompleted = "action.completed"
    case actionFailed = "action.failed"
    case actionUnknown = "action.unknown"
    case actionRefused = "action.refused"
    case actionVerified = "action.verified"
    case verificationSucceeded = "verification.succeeded"
    case verificationFailed = "verification.failed"
    // Person in the loop (the server raises the real request; this is display only)
    case approvalRequired = "approval.required"
    case questionAsked = "question.asked"

    /// Kevin's three tiers (docs/acp/README.md §五 constraint 3).
    public var tier: ACPEventTier {
        switch self {
        case .runAccepted, .runQueued, .runStarted, .runResumed, .runFinishing, .stopAccepted, .runQuiescent, .runEnded,
             .unitStarted, .unitEnded:
            return .normal
        case .actionAccepted, .actionDispatched, .actionCompleted, .actionFailed, .actionUnknown, .actionRefused,
             .actionVerified, .verificationSucceeded, .verificationFailed:
            return .sensitive
        case .runWaitingApproval, .approvalRequired, .runWaitingInput, .questionAsked:
            return .protected
        }
    }

    /// The tier of any type string: one outside the catalogue is protected
    /// (status only — a neutral line, nothing of its payload).
    public static func tier(of type: String) -> ACPEventTier {
        ACPEventType(rawValue: type)?.tier ?? .protected
    }

    /// Emitted by the Runtime today and named in F1-01.
    public var emitted: Bool {
        switch self {
        case .runStarted, .runFinishing, .stopAccepted, .runQuiescent, .runEnded,
             .actionAccepted, .actionDispatched, .actionCompleted, .actionFailed, .actionUnknown:
            return true
        default:
            return false
        }
    }
}

/// One Runtime event with its `data` and time pulled out, whichever way the
/// bridge delivered it: `payload` may be the RunEvent's `data` object or
/// the whole RunEvent (`{runId, sequence, at, type, data}`).
struct ACPEventFacts {
    var runId: String
    var cursor: Int
    var type: String
    var data: JSONValue
    var at: String?

    init(_ e: ACPRuntimeEvent) {
        runId = e.runId; cursor = e.cursor; type = e.type
        if let inner = e.payload["data"], inner.objectMembers != nil, e.payload["type"] != nil || e.payload["sequence"] != nil {
            data = inner
            at = e.payload["at"]?.stringValue
        } else {
            data = e.payload.objectMembers != nil ? e.payload : .obj([])
            at = e.payload["at"]?.stringValue
        }
    }

    var receipt: JSONValue? {
        if let r = data["receipt"], r.objectMembers != nil { return r }
        return nil
    }

    /// The action this event is about: its request id, from the event or its receipt.
    var requestId: String? {
        data["requestId"]?.stringValue ?? receipt?["requestId"]?.stringValue
    }

    func string(_ key: String) -> String? { data[key]?.stringValue }
}

/// What the projector learned from earlier events of the same session. A
/// value, so projection stays pure: same context + same event → same output.
public struct ACPEventContext: Equatable, Sendable {
    /// toolCallId → action kind seen on `action.accepted`.
    public var actionKinds: [String: String] = [:]
    /// runId → Run kind (act / exec / unit) seen on `run.started`.
    public var runKinds: [String: String] = [:]
    /// runId → `at` of `run.started`, for the Run's elapsed time.
    public var runStartedAt: [String: String] = [:]
    /// toolCallIds for which a tool call was already announced.
    public var announced: Set<String> = []
    /// toolCallId → "accepted" or "dispatched": actions with no result event
    /// yet. A G0 refusal before dispatch emits no result event (the request
    /// fails after `action.accepted`), so these are settled at `run.ended`.
    public var openActions: [String: String] = [:]
    /// toolCallId → runId, for `openActions`.
    public var actionRuns: [String: String] = [:]
    /// toolCallId → runId: actions whose result is unknown while the Run is
    /// active. Made terminal at `run.ended` (ruling P2).
    public var unknownActions: [String: String] = [:]
    public init() {}

    /// Learn from one event (after projecting it).
    public mutating func absorb(_ event: ACPRuntimeEvent) {
        let f = ACPEventFacts(event)
        switch f.type {
        case ACPEventType.runStarted.rawValue:
            if let k = f.string("kind") { runKinds[f.runId] = k }
            if let at = f.at { runStartedAt[f.runId] = at }
        case ACPEventType.actionAccepted.rawValue:
            let id = ACPProjector.toolCallId(f)
            if let k = f.string("kind") ?? f.string("action") { actionKinds[id] = k }
            announced.insert(id)
            openActions[id] = "accepted"; actionRuns[id] = f.runId
        case ACPEventType.actionDispatched.rawValue:
            let id = ACPProjector.toolCallId(f)
            announced.insert(id)
            openActions[id] = "dispatched"; actionRuns[id] = f.runId
        case ACPEventType.actionCompleted.rawValue, ACPEventType.actionFailed.rawValue,
             ACPEventType.actionUnknown.rawValue, ACPEventType.actionRefused.rawValue:
            let id = ACPProjector.toolCallId(f)
            announced.insert(id)
            openActions[id] = nil; actionRuns[id] = nil
            let unknown = f.type == ACPEventType.actionUnknown.rawValue
                || (f.type != ACPEventType.actionRefused.rawValue
                    && f.receipt.map { ACPProjector.level(receipt: $0, errorCode: nil) == .unknown } == true)
            unknownActions[id] = unknown ? f.runId : nil
        case ACPEventType.actionVerified.rawValue, ACPEventType.verificationSucceeded.rawValue,
             ACPEventType.verificationFailed.rawValue:
            // A verification result is a result: the action is no longer open.
            let id = ACPProjector.toolCallId(f)
            announced.insert(id)
            openActions[id] = nil; actionRuns[id] = nil; unknownActions[id] = nil
        case ACPEventType.runEnded.rawValue:
            for (id, run) in actionRuns where run == f.runId { openActions[id] = nil; actionRuns[id] = nil }
            for (id, run) in unknownActions where run == f.runId { unknownActions[id] = nil }
        default:
            break
        }
    }
}
