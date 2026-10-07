import Foundation

/// A versioned request that passed framing, strict parsing and the
/// rpc.schema.json `<command>_request` definition.
public struct RpcRequest: Sendable {
    public let requestId: String
    public let command: String
    public let operation: OperationSpec
    public let params: JSONValue
    /// `context.deadlineAt`, when sent.
    public let deadlineAt: String?
    /// `context.idempotencyKey`, when sent (required for mutations).
    public let idempotencyKey: String?
    /// The whole request as received, for semantic digests. Never log it:
    /// credential writes carry a secret here.
    public let raw: JSONValue
}

/// What one frame turned into.
public enum DecodedFrame: Sendable {
    /// A request of contract v1, ready for its handler.
    case request(RpcRequest)
    /// A JSON object without `schemaVersion`: the pre-v1 ControlRequest
    /// protocol. The caller hands it to the legacy decoder, which must end
    /// in the same Runtime.
    case legacy(JSONValue)
    /// The frame was refused; `response` is the complete error envelope.
    case rejected(response: JSONValue, error: ContractError)
}

public enum Envelope {
    /// Frame limit including the terminating LF (contract §05.1).
    public static let maxFrameBytes = 1_048_576

    public static func success(requestId: String, result: JSONValue) -> JSONValue {
        .obj([
            ("schemaVersion", .string(ContractBundle.schemaVersion)),
            ("requestId", .string(requestId)),
            ("ok", .bool(true)),
            ("result", result),
        ])
    }

    /// `requestId` may be nil only for VALIDATION_ERROR, UNSUPPORTED_SCHEMA
    /// and IPC_FRAME_TOO_LARGE on frames that could not be correlated.
    public static func failure(requestId: String?, error: ContractError) -> JSONValue {
        precondition(requestId != nil || [.validationError, .unsupportedSchema, .ipcFrameTooLarge].contains(error.code),
                     "only an uncorrelatable framing error may answer with requestId null")
        return .obj([
            ("schemaVersion", .string(ContractBundle.schemaVersion)),
            ("requestId", requestId.map(JSONValue.string) ?? .null),
            ("ok", .bool(false)),
            ("error", error.json),
        ])
    }

    /// One response line: compact JSON plus LF.
    public static func line(_ response: JSONValue) -> Data {
        var d = response.encodedData()
        d.append(0x0A)
        return d
    }

    /// Decode one frame body (the bytes before its LF).
    public static func decode(_ body: Data, contract: ContractBundle = .shared) -> DecodedFrame {
        func reject(_ id: String?, _ e: ContractError) -> DecodedFrame {
            .rejected(response: failure(requestId: id, error: e), error: e)
        }
        guard body.count < maxFrameBytes else {
            return reject(nil, ContractError(.ipcFrameTooLarge, "request frame exceeds \(maxFrameBytes) bytes"))
        }
        let value: JSONValue
        do {
            value = try StrictJSON.parse(body)
        } catch let e as StrictJSONError {
            return reject(nil, ContractError(.validationError, "request is not valid JSON",
                                             details: .obj([("reason", .string(e.kind.rawValue))])))
        } catch {
            return reject(nil, ContractError(.validationError, "request is not valid JSON"))
        }
        guard case .object = value else {
            return reject(nil, ContractError(.validationError, "request must be one JSON object"))
        }
        guard let version = value["schemaVersion"] else { return .legacy(value) }

        // Correlate as early as possible; a malformed id cannot be echoed.
        let rawId = value["requestId"]?.stringValue
        let requestId = rawId.flatMap { Formats.check("uuid", $0) ? $0 : nil }

        guard version.stringValue == ContractBundle.schemaVersion else {
            return reject(requestId, ContractError(.unsupportedSchema, "unsupported schemaVersion",
                                                   details: .obj([("supported", .array([.string(ContractBundle.schemaVersion)]))])))
        }
        guard let requestId else {
            return reject(nil, ContractError(.validationError, "requestId must be a UUID string"))
        }
        guard let command = value["command"]?.stringValue else {
            return reject(requestId, ContractError(.validationError, "command is required"))
        }
        guard let op = contract.operation(command) else {
            return reject(requestId, ContractError(.unsupportedCommand, "unknown command"))
        }
        let violations: [SchemaViolation]
        do {
            violations = try contract.validateRpc(value, "\(op.defPrefix)_request")
        } catch {
            return reject(requestId, ContractError(.internalError, "contract schema unavailable"))
        }
        if !violations.isEmpty {
            return reject(requestId, ContractError(.validationError, "request does not match the contract",
                                                   details: violationDetails(violations)))
        }
        let context = value["context"]
        return .request(RpcRequest(
            requestId: requestId, command: command, operation: op,
            params: value["params"] ?? .obj([]),
            deadlineAt: context?["deadlineAt"]?.stringValue,
            idempotencyKey: context?["idempotencyKey"]?.stringValue,
            raw: value))
    }

    /// Violations as error details: pointer and keyword only, never the
    /// offending value (it may be a secret).
    public static func violationDetails(_ v: [SchemaViolation]) -> JSONValue {
        .obj([("violations", .array(v.prefix(20).map {
            .obj([("path", .string($0.path.isEmpty ? "/" : $0.path)), ("keyword", .string($0.keyword))])
        }))])
    }
}

