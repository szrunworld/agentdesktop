import AgentDesktopProtocol
import Foundation

/// Who a connection speaks for (A4). The owner is the user: the main window
/// in this process, or a local client that showed the owner credential.
/// A paired app showed its own credential. Anything else is unpaired.
public enum PrincipalRole: String, Sendable {
    case owner, paired, unpaired
}

/// What the Runtime knows about one connection.
public final class ConnectionState: @unchecked Sendable {
    public let peerUID: uid_t
    /// Issued by the Runtime for this channel; changes on every reconnect.
    public let connectionId: String
    /// The principal behind the connection: "local:<uid>" for the owner,
    /// "app:<id>" for a paired app, "unpaired:<connectionId>" otherwise.
    /// Set only by the Runtime, from a credential; never from params.
    public internal(set) var clientId: String
    public internal(set) var role: PrincipalRole
    /// What the server saw of the peer (pid, executable), for pairing.
    public internal(set) var callerFacts: JSONValue = .obj([])
    /// Set by a successful runtime.handshake; every other method needs it.
    public internal(set) var apiVersion: String?
    public internal(set) var clientName: String?
    /// Runs this connection started; its loss stops them.
    var ownedRuns: Set<String> = []
    /// Exec Runs this connection joined with the Run's token.
    var attachedRuns: Set<String> = []
    /// Set by events.subscribe: the server pushes frames on this connection.
    var subscription: EventSubscription?
    public var isSubscribed: Bool { subscription != nil }

    // A4 revocation boundary. Once the owner withdraws this connection's
    // access it is cut: nothing more is sent on it. Every send holds the
    // gate; `cut` first shuts the socket (a send in progress fails rather
    // than finishing later), then marks it under the gate. What was already
    // in the kernel's buffer may still arrive; nothing starts after.
    private let sendGate = NSLock()
    private var cutBy: String?
    private let closerLock = NSLock()
    private var closer: (@Sendable () -> Void)?

    /// Why this connection was cut, if it was.
    public var cutReason: String? { sendGate.withLock { cutBy } }

    /// Send through the gate: false, without sending, once cut.
    public func send(_ write: () -> Bool) -> Bool {
        sendGate.withLock { cutBy == nil ? write() : false }
    }

    /// The server's way to shut this connection's socket; `detach` runs the
    /// server's close under the same lock so a late cut never shuts a
    /// reused descriptor.
    public func attachCloser(_ close: @escaping @Sendable () -> Void) { closerLock.withLock { closer = close } }
    public func detach(_ close: () -> Void) { closerLock.withLock { closer = nil; close() } }

    func cut(_ reason: String) {
        closerLock.withLock { closer?() }
        sendGate.withLock { if cutBy == nil { cutBy = reason } }
    }

    /// A connection inside this process (the main window, the GUI ports):
    /// the owner.
    public init(peerUID: uid_t) {
        self.peerUID = peerUID
        connectionId = "conn_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        clientId = "local:\(peerUID)"
        role = .owner
    }

    /// A socket connection: unpaired until its handshake shows a credential.
    public init(socketPeer uid: uid_t, pid: pid_t?, executable: String?) {
        peerUID = uid
        connectionId = "conn_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        clientId = "unpaired:" + connectionId
        role = .unpaired
        var facts: [(String, JSONValue)] = []
        if let pid { facts.append(("pid", .int(Int(pid)))) }
        if let executable { facts.append(("executable", .string(executable))) }
        callerFacts = .obj(facts)
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
    let execution: ExecutionCoordinator
    let conflicts = ConflictRegistry()
    public let artifacts: ArtifactStore
    /// Accessibility reads, off the main thread, the cooperative pool and
    /// every Desktop lock (RT-23A/B).
    public let axReader = AXReader()
    /// Methods other in-process services answer on this endpoint (ai.*).
    let extensions = ExtensionRegistry()
    /// Paired clients, grants, pairing requests and the authorization audit (A4).
    public let hub: HubStore
    /// What a local client shows in runtime.handshake to act as the owner
    /// (the CLI reads it from `owner.credential` in the records directory).
    public let ownerCredential: String
    /// Open socket connections, for hub.connections.list.
    let openConnections = ConnectionRegistry()
    /// How long one element read may take before an observation goes on
    /// with the screenshot alone (RT-23A).
    public var elementReadBudget: TimeInterval = 5
    /// Tests only: runs on a pushing connection between its access check and
    /// fetching the next frames, to hold a revocation race open.
    var pushCheckpoint: (@Sendable (ConnectionState) -> Void)?
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
        .act, .wait, .runStart, .runAttach, .runFinish, .runShow, .runEvents, .runWait, .runCancel, .runList,
        .eventsSubscribe, .eventsUnsubscribe,
    ]

