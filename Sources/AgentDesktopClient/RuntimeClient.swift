import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// The typed client every entry uses. It never executes anything itself:
/// it finds the product's Runtime, confirms who answered, and carries
/// requests. Rules (scope, leases, queues, stop) live in the Runtime.
public protocol RuntimeClient: AnyObject {
    var endpoint: Endpoint { get }
    /// Connect if needed and confirm product and API version.
    func handshake() throws -> RuntimeIdentity
    /// Send one request; its `data`, or the Runtime's error.
    func call(_ request: RuntimeRequest) throws -> JSONValue
    func close()
}

/// Who is calling, sent in the handshake.
public struct ClientInfo: Sendable {
    public var name: String
    public var version: String

    public init(name: String, version: String) {
        self.name = name
        self.version = version
    }
}

public final class SocketRuntimeClient: RuntimeClient {
    public let endpoint: Endpoint
    public let info: ClientInfo
    public let timeout: Double
    private let contract: RuntimeContract
    private let connect: (String, Double) throws -> RuntimeTransport
    private var transport: RuntimeTransport?
    private var identity: RuntimeIdentity?

    public init(endpoint: Endpoint, info: ClientInfo, timeout: Double = 10,
                contract: RuntimeContract = .shared,
                connect: @escaping (String, Double) throws -> RuntimeTransport = { try UnixSocketTransport(path: $0, timeout: $1) }) {
        self.endpoint = endpoint
        self.info = info
        self.timeout = timeout
        self.contract = contract
        self.connect = connect
    }

    public func handshake() throws -> RuntimeIdentity {
        if let identity { return identity }
        let t = try connect(endpoint.path, timeout)
        transport = t
        let request = RuntimeRequest(.handshake, params: .obj([
            ("apiVersions", .array(RuntimeAPI.supportedVersions.map(JSONValue.string))),
            ("client", .obj([("name", .string(info.name)), ("version", .string(info.version))])),
        ]))
        let data: JSONValue
        do {
            data = try exchange(request, on: t)
        } catch var e as RuntimeError {
            if e.phase == .handler || e.phase == .request { e.phase = .handshake }
            close()
            throw e
        }
        guard contract.validate(data, "RuntimeIdentity").isEmpty, let id = RuntimeIdentity(json: data) else {
            close()
            throw RuntimeError("instance_mismatch", "\(endpoint.path) answered, but not with an AgentDesktop Runtime identity",
                               phase: .handshake)
        }
        guard RuntimeAPI.supportedVersions.contains(id.apiVersion) else {
            close()
            throw RuntimeError("version_mismatch", "Runtime chose \(id.apiVersion); this client speaks \(RuntimeAPI.supportedVersions.joined(separator: ", "))",
                               phase: .handshake)
        }
        identity = id
        return id
    }

    public func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        guard let transport else { throw RuntimeError.connectionLost("the connection is closed") }
        do {
            return try exchange(request, on: transport)
        } catch let e as RuntimeError where e.code == "connection_lost" {
            close()
            throw e
        }
    }

    public func close() {
        transport?.close()
        transport = nil
        identity = nil
    }

    private func exchange(_ request: RuntimeRequest, on transport: RuntimeTransport) throws -> JSONValue {
        let reply = try transport.exchange(request.json.encodedData())
        let value: JSONValue
        do {
            value = try StrictJSON.parse(reply)
        } catch {
            throw RuntimeError("instance_mismatch", "reply is not JSON: \(error)", phase: .transport)
        }
        let violations = contract.validate(value, "Response")
        guard violations.isEmpty, let response = RuntimeResponse(validated: value) else {
            if value["apiVersion"]?.stringValue != RuntimeAPI.version {
                throw RuntimeError("version_mismatch", "reply is not \(RuntimeAPI.version)", phase: .transport)
            }
            throw RuntimeError("instance_mismatch", "reply breaks the Response schema: \(violations.prefix(3).joined(separator: "; "))",
                               phase: .transport)
        }
        if let id = response.requestId, id != request.requestId {
            throw RuntimeError("instance_mismatch", "reply answers \(id), not \(request.requestId)", phase: .transport)
        }
        switch response.result {
        case let .success(data): return data
        case let .failure(error): throw error
        }
    }
}
