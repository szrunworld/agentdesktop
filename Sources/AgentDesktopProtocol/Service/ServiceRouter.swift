import Foundation

/// One call of a method the AI service answers, after the Runtime accepted
/// it on its endpoint (or the main window made it in process). There is no
/// envelope of its own: the caller's identity travels beside it, never in it.
public struct ServiceRequest: Sendable {
    public let method: String
    public let operation: OperationSpec
    public let params: JSONValue
    /// The runtime/1 deadline, when sent.
    public let deadline: String?
    /// The requestId of a write: the service keys its idempotency on it.
    public let idempotencyKey: String?

    public init(method: String, operation: OperationSpec, params: JSONValue, deadline: String? = nil,
                idempotencyKey: String? = nil) {
        self.method = method
        self.operation = operation
        self.params = params
        self.deadline = deadline
        self.idempotencyKey = idempotencyKey
    }
}

/// Handles one method. Throw `ContractError` for an expected failure;
/// anything else becomes INTERNAL_ERROR without detail.
public typealias ServiceHandler = @Sendable (ServiceRequest) async throws -> JSONValue

/// Checks a call against the contract and hands it to its handler. The
/// router owns no executor of its own.
public final class ServiceRouter: Sendable {
    public let contract: ContractBundle
    private let handlers: [String: ServiceHandler]
    private let checkResults: Bool
    private let onInternalFault: (@Sendable (String, String) -> Void)?

    /// - Parameters:
    ///   - handlers: by method. A contract method without a handler answers
    ///     UNSUPPORTED_COMMAND.
    ///   - checkResults: validate every result against `<method>_result`;
    ///     a mismatch answers INTERNAL_ERROR instead of breaking the contract.
    ///   - onInternalFault: (method, reason) for diagnostics; never gets params.
    public init(contract: ContractBundle = .shared,
                handlers: [String: ServiceHandler],
                checkResults: Bool = true,
                onInternalFault: (@Sendable (String, String) -> Void)? = nil) {
        self.contract = contract
        self.handlers = handlers
        self.checkResults = checkResults
        self.onInternalFault = onInternalFault
    }

    /// Answer one call: params checked against `<method>_params`, a write
    /// refused without its idempotency key, the result checked on the way out.
    public func answer(method: String, params: JSONValue, deadline: String? = nil,
                       idempotencyKey: String? = nil) async -> Result<JSONValue, ContractError> {
        guard let op = contract.operation(method) else {
            return .failure(ContractError(.unsupportedCommand, "unknown method"))
        }
        guard let handler = handlers[method] else {
            return .failure(ContractError(.unsupportedCommand, "method is not implemented in this build"))
        }
        if op.requiresIdempotencyKey {
            guard let key = idempotencyKey, (8...128).contains(key.count),
                  key.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "._:-".contains($0)) }) else {
                return .failure(ContractError(.validationError, "a write needs a requestId of 8 to 128 characters [A-Za-z0-9._:-]",
                                              details: .obj([("fieldErrors", .array([.obj([("path", .string("/requestId")),
                                                                                           ("code", .string("pattern"))])]))])))
            }
        }
        do {
            let v = try contract.validate(params, "\(op.defPrefix)_params")
            if !v.isEmpty {
                return .failure(ContractError(.validationError, "params do not match the contract",
                                              details: Self.violationDetails(v)))
            }
        } catch {
            return .failure(ContractError(.internalError, "contract schema unavailable"))
        }
        let request = ServiceRequest(method: method, operation: op, params: params, deadline: deadline,
                                     idempotencyKey: op.requiresIdempotencyKey ? idempotencyKey : nil)
        do {
            let result = try await handler(request)
            if checkResults {
                let v = try contract.validate(result, "\(op.defPrefix)_result")
                if !v.isEmpty {
                    onInternalFault?(method, "result breaks the contract: \(v.prefix(5).map(\.description).joined(separator: "; "))")
                    return .failure(ContractError(.internalError, "internal error"))
                }
            }
            return .success(result)
        } catch let e as ContractError {
            return .failure(e)
        } catch is CancellationError {
            return .failure(ContractError(.cancelled, "cancelled"))
        } catch {
            onInternalFault?(method, String(describing: type(of: error)))
            return .failure(ContractError(.internalError, "internal error"))
        }
    }

    /// Violations as `details.fieldErrors`: pointer and failing keyword
    /// only, never the offending value (it may be a secret). Pointers are
    /// into the request, so a params member reads `/params/<name>` (the same
    /// verdicts as the Windows layer's).
    public static func violationDetails(_ v: [SchemaViolation], under prefix: String = "/params") -> JSONValue {
        .obj([("fieldErrors", .array(v.prefix(20).map {
            .obj([("path", .string(String((prefix + $0.path).prefix(256)))), ("code", .string($0.keyword))])
        }))])
    }
}
