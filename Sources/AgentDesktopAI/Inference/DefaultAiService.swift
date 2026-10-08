import Foundation
import AgentDesktopProtocol

/// Prices for estimating cost from reported tokens. An estimate, never a bill.
public struct AiPriceTable: Sendable {
    public struct Price: Sendable {
        public let inputPerMillion: Decimal
        public let outputPerMillion: Decimal
        public init(inputPerMillion: Decimal, outputPerMillion: Decimal) {
            self.inputPerMillion = inputPerMillion
            self.outputPerMillion = outputPerMillion
        }
    }

    public let pricingRevision: ResourceID
    public let currency: String
    /// By model id, exact.
    public let prices: [String: Price]

    public init(pricingRevision: ResourceID, currency: String, prices: [String: Price]) {
        self.pricingRevision = pricingRevision
        self.currency = currency
        self.prices = prices
    }

    /// nil when a token count is unknown or the model has no price.
    public func estimate(modelId: String, usage: UsageTokens?) -> CostEstimate? {
        guard let p = prices[modelId], let i = usage?.inputTokens, let o = usage?.outputTokens else { return nil }
        let amount = (Decimal(i) * p.inputPerMillion + Decimal(o) * p.outputPerMillion) / Decimal(1_000_000)
        return CostEstimate(amount: DecimalText.format(amount), currency: currency, source: .estimated,
                            pricingRevision: pricingRevision)
    }
}

enum DecimalText {
    /// Plain decimal text with at most 12 fraction digits, as the contract's
    /// CostEstimate.amount pattern requires.
    static func format(_ value: Decimal) -> String {
        var v = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &v, 12, .plain)
        if rounded < 0 { rounded = 0 }
        var s = NSDecimalNumber(decimal: rounded).stringValue
        if s.contains("e") || s.contains("E") { s = String(format: "%.12f", NSDecimalNumber(decimal: rounded).doubleValue) }
        if s.contains(".") {
            while s.hasSuffix("0") { s.removeLast() }
            if s.hasSuffix(".") { s.removeLast() }
        }
        return s.isEmpty ? "0" : s
    }
}

/// The shared model service (spec §06.1). Each call follows the fixed order:
///
/// 1. check the context, deadline, limits and admission (run generation,
///    candidate authorization);
/// 2. resolve the credential identity to its key;
/// 3. reserve the attempt in the ledger before any HTTP;
/// 4. build only what openai_chat supports and send it (no redirects);
/// 5. read the bounded response completely;
/// 6. record the attempt's end: success, failure, cancellation, unknown usage;
/// 7. check admission again; a result that is no longer current is recorded
///    as discarded and never returned for use.
public final class DefaultAiService: AiService, Sendable {
    private let transport: OpenAIChatTransport
    private let credentials: CredentialResolver
    private let ledger: AiCallLedgerPort
    private let admission: AiCallAdmission
    private let clock: MonotonicClock
    private let prices: AiPriceTable?

    public init(http: HTTPTransport = URLSessionHTTPTransport(),
                credentials: CredentialResolver,
                ledger: AiCallLedgerPort,
                admission: AiCallAdmission = AdmitAll(),
                clock: MonotonicClock = SystemMonotonicClock(),
                prices: AiPriceTable? = nil) {
        self.transport = OpenAIChatTransport(http: http)
        self.credentials = credentials
        self.ledger = ledger
        self.admission = admission
        self.clock = clock
        self.prices = prices
    }

