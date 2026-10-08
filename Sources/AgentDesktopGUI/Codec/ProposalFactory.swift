import AgentDesktopProtocol
import Foundation

/// Builds proposals with their provenance. Identity fields (desktop,
/// snapshot, epoch, generation, screenshot) come from the Runtime's
/// observation; the model's text only ever supplies the body.
public struct ProposalFactory: Sendable {
    public let newId: @Sendable () -> String

    public init(newId: @escaping @Sendable () -> String = { "prop-" + UUID().uuidString.lowercased() }) {
        self.newId = newId
    }

    /// Decode a complete reply against the observation's screenshot and
    /// build the proposal. The codec gets that screenshot's transform, so a
    /// model cannot pick another image's coordinate space.
    public func propose(codec: GuiActionCodec, modelOutput: String, runId: String, stepIndex: Int,
                        inferenceAttemptId: String, observation: Observation, screenshotId: String,
                        maxWaitMs: Int) throws -> (proposal: GuiProposal, thought: String?) {
        guard let shot = observation.screenshot(screenshotId) else {
            throw ContractError(.staleObservation, "screenshot is not part of this observation")
        }
        let decoded = try codec.decode(modelOutput, context: CodecContext(transform: shot.transform, maxWaitMs: maxWaitMs))
        let proposal = try make(runId: runId, stepIndex: stepIndex, inferenceAttemptId: inferenceAttemptId,
                                observation: observation, screenshotId: screenshotId,
                                provenance: codec.provenance, body: decoded.body)
        return (proposal, decoded.thought)
    }

    public func make(runId: String, stepIndex: Int, inferenceAttemptId: String, observation: Observation,
                     screenshotId: String, provenance: AdapterProvenance, body: GuiProposalBody) throws -> GuiProposal {
        guard let shot = observation.screenshot(screenshotId) else {
            throw ContractError(.staleObservation, "screenshot is not part of this observation")
        }
        switch body {
        case let .action(.click(p)), let .action(.scroll(p, _, _)):
            try CoordinateMapper.checkDomain(p, shot.transform.sourceSize, "source pixel")
        default: break
        }
        let proposal = GuiProposal(proposalId: newId(), runId: runId, stepIndex: stepIndex,
                                   inferenceAttemptId: inferenceAttemptId, stamp: observation.stamp,
                                   screenshotId: screenshotId, provenance: provenance, body: body)
        let violations = try ContractBundle.shared.validate(proposal.json, "GuiProposal")
        guard violations.isEmpty else {
            throw ContractError(.validationError, "proposal does not match the contract",
                                details: ServiceRouter.violationDetails(violations, under: ""))
        }
        return proposal
    }
}
