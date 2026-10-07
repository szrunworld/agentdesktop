import AgentDesktopContracts
import Foundation

/// The V1 verifier (spec §06.4): does the bound window, in this
/// observation, hold a static text element whose whole text equals the
/// bound verification text? Exact comparison, no fuzzy matching, no search
/// across other windows or desktops, and no concatenation of the window's
/// text into one node. The predicate comes from the binding; nothing a
/// model says reaches it.
public struct GoalVerifier: Sendable {
    public static let verifierId = "element-text-equals-v1"
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
        let passed = elements.contains { $0.role == Self.staticTextRole && $0.text == binding.verification.text }
        return GoalVerification(status: passed ? .passed : .failed, observationId: bundle.observation.observationId,
                                verifierId: Self.verifierId, checkedAt: checkedAt)
    }
}
