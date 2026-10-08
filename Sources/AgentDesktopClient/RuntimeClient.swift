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
    /// Turn this connection into an event stream (events.subscribe); use a
    /// connection that controls no Run.
    func subscribe(runId: String?, after: Int?) throws -> JSONValue
    /// The next pushed event frame.
    func nextEvent() throws -> PushedEvent
    func close()
    /// The process on the other end of this client's own connection.
    var peer: PeerCredentials? { get }
}

extension RuntimeClient {
    public var peer: PeerCredentials? { nil }
}

/// What an event subscription delivered.
public enum PushedEvent: Equatable {
    /// An EventFrame: `event` and the `cursor` to resume after.
    case frame(JSONValue)
    /// Nothing within the receive timeout; the subscription is still open.
    case idle
    /// The Runtime ended the stream: a Run's stream after the Run ended.
    case closed
}

extension RuntimeClient {
    public func subscribe(runId: String?, after: Int?) throws -> JSONValue {
        throw RuntimeError("capability_missing", "this client does not carry event subscriptions", phase: .local)
    }

    public func nextEvent() throws -> PushedEvent { .closed }
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
    /// The Runtime's process on this client's connection (after handshake).
    public var peer: PeerCredentials? { transport?.peer }

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

    public func subscribe(runId: String?, after: Int?) throws -> JSONValue {
        var p: [(String, JSONValue)] = []
        if let runId { p.append(("runId", .string(runId))) }
        if let after { p.append(("after", .int(after))) }
        return try call(RuntimeRequest(.eventsSubscribe, params: .obj(p)))
    }

    public func nextEvent() throws -> PushedEvent {
        guard let transport else { return .closed }
        let line: Data?
        do {
            line = try transport.receive()
        } catch let e as RuntimeError where e.code == "connection_lost" {
            close()
            return .closed
        }
        guard let line else { return .idle }
        guard let frame = try? StrictJSON.parse(line), contract.validate(frame, "EventFrame").isEmpty else {
            throw RuntimeError("instance_mismatch", "a pushed line is not an EventFrame", phase: .transport)
        }
        return .frame(frame)
    }

    public func close() {
        transport?.close()
        transport = nil
        identity = nil
    }

    private func exchange(_ request: RuntimeRequest, on transport: RuntimeTransport) throws -> JSONValue {
        var reply = try transport.exchange(request.json.encodedData())
        var value: JSONValue
        while true {
            do {
                value = try StrictJSON.parse(reply)
            } catch {
                throw RuntimeError("instance_mismatch", "reply is not JSON: \(error)", phase: .transport)
            }
            // On a subscribed connection, frames pushed before the reply
            // (events.unsubscribe) are passed over.
            guard value["event"] != nil, value["ok"] == nil else { break }
            guard let next = try transport.receive() else {
                throw RuntimeError.connectionLost("no reply from the Runtime within the timeout")
            }
            reply = next
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
