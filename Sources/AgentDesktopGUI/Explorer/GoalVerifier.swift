import AgentDesktopContracts
import Foundation

/// The V1 verifier (spec §06.4): does the bound window, in this
/// observation, hold a static text element whose whole text equals the
/// bound verification text? Exact comparison, no fuzzy matching, no search
/// across other windows or desktops, and no concatenation of the window's
/// text into one node. The predicate comes from the binding; nothing a
/// model says reaches it.
///
/// Cross-platform normalization before comparing (v2): invisible
/// bidirectional formatting characters are removed from both sides (an
/// accessibility tree may wrap text in them: macOS Calculator puts U+200E
/// around its display), and Swift compares strings by canonical
/// equivalence. Nothing else is relaxed: spaces, case, width and digits
/// must still match exactly.
public struct GoalVerifier: Sendable {
    public static let verifierId = "element-text-equals-v2"
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

    public init() {}

    public func evaluate(_ bundle: ObservationBundle, binding: GuiRunBinding, checkedAt: Date) throws -> GoalVerification {
        let stamp = bundle.observation.stamp
        guard stamp.desktopId == binding.desktopId, stamp.sessionId == binding.sessionId else {
            throw ContractError(.staleObservation, "the observation is not of the run's bound desktop and session")
        }
        guard let elements = bundle.elements else {
            throw ContractError(.capabilityMismatch, "this backend cannot read static text for element_text_equals")
        }
        let expected = Self.normalized(binding.verification.text)
        let passed = elements.contains { $0.role == Self.staticTextRole && Self.normalized($0.text) == expected }
        return GoalVerification(status: passed ? .passed : .failed, observationId: bundle.observation.observationId,
                                verifierId: Self.verifierId, checkedAt: checkedAt)
    }
}
