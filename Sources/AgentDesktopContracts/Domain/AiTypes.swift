import Foundation

// Internal call contracts of the shared model service (spec §06.1, §18.1),
// after docs/ai-gui/interfaces/AiGuiContracts.swift. These are not wire
// DTOs: nothing here is sent over the local RPC as-is. GUI observation and
// proposal types live with the GUI codec (T06).

public typealias ResourceID = String
public typealias Revision = UInt64

public enum AiProtocol: String, Sendable, CaseIterable {
    case openaiChat = "openai_chat"
    case anthropicMessages = "anthropic_messages"
    case openaiResponses = "openai_responses"
    case geminiGenerateContent = "gemini_generate_content"

    /// V1 implements openai_chat only; the others are reserved names.
    public var isImplemented: Bool { self == .openaiChat }
}

public enum ResourceState: String, Sendable { case enabled, disabled }

/// The only request options V1 sends upstream (spec §06.1). Anything else
/// is refused before a request is built, never forwarded.
public struct ModelRequestOptions: Equatable, Sendable {
    public let temperature: Double?
    public let seed: Int?

    public init(temperature: Double? = nil, seed: Int? = nil) {
        self.temperature = temperature
        self.seed = seed
    }

    /// Read `requestOptions` as stored on a model profile. Unknown members
    /// (thinking, vendor extensions, model/stream/endpoint overrides) are a
    /// VALIDATION_ERROR.
    public static func parse(_ json: JSONValue) throws -> ModelRequestOptions {
        guard let members = json.objectMembers else {
            throw ContractError(.validationError, "requestOptions must be an object")
        }
        var temperature: Double?
        var seed: Int?
        for m in members {
            switch m.key {
            case "temperature":
                guard let t = m.value.doubleValue, t >= 0, t <= 2 else {
                    throw ContractError(.validationError, "requestOptions.temperature must be a number from 0 to 2")
                }
                temperature = t
            case "seed":
                guard let s = m.value.intValue else {
                    throw ContractError(.validationError, "requestOptions.seed must be an integer")
                }
                seed = s
            default:
                throw ContractError(.validationError, "requestOptions supports only temperature and seed",
                                    details: .obj([("field", .string(m.key))]))
            }
        }
        return ModelRequestOptions(temperature: temperature, seed: seed)
    }
}

public struct AiConnectionSnapshot: Equatable, Sendable {
    public let connectionId: ResourceID
    public let revision: Revision
    public let name: String
    public let apiProtocol: AiProtocol
    public let baseUrl: URL
    /// Credential identity; the key itself is resolved per call.
    public let credentialIdentityRef: ResourceID
    public let timeoutMs: Int
    public let state: ResourceState

    public init(connectionId: ResourceID, revision: Revision, name: String, apiProtocol: AiProtocol,
                baseUrl: URL, credentialIdentityRef: ResourceID, timeoutMs: Int, state: ResourceState = .enabled) {
        self.connectionId = connectionId
        self.revision = revision
        self.name = name
        self.apiProtocol = apiProtocol
        self.baseUrl = baseUrl
        self.credentialIdentityRef = credentialIdentityRef
        self.timeoutMs = timeoutMs
        self.state = state
    }
}

public struct AiModelSnapshot: Equatable, Sendable {
    public let modelProfileId: ResourceID
    public let revision: Revision
    public let connectionId: ResourceID
    public let connectionRevision: Revision
    /// Kept exactly, case included.
    public let modelId: String
    public let requestOptions: ModelRequestOptions
    public let maxOutputTokens: Int

    public init(modelProfileId: ResourceID, revision: Revision, connectionId: ResourceID,
                connectionRevision: Revision, modelId: String,
                requestOptions: ModelRequestOptions = ModelRequestOptions(), maxOutputTokens: Int = 1024) {
        self.modelProfileId = modelProfileId
        self.revision = revision
        self.connectionId = connectionId
        self.connectionRevision = connectionRevision
        self.modelId = modelId
        self.requestOptions = requestOptions
        self.maxOutputTokens = maxOutputTokens
    }
}

/// A fixed candidate: endpoint, model and credential identity resolved at
/// binding time, never re-read from the current default.
public struct AiResolvedModel: Equatable, Sendable {
    public let connection: AiConnectionSnapshot
    public let model: AiModelSnapshot
    public let authorizationScopeRef: ResourceID
    public let dataScopeRef: ResourceID

    public init(connection: AiConnectionSnapshot, model: AiModelSnapshot,
                authorizationScopeRef: ResourceID, dataScopeRef: ResourceID) {
        self.connection = connection
        self.model = model
        self.authorizationScopeRef = authorizationScopeRef
        self.dataScopeRef = dataScopeRef
    }
}

