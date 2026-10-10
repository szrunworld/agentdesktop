import AgentDesktopProtocol
import Foundation

/// Who a connection speaks for (A4). The owner is the user: the main window
/// in this process, or a local client that showed the owner credential.
/// A paired app showed its own credential. Anything else is unpaired.
public enum PrincipalRole: String, Sendable {
    case owner, paired, unpaired
}

/// What the Runtime knows about one connection.
/// Where a connection comes from, as the Runtime saw it. Never taken from
/// anything the client sends.
public enum ConnectionOrigin: String, Sendable {
    /// Built inside this process: the main window, the GUI ports.
    case host
    /// Accepted by RuntimeServer on the socket: any local client.
    case socket
}

public final class ConnectionState: @unchecked Sendable {
    public let peerUID: uid_t
    /// Where the connection comes from, as the Runtime saw it (#153's
    /// interface); nothing on the wire changes it.
    public let origin: ConnectionOrigin
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

    /// The kernel's audit token of the socket peer, and the code identity
    /// the Runtime read from it at connect (A4 S2). In-process: none.
    public internal(set) var peerAuditToken: Data?
    public internal(set) var codeIdentity: CodeIdentity = .inProcess

    /// A paired client's one owner-only call the user just confirmed: the
    /// connection acts as the owner for that request only (respond clears it).
    private(set) var elevatedFor: String?
    /// The target grant revision the user approved a change of (if any).
    private(set) var approvedTargetRevision: Int?
    func elevate(_ requestId: String, targetRevision: Int? = nil) { elevatedFor = requestId; approvedTargetRevision = targetRevision }
    func endElevation() { elevatedFor = nil; approvedTargetRevision = nil }

    func cut(_ reason: String) {
        closerLock.withLock { closer?() }
        sendGate.withLock { if cutBy == nil { cutBy = reason } }
    }

    /// A connection inside this process (the main window, the GUI ports):
    /// the owner.
    package init(peerUID: uid_t) {
        self.peerUID = peerUID
        origin = .host
        connectionId = "conn_" + UUID().uuidString.lowercased().replacingOccurrences(of: "-", with: "").prefix(16)
        clientId = "local:\(peerUID)"
        role = .owner
    }

    /// A socket connection: unpaired until its handshake shows a credential.
    public init(socketPeer uid: uid_t, pid: pid_t? = nil, executable: String? = nil) {
        peerUID = uid
        origin = .socket
        codeIdentity = .unknown
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
    let quotaBucketLock = NSLock()
    var quotaBuckets: [String: String] = [:]
    /// Requests whose reserved place a registered screenshot now holds.
    var quotaBucketsUsed: Set<String> = []
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
    /// Tests only. The owner is the host's own window (in-process
    /// connections); no socket client is ever the owner (A4 S1). A test that
    /// drives owner-only methods over a socket passes a token here; the
    /// product (RuntimeService.persistent) never does, so no credential,
    /// file or environment variable can make a socket client the owner.
    let testSocketOwnerToken: String?
    /// Open socket connections, for hub.connections.list.
    let openConnections = ConnectionRegistry()
    /// How long one element read may take before an observation goes on
    /// with the screenshot alone (RT-23A).
    public var elementReadBudget: TimeInterval = 5
    /// The host's trusted confirmation window (A4 S1); nil refuses every
    /// confirmation. Set before the server starts.
    public var confirmer: TrustedConfirmer?
    let confirmationGate = ConfirmationGate()
    let accessObservers = AccessObservers()
    /// Called with a clientId whose access was revoked (A4 R4).
    public func onAccessWithdrawn(_ observer: @escaping @Sendable (String) -> Void) { accessObservers.add(observer) }
    /// Reads socket peers' code identities (A4 S2); tests replace it.
    public var codeVerifier: CodeIdentityVerifier = SecurityCodeIdentityVerifier()
    /// Tests only: runs on a pushing connection between its access check and
    /// fetching the next frames, to hold a revocation race open.
    var pushCheckpoint: (@Sendable (ConnectionState) -> Void)?
    /// Physical Desktops attach one of the user's own displays. Open since
    /// Kevin's ruling of 2026-10-10 (owner-display-attach.md): window grants
    /// (#205) let the user authorize observing, acting on and keeping each
    /// window separately, and only the owner attaches a display (A4), from
    /// the Agent Desktop window with Touch ID. Attaching shows no window:
    /// every one still needs its own grant. Tests turn it off to keep
    /// covering the refusal.
    var physicalDesktopsEnabled = true
    /// Until grants (PR3): window.bind on a virtual Desktop only takes a
    /// process that app.launch started on that Desktop, so no local client
    /// can pull one of the user's windows onto an agent screen and read or
    /// drive it there. Tests turn this off; the product never does.
    var bindsOnlyLaunchedProcesses = true
    /// Until a screen-level grant exists: an observation of a Desktop with no
    /// bound window takes no screenshot (the whole screen carries the menu
    /// bar, notifications and any window dragged there). Tests turn this
    /// off; the product never does.
    var refusesScreenCaptureWithoutBinding = true
    /// How long a request without a deadline waits for a busy Desktop
    /// (RuntimeService.desktopLockWait); tests shorten it.
    var desktopLockWait = RuntimeService.desktopLockWait
    /// How long a screenshot taken under a window grant without persist is
    /// kept (window-grants.md); tests shorten it.
    var transientArtifactLifetime = RuntimeService.transientArtifactSeconds
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
        .eventsSubscribe, .eventsUnsubscribe, .displaysList, .displaysAttach, .displaysDetach,
    ]

