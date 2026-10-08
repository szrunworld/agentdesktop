import AgentDesktopProtocol
import Foundation

/// One call of a method another in-process service answers (A2: the AI
/// service's ai.* methods on the Runtime's single endpoint). The caller's
/// identity comes from the connection, never from params.
public struct ExtensionCall: Sendable {
    public let method: String
    public let requestId: String
    public let deadline: Date?
    public let params: JSONValue
    public let clientId: String
    /// The local owner (same uid, not a paired app).
    public let owner: Bool

    public init(method: String, requestId: String, deadline: Date?, params: JSONValue, clientId: String, owner: Bool) {
        self.method = method
        self.requestId = requestId
        self.deadline = deadline
        self.params = params
        self.clientId = clientId
        self.owner = owner
    }
}

public typealias ExtensionMethod = @Sendable (ExtensionCall) -> Result<JSONValue, RuntimeError>

