import AgentDesktopProtocol
import Foundation

// JSON-RPC 2.0 as ACP uses it: single messages (no batches), ids that are
// integers or strings, params an object when present.

/// JSON-RPC and ACP error codes (schema/v1 `ErrorCode`).
public enum ACPJsonRpcErrorCode {
    public static let parseError = -32700
    public static let invalidRequest = -32600
    public static let methodNotFound = -32601
    public static let invalidParams = -32602
    public static let internalError = -32603
    public static let requestCancelled = -32800
    public static let authRequired = -32000
    public static let resourceNotFound = -32002
}

public struct ACPJsonRpcError: Error, Equatable, Sendable {
    public var code: Int
    public var message: String
    public var data: JSONValue?
    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code; self.message = message; self.data = data
    }

    var json: JSONValue {
        var m: [(String, JSONValue)] = [("code", .int(code)), ("message", .string(message))]
        if let data { m.append(("data", data)) }
        return .obj(m)
    }
}

public enum ACPJsonRpcMessage: Equatable, Sendable {
    case request(id: JSONValue, method: String, params: JSONValue?)
    case notification(method: String, params: JSONValue?)
    case response(id: JSONValue, result: JSONValue)
    case errorResponse(id: JSONValue, error: ACPJsonRpcError)
}

/// Why a frame was refused, and the id to answer when one could be read.
public struct ACPJsonRpcDecodeFailure: Error, Equatable, Sendable {
    /// The request id to answer with, or `.null` when unknown. nil means
    /// the frame must not be answered (a malformed response or notification).
    public var replyId: JSONValue?
    public var error: ACPJsonRpcError
}

public enum ACPJsonRpcCodec {
    /// Nesting limit for incoming frames (same default as the contract parser).
    public static let maxDepth = StrictJSON.defaultMaxDepth

    public static func decode(_ frame: Data) -> Result<ACPJsonRpcMessage, ACPJsonRpcDecodeFailure> {
        let value: JSONValue
        do {
            value = try StrictJSON.parse(frame, maxDepth: maxDepth)
        } catch let e as StrictJSONError {
            return .failure(.init(replyId: .null, error: .init(
                code: ACPJsonRpcErrorCode.parseError, message: "parse error: \(e.kind.rawValue) at byte \(e.offset)")))
        } catch {
            return .failure(.init(replyId: .null, error: .init(
                code: ACPJsonRpcErrorCode.parseError, message: "parse error")))
        }
        return decode(value)
    }

    public static func decode(_ value: JSONValue) -> Result<ACPJsonRpcMessage, ACPJsonRpcDecodeFailure> {
        func invalid(_ msg: String, id: JSONValue? = .null) -> Result<ACPJsonRpcMessage, ACPJsonRpcDecodeFailure> {
            .failure(.init(replyId: id, error: .init(code: ACPJsonRpcErrorCode.invalidRequest, message: msg)))
        }
        if value.arrayValue != nil { return invalid("batches are not supported") }
        guard value.objectMembers != nil else { return invalid("a message must be a JSON object") }
        let rawId = value["id"]
        let validId: JSONValue? = rawId.flatMap { isValidId($0) ? $0 : nil }
        guard value["jsonrpc"]?.stringValue == "2.0" else {
            return invalid("jsonrpc must be \"2.0\"", id: validId ?? .null)
        }
        let params = value["params"]
        if let params, params.objectMembers == nil, params.arrayValue == nil, !params.isNull {
            return .failure(.init(replyId: validId ?? .null, error: .init(
                code: ACPJsonRpcErrorCode.invalidRequest, message: "params must be an object")))
        }
        if let method = value["method"] {
            guard let name = method.stringValue, !name.isEmpty else {
                return invalid("method must be a non-empty string", id: validId ?? .null)
            }
            guard let rawId else { return .success(.notification(method: name, params: params)) }
            guard let id = validId, !rawId.isNull else {
                return invalid("request id must be an integer or a string", id: .null)
            }
            return .success(.request(id: id, method: name, params: params))
        }
        // A response to one of our requests.
        guard let rawId, let id = validId, !rawId.isNull else {
            return .failure(.init(replyId: nil, error: .init(
                code: ACPJsonRpcErrorCode.invalidRequest, message: "response without a valid id")))
        }
        let result = value["result"], error = value["error"]
        switch (result, error) {
        case let (r?, nil):
            return .success(.response(id: id, result: r))
        case let (nil, e?):
            guard let code = e["code"]?.intValue, let msg = e["message"]?.stringValue else {
                return .failure(.init(replyId: nil, error: .init(
                    code: ACPJsonRpcErrorCode.invalidRequest, message: "malformed error object")))
            }
            return .success(.errorResponse(id: id, error: .init(code: code, message: msg, data: e["data"])))
        default:
            return .failure(.init(replyId: nil, error: .init(
                code: ACPJsonRpcErrorCode.invalidRequest, message: "response needs exactly one of result and error")))
        }
    }

    /// Integer (int64 range, no fraction/exponent) or string.
    static func isValidId(_ v: JSONValue) -> Bool {
        switch v {
        case .null, .string: return true
        case let .number(raw, value):
            return !raw.contains(".") && !raw.lowercased().contains("e") && value.isFinite
                && abs(value) <= 9_223_372_036_854_775_807
        default: return false
        }
    }

    public static func encode(_ message: ACPJsonRpcMessage) -> JSONValue {
        switch message {
        case let .request(id, method, params):
            var m: [(String, JSONValue)] = [("jsonrpc", .string("2.0")), ("id", id), ("method", .string(method))]
            if let params { m.append(("params", params)) }
            return .obj(m)
        case let .notification(method, params):
            var m: [(String, JSONValue)] = [("jsonrpc", .string("2.0")), ("method", .string(method))]
            if let params { m.append(("params", params)) }
            return .obj(m)
        case let .response(id, result):
            return .obj([("jsonrpc", .string("2.0")), ("id", id), ("result", result)])
        case let .errorResponse(id, error):
            return .obj([("jsonrpc", .string("2.0")), ("id", id), ("error", error.json)])
        }
    }

    /// One frame: compact JSON plus "\n". `JSONValue.encoded()` escapes every
    /// line terminator, so the frame never contains an embedded newline.
    public static func frame(_ message: ACPJsonRpcMessage) -> Data {
        var d = encode(message).encodedData()
        d.append(0x0A)
        return d
    }
}
