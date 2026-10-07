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
        guard (try? ContractBundle.shared.validateDomain(probe, "RpcError"))?.isEmpty == true else { return nil }
        return candidate
    }

    static func cut(_ s: String) -> String {
        guard s.unicodeScalars.count > maxMessageLength else { return s.isEmpty ? "error" : s }
        return String(String.UnicodeScalarView(s.unicodeScalars.prefix(maxMessageLength - 1))) + "…"
    }
}

/// One entry of contracts/ai-gui/v1/operations.json.
public struct OperationSpec: Equatable, Sendable {
    public let command: String
    public let mutation: Bool
    public let asynchronous: Bool
    public let requiresIdempotencyKey: Bool
    public let paramsRef: String
    public let resultRef: String

    /// The rpc.schema.json $defs prefix for this command: "gui.runs.start" → "gui_runs_start".
    public var defPrefix: String { command.replacingOccurrences(of: ".", with: "_") }
}

/// The contract files bundled with the target: both schemas and the
/// operation catalog, loaded once.
public final class ContractBundle: Sendable {
    public static let schemaVersion = "agentdesktop.ai/1"
    public static let domainSchemaId = "https://schemas.agentdesktop.invalid/ai-gui/v1/domain.schema.json"
    public static let rpcSchemaId = "https://schemas.agentdesktop.invalid/ai-gui/v1/rpc.schema.json"

    public let registry: SchemaRegistry
    public let operations: [OperationSpec]
    private let byCommand: [String: OperationSpec]

    /// The contract shipped in this build.
    public static let shared: ContractBundle = {
        do { return try ContractBundle(loadingFrom: Bundle.module) } catch {
            fatalError("AI/GUI contract files are missing or invalid: \(error)")
        }
    }()

    public convenience init(loadingFrom bundle: Bundle) throws {
        func read(_ name: String) throws -> Data {
            guard let url = bundle.url(forResource: name, withExtension: "json") else {
                throw SchemaError.unknownDocument(name)
            }
            return try Data(contentsOf: url)
        }
        try self.init(domain: read("domain.schema"), rpc: read("rpc.schema"), operations: read("operations"))
    }

    public init(domain: Data, rpc: Data, operations: Data) throws {
        let registry = SchemaRegistry()
        _ = try registry.add(jsonData: domain)
        _ = try registry.add(jsonData: rpc)
        self.registry = registry

        let catalog = try StrictJSON.parse(operations)
        guard catalog["schemaVersion"]?.stringValue == Self.schemaVersion,
              let list = catalog["operations"]?.arrayValue else {
            throw SchemaError.invalidSchema("operations.json is not for \(Self.schemaVersion)")
        }
        var specs: [OperationSpec] = []
        for item in list {
            guard let command = item["command"]?.stringValue,
                  let mutation = item["mutation"]?.boolValue,
                  let asynchronous = item["asynchronous"]?.boolValue,
                  let idem = item["requiresIdempotencyKey"]?.boolValue,
                  let paramsRef = item["paramsRef"]?.stringValue,
                  let resultRef = item["resultRef"]?.stringValue else {
                throw SchemaError.invalidSchema("operations.json entry is incomplete: \(item.encoded())")
            }
            specs.append(OperationSpec(command: command, mutation: mutation, asynchronous: asynchronous,
                                       requiresIdempotencyKey: idem, paramsRef: paramsRef, resultRef: resultRef))
        }
        self.operations = specs
        self.byCommand = Dictionary(uniqueKeysWithValues: specs.map { ($0.command, $0) })
    }

    public func operation(_ command: String) -> OperationSpec? { byCommand[command] }

    /// Validate against a domain type, e.g. `validateDomain(x, "AiConnection")`.
    public func validateDomain(_ instance: JSONValue, _ def: String) throws -> [SchemaViolation] {
        try registry.validate(instance, documentId: Self.domainSchemaId, pointer: "/$defs/\(def)")
    }

    /// Validate against an rpc.schema.json definition, e.g. "gui_runs_start_result".
    public func validateRpc(_ instance: JSONValue, _ def: String) throws -> [SchemaViolation] {
        try registry.validate(instance, documentId: Self.rpcSchemaId, pointer: "/$defs/\(def)")
    }
}