    public func infer(_ request: AiInferenceRequest, resolvedModel: AiResolvedModel,
                      context: AiCallContext) async throws -> AiInferenceResult {
        // 1. Checks that need no network and no ledger row.
        try Self.check(request, model: resolvedModel)
        guard clock.nowNanoseconds() < context.deadlineMonotonicNanoseconds else {
            throw ContractError(.deadlineExceeded, "the deadline passed before the model call")
        }
        try Task.checkCancellation()
        try await admission.admit(context, target: resolvedModel)

        // 2. The key, resolved per call; a revoked identity stops here.
        let apiKey = try await credentials.resolveKey(credentialIdentity: resolvedModel.connection.credentialIdentityRef)

        // Build before reserving so a malformed endpoint costs no attempt.
        let remainingNs = context.deadlineMonotonicNanoseconds &- clock.nowNanoseconds()
        let timeout = min(Double(resolvedModel.connection.timeoutMs) / 1000, Double(remainingNs) / 1e9)
        _ = try transport.makeRequest(request, model: resolvedModel, apiKey: apiKey, timeout: timeout)

        // 3. Reserve before HTTP. No row, no call.
        let reservationId: ResourceID
        do {
            reservationId = try await ledger.reserve(context: context, target: resolvedModel)
        } catch let e as ContractError where e.code == .auditUnavailable {
            throw e
        } catch {
            throw ContractError(.auditUnavailable, "the call ledger cannot record a new attempt")
        }

        let startedWall = clock.wallNow()
        let startedNs = clock.nowNanoseconds()

        // 4–5. Send and read, raced against the one shared deadline.
        enum Outcome { case completion(ChatCompletion), deadline }
        var completion: ChatCompletion?
        var failure: ContractError?
        var cancelled = false
        do {
            let outcome: Outcome = try await withThrowingTaskGroup(of: Outcome.self) { group in
                group.addTask { [transport] in
                    .completion(try await transport.complete(request, model: resolvedModel, apiKey: apiKey, timeout: timeout))
                }
                group.addTask { [clock] in
                    try await clock.sleep(untilNanoseconds: context.deadlineMonotonicNanoseconds)
                    return .deadline
                }
                let first = try await group.next()!
                group.cancelAll()
                return first
            }
            switch outcome {
            case let .completion(c): completion = c
            case .deadline: failure = ContractError(.deadlineExceeded, "the model call ran past the deadline")
            }
        } catch let e as ContractError {
            failure = e
        } catch {
            if Task.isCancelled || error is CancellationError {
                cancelled = true
            } else {
                failure = ContractError(.upstreamUnavailable, "the model call failed")
            }
        }
        // A response that arrived after cancellation is never used.
        if Task.isCancelled, completion != nil { cancelled = true }

        // 6. Record the end, whatever it was.
        var discarded = cancelled && completion != nil
        if completion != nil, !cancelled, !(await admission.isStillCurrent(context, target: resolvedModel)) {
            discarded = true
        }
        let endedNs = clock.nowNanoseconds()
        let state: InferenceState = cancelled ? .cancelled : (completion != nil ? .succeeded : .failed)
        let record = AiCallRecord(
            reservationId: reservationId, context: context, target: resolvedModel,
            requestedModelId: resolvedModel.model.modelId,
            actualModelId: completion?.actualModelId,
            upstreamRequestId: completion?.upstreamRequestId,
            httpStatus: completion?.httpStatus ?? failure?.details?["httpStatus"]?.intValue,
            finishReason: completion?.finishReason,
            startedAt: startedWall, endedAt: clock.wallNow(),
            latencyMs: Int((endedNs &- startedNs) / 1_000_000),
            state: state, usage: completion?.usage,
            cost: prices?.estimate(modelId: completion?.actualModelId ?? resolvedModel.model.modelId, usage: completion?.usage),
            error: cancelled ? ContractError(.cancelled, "cancelled") : failure,
            discarded: discarded)
        do {
            try await ledger.finish(record)
        } catch {
            // The call happened but cannot be traced: stop, do not proceed.
            throw ContractError(.auditUnavailable, "the model call could not be recorded")
        }

        // 7. Only a current, successful result leaves the service.
        if cancelled { throw CancellationError() }
        if let failure { throw failure }
        if discarded { throw ContractError(.staleGeneration, "the call's run moved on; its result is discarded") }
        guard let completion else { throw ContractError(.internalError, "internal error") }
        return AiInferenceResult(outputText: completion.text, finishReason: completion.finishReason, record: record)
    }

    /// Limits and protocol checks (no network, no ledger).
    static func check(_ request: AiInferenceRequest, model: AiResolvedModel) throws {
        guard model.connection.apiProtocol.isImplemented else {
            throw ContractError(.unsupportedProtocol, "\(model.connection.apiProtocol.rawValue) is not implemented")
        }
        guard model.connection.state == .enabled else {
            throw ContractError(.resourceDisabled, "the connection is disabled")
        }
        guard !request.messages.isEmpty else {
            throw ContractError(.validationError, "a model call needs at least one message")
        }
        guard (1...AiInferenceRequest.hardMaxOutputTokens).contains(request.maxOutputTokens) else {
            throw ContractError(.limitExceeded, "maxOutputTokens must be 1 to \(AiInferenceRequest.hardMaxOutputTokens)")
        }
        guard (1...AiInferenceRequest.hardMaxOutputTokens).contains(model.model.maxOutputTokens) else {
            throw ContractError(.limitExceeded, "the model profile's maxOutputTokens is out of range")
        }
        let images = request.images
        let maxImages = min(request.maxImages, AiInferenceRequest.hardMaxImages)
        guard images.count <= maxImages else {
            throw ContractError(.limitExceeded, "a model call carries at most \(maxImages) images")
        }
        let budget = min(request.maxImageEncodedBytes, AiInferenceRequest.hardMaxImageEncodedBytes)
        let encoded = images.reduce(0) { $0 + $1.encodedByteCount }
        guard encoded <= budget else {
            throw ContractError(.limitExceeded, "images exceed the \(budget)-byte base64 budget",
                                details: .obj([("encodedBytes", .int(encoded)), ("limit", .int(budget))]))
        }
        for img in images where !["image/png", "image/jpeg", "image/webp"].contains(img.mimeType) {
            throw ContractError(.validationError, "unsupported image type \(img.mimeType)")
        }
    }
}
