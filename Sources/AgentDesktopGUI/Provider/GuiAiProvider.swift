import AgentDesktopAI
import AgentDesktopContracts
import Foundation

/// One earlier step as the model saw it: its screenshot (when kept) and its
/// complete reply.
public struct GuiHistoryTurn: Sendable {
    public let image: AiImageContent?
    public let reply: String

    public init(image: AiImageContent?, reply: String) {
        self.image = image
        self.reply = reply
    }
}

public struct GuiInferenceInput: Sendable {
    public let binding: GuiRunBinding
    /// The observation to suggest from, with its authorized image bytes.
    public let bundle: ObservationBundle
    public let history: [GuiHistoryTurn]
    public let stepIndex: Int
    /// The run's shared attempt budget (per step and in total).
    public let budget: AttemptBudget
    /// The run's single monotonic deadline.
    public let deadlineNs: UInt64
    public let callerScope: String

    public init(binding: GuiRunBinding, bundle: ObservationBundle, history: [GuiHistoryTurn], stepIndex: Int,
                budget: AttemptBudget, deadlineNs: UInt64, callerScope: String) {
        self.binding = binding; self.bundle = bundle; self.history = history; self.stepIndex = stepIndex
        self.budget = budget; self.deadlineNs = deadlineNs; self.callerScope = callerScope
    }
}

public struct GuiInferenceOutput: Sendable {
    public let proposal: GuiProposal
    public let receipt: GuiInferenceReceipt
    /// The complete reply, kept for the next step's history.
    public let reply: String
    public let thought: String?
    public let imagesSent: Int
    /// History screenshots left out to stay within maxScreenshots and the
    /// image byte budget; the current screenshot is always sent.
    public let historyImagesDropped: Int
}

/// The model answered, but not with a usable suggestion. The receipt of the
/// call is kept so the attempt stays on record.
public struct GuiSuggestionFailure: Error, Sendable {
    public let error: ContractError
    public let receipt: GuiInferenceReceipt

    /// The model answered with nothing at all (or only whitespace).
    public var isEmptyReply: Bool { error.details?["reasonCode"]?.stringValue == Self.emptyReplyReason }

    public static let emptyReplyReason = "MODEL_EMPTY_RESPONSE"

    /// INVALID_ACTION with reasonCode MODEL_EMPTY_RESPONSE: an existing code,
    /// the reason in RpcError.details.
    public static func emptyReplyError() -> ContractError {
        ContractError(.invalidAction, "the model's reply was empty",
                      details: .obj([("reasonCode", .string(emptyReplyReason))]))
    }
}

/// Turns one observation into exactly one proposal (spec §06.2):
/// versioned prompt, current screenshot plus bounded history, the shared
/// AiService, then the strict codec. It holds no screen, input engine,
/// window, capture closure or Runtime port; it can only read what the
/// explorer hands it and only return a suggestion.
public struct GuiAiProvider: Sendable {
    public let service: AiService
    public let codecs: GuiCodecRegistry
    public let clock: MonotonicClock
    public let factory: ProposalFactory
    public let newAttemptId: @Sendable () -> String

    public init(service: AiService, codecs: GuiCodecRegistry = GuiCodecRegistry(),
                clock: MonotonicClock = SystemMonotonicClock(), factory: ProposalFactory = ProposalFactory(),
                newAttemptId: @escaping @Sendable () -> String = { "att-" + UUID().uuidString.lowercased() }) {
        self.service = service
        self.codecs = codecs
        self.clock = clock
        self.factory = factory
        self.newAttemptId = newAttemptId
    }

    public static let historyPolicy = "keep-current-then-newest-history-within-limits-v1"

