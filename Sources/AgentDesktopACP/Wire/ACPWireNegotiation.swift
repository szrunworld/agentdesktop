import AgentDesktopProtocol
import Foundation

/// Version negotiation in `initialize` (spec v1 initialization.mdx,
/// "Version Negotiation"; same rule as the official TypeScript SDK's
/// `AgentProtocolRouter`, @agentclientprotocol/sdk 1.7.0).
///
/// The client sends the latest version it speaks. We answer that version
/// when we speak it, else the newest version we speak that is not above it.
/// A client whose latest version is below everything we speak cannot talk to
/// us: that is refused with a clear error. A malformed version is invalid
/// params.
public enum ACPWireNegotiation {
    /// Versions this build speaks on the wire. A version is listed only
    /// after a real client spoke it (docs/acp/02-protocol-version.md).
    public static let supported: [ACPVersion] = [.v1]

    public static func number(_ v: ACPVersion) -> Int {
        switch v {
        case .v1: return 1
        case .v2: return 2
        }
    }

    public struct Outcome: Equatable, Sendable {
        /// What the client asked for.
        public var requested: Int
        /// What this connection will speak.
        public var version: ACPVersion
    }

    public static func negotiate(params: JSONValue?,
                                 supported: [ACPVersion] = supported) -> Result<Outcome, ACPJsonRpcError> {
        guard let params, params.objectMembers != nil else {
            return .failure(.init(code: ACPJsonRpcErrorCode.invalidParams,
                                  message: "initialize needs params with protocolVersion"))
        }
        guard let raw = params["protocolVersion"] else {
            return .failure(.init(code: ACPJsonRpcErrorCode.invalidParams,
                                  message: "initialize.protocolVersion is required"))
        }
        guard case let .number(text, _) = raw, !text.contains("."), !text.lowercased().contains("e"),
              let requested = raw.intValue, (0...65535).contains(requested) else {
            return .failure(.init(code: ACPJsonRpcErrorCode.invalidParams,
                                  message: "initialize.protocolVersion must be an integer from 0 to 65535"))
        }
        let ours = supported.sorted { number($0) < number($1) }
        if let exact = ours.first(where: { number($0) == requested }) {
            return .success(Outcome(requested: requested, version: exact))
        }
        if let lower = ours.last(where: { number($0) < requested }) {
            return .success(Outcome(requested: requested, version: lower))
        }
        let list = ours.map { String(number($0)) }.joined(separator: ", ")
        return .failure(.init(
            code: ACPJsonRpcErrorCode.invalidRequest,
            message: "unsupported ACP protocol version \(requested); this agent speaks \(list)",
            data: .obj([("reason", .string("protocol_version_unsupported")),
                        ("requested", .int(requested)),
                        ("supported", .array(ours.map { .int(number($0)) }))])))
    }
}
