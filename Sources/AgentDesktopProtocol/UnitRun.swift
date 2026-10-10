import CryptoKit
import Foundation

// A6 (PR2d): `unit.run` on the Runtime's RunStore. The Runtime owns the Run
// (admission, ownership, lifetime, phase, outcome, quiescence, events); the
// GUI executor the host registers only drives it: it observes and acts
// through the Runtime under the Run's runId and reports `unit.*` facts.
// Nothing here lets the executor choose who owns a Run or how long it lives.

/// What the executor resolved at admission (F40-06 rows 7–15), handed back
/// to it when the Run starts. Opaque to the Runtime except for the profile
/// it pins on `Run.unit`.
public protocol UnitRunPlan: Sendable {
    var guiProfileId: String? { get }
    var guiProfileRevision: Int? { get }
}

/// The admitted Run as the executor sees it.
public struct UnitRunContext: Sendable {
    public let runId: String
    public let sessionId: String
    public let desktopId: String
    /// The binding generation of the Desktop's window when the Run started;
    /// an observation of any other generation is stale.
    public let bindingEpoch: UInt64
    /// The caller's scope in the AI service's configuration ("uid:<n>" for
    /// the local owner, the clientId of a paired app).
    public let callerScope: String
    /// The validated unit_run_params.
    public let params: JSONValue

    public init(runId: String, sessionId: String, desktopId: String, bindingEpoch: UInt64, callerScope: String,
                params: JSONValue) {
        self.runId = runId; self.sessionId = sessionId; self.desktopId = desktopId
        self.bindingEpoch = bindingEpoch; self.callerScope = callerScope; self.params = params
    }
}

/// How the executor's part of a Run ended. The Runtime turns it into the
/// Run's outcome; an action whose delivery is unknown makes the outcome
/// unknown whatever is reported here.
public enum UnitRunEnding: Equatable, Sendable {
    /// The bound verification held on a fresh observation.
    case verified
    /// The unit could not reach its goal; `reason` becomes closingReason.
    case failed(reason: String)
    /// The Run was stopped (cancel, owner lost, global stop, revoke).
    case cancelled
    /// A person must look (needs_user): the Run waits in waiting_input, takes
    /// no input, and ends only by a stop.
    case needsInput(reason: String)
}

/// The Runtime's side of one unit Run, for its executor.
public protocol UnitRunSink: AnyObject, Sendable {
    /// Append a `unit.*` event to the Run's timeline. False when it was not
    /// written (the Run ended, or the audit store failed): the executor
    /// must then stop before any further model call or input.
    @discardableResult
    func record(_ type: String, _ data: JSONValue) -> Bool
    /// The latest verification of the bound predicates (Run.unit.verification).
    func verified(status: String, observationId: String?, checkedAt: Date)
    /// The executor is done. Called once; the Run ends once quiescent.
    func finished(_ ending: UnitRunEnding)
}

/// The GUI executor the host registers with the Runtime (A6).
public protocol UnitRunExecutor: Sendable {
    /// Rows 7–15 of F40-06 for this caller, before any Run exists: the GUI
    /// profile, its model and credential, the backend's actions and
    /// predicates, and the mode. A refusal is in runtime/1 terms.
    func admit(params: JSONValue, callerScope: String) async -> Result<any UnitRunPlan, RuntimeError>
    /// Start driving the admitted Run; returns at once. Before anything of
    /// the Run can run, the executor arms `stop` with what stops it: the
    /// Runtime fires it when it accepts a stop of the Run (possibly already
    /// before start). No model call or input may start after it; the
    /// executor still reports `finished`.
    func start(_ plan: any UnitRunPlan, context: UnitRunContext, sink: UnitRunSink, stop: UnitRunStopHandle)
}

/// A unit Run's stop, created by the Runtime before its executor starts
/// (codex on 25f29ff): a stop accepted at any moment, even before the
/// executor armed it, reaches the executor exactly once.
public final class UnitRunStopHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var action: (@Sendable () -> Void)?

    public init() {}

    public var isStopped: Bool { lock.withLock { stopped } }

    /// The executor's stop. Runs at once when the Run was already stopped.
    public func arm(_ body: @escaping @Sendable () -> Void) {
        let now: Bool = lock.withLock {
            action = body
            return stopped
        }
        if now { body() }
    }

    /// The Runtime accepted a stop. Repeats do nothing.
    public func stop() {
        let body: (@Sendable () -> Void)? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            return action
        }
        body?()
    }
}

public enum UnitRun {
    /// Fields a caller may name only to be refused (ADR v2.2, F40-06 row 1).
    public static let escalationFields = ["origin", "lifetime", "ownership"]

    /// The runtime/1 requestId of the `act` an explorer actionId becomes
    /// (same ID ⇒ same request, so a repeated actionId never inputs twice).
    public static func actRequestId(for actionId: String) -> String {
        let allowed = actionId.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._:-".unicodeScalars.contains($0) }
        if allowed, let first = actionId.unicodeScalars.first, CharacterSet.alphanumerics.contains(first), actionId.count <= 120 {
            return "gui-" + actionId
        }
        return "gui-" + SHA256.hash(data: Data(actionId.utf8)).prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// `sha256:<hex>` of the goal's description; parameter values never
    /// take part (05 §5.3: parameters and steps are kept apart).
    public static func goalHash(_ description: String) -> String {
        "sha256:" + SHA256.hash(data: Data(description.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
