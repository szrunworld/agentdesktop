import AgentDesktopProtocol
import Foundation

/// The verifier (spec §06.4, X1): judges the bound predicates on one
/// observation of the bound window, three-valued.
///
/// - matched: complete, consistent evidence that the condition holds.
/// - contradicted: complete evidence that it does not.
/// - inconclusive: the observation cannot decide. Only a complete element
///   read can show that something is absent; a partial or unavailable read
///   leaves "not found" inconclusive, never true. A `value_equals_parameter`
///   whose labelled element is missing, appears twice or has no readable
///   value is inconclusive too: the verifier never picks one of two. Its one
///   candidate is unique only on a complete read.
///
/// Combinators: `not` swaps matched and contradicted and keeps inconclusive;
/// `all` is contradicted when any operand is, matched only when every one
/// is; `any` is matched when any operand is, contradicted only when every
/// one is. The run's predicates together are one `all`.
///
/// Exact comparison, no fuzzy matching, no search across other windows or
/// desktops, and no concatenation of the window's text into one node. The
/// predicates come from the binding; nothing a model says reaches them.
///
/// Cross-platform normalization before comparing (since v2): invisible
/// bidirectional formatting characters are removed from both sides (an
/// accessibility tree may wrap text in them: macOS Calculator puts U+200E
/// around its display), and Swift compares strings by canonical
/// equivalence. Nothing else is relaxed: spaces, case, width and digits
/// must still match exactly.
public struct GoalVerifier: Sendable {
    public static let verifierId = "gui-predicates-v3"
    /// LRM, RLM, ALM, the embeddings/overrides U+202A–U+202E, the isolates
    /// U+2066–U+2069, and the BOM.
    static let invisibleFormatting: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E,
                                                   0x2066, 0x2067, 0x2068, 0x2069, 0xFEFF]

    public static func normalized(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: s.unicodeScalars.filter { !invisibleFormatting.contains($0.value) })
        return String(scalars)
    }
    public static let staticTextRole = "static_text"

    /// One predicate's verdict.
    enum Verdict: Equatable {
        case matched, contradicted
        case inconclusive(GoalVerification.Reason)
    }

    public init() {}

    public func evaluate(_ bundle: ObservationBundle, binding: GuiRunBinding, checkedAt: Date) throws -> GoalVerification {
        let stamp = bundle.observation.stamp
        guard stamp.desktopId == binding.desktopId, stamp.sessionId == binding.sessionId else {
            throw ContractError(.staleObservation, "the observation is not of the run's bound desktop and session")
        }
        guard let elements = bundle.elements else {
            throw ContractError(.capabilityMismatch, "this backend cannot read the elements the run's predicates need")
        }
        let verdict = Self.judge(.all(binding.verifications), elements: elements, coverage: bundle.elementCoverage)
        let status: GoalVerification.Status
        var reason: GoalVerification.Reason?
        switch verdict {
        case .matched: status = .passed
        case .contradicted: status = .failed
        case let .inconclusive(r): status = .inconclusive; reason = r
        }
        return GoalVerification(status: status, observationId: bundle.observation.observationId,
                                verifierId: Self.verifierId, checkedAt: checkedAt, reason: reason)
    }

    static func judge(_ p: GuiVerification, elements: [ObservedElement], coverage: ElementCoverage) -> Verdict {
        /// "Not found": only a complete read shows absence.
        var absent: Verdict {
            switch coverage {
            case .complete: return .contradicted
            case .partial: return .inconclusive(.elementsPartial)
            case .unavailable: return .inconclusive(.elementsUnavailable)
            }
        }
        func same(_ a: String?, _ b: String) -> Bool { a.map { normalized($0) == normalized(b) } ?? false }

        switch p {
        case let .elementTextEquals(text):
            return elements.contains { $0.role == staticTextRole && same($0.text, text) } ? .matched : absent
        case let .elementExists(role, label, text):
            let found = elements.contains { e in
                e.role == role && (label.map { same(e.label, $0) } ?? true) && (text.map { same(e.text, $0) } ?? true)
            }
            return found ? .matched : absent
        case let .valueEqualsParameter(role, label, _, value):
            let candidates = elements.filter { $0.role == role && same($0.label, label) }
            // Two found already are ambiguous however much was read; one
            // found is unique only when the whole tree was read (Codex on
            // 3f59d7c: the unread part may hold a second one).
            if candidates.count == 1, case .inconclusive = absent { return absent }
            guard candidates.count == 1, let shown = candidates[0].value else {
                if candidates.count > 1 { return .inconclusive(.ambiguous) }
                if candidates.isEmpty {
                    // The labelled target is gone: the evidence is missing,
                    // which is not evidence of a wrong value.
                    if case .inconclusive = absent { return absent }
                    return .inconclusive(.targetMissing)
                }
                return .inconclusive(.valueUnreadable)
            }
            return same(shown, value) ? .matched : .contradicted
        case let .not(inner):
            switch judge(inner, elements: elements, coverage: coverage) {
            case .matched: return .contradicted
            case .contradicted: return .matched
            case let undecided: return undecided
            }
        case let .all(ps):
            var firstUndecided: Verdict?
            for q in ps {
                let v = judge(q, elements: elements, coverage: coverage)
                if v == .contradicted { return .contradicted }
                if v != .matched, firstUndecided == nil { firstUndecided = v }
            }
            return firstUndecided ?? .matched
        case let .any(ps):
            var firstUndecided: Verdict?
            for q in ps {
                let v = judge(q, elements: elements, coverage: coverage)
                if v == .matched { return .matched }
                if v != .contradicted, firstUndecided == nil { firstUndecided = v }
            }
            return firstUndecided ?? .contradicted
        }
    }
}