    public init(identity: RuntimeIdentity, backend: RuntimeBackend, platform: DesktopPlatform? = nil,
                ledger: RequestLedger? = nil, runs: RunStore? = nil, artifacts: ArtifactStore? = nil,
                desktops: DesktopRegistry = DesktopRegistry(), hub: HubStore? = nil, ownerCredential: String? = nil,
                contract: RuntimeContract = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.hub = hub ?? (try! HubStore(path: nil, now: now))
        self.ownerCredential = ownerCredential ?? HubStore.newToken()
        self.backend = backend
        self.platform = platform
        self.desktops = desktops
        // In-memory defaults keep a Runtime without storage (tests) whole.
        self.ledger = ledger ?? (try! RequestLedger(path: nil, now: now))
        let runStore = runs ?? (try! RunStore(path: nil, now: now))
        self.runs = runStore
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
        if let spec = contract.method(request.method), spec.servedBy != nil {
            guard connection.apiVersion != nil else {
                return .failure(request.requestId, RuntimeError(
                    "handshake_required", "send runtime.handshake first on each connection", phase: .handshake))
            }
            guard connection.subscription == nil else {
                return .failure(request.requestId, RuntimeError(
                    "conflict", "this connection carries an event subscription; use another connection or send events.unsubscribe",
                    phase: .handler, details: .obj([("reason", .string("subscribed"))])))
            }
            if let denied = authorization(request, connection) { return .failure(request.requestId, denied) }
            guard let handler = extensions.handler(request.method) else {
                return .failure(request.requestId, .capabilityMissing("\(request.method) is not available: the \(spec.servedBy!) is not running"))
            }
            // Reads go straight to the service. A write's requestId is unique
            // per caller across every method (runtime/1 §1): the ledger
            // replays a done write, refuses the same id for another method or
            // other params, and keeps an unknown outcome unknown.
            guard spec.mutation else { return answerExtension(request, handler, on: connection) }
            return ledgeredExtension(request, handler, on: connection)
        }
        guard let spec = contract.method(request.method), let method = RuntimeMethod(rawValue: request.method),
              implemented(method) else {
            return .failure(request.requestId, .capabilityMissing("method \(request.method) is not available in this Runtime"))
        }
        if connection.apiVersion == nil, request.method != RuntimeMethod.handshake.rawValue {
            return .failure(request.requestId, RuntimeError(
                "handshake_required", "send runtime.handshake first on each connection", phase: .handshake))
        }
        if connection.subscription != nil, method != .eventsUnsubscribe {
            return .failure(request.requestId, RuntimeError(
                "conflict", "this connection carries an event subscription; use another connection or send events.unsubscribe",
                phase: .handler, details: .obj([("reason", .string("subscribed"))])))
        }
        if method != .handshake, let denied = authorization(request, connection) {
            return .failure(request.requestId, denied)
        }
        let paramViolations = contract.validate(request.params, spec.params)
        guard paramViolations.isEmpty else {
            return .failure(request.requestId, .schemaInvalid("params break \(spec.params)", violations: paramViolations))
        }
        var result: Result<JSONValue, RuntimeError>
        if spec.mutation {
            result = ledgered(request, on: connection)
        } else {
            result = handle(request, on: connection)
            // A read that took a while (wait, run.wait, observe) answers only
            // if the caller may still see the answer. A write reports what
            // happened, as recorded in the ledger.
            if case .success = result, let lost = accessLost(request, connection) { result = .failure(lost) }
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
        openConnections.remove(connection)
        execution.ownerLost(connection)
    }

    /// A write runs once per caller and requestId; a repeat gets the
    /// original outcome, other content under the same ID is refused.
    private func ledgered(_ request: RuntimeRequest, on connection: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let begin: RequestLedger.Begin
        do {
            begin = try ledger.begin(caller: connection.clientId, request)
        } catch {
            execution.auditStorageFailed()
            return .failure(ExecutionCoordinator.auditError(notSent: true))
        }
        switch begin {
        case .fresh:
            var result: Result<JSONValue, RuntimeError> = execution.auditUnavailable
                ? .failure(ExecutionCoordinator.auditError(notSent: true))
                : handle(request, on: connection)
            do { try runs.checkWritable() } catch {
                execution.auditStorageFailed()
                if case .success = result { result = .failure(ExecutionCoordinator.auditError()) }
            }
            do {
                try ledger.finish(caller: connection.clientId, requestId: request.requestId, result)
            } catch {
                execution.auditStorageFailed()
                // A failure before dispatch can still say notSent. After
                // dispatch, never turn an unsaved outcome into permission to retry.
                let notSent: Bool? = {
                    if case let .failure(e) = result, e.notSent == true { return true }
                    return nil
                }()
                return .failure(ExecutionCoordinator.auditError(notSent: notSent))
            }
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
            if let refused = authenticate(p["credential"], connection) { return .failure(refused) }
            connection.apiVersion = chosen
            connection.clientName = p["client"]?["name"]?.stringValue
            openConnections.add(connection, at: nowString)
            var id = identity
            id.apiVersion = chosen
            return .success(id.json.setting("principal", principalJSON(connection)))

        case .status:
            return .success(RuntimeStatus(
                instanceId: identity.instanceId, state: "running", startedAt: identity.startedAt,
                uptimeSeconds: max(0, now().timeIntervalSince(startedAt)),
                connections: connectionCount(), desktops: desktops.count, sessions: sessions.openCount,
                runs: execution.activeCount).json.setting("inputAdmission", .string(execution.inputAdmission.rawValue)))

        case .capabilities:
            let served = extensions.names
            let methods = contract.methods
                .filter { RuntimeMethod(rawValue: $0.method).map(implemented) ?? served.contains($0.method) }
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
            ] + extensions.capabilitySections()))

