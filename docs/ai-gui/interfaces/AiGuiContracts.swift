// PROPOSED INTERFACE DECLARATIONS ONLY. Native compilation and product tests: NOT_RUN.
// Internal Swift domain interfaces, not a Codable implementation of the wire schema.
// Place in AgentDesktopContracts. AI/GUI targets import Contracts; neither imports Runtime.
// Runtime is the composition root and implements observation/execution/verifier ports.
import Foundation

public typealias ResourceID = String
public typealias Revision = UInt64

public enum AiProtocol: String, Sendable {
    case openaiChat = "openai_chat"
    case anthropicMessages = "anthropic_messages"
    case openaiResponses = "openai_responses"
    case geminiGenerateContent = "gemini_generate_content"
}
public enum CoordinateProtocol: String, Sendable {
    case normalized1000 = "normalized_1000"
    case imagePixels = "image_pixels"
}
public enum ResourceState: String, Sendable { case enabled, disabled }
public struct ModelRequestOptions: Sendable {
    public let temperature: Double?
    public let seed: Int?
}
public struct AiConnectionSnapshot: Sendable {
    public let connectionId: ResourceID
    public let revision: Revision
    public let name: String
    public let apiProtocol: AiProtocol
    public let baseUrl: URL
    public let credentialIdentityRef: ResourceID
    public let timeoutMs: Int
    public let state: ResourceState
}
public struct AiModelSnapshot: Sendable {
    public let modelProfileId: ResourceID
    public let revision: Revision
    public let connectionId: ResourceID
    public let connectionRevision: Revision
    public let modelId: String
    public let requestOptions: ModelRequestOptions
    public let maxOutputTokens: Int
}
public struct GuiLimits: Sendable {
    public let maxSteps: Int
    public let maxWallTimeMs: Int
    public let maxModelAttemptsPerStep: Int
    public let maxTotalModelAttempts: Int
    public let maxOutputTokens: Int
    public let maxWaitMs: Int
    public let maxScreenshots: Int
    public let maxImageEncodedBytes: Int
    public let requireReportedUsage: Bool
}
public struct AdapterProvenance: Sendable {
    public let adapterId: String
    public let adapterVersion: String
    public let promptVersion: String
    public let parserVersion: String
    public let coordinateProtocol: CoordinateProtocol
}
public struct GuiProfileSnapshot: Sendable {
    public let guiProfileId: ResourceID
    public let revision: Revision
    public let modelProfileId: ResourceID
    public let modelProfileRevision: Revision
    public let provenance: AdapterProvenance
    public let limits: GuiLimits
}
public struct ResolvedGuiCandidate: Sendable {
    public let candidateIndex: Int
    public let connection: AiConnectionSnapshot
    public let model: AiModelSnapshot
    public let gui: GuiProfileSnapshot
    public let authorizationScopeRef: ResourceID
    public let dataScopeRef: ResourceID
}
public struct GuiVerificationPredicate: Sendable {
    // v1 wire codec requires kind="element_text_equals", role="static_text".
    public let exactStaticText: String
}
public struct GuiRunBinding: Sendable {
    public let runId: ResourceID
    public let sessionId: ResourceID
    public let desktopId: ResourceID
    public let goal: String // Exact submitted goal, durable across UI/service restart.
    public let bindingEpoch: Revision
    public let initialGeneration: Revision
    public let policyRevision: Revision
    public let primary: ResolvedGuiCandidate
    public let fallbackCandidates: [ResolvedGuiCandidate] // <= 1; deep snapshot at binding.
    public let allowedActions: Set<GuiActionKind>
    public let verification: GuiVerificationPredicate
}
public struct Point: Sendable { public let x: Double; public let y: Double }
public struct Size: Sendable { public let width: Double; public let height: Double }
public struct Rect: Sendable { public let origin: Point; public let size: Size }
public struct Insets: Sendable {
    public let left: Double; public let top: Double
    public let right: Double; public let bottom: Double
}
public struct AffineTransform: Sendable {
    public let a: Double; public let b: Double; public let c: Double
    public let d: Double; public let tx: Double; public let ty: Double
}
public struct TargetIdentity: Sendable {
    public let appId: String
    public let processId: Int
    public let processStartId: ResourceID
    public let windowId: ResourceID
    public let windowGeometryRevision: Revision
    public let backendId: String
    public let windowFrameDesktopLogical: Rect
}
public struct ScreenshotTransform: Sendable {
    public let sourceSize: Size
    public let crop: Rect
    public let resizedSize: Size
    public let letterbox: Insets
    public let modelInputSize: Size
    public let sourceToModel: AffineTransform
    public let modelToSource: AffineTransform
}
public struct ScreenshotDescriptor: Sendable {
    public let screenshotId: ResourceID
    public let artifactRef: ResourceID
    public let sha256: String
    public let mimeType: String
    public let transformVersion: String
    public let sourceToDesktop: AffineTransform
    public let transform: ScreenshotTransform
}
public struct ObservationStamp: Sendable {
    public let sessionId: ResourceID
    public let desktopId: ResourceID
    public let snapshotId: ResourceID
    public let bindingEpoch: Revision
    public let runGeneration: Revision // Runtime.currentGeneration at observation time.
}
public struct Observation: Sendable {
    public let observationId: ResourceID
    public let stamp: ObservationStamp
    public let target: TargetIdentity
    public let observedAt: Date
    public let screenshots: [ScreenshotDescriptor]
}
public struct EncodedInferenceImage: Sendable {
    public let screenshotId: ResourceID
    public let mimeType: String
    public let bytes: Data // internal-only image bytes; never local-RPC JSON or ordinary logs.
}
public struct ObservationBundle: Sendable {
    public let observation: Observation
    public let authorizedImages: [EncodedInferenceImage]
}
public enum GuiActionKind: String, Hashable, Sendable { case click, type, key, scroll }
public enum ScrollDirection: String, Sendable { case up, down, left, right }
public enum GuiAction: Sendable {
    case click(sourcePixel: Point) // v1 left button only.
    case type(text: String) // sensitive; never include raw text in run-event logging.
    case key(keys: [String]) // codec validates the exact schema allowlist.
    case scroll(sourcePixel: Point, direction: ScrollDirection, amountPixels: Int)
}
public enum GuiProposalBody: Sendable {
    case action(GuiAction)
    case wait(milliseconds: Int)
    case finish(reason: String) // requests verifier; cannot mark success.
    case needsUser(reasonCode: String, message: String)
}
public struct GuiProposal: Sendable {
    public let proposalId: ResourceID
    public let runId: ResourceID
    public let stepIndex: Int
    public let inferenceAttemptId: ResourceID
    public let stamp: ObservationStamp
    public let screenshotId: ResourceID
    public let provenance: AdapterProvenance
    public let body: GuiProposalBody
}
public struct UsageTokens: Sendable {
    public let inputTokens: Int?; public let outputTokens: Int?
    public let cacheReadTokens: Int?; public let cacheWriteTokens: Int?; public let totalTokens: Int?
}
public struct CostEstimate: Sendable {
    public let amountDecimal: String
    public let currency: String
    public let source: String // "reported" or "estimated"; not a billing guarantee.
    public let pricingRevision: ResourceID?
}
public struct AiGuiError: Error, Sendable {
    public let code: String // exact enum lives in domain.schema.json.
    public let message: String
    public let retryable: Bool
}
// Shared model service types. These are internal call contracts, not new RPC DTOs.
// Diagnostic calls use an operation identity; never fabricate a GUI run/session.
public enum CapabilityModelTestLevel: String, Sendable {
    case authModel = "auth_model", imageInput = "image_input", guiContract = "gui_contract"
}
public struct GuiStepCallPurpose: Sendable {
    public let runId: ResourceID
    public let stepIndex: Int
    public let snapshotId: ResourceID
    public let bindingEpoch: Revision
    public let currentGeneration: Revision
}
public struct CapabilityTestCallPurpose: Sendable {
    public let operationId: ResourceID
    public let level: CapabilityModelTestLevel
    public let syntheticSnapshotId: ResourceID
    public let fixtureId: ResourceID
    public let guiProfileId: ResourceID
    public let guiProfileRevision: Revision
}
public enum AiCallPurpose: Sendable {
    case guiStep(GuiStepCallPurpose) // persisted purpose="gui_step".
    case capabilityTest(CapabilityTestCallPurpose) // persisted purpose="capability_test".
}
public struct AiCallContext: Sendable {
    public let requestId: UUID
    public let inferenceAttemptId: ResourceID
    public let purpose: AiCallPurpose
    public let callerScopeRef: ResourceID
    public let budgetScopeRef: ResourceID // server-owned run/operation budget; not caller authority.
    public let deadlineMonotonicNanoseconds: UInt64 // one deadline, never renewed per attempt.
}
public struct AiResolvedModel: Sendable {
    public let connection: AiConnectionSnapshot
    public let model: AiModelSnapshot
    public let authorizationScopeRef: ResourceID
    public let dataScopeRef: ResourceID
}
public enum AiMessageRole: String, Sendable { case system, user, assistant }
public enum AiMessageContent: Sendable {
    case text(String)
    case image(EncodedInferenceImage)
}
public struct AiMessage: Sendable {
    public let role: AiMessageRole
    public let content: [AiMessageContent]
}
public struct AiInferenceRequest: Sendable {
    public let messages: [AiMessage]
    public let options: ModelRequestOptions
    public let maxOutputTokens: Int
    // No stream flag: V1 transport always sends stream:false.
}
public struct AiCallRecord: Sendable {
    public let reservationId: ResourceID
    public let context: AiCallContext
    public let target: AiResolvedModel
    public let requestedModelId: String
    public let actualModelId: String?
    public let upstreamRequestId: String?
    public let startedAt: Date; public let endedAt: Date; public let latencyMs: Int
    public let state: InferenceState
    public let usage: UsageTokens?
    public let cost: CostEstimate?
    public let error: AiGuiError?
}
public struct AiInferenceResult: Sendable {
    public let outputText: String // complete bounded response; still untrusted model output.
    public let finishReason: String?
    public let record: AiCallRecord
}
public protocol AiService: Sendable {
    // Shared credential/HTTP/deadline/budget/ledger path for both purposes.
    // Must durably record failures/cancellation before throwing, subject to recovery policy.
    func infer(_ request: AiInferenceRequest, resolvedModel: AiResolvedModel,
               context: AiCallContext) async throws -> AiInferenceResult
}
public protocol AiCallLedgerPort: Sendable {
    // Reserve atomically before HTTP. Diagnostic operation quota is independent of run quota.
    func reserve(context: AiCallContext, target: AiResolvedModel) async throws -> ResourceID
    // User cancellation must not erase the terminal ledger record.
    func finish(_ record: AiCallRecord) async throws
}
public enum InferenceState: String, Sendable { case succeeded, failed, cancelled }
public struct InferenceReceipt: Sendable {
    public let inferenceAttemptId: ResourceID
    public let requestId: UUID
    public let upstreamRequestId: String?
    public let snapshotId: ResourceID
    public let runId: ResourceID
    public let stepIndex: Int
    public let candidate: ResolvedGuiCandidate
    public let requestedModelId: String
    public let actualModelId: String?
    public let startedAt: Date; public let endedAt: Date; public let latencyMs: Int
    public let state: InferenceState
    public let usage: UsageTokens?
    public let cost: CostEstimate?
    public let proposalId: ResourceID?
    public let error: AiGuiError?
}
public struct GuiInferenceInput: Sendable {
    public let binding: GuiRunBinding
    public let candidate: ResolvedGuiCandidate
    public let observation: Observation
    public let images: [EncodedInferenceImage]
    public let stepIndex: Int
    public let inferenceAttemptId: ResourceID
    public let taskText: String
    public let remainingBudgetMs: Int // computed from shared monotonic deadline.
}
public struct GuiInferenceOutput: Sendable {
    public let proposal: GuiProposal
    public let receipt: InferenceReceipt
}
public enum DeliveryState: String, Sendable { case notSent = "not_sent", submitted, confirmed, unknown, rejected }
public struct ActionReceipt: Sendable {
    public let actionId: ResourceID
    public let proposalId: ResourceID
    public let runId: ResourceID
    public let stamp: ObservationStamp
    public let actionType: GuiActionKind
    public let deliveryState: DeliveryState
    public let executionTarget: TargetIdentity?
    public let inputPath: String?
    public let startedAt: Date?; public let endedAt: Date?
    public let evidenceRefs: [ResourceID]
    public let confirmationObservationId: ResourceID?
    public let reasonCode: String?
}
public struct VerificationResult: Sendable {
    public let passed: Bool
    public let observationId: ResourceID
    public let verifierId: ResourceID
}
public struct InferenceAttemptReservation: Sendable {
    public let inferenceAttemptId: ResourceID
    public let requestId: UUID
    public let runId: ResourceID
    public let stepIndex: Int
    public let snapshotId: ResourceID
    public let candidate: ResolvedGuiCandidate
}