public enum CapabilityModelTestLevel: String, Sendable {
    case authModel = "auth_model", imageInput = "image_input", guiContract = "gui_contract"
}

public struct GuiStepCallPurpose: Equatable, Sendable {
    public let runId: ResourceID
    public let stepIndex: Int
    public let snapshotId: ResourceID
    public let bindingEpoch: Revision
    public let currentGeneration: Revision

    public init(runId: ResourceID, stepIndex: Int, snapshotId: ResourceID, bindingEpoch: Revision, currentGeneration: Revision) {
        self.runId = runId
        self.stepIndex = stepIndex
        self.snapshotId = snapshotId
        self.bindingEpoch = bindingEpoch
        self.currentGeneration = currentGeneration
    }
}

public struct CapabilityTestCallPurpose: Equatable, Sendable {
    public let operationId: ResourceID
    public let level: CapabilityModelTestLevel
    public let syntheticSnapshotId: ResourceID
    public let fixtureId: ResourceID
    public let guiProfileId: ResourceID
    public let guiProfileRevision: Revision

    public init(operationId: ResourceID, level: CapabilityModelTestLevel, syntheticSnapshotId: ResourceID,
                fixtureId: ResourceID, guiProfileId: ResourceID, guiProfileRevision: Revision) {
        self.operationId = operationId
        self.level = level
        self.syntheticSnapshotId = syntheticSnapshotId
        self.fixtureId = fixtureId
        self.guiProfileId = guiProfileId
        self.guiProfileRevision = guiProfileRevision
    }
}

/// Why a call is made. Diagnostics carry an operation identity and never
/// pretend to be a GUI run (spec §18.1).
public enum AiCallPurpose: Equatable, Sendable {
    case guiStep(GuiStepCallPurpose)
    case capabilityTest(CapabilityTestCallPurpose)

    /// The persisted purpose value: "gui_step" or "capability_test".
    public var persistedName: String {
        switch self {
        case .guiStep: return "gui_step"
        case .capabilityTest: return "capability_test"
        }
    }

    public var runId: ResourceID? { if case let .guiStep(p) = self { return p.runId }; return nil }
    public var operationId: ResourceID? { if case let .capabilityTest(p) = self { return p.operationId }; return nil }
}

public struct AiCallContext: Equatable, Sendable {
    public let requestId: UUID
    public let inferenceAttemptId: ResourceID
    public let purpose: AiCallPurpose
    public let callerScopeRef: ResourceID
    /// Server-owned run or operation budget; not caller authority.
    public let budgetScopeRef: ResourceID
    /// One monotonic deadline for the whole run/operation, never renewed.
    public let deadlineMonotonicNanoseconds: UInt64

    public init(requestId: UUID = UUID(), inferenceAttemptId: ResourceID, purpose: AiCallPurpose,
                callerScopeRef: ResourceID, budgetScopeRef: ResourceID, deadlineMonotonicNanoseconds: UInt64) {
        self.requestId = requestId
        self.inferenceAttemptId = inferenceAttemptId
        self.purpose = purpose
        self.callerScopeRef = callerScopeRef
        self.budgetScopeRef = budgetScopeRef
        self.deadlineMonotonicNanoseconds = deadlineMonotonicNanoseconds
    }
}

public enum AiMessageRole: String, Sendable { case system, user, assistant }

/// Image bytes for one model call. Internal only: never in local-RPC JSON
/// or ordinary logs.
public struct AiImageContent: Equatable, Sendable {
    public let screenshotId: ResourceID
    public let mimeType: String
    public let bytes: Data

    public init(screenshotId: ResourceID, mimeType: String, bytes: Data) {
        self.screenshotId = screenshotId
        self.mimeType = mimeType
        self.bytes = bytes
    }

    /// Bytes of its base64 encoding, which is what the image budget counts
    /// (spec §09.1: excludes the data-URL prefix and JSON overhead).
    public var encodedByteCount: Int { (bytes.count + 2) / 3 * 4 }
}

public enum AiMessageContent: Equatable, Sendable {
    case text(String)
    case image(AiImageContent)
}

public struct AiMessage: Equatable, Sendable {
    public let role: AiMessageRole
    public let content: [AiMessageContent]

    public init(role: AiMessageRole, content: [AiMessageContent]) {
        self.role = role
        self.content = content
    }

    public static func text(_ role: AiMessageRole, _ text: String) -> AiMessage {
        AiMessage(role: role, content: [.text(text)])
    }
}

/// A bounded multimodal request. V1 always sends stream:false; there is no
/// streaming flag to set.
public struct AiInferenceRequest: Equatable, Sendable {
    public static let hardMaxOutputTokens = 1024
    public static let hardMaxImages = 5
    public static let hardMaxImageEncodedBytes = 8_388_608

