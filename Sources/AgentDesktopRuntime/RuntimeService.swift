import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// What the Runtime knows about one connection.
public final class ConnectionState: @unchecked Sendable {
    public let peerUID: uid_t
    /// Set by a successful runtime.handshake; every other method needs it.
    public internal(set) var apiVersion: String?
    public internal(set) var clientName: String?

    public init(peerUID: uid_t) {
        self.peerUID = peerUID
    }
}

/// Turns one request line into one response line. Every method passes the
/// same checks in the same order: JSON, apiVersion, Request schema, method,
/// handshake, params schema, handler.
public final class RuntimeService: @unchecked Sendable {
    public let identity: RuntimeIdentity
    public let backend: RuntimeBackend
    public let desktops: DesktopRegistry
    public let contract: RuntimeContract
    private let startedAt: Date
    private let now: @Sendable () -> Date
    /// Open connections, supplied by the server.
    public var connectionCount: @Sendable () -> Int = { 0 }

    public init(identity: RuntimeIdentity, backend: RuntimeBackend, desktops: DesktopRegistry = DesktopRegistry(),
                contract: RuntimeContract = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.backend = backend
        self.desktops = desktops
        self.contract = contract
        self.startedAt = Timestamp.date(identity.startedAt) ?? now()
        self.now = now
    }

    public func respond(to line: Data, on connection: ConnectionState) -> RuntimeResponse {
        let value: JSONValue
        do {
            value = try StrictJSON.parse(line)
        } catch {
            return .failure(nil, .schemaInvalid("request is not strict JSON: \(error)"))
        }
        // Echo the requestId when it is one, so the caller can correlate.
        let rawId = value["requestId"]?.stringValue
        let requestId = rawId.flatMap { contract.validate(.string($0), "Id").isEmpty ? $0 : nil }

        if let v = value["apiVersion"]?.stringValue, v != RuntimeAPI.version {
            return .failure(requestId, RuntimeError(
                "version_mismatch", "this Runtime speaks \(RuntimeAPI.version), the request is \(v)",
                phase: .request, details: .obj([("supported", .array(RuntimeAPI.supportedVersions.map(JSONValue.string)))])))
        }
        let violations = contract.validate(value, "Request")
        guard violations.isEmpty else {
            return .failure(requestId, .schemaInvalid("request breaks the Request schema", violations: violations))
        }
        let request = RuntimeRequest(validated: value)
        guard let spec = contract.method(request.method), RuntimeMethod(rawValue: request.method) != nil else {
            return .failure(request.requestId, .capabilityMissing("method \(request.method) is not available in this Runtime"))
        }
        if connection.apiVersion == nil, request.method != RuntimeMethod.handshake.rawValue {
            return .failure(request.requestId, RuntimeError(
                "handshake_required", "send runtime.handshake first on each connection", phase: .handshake))
        }
        let paramViolations = contract.validate(request.params, spec.params)
        guard paramViolations.isEmpty else {
            return .failure(request.requestId, .schemaInvalid("params break \(spec.params)", violations: paramViolations))
        }
        switch handle(request, on: connection) {
        case let .success(data):
            return .success(request.requestId, data)
        case let .failure(error):
            return .failure(request.requestId, error)
        }
    }

    private func handle(_ request: RuntimeRequest, on connection: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let p = request.params
        switch RuntimeMethod(rawValue: request.method)! {
        case .handshake:
            let offered = p["apiVersions"]?.arrayValue?.compactMap(\.stringValue) ?? []
            guard let chosen = RuntimeAPI.supportedVersions.first(where: offered.contains) else {
                return .failure(RuntimeError(
                    "version_mismatch", "no common API version; this Runtime speaks \(RuntimeAPI.supportedVersions.joined(separator: ", "))",
                    phase: .handshake, details: .obj([("supported", .array(RuntimeAPI.supportedVersions.map(JSONValue.string)))])))
            }
            connection.apiVersion = chosen
            connection.clientName = p["client"]?["name"]?.stringValue
            var id = identity
            id.apiVersion = chosen
            return .success(id.json)

        case .status:
            return .success(RuntimeStatus(
                instanceId: identity.instanceId, state: "running", startedAt: identity.startedAt,
                uptimeSeconds: max(0, now().timeIntervalSince(startedAt)),
                connections: connectionCount(), desktops: desktops.count, sessions: 0, runs: 0).json)

        case .capabilities:
            let methods = contract.methods
                .filter { RuntimeMethod(rawValue: $0.method) != nil }
                .map { JSONValue.obj([("method", .string($0.method)), ("mutation", .bool($0.mutation)),
                                      ("stage", .string($0.stage))]) }
            let perms = backend.permissions()
            return .success(.obj([
                ("apiVersion", .string(RuntimeAPI.version)),
                ("interface", .obj([("methods", .array(methods))])),
                ("backend", .obj([
                    ("platform", backend.platform.json),
                    ("permissions", .obj([("screenRecording", .string(perms.screenRecording.rawValue)),
                                          ("accessibility", .string(perms.accessibility.rawValue))])),
                    ("features", .array(backend.features().map(JSONValue.string))),
                ])),
            ]))

        case .desktopList:
            return .success(.obj([("desktops", .array(desktops.list().map(\.json)))]))

        case .desktopShow:
            let id = p["desktopId"]?.stringValue ?? ""
            guard let d = desktops.show(id) else { return .failure(.notFound("no desktop \(id)")) }
            return .success(d.json)

        case .appList:
            let apps = backend.applications(includeBackground: p["includeBackground"]?.boolValue ?? false)
            return .success(.obj([("apps", .array(apps.map(\.json)))]))

        case .windowList:
            let pid = p["pid"]?.intValue.map(Int32.init)
            let windows = backend.windows(pid: pid, bundleId: p["bundleId"]?.stringValue,
                                          includeOffscreen: p["includeOffscreen"]?.boolValue ?? false)
            return .success(.obj([("windows", .array(windows.map(\.json)))]))
        }
    }
}
