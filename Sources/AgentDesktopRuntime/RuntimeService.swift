import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// What the Runtime knows about one connection.
public final class ConnectionState: @unchecked Sendable {
    public let peerUID: uid_t
    /// Set by a successful runtime.handshake; every other method needs it.
    public internal(set) var apiVersion: String?
    public internal(set) var clientName: String?
    /// Runs this connection started; its loss stops them.
    var ownedRuns: Set<String> = []
    /// Exec Runs this connection joined with the Run's token.
    var attachedRuns: Set<String> = []

    public init(peerUID: uid_t) {
        self.peerUID = peerUID
    }
}

/// Turns one request line into one response line. Every method passes the
/// same checks in the same order: JSON, apiVersion, Request schema, method,
/// handshake, params schema; a write then goes through the request ledger
/// before its handler runs.
public final class RuntimeService: @unchecked Sendable {
    public let identity: RuntimeIdentity
    public let backend: RuntimeBackend
    /// nil: this Runtime has no desktop platform, and every method that
    /// needs one is missing from its capabilities.
    public let platform: DesktopPlatform?
    public let desktops: DesktopRegistry
    public let sessions = SessionManager()
    public let observations = ObservationStore()
    public let ledger: RequestLedger
    public let runs: RunStore
    public let procedures: ProcedureStore
    /// Model exploration for GUI units; set by the host when real GUI input
    /// is on. nil: units replay only.
    public var unitExplorer: UnitExplorer?
    /// Steps a GUI run executed, for learning (RuntimeGuiPorts).
    public var guiRunSteps: (@Sendable (String) -> [JSONValue]?)?
    let execution: ExecutionCoordinator
    let conflicts = ConflictRegistry()
    public let artifacts: ArtifactStore
    public let contract: RuntimeContract
    let startedAt: Date
    let now: @Sendable () -> Date
    /// Serializes Desktop creation, so name checks and limits hold.
    let createLock = NSLock()
    /// Open connections, supplied by the server.
    public var connectionCount: @Sendable () -> Int = { 0 }

    /// Methods that exist only with a desktop platform.
    static let platformMethods: Set<RuntimeMethod> = [
        .desktopCreate, .desktopDestroy, .appLaunch, .windowBind, .windowUnbind,
        .sessionOpen, .sessionShow, .sessionClose, .observe,
        .act, .wait, .runStart, .runAttach, .runFinish, .runShow, .runEvents, .runWait, .runCancel,
        .unitRun,
    ]

    public init(identity: RuntimeIdentity, backend: RuntimeBackend, platform: DesktopPlatform? = nil,
                ledger: RequestLedger? = nil, runs: RunStore? = nil, procedures: ProcedureStore? = nil,
                artifacts: ArtifactStore? = nil,
                desktops: DesktopRegistry = DesktopRegistry(),
                contract: RuntimeContract = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.backend = backend
        self.platform = platform
        self.desktops = desktops
        // In-memory defaults keep a Runtime without storage (tests) whole.
        self.ledger = ledger ?? (try! RequestLedger(path: nil, now: now))
        let runStore = runs ?? (try! RunStore(path: nil, now: now))
        self.runs = runStore
        self.procedures = procedures ?? (try! ProcedureStore(path: nil, now: now))
        self.execution = ExecutionCoordinator(runs: runStore, now: now)
        self.artifacts = artifacts ?? (try! ArtifactStore(
            directory: NSTemporaryDirectory() + "agentdesktop-artifacts-\(getpid())-\(UUID().uuidString.prefix(8))"))
        self.contract = contract
        self.startedAt = Timestamp.date(identity.startedAt) ?? now()
        self.now = now
    }

    func implemented(_ m: RuntimeMethod) -> Bool { platform != nil || !Self.platformMethods.contains(m) }

    var nowString: String { Timestamp.string(now()) }

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
        guard let spec = contract.method(request.method), let method = RuntimeMethod(rawValue: request.method),
              implemented(method) else {
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
        let result: Result<JSONValue, RuntimeError>
        if spec.mutation {
            result = ledgered(request, on: connection)
        } else {
            result = handle(request, on: connection)
        }
        switch result {
        case let .success(data):
            return .success(request.requestId, data)
        case let .failure(error):
            return .failure(request.requestId, error)
        }
    }

    /// The connection is gone: Runs it owned take no further input.
    public func connectionClosed(_ connection: ConnectionState) {
        execution.ownerLost(connection)
    }

    /// An act on behalf of another handler (unit steps), with its own
    /// ledger entry and the same checks as from outside.
    func ledgeredAct(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        ledgered(request, on: c)
    }

    /// A write runs once per caller and requestId; a repeat gets the
    /// original outcome, other content under the same ID is refused.
    private func ledgered(_ request: RuntimeRequest, on connection: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let begin: RequestLedger.Begin
        do {
            begin = try ledger.begin(caller: connection.peerUID, request)
        } catch {
            return .failure(RuntimeError("internal_error", "the request ledger is unavailable: \(error)", phase: .request))
        }
        switch begin {
        case .fresh:
            let result = handle(request, on: connection)
            ledger.finish(caller: connection.peerUID, requestId: request.requestId, result)
            return result
        case let .existing(record):
            return RequestLedger.replay(record)
        case let .conflict(record):
            return .failure(RuntimeError(
                "idempotency_conflict",
                "requestId \(request.requestId) was used for a different \(record.method) request; use a new requestId for a new operation",
                phase: .request, details: .obj([("requestId", .string(request.requestId)), ("originalMethod", .string(record.method))])))
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
                connections: connectionCount(), desktops: desktops.count, sessions: sessions.openCount,
                runs: execution.activeCount).json)

        case .capabilities:
            let methods = contract.methods
                .filter { RuntimeMethod(rawValue: $0.method).map(implemented) ?? false }
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
            return .success(.obj([("desktops", .array(desktops.list().map(desktopJSON)))]))

        case .desktopShow:
            return desktop(p["desktopId"]).map(desktopJSON)

        case .appList:
            let apps = backend.applications(includeBackground: p["includeBackground"]?.boolValue ?? false)
            return .success(.obj([("apps", .array(apps.map(\.json)))]))

        case .windowList:
            let pid = p["pid"]?.intValue.map(Int32.init)
            let windows = backend.windows(pid: pid, bundleId: p["bundleId"]?.stringValue,
                                          includeOffscreen: p["includeOffscreen"]?.boolValue ?? false)
            return .success(.obj([("windows", .array(windows.map(\.json)))]))

        case .desktopCreate: return createDesktop(p)
        case .desktopDestroy: return destroyDesktop(p)
        case .appLaunch: return launchApp(p)
        case .windowBind: return bindWindow(p)
        case .windowUnbind: return unbindWindow(p)
        case .sessionOpen: return openSession(p, connection)
        case .sessionShow: return showSession(p, connection)
        case .sessionClose: return closeSession(p, connection)
        case .observe: return observe(request, connection)
        case .requestShow: return showRequest(p, connection)
        case .act: return act(request, connection)
        case .wait: return wait(request, connection)
        case .runStart: return startRun(request, connection)
        case .runAttach: return attachRun(p, connection)
        case .runFinish: return finishRun(p, connection)
        case .runShow: return showRun(p, connection)
        case .runEvents: return runEvents(p, connection)
        case .runWait: return waitRun(p, connection)
        case .runCancel: return cancelRun(p, connection)
        case .unitRun: return runUnit(request, connection)
        case .procedureList: return listProcedures(p)
        case .procedureShow: return showProcedure(p)
        }
    }
}
