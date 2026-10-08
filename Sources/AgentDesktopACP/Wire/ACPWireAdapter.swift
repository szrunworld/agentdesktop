import AgentDesktopProtocol
import Foundation

/// The only code that knows one ACP version's method names and field
/// spellings (docs/acp/README.md §3). It maps frames to the version-neutral
/// model and back. One instance serves one connection.
public protocol ACPWireAdapter: AnyObject, Sendable {
    var version: ACPVersion { get }

    /// The `initialize` params, after the version was negotiated.
    func decodeInitialize(params: JSONValue) -> (client: ACPImplementationInfo?, capabilities: ACPClientCapabilities)

    /// An editor request other than `initialize`. `advertised` is what we
    /// answered in `initialize`; methods it does not cover are refused.
    func decodeRequest(method: String, params: JSONValue?,
                       advertised: ACPAgentCapabilities) -> Result<ACPIncoming, ACPJsonRpcError>

    /// An editor notification; nil means "ignore" (unknown notifications
    /// get no answer in JSON-RPC).
    func decodeNotification(method: String, params: JSONValue?) -> ACPIncoming?

    /// The `result` for `reply` to a request of `method`. A reply that does
    /// not fit the method is an internal error, never sent as is.
    func encodeReply(_ reply: ACPReply, method: String) -> Result<JSONValue, ACPJsonRpcError>

    /// Called after a successful reply was sent, with the request's params,
    /// so the adapter can keep per-connection wire facts (e.g. a session's cwd).
    func didReply(_ reply: ACPReply, method: String, requestParams: JSONValue?)

    /// A `session/update` notification; nil when this version has no such
    /// update (it is then dropped, never approximated).
    func encodeUpdate(sessionId: String, _ update: ACPSessionUpdate) -> (method: String, params: JSONValue)?

    func encodePermissionRequest(_ request: ACPPermissionRequest) -> (method: String, params: JSONValue)
    func decodePermissionResult(_ result: JSONValue, request: ACPPermissionRequest) -> ACPPermissionOutcome

    func encodeQuestion(_ question: ACPQuestion) -> (method: String, params: JSONValue)
    func decodeAnswer(_ result: JSONValue, question: ACPQuestion) -> ACPAnswer
}

public enum ACPWire {
    /// The adapter for a negotiated version, or nil when this build has none.
    public static func adapter(for version: ACPVersion) -> ACPWireAdapter? {
        switch version {
        case .v1: return ACPWireV1()
        case .v2: return nil  // Draft upstream; no real client speaks it yet.
        }
    }
}