/// Reads one LF-terminated frame from a socket or pipe, refusing to buffer
/// more than `Envelope.maxFrameBytes` (LF included).
public enum FrameReader {
    public enum Result: Equatable, Sendable {
        case frame(Data)          // body without the LF
        case tooLarge
        case truncated(Data)      // EOF before LF
        case trailingData(Data)   // bytes after the LF in the same read
        case ioError(Int32)
    }

    public static func read(fd: Int32, limit: Int = Envelope.maxFrameBytes) -> Result {
        var body = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let want = min(chunk.count, limit - body.count)
            if want <= 0 { return .tooLarge }
            let n = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n < 0 {
                if errno == EINTR { continue }
                return .ioError(errno)
            }
            if n == 0 { return .truncated(body) }
            if let lf = chunk[0..<n].firstIndex(of: 0x0A) {
                body.append(contentsOf: chunk[0..<lf])
                if lf + 1 < n { return .trailingData(body) }
                return .frame(body)
            }
            body.append(contentsOf: chunk[0..<n])
        }
    }

    /// Frame a byte buffer the same way (for tests and in-memory transports).
    public static func split(_ data: Data, limit: Int = Envelope.maxFrameBytes) -> Result {
        guard let lf = data.firstIndex(of: 0x0A) else {
            return data.count >= limit ? .tooLarge : .truncated(data)
        }
        let body = data[data.startIndex..<lf]
        if body.count + 1 > limit { return .tooLarge }
        if data.index(after: lf) < data.endIndex { return .trailingData(Data(body)) }
        return .frame(Data(body))
    }
}

/// Handles one command of the contract. Throw `ContractError` for an
/// expected failure; anything else becomes INTERNAL_ERROR without detail.
public typealias RpcHandler = @Sendable (RpcRequest) async throws -> JSONValue

/// Routes v1 requests to handlers and pre-v1 requests to the legacy
/// decoder. Both paths must end in the same Runtime; the router owns no
/// executor of its own.
public final class RpcRouter: Sendable {
    public let contract: ContractBundle
    private let handlers: [String: RpcHandler]
    private let legacy: (@Sendable (JSONValue) async -> Data)?
    private let checkResults: Bool
    private let onInternalFault: (@Sendable (String, String) -> Void)?

    /// - Parameters:
    ///   - handlers: by command. A contract command without a handler answers
    ///     UNSUPPORTED_COMMAND; `runtime.capabilities` should say so too.
    ///   - legacy: answers a pre-v1 request (its full response line, LF
    ///     included). Nil refuses legacy frames.
    ///   - checkResults: validate every result against `<command>_result`;
    ///     a mismatch answers INTERNAL_ERROR instead of breaking the contract.
    ///   - onInternalFault: (command, reason) for diagnostics; never gets params.
    public init(contract: ContractBundle = .shared,
                handlers: [String: RpcHandler],
                legacy: (@Sendable (JSONValue) async -> Data)? = nil,
                checkResults: Bool = true,
                onInternalFault: (@Sendable (String, String) -> Void)? = nil) {
        self.contract = contract
        self.handlers = handlers
        self.legacy = legacy
        self.checkResults = checkResults
        self.onInternalFault = onInternalFault
    }

    /// Answer one frame read by `FrameReader`.
    public func respond(to read: FrameReader.Result) async -> Data {
        switch read {
        case let .frame(body):
            return await respond(toBody: body)
        case .tooLarge:
            return Envelope.line(Envelope.failure(requestId: nil,
                error: ContractError(.ipcFrameTooLarge, "request frame exceeds \(Envelope.maxFrameBytes) bytes")))
        case .truncated, .trailingData, .ioError:
            return Envelope.line(Envelope.failure(requestId: nil,
                error: ContractError(.validationError, "a connection carries exactly one LF-terminated request")))
        }
    }

    public func respond(toBody body: Data) async -> Data {
        switch Envelope.decode(body, contract: contract) {
        case let .rejected(response, _):
            return Envelope.line(response)
        case let .legacy(value):
            guard let legacy else {
                return Envelope.line(Envelope.failure(requestId: nil,
                    error: ContractError(.unsupportedSchema, "schemaVersion is required")))
            }
            return await legacy(value)
        case let .request(req):
            return Envelope.line(await answer(req))
        }
    }

    public func answer(_ req: RpcRequest) async -> JSONValue {
        guard let handler = handlers[req.command] else {
            return Envelope.failure(requestId: req.requestId,
                                    error: ContractError(.unsupportedCommand, "command is not implemented in this build"))
        }
        do {
            let result = try await handler(req)
            if checkResults {
                let v = try contract.validateRpc(result, "\(req.operation.defPrefix)_result")
                if !v.isEmpty {
                    onInternalFault?(req.command, "result breaks the contract: \(v.prefix(5).map(\.description).joined(separator: "; "))")
                    return Envelope.failure(requestId: req.requestId,
                                            error: ContractError(.internalError, "internal error"))
                }
            }
            return Envelope.success(requestId: req.requestId, result: result)
        } catch let e as ContractError {
            return Envelope.failure(requestId: req.requestId, error: e)
        } catch is CancellationError {
            return Envelope.failure(requestId: req.requestId, error: ContractError(.cancelled, "cancelled"))
        } catch {
            onInternalFault?(req.command, String(describing: type(of: error)))
            return Envelope.failure(requestId: req.requestId, error: ContractError(.internalError, "internal error"))
        }
    }
}