    public let messages: [AiMessage]
    public let options: ModelRequestOptions
    public let maxOutputTokens: Int
    /// Image limits for this call; may only tighten the hard ceilings.
    public let maxImages: Int
    public let maxImageEncodedBytes: Int

    public init(messages: [AiMessage], options: ModelRequestOptions = ModelRequestOptions(),
                maxOutputTokens: Int = hardMaxOutputTokens, maxImages: Int = hardMaxImages,
                maxImageEncodedBytes: Int = hardMaxImageEncodedBytes) {
        self.messages = messages
        self.options = options
        self.maxOutputTokens = maxOutputTokens
        self.maxImages = maxImages
        self.maxImageEncodedBytes = maxImageEncodedBytes
    }

    public var images: [AiImageContent] {
        messages.flatMap(\.content).compactMap { if case let .image(i) = $0 { return i }; return nil }
    }
}

/// Token counts as reported upstream. nil means not reported: never zero.
public struct UsageTokens: Equatable, Sendable {
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let cacheReadTokens: Int?
    public let cacheWriteTokens: Int?
    public let totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, cacheReadTokens: Int? = nil,
                cacheWriteTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.totalTokens = totalTokens
    }

    /// Both the input and output counts are known.
    public var isComplete: Bool { inputTokens != nil && outputTokens != nil }

    public var json: JSONValue {
        func n(_ v: Int?) -> JSONValue { v.map(JSONValue.int) ?? .null }
        return .obj([("inputTokens", n(inputTokens)), ("outputTokens", n(outputTokens)),
                     ("cacheReadTokens", n(cacheReadTokens)), ("cacheWriteTokens", n(cacheWriteTokens)),
                     ("totalTokens", n(totalTokens))])
    }
}

public struct CostEstimate: Equatable, Sendable {
    public enum Source: String, Sendable { case reported, estimated }
    /// Decimal string, e.g. "0.0042"; never a guaranteed bill.
    public let amount: String
    public let currency: String
    public let source: Source
    public let pricingRevision: ResourceID?

    public init(amount: String, currency: String, source: Source, pricingRevision: ResourceID?) {
        self.amount = amount
        self.currency = currency
        self.source = source
        self.pricingRevision = pricingRevision
    }

    public var json: JSONValue {
        .obj([("amount", .string(amount)), ("currency", .string(currency)),
              ("source", .string(source.rawValue)), ("pricingRevision", pricingRevision.map(JSONValue.string) ?? .null)])
    }
}

public enum InferenceState: String, Sendable { case succeeded, failed, cancelled }

/// The ledger row of one started model call: successes, failures,
/// cancellations and missing usage alike. It never holds a key, a prompt,
/// an image or the response text.
public struct AiCallRecord: Equatable, Sendable {
    public let reservationId: ResourceID
    public let context: AiCallContext
    public let target: AiResolvedModel
    public let requestedModelId: String
    public let actualModelId: String?
    public let upstreamRequestId: String?
    public let httpStatus: Int?
    public let finishReason: String?
    public let startedAt: Date
    public let endedAt: Date
    public let latencyMs: Int
    public let state: InferenceState
    /// nil when upstream reported no usage.
    public let usage: UsageTokens?
    public let cost: CostEstimate?
    public let error: ContractError?
    /// The result arrived after the call stopped mattering (cancelled, or
    /// the run's generation moved on) and must not drive any action.
    public let discarded: Bool

    public init(reservationId: ResourceID, context: AiCallContext, target: AiResolvedModel,
                requestedModelId: String, actualModelId: String?, upstreamRequestId: String?,
                httpStatus: Int?, finishReason: String?, startedAt: Date, endedAt: Date, latencyMs: Int,
                state: InferenceState, usage: UsageTokens?, cost: CostEstimate?, error: ContractError?,
                discarded: Bool) {
        self.reservationId = reservationId
        self.context = context
        self.target = target
        self.requestedModelId = requestedModelId
        self.actualModelId = actualModelId
        self.upstreamRequestId = upstreamRequestId
        self.httpStatus = httpStatus
        self.finishReason = finishReason
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.latencyMs = latencyMs
        self.state = state
        self.usage = usage
        self.cost = cost
        self.error = error
        self.discarded = discarded
    }
}

public struct AiInferenceResult: Sendable {
    /// The complete bounded response text. Still untrusted model output.
    public let outputText: String
    public let finishReason: String?
    public let record: AiCallRecord

    public init(outputText: String, finishReason: String?, record: AiCallRecord) {
        self.outputText = outputText
        self.finishReason = finishReason
        self.record = record
    }
}
