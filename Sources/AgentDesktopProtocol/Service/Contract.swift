import Foundation

/// Error codes of contract v1 (domain.schema.json#/$defs/ErrorCode).
/// `ContractBundleTests` checks this list against the schema file.
public enum ErrorCode: String, CaseIterable, Sendable {
    case validationError = "VALIDATION_ERROR"
    case unsupportedSchema = "UNSUPPORTED_SCHEMA"
    case unsupportedCommand = "UNSUPPORTED_COMMAND"
    case ipcFrameTooLarge = "IPC_FRAME_TOO_LARGE"
    case unauthorized = "UNAUTHORIZED"
    case forbidden = "FORBIDDEN"
    case notFound = "NOT_FOUND"
    case configConflict = "CONFIG_CONFLICT"
    case idempotencyConflict = "IDEMPOTENCY_CONFLICT"
    case resourceInUse = "RESOURCE_IN_USE"
    case resourceDisabled = "RESOURCE_DISABLED"
    case unsupportedProtocol = "UNSUPPORTED_PROTOCOL"
    case capabilityMismatch = "CAPABILITY_MISMATCH"
    case credentialRequired = "CREDENTIAL_REQUIRED"
    case credentialRevoked = "CREDENTIAL_REVOKED"
    case authFailed = "AUTH_FAILED"
    case rateLimited = "RATE_LIMITED"
    case upstreamUnavailable = "UPSTREAM_UNAVAILABLE"
    case upstreamProtocolError = "UPSTREAM_PROTOCOL_ERROR"
    case modelNotFound = "MODEL_NOT_FOUND"
    case deadlineExceeded = "DEADLINE_EXCEEDED"
    case cancelled = "CANCELLED"
    case operationNotCancellable = "OPERATION_NOT_CANCELLABLE"
    case desktopBusy = "DESKTOP_BUSY"
    case staleObservation = "STALE_OBSERVATION"
    case staleGeneration = "STALE_GENERATION"
    case invalidAction = "INVALID_ACTION"
    case coordinateOutOfBounds = "COORDINATE_OUT_OF_BOUNDS"
    case actionOutcomeUnknown = "ACTION_OUTCOME_UNKNOWN"
    case verificationFailed = "VERIFICATION_FAILED"
    case limitExceeded = "LIMIT_EXCEEDED"
    case usageUnavailable = "USAGE_UNAVAILABLE"
    case eventsCursorExpired = "EVENTS_CURSOR_EXPIRED"
    case auditUnavailable = "AUDIT_UNAVAILABLE"
    case internalError = "INTERNAL_ERROR"

    /// Whether a failure of this kind may have a recovery path. This is not
    /// permission to replay a GUI run; see the contract §05.5.
    public var defaultRetryable: Bool {
        switch self {
        case .rateLimited, .upstreamUnavailable, .desktopBusy, .staleObservation, .auditUnavailable:
            return true
        default:
            return false
        }
    }
}

/// A failure that leaves the service as a contract error. `message` and
/// `details` must never carry secrets or upstream bodies.
public struct ContractError: Error, Equatable, Sendable, CustomStringConvertible {
    public let code: ErrorCode
    public let message: String
    public let retryable: Bool
    public let details: JSONValue?

    public init(_ code: ErrorCode, _ message: String, retryable: Bool? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.retryable = retryable ?? code.defaultRetryable
        self.details = details
    }

    public var description: String { "\(code.rawValue): \(message)" }

    /// Members `RpcError.details` may carry on the wire (domain.schema.json).
    public static let wireDetailKeys: Set<String> = [
        "retryAfterMs", "currentRevision", "resourceId", "operationId", "runId", "reasonCode", "fieldErrors",
    ]
    public static let maxMessageLength = 512

    /// The error as `RpcError`. Internal-only detail members (an HTTP status,
    /// a byte count) are dropped, a `field` becomes a `fieldErrors` entry,
    /// the message is cut to the contract's length, and details that still
    /// break the contract are left out rather than sent.
    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("code", .string(code.rawValue)),
            ("message", .string(Self.cut(message))),
            ("retryable", .bool(retryable)),
        ]
        if let d = wireDetails { m.append(("details", d)) }
        return .obj(m)
    }

    var wireDetails: JSONValue? {
        guard let members = details?.objectMembers else { return nil }
        var out: [(String, JSONValue)] = members.filter { Self.wireDetailKeys.contains($0.key) }.map { ($0.key, $0.value) }
        if let field = details?["field"]?.stringValue, !out.contains(where: { $0.0 == "fieldErrors" }) {
            out.append(("fieldErrors", .array([.obj([("path", .string("/params/\(field)")), ("code", .string("invalid"))])])))
        }
        guard !out.isEmpty else { return nil }
        let candidate = JSONValue.obj(out)
        let probe = JSONValue.obj([("code", .string(code.rawValue)), ("message", .string("x")),
                                   ("retryable", .bool(retryable)), ("details", candidate)])
        guard (try? ContractBundle.shared.validate(probe, "RpcError"))?.isEmpty == true else { return nil }
        return candidate
    }

    static func cut(_ s: String) -> String {
        guard s.unicodeScalars.count > maxMessageLength else { return s.isEmpty ? "error" : s }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(maxMessageLength - 1))) + "…"
    }
}

/// One method the AI service answers, as methods.json lists it.
public struct OperationSpec: Equatable, Sendable {
    public let command: String
    public let mutation: Bool
    public let asynchronous: Bool
    public let requiresIdempotencyKey: Bool

    /// The service.schema.json $defs prefix: "ai.profiles.get" → "ai_profiles_get".
    public var defPrefix: String { command.replacingOccurrences(of: ".", with: "_") }
}

/// The service side of the runtime/1 contract: the methods marked
/// `servedBy` in methods.json and their definitions in service.schema.json,
/// embedded in the build like the rest of the contract (no resource bundle
/// to lose when the app is packaged).
public final class ContractBundle: Sendable {
    public let registry: SchemaRegistry
    public let operations: [OperationSpec]
    private let byCommand: [String: OperationSpec]

    /// The contract shipped in this build.
    public static let shared = ContractBundle(RuntimeContract.shared)

    public init(_ contract: RuntimeContract) {
        registry = contract.registry
        operations = contract.methods.filter { $0.servedBy != nil }.map {
            OperationSpec(command: $0.method, mutation: $0.mutation, asynchronous: $0.asynchronous,
                          requiresIdempotencyKey: $0.requiresIdempotencyKey)
        }
        byCommand = Dictionary(uniqueKeysWithValues: operations.map { ($0.command, $0) })
    }

    public func operation(_ command: String) -> OperationSpec? { byCommand[command] }

    /// Validate against a service.schema.json definition, e.g. "AiConnection"
    /// or "ai_profiles_get_result".
    public func validate(_ instance: JSONValue, _ def: String) throws -> [SchemaViolation] {
        try registry.validate(instance, documentId: RuntimeContract.serviceSchemaId, pointer: "/$defs/\(def)")
    }
}
