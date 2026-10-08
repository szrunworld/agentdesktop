// PROPOSED INTERFACE DECLARATIONS ONLY. Native compilation/product tests: NOT_RUN.
// Internal types, not a System.Text.Json wire codec. JSON Schema is authoritative.
// Put in AgentDesktop.Contracts. AI/GUI reference Contracts, not Runtime.
using System;
using System.Collections.Generic;
using System.Threading;
using System.Threading.Tasks;

namespace AgentDesktop.Contracts;

public enum AiProtocol { OpenAiChat, AnthropicMessages, OpenAiResponses, GeminiGenerateContent }
public enum CoordinateProtocol { Normalized1000, ImagePixels }
public enum ResourceState { Enabled, Disabled }
public enum GuiActionKind { Click, Type, Key, Scroll }
public enum ScrollDirection { Up, Down, Left, Right }
public enum DeliveryState { NotSent, Submitted, Confirmed, Unknown, Rejected }
public enum InferenceState { Succeeded, Failed, Cancelled }

public sealed record ModelRequestOptions(double? Temperature, int? Seed);
public sealed record AiConnectionSnapshot(string ConnectionId, ulong Revision, string Name,
    AiProtocol Protocol, Uri BaseUrl, string CredentialIdentityRef, int TimeoutMs, ResourceState State);
public sealed record AiModelSnapshot(string ModelProfileId, ulong Revision, string ConnectionId,
    ulong ConnectionRevision, string ModelId, ModelRequestOptions RequestOptions, int MaxOutputTokens);
public sealed record GuiLimits(int MaxSteps, int MaxWallTimeMs, int MaxModelAttemptsPerStep,
    int MaxTotalModelAttempts, int MaxOutputTokens, int MaxWaitMs, int MaxScreenshots,
    int MaxImageEncodedBytes, bool RequireReportedUsage);
public sealed record AdapterProvenance(string AdapterId, string AdapterVersion, string PromptVersion,
    string ParserVersion, CoordinateProtocol CoordinateProtocol);
public sealed record GuiProfileSnapshot(string GuiProfileId, ulong Revision, string ModelProfileId,
    ulong ModelProfileRevision, AdapterProvenance Provenance, GuiLimits Limits);
public sealed record ResolvedGuiCandidate(int CandidateIndex, AiConnectionSnapshot Connection,
    AiModelSnapshot Model, GuiProfileSnapshot Gui, string AuthorizationScopeRef, string DataScopeRef);
public sealed record GuiVerificationPredicate(string ExactStaticText); // element_text_equals/static_text.
public sealed record GuiRunBinding(string RunId, string SessionId, string DesktopId, string Goal,
    ulong BindingEpoch, ulong InitialGeneration, ulong PolicyRevision,
    ResolvedGuiCandidate Primary, IReadOnlyList<ResolvedGuiCandidate> FallbackCandidates,
    IReadOnlySet<GuiActionKind> AllowedActions, GuiVerificationPredicate Verification);

public readonly record struct Point(double X, double Y);
public readonly record struct Size(double Width, double Height);
public readonly record struct Rect(Point Origin, Size Size);
public readonly record struct Insets(double Left, double Top, double Right, double Bottom);
public readonly record struct AffineTransform(double A, double B, double C, double D, double Tx, double Ty);
public sealed record TargetIdentity(string AppId, int ProcessId, string ProcessStartId,
    string WindowId, ulong WindowGeometryRevision, string BackendId, Rect WindowFrameDesktopLogical);
public sealed record ScreenshotTransform(Size SourceSize, Rect Crop, Size ResizedSize,
    Insets Letterbox, Size ModelInputSize, AffineTransform SourceToModel, AffineTransform ModelToSource);
public sealed record ScreenshotDescriptor(string ScreenshotId, string ArtifactRef, string Sha256,
    string MimeType, string TransformVersion, AffineTransform SourceToDesktop, ScreenshotTransform Transform);
public sealed record ObservationStamp(string SessionId, string DesktopId, string SnapshotId,
    ulong BindingEpoch, ulong RunGeneration);