        case .desktopList:
            // A paired app sees only the Desktops its grant covers.
            let visible = desktops.list().filter { desktopAllowed(connection, $0.desktopId) }
            return .success(.obj([("desktops", .array(visible.map(desktopJSON)))]))

        case .desktopShow:
            return desktop(p["desktopId"]).map(desktopJSON)

        case .appList:
            // A paired app sees only the apps its grant names, not the user's others.
            let apps = backend.applications(includeBackground: p["includeBackground"]?.boolValue ?? false)
                .filter { appAllowed(connection, bundleId: $0.bundleId) }
            return .success(.obj([("apps", .array(apps.map(\.json)))]))

        case .windowList:
            let pid = p["pid"]?.intValue.map(Int32.init)
            let windows = backend.windows(pid: pid, bundleId: p["bundleId"]?.stringValue,
                                          includeOffscreen: p["includeOffscreen"]?.boolValue ?? false)
                .filter { appAllowed(connection, bundleId: $0.bundleId) }
            return .success(.obj([("windows", .array(windows.map(\.json)))]))

        case .desktopCreate: return createDesktop(p, connection)
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
        case .runList: return listRuns(p, connection)
        case .stopAll: return stopAll(connection)
        case .enableInput: return enableInput(connection)
        case .artifactShow: return showArtifact(p, connection)
        case .artifactRead: return readArtifact(p, connection)
        case .eventsSubscribe: return subscribe(p, connection)
        case .eventsUnsubscribe: return unsubscribe(connection)
        case .pairingStart: return startPairing(p, connection)
        case .pairingStatus: return pairingStatus(p, connection)
        case .pairingApprove: return approvePairing(p, connection)
        case .pairingDeny: return denyPairing(p, connection)
        case .clientsList: return listClients()
        case .clientsShow: return showClient(p)
        case .clientsRevoke: return revokeClient(p, connection)
        case .grantsList: return listGrants()
        case .grantsSet: return setGrant(p, connection)
        case .grantsRevoke: return revokeGrant(p, connection)
        case .connectionsList: return listConnections()
        }
    }
}
