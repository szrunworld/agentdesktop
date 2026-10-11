import AgentDesktopProtocol
import CryptoKit
import Foundation

/// Stall detection for one run (X1-2; docs/plan/05 §5.2, GUI Explorer plan
/// §7.4 and §11). It watches state fingerprints and action intents and says
/// when the run stopped making progress. It never proves success, never
/// sends input and never asks the model anything: the loop decides what a
/// stall costs (one bounded recovery, then a bounded end).
///
/// - Fingerprint: the bound window's element tree (role, label, value),
///   with clock-like text masked. Observation ids, times and screenshots
///   are not part of it. A read that is not complete has no fingerprint,
///   and a step without one counts neither for nor against progress.
/// - repeated_action: the same intent in the same state changed nothing
///   `repeatThreshold` times in a row (default 2: the third is not sent
///   before a recovery).
/// - no_progress: `noProgressThreshold` actions in a row changed nothing
///   (default 3).
/// - state_loop: the state came back to the one two observations ago
///   (A → B → A) after an action.
///
/// The tracker only holds fingerprints and intent digests in memory: no
/// typed text, label or value leaves it.
struct ProgressTracker {
    struct Policy: Equatable {
        var repeatThreshold = 2
        var noProgressThreshold = 3
        /// Recoveries one run may take before a stall ends it.
        var maxRecoveries = 1
        static let standard = Policy()
    }

    enum Stall: String, Equatable {
        case repeatedAction = "repeated_action"
        case noProgress = "no_progress"
        case stateLoop = "state_loop"

        /// The run's closingReason when this stall ends it.
        var closingReason: String { self == .stateLoop ? "loop_detected" : "no_progress" }
    }

    /// What an action tried to do, for comparing two actions; digests only.
    struct Intent: Equatable {
        let digest: String

        /// Clicks and scrolls are compared by a 24-pixel cell of the source
        /// screenshot, so a model nudging the same spot counts as the same.
        static let cell = 24.0

        init(_ action: GuiAction) {
            func cell(_ p: Point) -> String { "\(Int((p.x / Self.cell).rounded(.down))),\(Int((p.y / Self.cell).rounded(.down)))" }
            let raw: String
            switch action {
            case let .click(p): raw = "click|\(cell(p))"
            case let .type(text): raw = "type|\(text)"
            case let .key(keys): raw = "key|\(keys.joined(separator: "+"))"
            case let .scroll(p, direction, _): raw = "scroll|\(cell(p))|\(direction.rawValue)"
            }
            digest = ProgressTracker.sha(raw)
        }
    }

    let policy: Policy
    private(set) var recoveries = 0
    /// Fingerprints of the latest observations, newest last (nil: unknown).
    private var states: [String?] = []
    private var sameIntentRun = 0
    private var lastIneffective: (state: String, intent: Intent)?
    private var noChangeRun = 0

    init(policy: Policy = .standard) { self.policy = policy }

    var mayRecover: Bool { recoveries < policy.maxRecoveries }

    /// The run's first observation.
    mutating func start(_ bundle: ObservationBundle) {
        states = [Self.fingerprint(bundle)]
    }

    /// After an action that was sent (confirmed / rejected / not sent) and
    /// the new observation of it.
    mutating func afterAction(_ intent: Intent, _ bundle: ObservationBundle) -> Stall? {
        let before = states.last ?? nil
        let after = Self.fingerprint(bundle)
        defer { push(after) }
        guard let before, let after else { return nil }
        if after != before {
            sameIntentRun = 0
            lastIneffective = nil
            noChangeRun = 0
            // Back where it was two observations ago: A → B → A.
            if states.count >= 2, let twoAgo = states[states.count - 2], twoAgo == after { return .stateLoop }
            return nil
        }
        noChangeRun += 1
        if let last = lastIneffective, last.state == before, last.intent == intent {
            sameIntentRun += 1
        } else {
            sameIntentRun = 1
            lastIneffective = (before, intent)
        }
        if sameIntentRun >= policy.repeatThreshold { return .repeatedAction }
        if noChangeRun >= policy.noProgressThreshold { return .noProgress }
        return nil
    }

    /// After a wait and the new observation: a change is progress; no
    /// change counts nothing (waits spend the step budget instead).
    mutating func afterWait(_ bundle: ObservationBundle) {
        let after = Self.fingerprint(bundle)
        if let before = states.last ?? nil, let after, after != before {
            sameIntentRun = 0
            lastIneffective = nil
            noChangeRun = 0
        }
        push(after)
    }

    /// A recovery was taken: the counters start over from the observation
    /// the recovery makes.
    mutating func recovered(_ bundle: ObservationBundle) {
        recoveries += 1
        sameIntentRun = 0
        lastIneffective = nil
        noChangeRun = 0
        states = [Self.fingerprint(bundle)]
    }

    private mutating func push(_ fp: String?) {
        states.append(fp)
        if states.count > 3 { states.removeFirst(states.count - 3) }
    }

    // MARK: Fingerprint

    /// nil when the element read was not complete (or not possible).
    static func fingerprint(_ bundle: ObservationBundle) -> String? {
        guard bundle.elementCoverage == .complete, let elements = bundle.elements else { return nil }
        let lines = elements.map { e in
            [e.role, mask(GoalVerifier.normalized(e.label ?? "")), mask(GoalVerifier.normalized(e.value ?? ""))]
                .joined(separator: "\u{1F}")
        }
        return sha(lines.joined(separator: "\u{1E}"))
    }

    /// Clock-like text (12:05, 12:05:59, 2026-10-11) never makes progress.
    static func mask(_ s: String) -> String {
        var out = s
        for pattern in [#"\d{4}-\d{2}-\d{2}"#, #"\d{1,2}:\d{2}(:\d{2})?"#] {
            out = out.replacingOccurrences(of: pattern, with: "⏱", options: .regularExpression)
        }
        return out
    }

    static func sha(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