    public func suggest(_ input: GuiInferenceInput) async throws -> GuiInferenceOutput {
        let binding = input.binding
        let primary = binding.primary
        let codec = try codecs.codec(adapterId: primary.adapterId, coordinateProtocol: primary.coordinateProtocol)
        let observation = input.bundle.observation
        guard let shot = observation.screenshots.first, let current = input.bundle.currentImage else {
            throw ContractError(.staleObservation, "the observation has no authorized screenshot")
        }
        let (request, sent, dropped) = try Self.buildRequest(binding: binding, codec: codec, current: current,
                                                             history: input.history)
        let stamp = observation.stamp
        let purpose = GuiStepCallPurpose(runId: binding.runId, stepIndex: input.stepIndex, snapshotId: stamp.snapshotId,
                                         bindingEpoch: stamp.bindingEpoch, currentGeneration: stamp.runGeneration)
        let scope = input.callerScope
        let deadline = input.deadlineNs
        let newId = newAttemptId
        let step = StepInference(service: service, budget: input.budget, clock: clock)
        let result = try await step.run(request, step: input.stepIndex,
                                        candidates: binding.candidates.map(\.resolvedModel), deadlineNs: deadline) { _, _ in
            AiCallContext(inferenceAttemptId: newId(), purpose: .guiStep(purpose), callerScopeRef: scope,
                          budgetScopeRef: binding.runId, deadlineMonotonicNanoseconds: deadline)
        }
        let candidate = binding.candidates.first { $0.resolvedModel == result.record.target } ?? primary
        func receipt(_ proposalId: String?) -> GuiInferenceReceipt {
            GuiInferenceReceipt(record: result.record, snapshotId: stamp.snapshotId, runId: binding.runId,
                                stepIndex: input.stepIndex, candidate: candidate, proposalId: proposalId)
        }
        do {
            guard !result.outputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw GuiSuggestionFailure.emptyReplyError()
            }
            let (proposal, thought) = try factory.propose(
                codec: codec, modelOutput: result.outputText, runId: binding.runId, stepIndex: input.stepIndex,
                inferenceAttemptId: result.record.context.inferenceAttemptId, observation: observation,
                screenshotId: shot.screenshotId, maxWaitMs: binding.limits.maxWaitMs)
            return GuiInferenceOutput(proposal: proposal, receipt: receipt(proposal.proposalId), reply: result.outputText,
                                      thought: thought, imagesSent: sent, historyImagesDropped: dropped)
        } catch let e as ContractError {
            throw GuiSuggestionFailure(error: e, receipt: receipt(nil))
        }
    }

    /// The versioned request: system prompt with the action space and goal,
    /// kept history (oldest first), then the current screenshot. History
    /// images are dropped newest-last until both the image count and the
    /// base64 byte budget fit; the current image is never dropped (if it
    /// alone is too large, AiService refuses with LIMIT_EXCEEDED).
    static func buildRequest(binding: GuiRunBinding, codec: GuiActionCodec, current: AiImageContent,
                             history: [GuiHistoryTurn]) throws -> (AiInferenceRequest, sent: Int, dropped: Int) {
        let limits = binding.limits
        var budget = limits.maxImageEncodedBytes - current.encodedByteCount
        var slots = limits.maxScreenshots - 1
        var keep = Set<Int>()
        for (i, turn) in history.enumerated().reversed() {
            guard let img = turn.image else { continue }
            if slots > 0, img.encodedByteCount <= budget {
                keep.insert(i)
                slots -= 1
                budget -= img.encodedByteCount
            }
        }
        let withImages = history.filter { $0.image != nil }.count
        var messages = [AiMessage.text(.system, systemPrompt(codec: codec, goal: binding.goal))]
        for (i, turn) in history.enumerated() {
            if let img = turn.image, keep.contains(i) {
                messages.append(AiMessage(role: .user, content: [.image(img)]))
            } else {
                messages.append(.text(.user, "(earlier screenshot omitted)"))
            }
            messages.append(.text(.assistant, turn.reply))
        }
        messages.append(AiMessage(role: .user, content: [.text("Task: \(binding.goal)"), .image(current)]))
        let model = binding.primary.resolvedModel.model
        let request = AiInferenceRequest(messages: messages, options: model.requestOptions,
                                         maxOutputTokens: min(limits.maxOutputTokens, model.maxOutputTokens),
                                         maxImages: limits.maxScreenshots, maxImageEncodedBytes: limits.maxImageEncodedBytes)
        return (request, keep.count + 1, withImages - keep.count)
    }

    static func systemPrompt(codec: GuiActionCodec, goal: String) -> String {
        let p = codec.provenance
        let header = "prompt \(p.promptVersion), adapter \(p.adapterId.rawValue) \(p.adapterVersion)"
        switch p.adapterId {
        case .uitarsV1:
            return """
            You operate one application window on a computer desktop through its screenshot. (\(header))
            \(UITarsCodec.actionSpace(for: p.coordinateProtocol))

            ## Task
            \(goal)
            """
        case .fixtureJsonV1:
            return "Test adapter (\(header)). Reply with exactly one JSON suggestion for the task: \(goal)"
        }
    }
}
