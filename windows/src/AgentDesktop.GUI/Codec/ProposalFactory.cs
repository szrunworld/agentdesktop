using AgentDesktop.Contracts;

namespace AgentDesktop.GUI;

/// <summary>
/// Builds proposals with their provenance. Identity fields (desktop,
/// snapshot, epoch, generation, screenshot) come from the Runtime's
/// observation; the model's text only ever supplies the body.
/// </summary>
public sealed class ProposalFactory(Func<string>? newId = null)
{
    private readonly Func<string> _newId = newId ?? (() => "prop-" + Guid.NewGuid().ToString("D"));

    /// <summary>Decode a complete reply against the observation's own screenshot and build the proposal.</summary>
    public (GuiProposal Proposal, string? Thought) Propose(IGuiActionCodec codec, string modelOutput, string runId, int stepIndex,
                                                          string inferenceAttemptId, Observation observation, string screenshotId,
                                                          int maxWaitMs)
    {
        var shot = observation.Screenshot(screenshotId)
            ?? throw new ContractError(ErrorCode.StaleObservation, "screenshot is not part of this observation");
        var decoded = codec.Decode(modelOutput, new CodecContext(shot.Transform, maxWaitMs));
        return (Make(runId, stepIndex, inferenceAttemptId, observation, screenshotId, codec.Provenance, decoded.Body), decoded.Thought);
    }

    public GuiProposal Make(string runId, int stepIndex, string inferenceAttemptId, Observation observation,
                            string screenshotId, AdapterProvenance provenance, GuiProposalBody body)
    {
        var shot = observation.Screenshot(screenshotId)
            ?? throw new ContractError(ErrorCode.StaleObservation, "screenshot is not part of this observation");
        switch (body)
        {
            case GuiProposalBody.Action { Value: GuiAction.Click c }:
                CoordinateMapper.CheckDomain(c.SourcePixel, shot.Transform.SourceSize, "source pixel");
                break;
            case GuiProposalBody.Action { Value: GuiAction.Scroll s }:
                CoordinateMapper.CheckDomain(s.SourcePixel, shot.Transform.SourceSize, "source pixel");
                break;
        }
        var proposal = new GuiProposal(_newId(), runId, stepIndex, inferenceAttemptId, observation.Stamp,
                                       screenshotId, provenance, body);
        var violations = ContractBundle.Shared.ValidateDomain(proposal.Json, "GuiProposal");
        if (violations.Count != 0)
            throw new ContractError(ErrorCode.ValidationError, "proposal does not match the contract",
                                    details: Envelope.ViolationDetails(violations));
        return proposal;
    }
}
