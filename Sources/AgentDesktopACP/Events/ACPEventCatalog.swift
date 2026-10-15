import AgentDesktopProtocol
import Foundation

// The Runtime event types the projector knows (docs/acp/08-event-mapping.md §三).
//
// Exactly the frozen F1-01 catalogue (#102):
// contracts/runtime/v1/runtime.schema.json#/$defs/PlatformRunEvent. The
// prefixes run., action. and stop. may only carry these types; unit. is the
// GUI unit's own (A6, not frozen yet) and every other prefix is reserved.
// Anything else is projected as one neutral line (§3.4). The catalogue sets
// no per-type sensitivity level, so the tiers below are ours (§二).

public enum ACPEventType: String, Sendable, CaseIterable {
    // Run lifecycle
    case runStarted = "run.started"
    case runFinishing = "run.finishing"
    case stopAccepted = "stop.accepted"
    case runQuiescent = "run.quiescent"
    case runEnded = "run.ended"
    // Actions
    case actionAccepted = "action.accepted"
    case actionDispatched = "action.dispatched"
    case actionCompleted = "action.completed"
    case actionFailed = "action.failed"
    case actionUnknown = "action.unknown"
    case actionRefused = "action.refused"

    /// Kevin's three tiers (docs/acp/README.md §五 constraint 3). The
    /// catalogue has no level of its own; a protected event type does not
    /// exist in it, so only types outside the catalogue are protected.
    public var tier: ACPEventTier {
        switch self {
        case .runStarted, .runFinishing, .stopAccepted, .runQuiescent, .runEnded:
            return .normal
        case .actionAccepted, .actionDispatched, .actionCompleted, .actionFailed, .actionUnknown, .actionRefused:
            return .sensitive
        }
    }

    /// The tier of any type string: one outside the catalogue is protected
    /// (status only — a neutral line, nothing of its payload).
    public static func tier(of type: String) -> ACPEventTier {
        ACPEventType(rawValue: type)?.tier ?? ACPUnitEventType(rawValue: type)?.tier ?? .protected
    }
}

/// The GUI unit's own events the projector reads (X1-3), from
/// runtime.schema.json#/$defs/UnitRunEvent. They are not part of the frozen
/// platform catalogue above; every other `unit.*` type stays one neutral
/// line. The contract keeps their `data` to ids, enums, codes and numbers
/// (never a screenshot, typed text, a window title, a goal or parameter
/// value, or a model reply), and only the closed values below are ever
/// turned into text: anything else is not shown.
public enum ACPUnitEventType: String, Sendable, CaseIterable {
    /// The verdict on one observation: matched / contradicted / inconclusive
    /// (with a reason, X1-1).
    case verification = "unit.verification"
    /// One bounded recovery: an unusable reply or a stall (X1-2).
    case recovery = "unit.recovery"

    /// Closed vocabularies and counts only: normal. A payload the Runtime
    /// marked withheld still shows its status only.
    public var tier: ACPEventTier { .normal }

    /// `unit.verification` data.status values.
    public static let verificationStatuses: Set<String> = ["matched", "contradicted", "inconclusive"]
    /// `unit.verification` data.reason values (inconclusive only).
    public static let inconclusiveReasons: Set<String> = ["elements_partial", "elements_unavailable", "ambiguous",
                                                          "target_missing", "value_unreadable"]
    /// `unit.recovery` data.kind values.
    public static let recoveryKinds: Set<String> = ["reobserve_after_empty_reply", "reobserve_after_no_action_line",
                                                    "repeated_action", "no_progress", "state_loop"]
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

    /// The catalogue's error code (F1-03): `data.reason.code` on
    /// `action.refused`, `receipt.reason.code` on a receipt that was not
    /// delivered, failed or is unknown. The `message` is never read: it may
    /// name other apps' windows (ruling P1).
    var reasonCode: String? {
        if let r = data["reason"], r.objectMembers != nil, let c = r["code"]?.stringValue { return c }
        return receipt?["reason"]?["code"]?.stringValue
    }
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
    /// yet. Since #102 every refusal before dispatch writes `action.refused`;
    /// an action still open at `run.ended` means its result event was never
    /// written (audit store failed), so these are settled there.
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
            if let k = f.string("kind") { actionKinds[id] = k }
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
        case ACPEventType.runEnded.rawValue:
            for (id, run) in actionRuns where run == f.runId { openActions[id] = nil; actionRuns[id] = nil }
            for (id, run) in unknownActions where run == f.runId { unknownActions[id] = nil }
        default:
            break
        }
    }
}
