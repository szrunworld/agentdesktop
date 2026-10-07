import AgentDesktopContracts
import Foundation

/// The only way the AI/GUI pages talk to the service (spec §2.1): one
/// contract v1 request per call, answered by the same application service
/// the CLI uses. The page never decides who the caller is.
public protocol ContractClient: Sendable {
    /// Send one command. Returns the validated `result`, or throws the
    /// service's `ContractError`.
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue
}

extension ContractClient {
    public func send(_ command: String, _ params: JSONValue = .obj([])) async throws -> JSONValue {
        try await send(command, params, idempotencyKey: nil)
    }
}

/// Envelope building and response checking shared by both transports.
enum ContractExchange {
    static func envelope(_ command: String, _ params: JSONValue, idempotencyKey: String?, requestId: String) -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("schemaVersion", .string(ContractBundle.schemaVersion)),
            ("requestId", .string(requestId)),
            ("command", .string(command)),
            ("params", params),
        ]
        if let idempotencyKey { m.append(("context", .obj([("idempotencyKey", .string(idempotencyKey))]))) }
        return .obj(m)
    }

    /// Check correlation and the contract, then unwrap.
    static func unwrap(_ body: Data, command: String, requestId: String) throws -> JSONValue {
        guard let response = try? StrictJSON.parse(body),
              (try? ContractBundle.shared.validateRpc(response, "Response"))?.isEmpty == true else {
            throw ContractError(.internalError, "服务返回了不符合合同的响应")
        }
        guard response["requestId"]?.stringValue == requestId else {
            throw ContractError(.internalError, "响应不属于本次请求")
        }
        if response["ok"]?.boolValue == true, let result = response["result"] {
            guard let op = ContractBundle.shared.operation(command),
                  (try? ContractBundle.shared.validateRpc(result, "\(op.defPrefix)_result"))?.isEmpty == true else {
                throw ContractError(.internalError, "服务结果不符合合同")
            }
            return result
        }
        let e = response["error"]
        let code = ErrorCode(rawValue: e?["code"]?.stringValue ?? "") ?? .internalError
        throw ContractError(code, e?["message"]?.stringValue ?? code.rawValue,
                            retryable: e?["retryable"]?.boolValue, details: e?["details"])
    }
}

/// Calls a router in the same process (the app hosting the service).
public struct InProcessContractClient: ContractClient {
    public let router: RpcRouter
    public init(router: RpcRouter) { self.router = router }

    public func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        let requestId = UUID().uuidString.lowercased()
        let request = ContractExchange.envelope(command, params, idempotencyKey: idempotencyKey, requestId: requestId)
        var out = await router.respond(toBody: request.encodedData())
        if out.last == 0x0A { out.removeLast() }
        return try ContractExchange.unwrap(out, command: command, requestId: requestId)
    }
}

/// One request per connection over the service's Unix socket (spec §05.1).
public struct SocketContractClient: ContractClient {
    public let path: String
    public init(path: String) { self.path = path }

    public func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        let requestId = UUID().uuidString.lowercased()
        var frame = ContractExchange.envelope(command, params, idempotencyKey: idempotencyKey, requestId: requestId).encodedData()
        frame.append(0x0A)
        let path = self.path
        let result = await Task.detached { Self.exchange(frame, path: path) }.value
        guard case let .frame(body) = result else {
            throw ContractError(.upstreamUnavailable, "无法连接本机服务", retryable: true)
        }
        return try ContractExchange.unwrap(body, command: command, requestId: requestId)
    }

    static func exchange(_ frame: Data, path: String) -> FrameReader.Result {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return .ioError(errno) }
        defer { close(fd) }
        var on: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0 else { return .ioError(errno) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return .ioError(ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { $0.copyBytes(from: bytes); $0[bytes.count] = 0 }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard rc == 0 else { return .ioError(errno) }
        var sent = 0
        while sent < frame.count {
            let n = frame.withUnsafeBytes { write(fd, $0.baseAddress! + sent, frame.count - sent) }
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return .ioError(errno) }
            sent += n
        }
        return FrameReader.read(fd: fd)
    }
}

/// Waiting between polls; tests inject a fast one.
public protocol PollClock: Sendable {
    func pause(milliseconds: Int) async throws
}

public struct SystemPollClock: PollClock {
    public init() {}
    public func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: UInt64(milliseconds) * 1_000_000) }
}

/// One logical submission keeps its idempotency key across retries; a
/// changed request gets a new one (spec §2.2).
struct SubmissionKey {
    private var key: String?
    private var semantic: String?

    mutating func key(for semantic: JSONValue, prefix: String) -> String {
        let s = semantic.encoded()
        if let key, self.semantic == s { return key }
        let fresh = "\(prefix)-\(UUID().uuidString.lowercased())"
        key = fresh
        self.semantic = s
        return fresh
    }

    mutating func reset() { key = nil; semantic = nil }
}