    public init(identity: RuntimeIdentity, backend: RuntimeBackend, platform: DesktopPlatform? = nil,
                ledger: RequestLedger? = nil, runs: RunStore? = nil, artifacts: ArtifactStore? = nil,
                desktops: DesktopRegistry = DesktopRegistry(), hub: HubStore? = nil, testSocketOwnerToken: String? = nil,
                contract: RuntimeContract = .shared, now: @escaping @Sendable () -> Date = { Date() }) {
        self.identity = identity
        self.hub = hub ?? (try! HubStore(path: nil, now: now))
        self.testSocketOwnerToken = testSocketOwnerToken
        self.backend = backend
        self.platform = platform
        self.desktops = desktops
        // In-memory defaults keep a Runtime without storage (tests) whole.
        self.ledger = ledger ?? (try! RequestLedger(path: nil, now: now))
        let runStore = runs ?? (try! RunStore(path: nil, now: now))
        self.runs = runStore
        self.execution = ExecutionCoordinator(runs: runStore, now: now)
        self.artifacts = artifacts ?? {
            let scratch = try! ArtifactStore(
                directory: NSTemporaryDirectory() + "agentdesktop-artifacts-\(getpid())-\(UUID().uuidString.prefix(8))")
            scratch.removesDirectoryWhenDone = true
            return scratch
        }()
        self.contract = contract
        // Desktops do not outlive the process that made them, so no window
        // grant on one does either (window-grants.md).
        // Each one audited like any other ending (Codex on 9ea0dad).
        for id in (try? self.hub.endWindowGrants(reason: "runtime_restarted")) ?? [] {
            self.hub.audit(connectionId: "runtime", clientId: self.hub.windowGrant(id)?.clientId ?? "?", method: "hub.windows",
                           decision: "ended", reason: "\(id) runtime_restarted")
        }
        self.startedAt = Timestamp.date(identity.startedAt) ?? now()
        self.now = now
        // The sweep never removes what the Runtime still uses: the
        // screenshot of an observation it holds, or anything of a Run that
        // has not ended. A Runtime already gone keeps everything.
        self.artifacts.retained = { [weak self] artifactId, runId in
            guard let self else { return true }
            if self.observations.find("obs_" + artifactId.dropFirst("art_".count)) != nil { return true }
            // Only a Run the Runtime knows and that has not ended keeps its
            // artifacts; an unknown runId keeps nothing.
            if let runId, let run = self.runs.find(runId), run.phase != .ended { return true }
            return false
        }
    }

    func implemented(_ m: RuntimeMethod) -> Bool { platform != nil || !Self.platformMethods.contains(m) }

    var nowString: String { Timestamp.string(now()) }