public sealed record Observation(string ObservationId, ObservationStamp Stamp, TargetIdentity Target,
    DateTimeOffset ObservedAt, IReadOnlyList<ScreenshotDescriptor> Screenshots);
public sealed record EncodedInferenceImage(string ScreenshotId, string MimeType, ReadOnlyMemory<byte> Bytes);
public sealed record ObservationBundle(Observation Observation, IReadOnlyList<EncodedInferenceImage> AuthorizedImages);

public abstract record GuiAction;
public sealed record ClickAction(Point SourcePixel) : GuiAction; // v1 left click only.
public sealed record TypeAction(string Text) : GuiAction; // sensitive; ordinary logs must redact.
public sealed record KeyAction(IReadOnlyList<string> Keys) : GuiAction; // exact codec allowlist.
public sealed record ScrollAction(Point SourcePixel, ScrollDirection Direction, int AmountPixels) : GuiAction;
public abstract record GuiProposalBody;
public sealed record ActionProposal(GuiAction Action) : GuiProposalBody;
public sealed record WaitProposal(int Milliseconds) : GuiProposalBody;
public sealed record FinishProposal(string Reason) : GuiProposalBody; // Runtime verifies new observation.
public sealed record NeedsUserProposal(string ReasonCode, string Message) : GuiProposalBody;
public sealed record GuiProposal(string ProposalId, string RunId, int StepIndex,
    string InferenceAttemptId, ObservationStamp Stamp, string ScreenshotId,
    AdapterProvenance Provenance, GuiProposalBody Body);

public sealed record UsageTokens(int? InputTokens, int? OutputTokens, int? CacheReadTokens,
    int? CacheWriteTokens, int? TotalTokens);
public sealed record CostEstimate(string AmountDecimal, string Currency, string Source, string? PricingRevision);
public sealed record AiGuiError(string Code, string Message, bool Retryable);
// Shared model service contracts: diagnostic purpose has operationId, not a fake run.
public enum CapabilityModelTestLevel { AuthModel, ImageInput, GuiContract }
public abstract record AiCallPurpose { public abstract string Kind { get; } }
public sealed record GuiStepCallPurpose(string RunId, int StepIndex, string SnapshotId,
    ulong BindingEpoch, ulong CurrentGeneration) : AiCallPurpose
{
    public override string Kind => "gui_step";
}
public sealed record CapabilityTestCallPurpose(string OperationId, CapabilityModelTestLevel Level,
    string SyntheticSnapshotId, string FixtureId, string GuiProfileId,
    ulong GuiProfileRevision) : AiCallPurpose
{
    public override string Kind => "capability_test";
}
public sealed record AiCallContext(Guid RequestId, string InferenceAttemptId, AiCallPurpose Purpose,
    string CallerScopeRef, string BudgetScopeRef, ulong DeadlineMonotonicNanoseconds);
public sealed record AiResolvedModel(AiConnectionSnapshot Connection, AiModelSnapshot Model,
    string AuthorizationScopeRef, string DataScopeRef);
public enum AiMessageRole { System, User, Assistant }
public abstract record AiMessageContent;
public sealed record AiTextContent(string Text) : AiMessageContent;
public sealed record AiImageContent(EncodedInferenceImage Image) : AiMessageContent;
public sealed record AiMessage(AiMessageRole Role, IReadOnlyList<AiMessageContent> Content);
public sealed record AiInferenceRequest(IReadOnlyList<AiMessage> Messages,
    ModelRequestOptions Options, int MaxOutputTokens); // V1 always stream:false.
public sealed record AiCallRecord(string ReservationId, AiCallContext Context, AiResolvedModel Target,
    string RequestedModelId, string? ActualModelId, string? UpstreamRequestId,
    DateTimeOffset StartedAt, DateTimeOffset EndedAt, int LatencyMs, InferenceState State,
    UsageTokens? Usage, CostEstimate? Cost, AiGuiError? Error);
