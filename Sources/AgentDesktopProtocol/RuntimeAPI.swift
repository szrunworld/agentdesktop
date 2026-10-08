import AgentDesktopContracts
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
    case unitRun = "unit.run"
    case procedureList = "procedure.list"
    case procedureShow = "procedure.show"
}

/// The machine-readable contract: schema, method catalog and error table.
public final class RuntimeContract: Sendable {
    public static let schemaId = "https://schemas.agentdesktop.invalid/runtime/v1/runtime.schema.json"

    public struct MethodSpec: Equatable, Sendable {
        public let method: String
        public let stage: String
        public let mutation: Bool
        /// `$defs` names in runtime.schema.json.
        public let params: String
        public let result: String
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
                                  methods: RuntimeContractData.methods,
                                  errors: RuntimeContractData.errors)

    public static let shared: RuntimeContract = {
        do {
            return try RuntimeContract(schema: Data(embedded.schema.utf8), methods: Data(embedded.methods.utf8),
                                       errors: Data(embedded.errors.utf8))
        } catch {
            fatalError("the embedded runtime contract is invalid: \(error)")
        }
    }()

    public init(schema: Data, methods: Data, errors: Data) throws {
        registry = SchemaRegistry()
        _ = try registry.add(jsonData: schema)
        let m = try StrictJSON.parse(methods)
        self.methods = try (m["methods"]?.arrayValue ?? []).map { v in
            guard let method = v["method"]?.stringValue, let stage = v["stage"]?.stringValue,
                  let mutation = v["mutation"]?.boolValue, let params = v["params"]?.stringValue,
                  let result = v["result"]?.stringValue
            else { throw SchemaError.invalidSchema("methods.json entry \(v.encoded())") }
            return MethodSpec(method: method, stage: stage, mutation: mutation, params: params, result: result)
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

    /// Violations of `#/$defs/<def>`, as text; empty means valid.
    public func validate(_ instance: JSONValue, _ def: String) -> [String] {
        do {
            return try registry.validate(instance, documentId: Self.schemaId, pointer: "/$defs/\(def)")
                .map(\.description)
        } catch {
            return ["/: $ref: \(error)"]
        }
    }
}