    public func respond(to line: Data, on connection: ConnectionState) -> RuntimeResponse {
        // An owner call a user confirmed for a paired client ends with it.
        defer { connection.endElevation() }
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
            let response = spec.mutation ? ledgeredExtension(request, handler, on: connection)
                                         : answerExtension(request, handler, on: connection)
            // Access withdrawn while the service worked (round-four review
            // M2): what it started for this caller after the revocation's
            // sweep is cancelled now, and the answer is not given.
            if connection.role == .paired {
                let lost = accessError(connection, method: "runtime.status")
                let cut = connection.cutReason
                // Only a withdrawal (revoked, expired) cancels the client's work
                // again; a narrowing only cut this connection (round-five Low-2).
                if lost != nil || cut == "client_revoked" || cut == "grant_revoked" {
                    accessWithdrawn(connection.clientId)
                }
                if let refusal = lost ?? cut.map({ Self.cutError(connection, $0) }), case .success = response.result {
                    return .failure(request.requestId, spec.mutation ? Self.writeDone(refusal, request.requestId) : refusal)
                }
            }
            return response
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
        hub.expirePairings(connectionId: connection.connectionId)
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
            // A socket connection says who it is once (review L4).
            if connection.origin == .socket, connection.apiVersion != nil {
                return .failure(RuntimeError("conflict", "this connection already completed its handshake; open a new one",
                                             phase: .handshake, notSent: true, details: .obj([("reason", .string("already_handshaken"))])))
            }
            if let refused = authenticate(p["credential"], connection) { return .failure(refused) }
            connection.apiVersion = chosen
            connection.clientName = p["client"]?["name"]?.stringValue
            openConnections.add(connection, at: nowString)
            // Revoked between the credential check and the registration: the
            // revocation could not cut it, so it is refused here (review L5).
            if connection.role == .paired, hub.client(connection.clientId)?.state != "active" {
                openConnections.remove(connection)
                connection.cut("client_revoked")
                return .failure(Self.cutError(connection, "client_revoked"))
            }
            var id = identity
            id.apiVersion = chosen
            return .success(id.json.setting("principal", principalJSON(connection)))

        case .status:
            // A paired app counts what it may see (#153's note: global counts
            // told it about the host's Desktops, sessions and Runs).
            let paired = connection.role == .paired
            return .success(RuntimeStatus(
                instanceId: identity.instanceId, state: "running", startedAt: identity.startedAt,
                uptimeSeconds: max(0, now().timeIntervalSince(startedAt)),
                connections: paired ? openConnections.all.filter { $0.connection.clientId == connection.clientId }.count : connectionCount(),
                desktops: paired ? desktops.list().filter { desktopAllowed(connection, $0.desktopId) }.count : desktops.count,
                sessions: paired ? sessions.openCount(caller: connection.clientId) : sessions.openCount,
                runs: paired ? activeRuns(of: connection.clientId).count : execution.activeCount)
                .json.setting("inputAdmission", .string(execution.inputAdmission.rawValue)))

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
            // A paired app sees only the Desktops its grant covers, and of a
            // bound window only one it may reach (window-grants.md).
            let visible = desktops.list().filter { desktopAllowed(connection, $0.desktopId) }
            return .success(.obj([("desktops", .array(visible.map { desktopJSON($0, for: connection) }))]))

        case .desktopShow:
            return desktop(p["desktopId"]).map { desktopJSON($0, for: connection) }

        case .appList:
            // A paired app sees only the apps its grant names, not the user's others.
            let apps = backend.applications(includeBackground: p["includeBackground"]?.boolValue ?? false)
                .filter { appAllowed(connection, bundleId: $0.bundleId) }
            return .success(.obj([("apps", .array(apps.map(\.json)))]))

        case .windowList:
            let pid = p["pid"]?.intValue.map(Int32.init)
            // A paired app sees only windows it holds a window grant for and
            // windows of launches it made: never every window of a granted app.
            let windows = backend.windows(pid: pid, bundleId: p["bundleId"]?.stringValue,
                                          includeOffscreen: p["includeOffscreen"]?.boolValue ?? false)
                .filter { connection.role != .paired || visibleToPaired(connection, $0) }
            return .success(.obj([("windows", .array(windows.map(\.json)))]))

        case .desktopCreate: return createDesktop(p, connection)
        case .desktopDestroy: return destroyDesktop(p, connection)
        case .appLaunch: return launchApp(p, connection)
        case .windowBind: return bindWindow(p, connection)
        case .windowUnbind: return unbindWindow(p, connection)
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
        case .windowsRequest: return requestWindowGrant(p, connection)
        case .windowsList: return listWindowGrants(p, connection)
        case .windowsRevoke: return revokeWindowGrant(p, connection)
        case .displaysList: return listDisplays(connection)
        case .displaysAttach: return attachDisplay(p, connection)
        case .displaysDetach: return detachDisplay(p, connection)
        }
    }
}

extension RuntimeService {
    /// A write the service answered as done, whose caller lost its access
    /// meanwhile (#203): the answer is still withheld, but the refusal never
    /// says not performed (runtime-api-v1-freeze §1.1). The service's success
    /// is the evidence; the ledger usually holds it completed too, but its
    /// write is best effort (b9 on f2d89bf).
    ///
    /// How to find the outcome depends on the code (Codex on 38edddd): an
    /// expired or narrowed grant keeps the client's id, so the same requestId
    /// reads the ledger again; a removed client can only pair again, under a
    /// new id the ledger does not know, so the same requestId would be a new
    /// write there. `details.recovery` says which.
    static func writeDone(_ refusal: RuntimeError, _ requestId: String) -> RuntimeError {
        var e = refusal
        e.notSent = false
        let revoked = refusal.code == "client_revoked"
        e.message += "; the write was done before access was withdrawn (requestId \(requestId)), only its answer is withheld. "
            + (revoked
                ? "Pairing again gives a new client that cannot look this request up: check the outcome first and do not submit it again"
                : "Once access is back, ask again with the same requestId; a new requestId would write again")
        e.details = .obj((refusal.details?.objectMembers ?? []) + [
            ("writeOutcome", .string("completed")),
            ("recovery", .string(revoked ? "check_outcome_do_not_resubmit" : "look_up_same_request_id")),
        ])
        return e
    }
}
