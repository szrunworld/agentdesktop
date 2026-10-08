import AgentDesktopProtocol
import Foundation

/// Who a client is to the Runtime (A4): the owner (the user's own tools,
/// with the owner credential the host keeps in its records directory) or a
/// paired app (`app:<id>`, from hub.pairing). Shown once, in
/// runtime.handshake; never put in request params.
public struct ClientCredential: Equatable, Sendable {
    public var clientId: String
    public var token: String

    public init(clientId: String, token: String) {
        self.clientId = clientId
        self.token = token
    }

    public var json: JSONValue { .obj([("clientId", .string(clientId)), ("token", .string(token))]) }

    /// A credential file: `{"clientId": …, "token": …}` (what `agentdesktop
    /// agents pair` writes), or the owner credential's bare token.
    public static func load(file path: String) throws -> ClientCredential {
        guard let data = FileManager.default.contents(atPath: path) else {
            throw RuntimeError("invalid_argument", "cannot read the credential file \(path)", phase: .local, notSent: true)
        }
        if let v = try? StrictJSON.parse(data), let id = v["clientId"]?.stringValue, let token = v["token"]?.stringValue {
            return ClientCredential(clientId: id, token: token)
        }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains("{") else {
            throw RuntimeError("invalid_argument", "\(path) holds no credential", phase: .local, notSent: true)
        }
        return ClientCredential(clientId: "local:\(getuid())", token: token)
    }

    /// The owner credential of the Runtime at `endpoint`: `<endpoint without
    /// .sock>/owner.credential` (the host's records directory).
    public static func ownerFile(forEndpoint endpoint: String) -> String {
        let base = endpoint.hasSuffix(".sock") ? String(endpoint.dropLast(".sock".count)) : endpoint
        return base + "/owner.credential"
    }

    /// Write a credential for a paired app, owner-only.
    public func save(to path: String) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: path) { try fm.removeItem(atPath: path) }
        guard fm.createFile(atPath: path, contents: Data(json.encoded().utf8), attributes: [.posixPermissions: 0o600]) else {
            throw RuntimeError("execution_failed", "cannot write \(path)", phase: .local)
        }
    }
}