public sealed record AiInferenceResult(string OutputText, string? FinishReason, AiCallRecord Record);
public interface IAiService
{
    // Shared credential/HTTP/deadline/budget/ledger path, both purposes.
    // No input port. Record failed/cancelled calls even when no result is returned.
    Task<AiInferenceResult> InferAsync(AiInferenceRequest request, AiResolvedModel resolvedModel,
        AiCallContext context, CancellationToken cancellationToken);
}
public interface IAiCallLedgerPort
{
    Task<string> ReserveAsync(AiCallContext context, AiResolvedModel target,
        CancellationToken systemShutdownToken);
    // Caller cancellation cannot be reused to skip the final durable ledger write.
    Task FinishAsync(AiCallRecord record, CancellationToken systemShutdownToken);
}
public sealed record InferenceReceipt(string InferenceAttemptId, Guid RequestId,
    string? UpstreamRequestId, string SnapshotId, string RunId, int StepIndex,
    ResolvedGuiCandidate Candidate, string RequestedModelId, string? ActualModelId,
    DateTimeOffset StartedAt, DateTimeOffset EndedAt, int LatencyMs, InferenceState State,
    UsageTokens? Usage, CostEstimate? Cost, string? ProposalId, AiGuiError? Error);
public sealed record GuiInferenceInput(GuiRunBinding Binding, ResolvedGuiCandidate Candidate,
    Observation Observation, IReadOnlyList<EncodedInferenceImage> Images, int StepIndex,
    string InferenceAttemptId, string TaskText, int RemainingBudgetMs);
public sealed record GuiInferenceOutput(GuiProposal Proposal, InferenceReceipt Receipt);
public sealed record ActionReceipt(string ActionId, string ProposalId, string RunId,
    ObservationStamp Stamp, GuiActionKind ActionType, DeliveryState DeliveryState,
    TargetIdentity? ExecutionTarget, string? InputPath, DateTimeOffset? StartedAt,
    DateTimeOffset? EndedAt, IReadOnlyList<string> EvidenceRefs,
    string? ConfirmationObservationId, string? ReasonCode);
public sealed record VerificationResult(bool Passed, string ObservationId, string VerifierId);
public sealed record InferenceAttemptReservation(string InferenceAttemptId, Guid RequestId,
    string RunId, int StepIndex, string SnapshotId, ResolvedGuiCandidate Candidate);

public interface IGuiAiProvider
{
    // No observation/input/executor handle; model proposes only.
    Task<GuiInferenceOutput> SuggestAsync(GuiInferenceInput input, CancellationToken cancellationToken);
}
public interface IGuiObservationPort
{
    Task<ObservationBundle> ObserveAsync(string runId, ulong expectedGeneration, CancellationToken cancellationToken);
}
public interface IGuiExecutionPort
{
    // Runtime checks caller/run authority, snapshot, generation, actual target and lease.
    // JSON cannot manufacture an input capability; unknown delivery is not auto-replayed.
    Task<ActionReceipt> ExecuteAsync(GuiProposal proposal, CancellationToken cancellationToken);
}
public interface IGuiVerificationPort
{
    Task<VerificationResult> VerifyAsync(GuiRunBinding binding, Observation newObservation,
        CancellationToken cancellationToken);
}
public interface IGuiAuditPort
{
    // Failure to durably reserve before a call/input blocks progress: AUDIT_UNAVAILABLE.
    Task ReserveInferenceAsync(InferenceAttemptReservation reservation, CancellationToken cancellationToken);
    Task<string> ReserveActionAsync(GuiProposal proposal, CancellationToken cancellationToken);
    Task RecordInferenceAsync(InferenceReceipt receipt, CancellationToken cancellationToken);
    Task RecordActionAsync(ActionReceipt receipt, CancellationToken cancellationToken);
}
public interface IGuiExplorerService
{
    Task StartAsync(GuiRunBinding binding, CancellationToken cancellationToken);
    Task RequestCancellationAsync(string runId, CancellationToken cancellationToken);
}

// Implementation notes:
// - These records/lists alone do not enforce deep immutability or server authorization.
// - Copy/freeze each snapshot at binding; use a separate Runtime currentGeneration counter.
// - Propagate cancellation to HTTP, but reconcile in-flight input before releasing ownership.
// - Implement tagged wire decoding from JSON Schema; do not rely on enum serialization defaults.
// - UTF-8 wire/image budgets must match Swift, including base64 payload bytes and LF framing.
