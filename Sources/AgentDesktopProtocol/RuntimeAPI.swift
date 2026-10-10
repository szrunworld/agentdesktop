import AgentDesktopProtocol
import Foundation

/// The Runtime API every entry speaks: CLI, MCP, SDKs, the app's own
/// clients and Hub-started agents (CLI plan v1.2 §05). The JSON files under
/// Resources are byte copies of contracts/runtime/v1; RuntimeContractTests
/// keeps them equal.
public enum RuntimeAPI {
    public static let version = "agentdesktop.runtime/1"
    /// Versions this build can speak, preferred first.
    public static let supportedVersions = [version]
    public static let product = "AgentDesktop"
    public static let productVersion = "0.1.0-dev"
    public static let bundleID = "com.agentdesktop.app"
    /// Message limit, the terminating LF included.
    public static let maxFrameBytes = 1_048_576
}

/// Methods of agentdesktop.runtime/1 this build implements. A method is
/// listed here, in methods.json and in `runtime.capabilities` only once the
/// Runtime really handles it.
public enum RuntimeMethod: String, CaseIterable, Sendable {
    case handshake = "runtime.handshake"
    case status = "runtime.status"
    case capabilities = "runtime.capabilities"
    case desktopList = "desktop.list"
    case desktopShow = "desktop.show"
    case appList = "app.list"
    case windowList = "window.list"
    case desktopCreate = "desktop.create"
    case desktopDestroy = "desktop.destroy"
    case appLaunch = "app.launch"
    case windowBind = "window.bind"
    case windowUnbind = "window.unbind"
    case sessionOpen = "session.open"
    case sessionShow = "session.show"
    case sessionClose = "session.close"
    case observe
    case requestShow = "request.show"
    case act
    case wait
    case runStart = "run.start"
    case runAttach = "run.attach"
    case runFinish = "run.finish"
    case runShow = "run.show"
    case runEvents = "run.events"
    case runWait = "run.wait"
    case runCancel = "run.cancel"
    case runList = "run.list"
    case stopAll = "runtime.stopAll"
    case enableInput = "runtime.enableInput"
    case artifactShow = "artifact.show"
    case artifactRead = "artifact.read"
    case eventsSubscribe = "events.subscribe"
    case eventsUnsubscribe = "events.unsubscribe"
    case pairingStart = "hub.pairing.start"
    case pairingStatus = "hub.pairing.status"
    case pairingApprove = "hub.pairing.approve"
    case pairingDeny = "hub.pairing.deny"
    case clientsList = "hub.clients.list"
    case clientsShow = "hub.clients.show"
    case clientsRevoke = "hub.clients.revoke"
    case grantsList = "hub.grants.list"
    case grantsSet = "hub.grants.set"
    case grantsRevoke = "hub.grants.revoke"
    case connectionsList = "hub.connections.list"
    case windowsRequest = "hub.windows.request"
    case windowsList = "hub.windows.list"
    case windowsRevoke = "hub.windows.revoke"
    case displaysList = "hub.displays.list"
    case displaysAttach = "hub.displays.attach"
    case displaysDetach = "hub.displays.detach"
}

/// The machine-readable contract: schema, method catalog and error table.
public final class RuntimeContract: Sendable {
    public static let schemaId = "https://schemas.agentdesktop.invalid/runtime/v1/runtime.schema.json"
    public static let serviceSchemaId = "https://schemas.agentdesktop.invalid/runtime/v1/service.schema.json"

    public struct MethodSpec: Equatable, Sendable {
        public let method: String
        public let stage: String
        public let mutation: Bool
        /// `$defs` names in runtime.schema.json, or for a method served by
        /// another service a `service.schema.json#/$defs/…` reference.
        public let params: String
        public let result: String
        /// The service that answers it inside the Runtime ("ai-service"),
        /// nil for the Runtime's own methods.
        public var servedBy: String? = nil
        /// For a servedBy method: answered with an operation to poll.
        public var asynchronous = false
        /// For a servedBy write: the requestId doubles as its idempotency key.
        public var requiresIdempotencyKey = false
    }

    public struct ErrorSpec: Equatable, Sendable {
        public let code: String
        public let exitCode: Int32
        public let phase: String
        public let reserved: Bool
    }

    public let registry: SchemaRegistry
    public let methods: [MethodSpec]
    public let errors: [ErrorSpec]
    private let methodsByName: [String: MethodSpec]
    private let errorsByCode: [String: ErrorSpec]

    /// The contract as embedded at build time (RuntimeContractData.swift).
    public static let embedded = (schema: RuntimeContractData.runtimeSchema,
                                  service: RuntimeContractData.serviceSchema,
                                  methods: RuntimeContractData.methods,
                                  errors: RuntimeContractData.errors)

    public static let shared: RuntimeContract = {
        do {
            return try RuntimeContract(schema: Data(embedded.schema.utf8), service: Data(embedded.service.utf8),
                                       methods: Data(embedded.methods.utf8), errors: Data(embedded.errors.utf8))
        } catch {
            fatalError("the embedded runtime contract is invalid: \(error)")
        }
    }()

    public init(schema: Data, service: Data? = nil, methods: Data, errors: Data) throws {
        registry = SchemaRegistry()
        _ = try registry.add(jsonData: schema)
        if let service { _ = try registry.add(jsonData: service) }
        let m = try StrictJSON.parse(methods)
        self.methods = try (m["methods"]?.arrayValue ?? []).map { v in
            guard let method = v["method"]?.stringValue, let stage = v["stage"]?.stringValue,
                  let mutation = v["mutation"]?.boolValue, let params = v["params"]?.stringValue,
                  let result = v["result"]?.stringValue
            else { throw SchemaError.invalidSchema("methods.json entry \(v.encoded())") }
            return MethodSpec(method: method, stage: stage, mutation: mutation, params: params, result: result,
                              servedBy: v["servedBy"]?.stringValue, asynchronous: v["asynchronous"]?.boolValue ?? false,
                              requiresIdempotencyKey: v["requiresIdempotencyKey"]?.boolValue ?? false)
        }
        let e = try StrictJSON.parse(errors)
        self.errors = try (e["codes"]?.arrayValue ?? []).map { v in
            guard let code = v["code"]?.stringValue, let exit = v["exitCode"]?.intValue,
                  let phase = v["phase"]?.stringValue
            else { throw SchemaError.invalidSchema("errors.json entry \(v.encoded())") }
            return ErrorSpec(code: code, exitCode: Int32(exit), phase: phase, reserved: v["reserved"]?.boolValue ?? false)
        }
        methodsByName = Dictionary(uniqueKeysWithValues: self.methods.map { ($0.method, $0) })
        errorsByCode = Dictionary(uniqueKeysWithValues: self.errors.map { ($0.code, $0) })
    }

    public func method(_ name: String) -> MethodSpec? { methodsByName[name] }
    public func error(_ code: String) -> ErrorSpec? { errorsByCode[code] }

    /// Violations of `#/$defs/<def>`, as text; empty means valid. A def
    /// written `service.schema.json#/$defs/<name>` is looked up there.
    public func validate(_ instance: JSONValue, _ def: String) -> [String] {
        let (doc, name) = def.hasPrefix("service.schema.json#/$defs/")
            ? (Self.serviceSchemaId, String(def.dropFirst("service.schema.json#/$defs/".count))) : (Self.schemaId, def)
        do {
            return try registry.validate(instance, documentId: doc, pointer: "/$defs/\(name)")
                .map(\.description)
        } catch {
            return ["/: $ref: \(error)"]
        }
    }
}
