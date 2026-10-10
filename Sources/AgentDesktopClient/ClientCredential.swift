import AgentDesktopProtocol
import Foundation

/// What a paired client shows in runtime.handshake (A4): its `app:<id>`
/// and the token issued at pairing. Never put in request params, files,
/// environment variables or command lines; kept in a CredentialStore.
public struct ClientCredential: Equatable, Sendable {
    public var clientId: String
    public var token: String

    public init(clientId: String, token: String) {
        self.clientId = clientId
        self.token = token
    }

    public var json: JSONValue { .obj([("clientId", .string(clientId)), ("token", .string(token))]) }
}
