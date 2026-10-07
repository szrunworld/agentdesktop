import AgentDesktopContracts
import Foundation

/// Where a failure happened. A client decides what is safe to repeat from
/// this, the code and `notSent`, never from the message text.
public enum ErrorPhase: String, Sendable {
    /// In the calling process, before any connection.
    case local
    /// Opening the connection; nothing was sent.
    case connect
    /// After sending; the reply did not arrive whole.
    case transport
    case handshake
    /// The Runtime refused the message itself (framing, schema, method).
    case request
    /// The method's handler ran and failed.
    case handler
}

/// The `error` member of a failed response (contracts/runtime/v1/errors.json).
public struct RuntimeError: Error, Equatable, Sendable, CustomStringConvertible {
    public var code: String
    public var message: String
    public var phase: ErrorPhase
    public var retryable: Bool
    /// True only when it is certain the request never reached the Runtime.
    public var notSent: Bool?
    public var details: JSONValue?

    public init(_ code: String, _ message: String, phase: ErrorPhase, retryable: Bool = false,
                notSent: Bool? = nil, details: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.phase = phase
        self.retryable = retryable
        self.notSent = notSent
        self.details = details
    }

    public var description: String { "\(code): \(message)" }

    public var json: JSONValue {
        var m: [(String, JSONValue)] = [
            ("code", .string(code)),
            ("message", .string(message)),
            ("phase", .string(phase.rawValue)),
            ("retryable", .bool(retryable)),
        ]
        if let notSent { m.append(("notSent", .bool(notSent))) }
        if let details { m.append(("details", details)) }
        return .obj(m)
    }

    public init?(json: JSONValue) {
        guard let code = json["code"]?.stringValue, let message = json["message"]?.stringValue,
              let phase = json["phase"]?.stringValue.flatMap(ErrorPhase.init(rawValue:))
        else { return nil }
        self.init(code, message, phase: phase, retryable: json["retryable"]?.boolValue ?? false,
                  notSent: json["notSent"]?.boolValue, details: json["details"])
    }

    // Constructors for the codes PR1 produces.
    public static func invalidArgument(_ m: String) -> RuntimeError {
        RuntimeError("invalid_argument", m, phase: .local, notSent: true)
    }
    public static func schemaInvalid(_ m: String, violations: [String] = []) -> RuntimeError {
        RuntimeError("schema_invalid", m, phase: .request,
                     details: violations.isEmpty ? nil : .obj([("violations", .array(violations.prefix(20).map(JSONValue.string)))]))
    }
    public static func notFound(_ m: String) -> RuntimeError { RuntimeError("not_found", m, phase: .handler) }
    public static func runtimeOffline(_ m: String, endpoint: String) -> RuntimeError {
        RuntimeError("runtime_offline", m, phase: .connect, retryable: true, notSent: true,
                     details: .obj([("endpoint", .string(endpoint))]))
    }
    public static func capabilityMissing(_ m: String) -> RuntimeError {
        RuntimeError("capability_missing", m, phase: .request)
    }
    public static func connectionLost(_ m: String) -> RuntimeError {
        RuntimeError("connection_lost", m, phase: .transport, retryable: false)
    }
}