public protocol GuiAiProvider: Sendable {
    // Must check Task cancellation; must not capture a Runtime/input/observation port.
    func suggest(_ input: GuiInferenceInput) async throws -> GuiInferenceOutput
}
public protocol GuiObservationPort: Sendable {
    func observe(runId: ResourceID, expectedGeneration: Revision) async throws -> ObservationBundle
}
public protocol GuiExecutionPort: Sendable {
    // Runtime rechecks authority, generation, snapshot, target, geometry and lease here.
    // Proposal JSON is not an execution capability. Never auto replay unknown delivery.
    func execute(_ proposal: GuiProposal) async throws -> ActionReceipt
}
public protocol GuiVerificationPort: Sendable {
    // Must use a new observation of the bound target; predicate comes from binding.
    func verify(binding: GuiRunBinding, newObservation: Observation) async throws -> VerificationResult
}
public protocol GuiAuditPort: Sendable {
    // Durable pre-call/pre-input ledger failure must stop progress (AUDIT_UNAVAILABLE).
    func reserveInference(_ reservation: InferenceAttemptReservation) async throws
    func reserveAction(_ proposal: GuiProposal) async throws -> ResourceID
    func recordInference(_ receipt: InferenceReceipt) async throws
    func recordAction(_ receipt: ActionReceipt) async throws
}
public protocol GuiExplorerService: Sendable {
    func start(binding: GuiRunBinding) async throws
    func requestCancellation(runId: ResourceID) async throws
}
