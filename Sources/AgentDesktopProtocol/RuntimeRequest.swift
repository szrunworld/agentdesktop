import AgentDesktopProtocol
import Foundation

/// Which Session, Run and Desktop a request belongs to. Only references:
/// the Runtime binds identity and authority to the connection, never to
/// these fields.
public struct RequestContext: Equatable, Sendable {
    public var sessionId: String?
    public var runId: String?
    public var desktopId: String?

    public init(sessionId: String? = nil, runId: String? = nil, desktopId: String? = nil) {
        self.sessionId = sessionId
        self.runId = runId
        self.desktopId = desktopId
    }

    public var isEmpty: Bool { sessionId == nil && runId == nil && desktopId == nil }

    public var json: JSONValue {
        var m: [(String, JSONValue)] = []
        if let sessionId { m.append(("sessionId", .string(sessionId))) }
        if let runId { m.append(("runId", .string(runId))) }
        if let desktopId { m.append(("desktopId", .string(desktopId))) }
        return .obj(m)
    }
}

/// One request line of agentdesktop.runtime/1.
public struct RuntimeRequest: Equatable, Sendable {
    public var requestId: String
    public var method: String
    public var context: RequestContext
    /// RFC 3339; how long the Runtime may work on it.
    public var deadline: String?
    public var params: JSONValue

    public init(requestId: String, method: String, context: RequestContext = .init(),
                deadline: String? = nil, params: JSONValue = .obj([])) {
        self.requestId = requestId
        self.method = method
        self.context = context
        self.deadline = deadline
        self.params = params
    }

    public init(_ method: RuntimeMethod, requestId: String = RuntimeRequest.newId(),
                params: JSONValue = .obj([])) {
        self.init(requestId: requestId, method: method.rawValue, params: params)
    }

    /// A fresh ID for a read or a first attempt.
    public static func newId(prefix: String = "req") -> String {
        "\(prefix)_\(UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: ""))"
    }

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("apiVersion", .string(RuntimeAPI.version)),
            ("requestId", .string(requestId)),
            ("method", .string(method)),
        ]
        if !context.isEmpty { m.append(("context", context.json)) }
        if let deadline { m.append(("deadline", .string(deadline))) }
        m.append(("params", params))
        return .obj(m)
    }

    /// Decode a message that already passed `#/$defs/Request`.
    public init(validated v: JSONValue) {
        let c = v["context"]
        self.init(requestId: v["requestId"]?.stringValue ?? "",
                  method: v["method"]?.stringValue ?? "",
                  context: RequestContext(sessionId: c?["sessionId"]?.stringValue,
                                          runId: c?["runId"]?.stringValue,
                                          desktopId: c?["desktopId"]?.stringValue),
                  deadline: v["deadline"]?.stringValue,
                  params: v["params"] ?? .obj([]))
    }
}

/// One response line: `data` on success, `error` otherwise.
public struct RuntimeResponse: Equatable, Sendable {
    public var requestId: String?
    public var result: Result<JSONValue, RuntimeError>

    public init(requestId: String?, result: Result<JSONValue, RuntimeError>) {
        self.requestId = requestId
        self.result = result
    }

    public static func success(_ requestId: String, _ data: JSONValue) -> RuntimeResponse {
        RuntimeResponse(requestId: requestId, result: .success(data))
    }

    public static func failure(_ requestId: String?, _ error: RuntimeError) -> RuntimeResponse {
        RuntimeResponse(requestId: requestId, result: .failure(error))
    }

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("apiVersion", .string(RuntimeAPI.version)),
            ("requestId", requestId.map(JSONValue.string) ?? .null),
        ]
        switch result {
        case let .success(data):
            m.append(("ok", .bool(true)))
            m.append(("data", data))
        case let .failure(error):
            m.append(("ok", .bool(false)))
            m.append(("error", error.json))
        }
        return .obj(m)
    }

    /// Decode a message that already passed `#/$defs/Response`.
    public init?(validated v: JSONValue) {
        let id = v["requestId"]?.stringValue
        if v["ok"]?.boolValue == true, let data = v["data"] {
            self.init(requestId: id, result: .success(data))
        } else if let e = v["error"].flatMap(RuntimeError.init(json:)) {
            self.init(requestId: id, result: .failure(e))
        } else {
            return nil
        }
    }
}
