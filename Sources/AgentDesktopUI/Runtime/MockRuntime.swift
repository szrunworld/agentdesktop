import AgentDesktopProtocol
import CommonCrypto
import CoreGraphics
import Foundation
import ImageIO

/// A stand-in Runtime for developing and testing the main window before
/// the in-process adapter exists (09 brief: "API 未实现时用 Mock Adapter").
///
/// Rules it keeps:
/// - It answers only methods of the implemented catalog; reserved and
///   frozen names get `capability_missing`, exactly as a Runtime without
///   them would. Of the implemented ones it models a subset and advertises
///   only that subset in `runtime.capabilities`.
/// - Every `params` is checked against the method's params schema and every
///   result against its result schema before it is returned; a result that
///   breaks the contract is a programming error recorded in
///   `contractViolations` and answered as `internal_error`. Since the
///   runtime/1 objects are `additionalProperties: false`, nothing outside
///   the contract (Desktop.control, businessResult, …) can pass.
/// - `isSample` is true: the shell marks every screen fed by it.
public final class MockRuntime: RuntimePort, @unchecked Sendable {
    public let isSample = true

    /// Methods this mock models; a subset of `RuntimeCatalog.implemented`.
    public static let modeled: [String] = [
        "runtime.handshake", "runtime.status", "runtime.capabilities", "runtime.stopAll", "runtime.enableInput",
        "desktop.list", "desktop.show", "desktop.create", "desktop.destroy",
        "app.list", "window.list", "app.launch", "window.bind",
        "observe", "artifact.show", "artifact.read",
        "run.list", "run.show", "run.events", "run.cancel",
        "request.show",
        "hub.clients.list", "hub.grants.list", "hub.displays.list", "hub.displays.attach", "hub.displays.detach",
    ]

    private let lock = NSLock()
    private let contract = RuntimeContract.shared
    private let base: Date
    private var clock: TimeInterval = 0

    private var desktops: [JSONValue] = []
    /// The user's displays (HubDisplay without the computed fields) and the
    /// paired clients with their grants, for the owner's display entry.
    private var displays: [JSONValue] = []
    private var clients: [JSONValue] = []
    /// Windows not on any Desktop (window.list, window.bind), and apps that
    /// app.launch can start; both neutral, never a real user app.
    private var freeWindows: [JSONValue] = []
    private var launchable: Set<String> = ["com.example.probe"]
    private var artifactsById: [String: (meta: JSONValue, bytes: Data)] = [:]
    private var observationCount = 0
    private var runs: [JSONValue] = []
    private var requests: [String: JSONValue] = [:]
    /// Global event log: (cursor, RunEvent).
    private var events: [(cursor: Int, event: JSONValue)] = []
    private var eventFloor = 0
    private var runSequences: [String: Int] = [:]
    private var admission = "enabled"
    private var nextId = 1
    private var subscribers: [UUID: AsyncThrowingStream<JSONValue, Error>.Continuation] = [:]
    private var queuedFailures: [String: [RuntimeError]] = [:]

    /// Calls answered, in order (method names); tests read it.
    public private(set) var callLog: [String] = []
    /// Results the mock tried to return that broke the contract.
    public private(set) var contractViolations: [String] = []

    /// When true every call fails with `runtime_offline` (Disconnected state).
    public var offline: Bool {
        get { lock.withLock { _offline } }
        set { lock.withLock { _offline = newValue } }
    }
    private var _offline = false

    /// Permission states reported in `runtime.capabilities`.
    /// Whether `events.subscribe` is offered (advertised and answered).
    public var subscriptionEnabled = true

    public var screenRecording = "granted"
    public var accessibility = "granted"

    public init(base: Date = Date(timeIntervalSince1970: 1_791_446_400)) {
        self.base = base
    }

    // MARK: Scenario building (only contract fields)

    /// Adds a Desktop; returns its desktopId.
    @discardableResult
    public func addDesktop(name: String, width: Int = 1280, height: Int = 800, state: String = "ready",
                           app: String? = nil, windowId: Int = 4100) -> String {
        lock.withLock {
            let id = "desk_" + String(format: "%03d", desktops.count + 1)
            desktops.append(desktopJSON(id: id, name: name, width: width, height: height, state: state,
                                        app: app, windowId: windowId + desktops.count))
            return id
        }
    }

    /// Adds one of the user's displays as the Runtime would prove it.
    public func addDisplay(id: Int, name: String, width: Int = 1512, height: Int = 982, x: Int = 0, hiDPI: Bool = true,
                           builtin: Bool = true, origin: String = "physical", detail: String? = nil) {
        lock.withLock {
            var m: [(String, JSONValue)] = [
                ("displayId", .int(id)), ("name", .string(name)),
                ("frame", .obj([("x", .int(x)), ("y", .int(0)), ("width", .int(width)), ("height", .int(height))])),
                ("hiDPI", .bool(hiDPI)), ("builtin", .bool(builtin)), ("origin", .string(origin)),
            ]
            if let detail { m.append(("originDetail", .string(detail))) }
            displays.append(.obj(m))
        }
    }

    /// Adds a paired client with an active grant; returns its clientId.
    @discardableResult
    public func addClient(name: String, capabilities: [String] = ["observe", "act", "desktop.manage"], apps: [String] = []) -> String {
        lock.withLock {
            let id = "app:mock-" + String(format: "%03d", clients.count + 1)
            let grant: JSONValue = .obj([
                ("clientId", .string(id)), ("capabilities", .array(capabilities.map(JSONValue.string))),
                ("desktops", .array([.string("created")])), ("apps", .array(apps.map(JSONValue.string))),
                ("expiresAt", .string(Timestamp.string(base.addingTimeInterval(3600)))), ("revision", .int(1)), ("state", .string("active")),
            ])
            clients.append(.obj([
                ("clientId", .string(id)), ("agentName", .string(name)), ("publisher", .null), ("callerFacts", .obj([])),
                ("codeIdentity", .obj([("level", .string("same_user")), ("hardenedRuntime", .bool(false))])),
                ("state", .string("active")), ("registeredAt", .string(stamp())), ("grant", grant), ("connections", .array([])),
            ]))
            return id
        }
    }

    /// Adds a Run on a Desktop; returns its runId.
    @discardableResult
    public func addRun(desktopId: String, kind: String = "act", origin: String = "agent_hub", phase: String = "running",
                       outcome: String? = nil, receipts: Int = 0, unknownActions: Int = 0) -> String {
        lock.withLock {
            let runId = "run_" + String(format: "%03d", runs.count + 1)
            let platform = origin == "gui_explorer" || origin == "user"
            let ended = phase == "ended"
            var m: [(String, JSONValue)] = [
                ("runId", .string(runId)), ("kind", .string(kind)), ("origin", .string(origin)),
                ("ownership", .string(platform ? "platform" : "external_client")),
                ("lifetime", .string(platform ? "platform_durable" : "connection_scoped")),
                ("clientId", platform ? .null : .string("local:501")),
                ("connectionId", platform ? .null : .string("conn_\(runId)")),
                ("sessionId", .string("ses_\(runId)")), ("desktopId", .string(desktopId)),
                ("phase", .string(phase)), ("outcome", outcome.map(JSONValue.string) ?? .null),
                ("quiescence", .string(ended ? "confirmed" : phase == "stopping" ? "pending" : "not_confirmed")),
                ("closingReason", ended ? .string(outcome == "cancelled" ? "cancelled" : "finished") : .null),
                ("revision", .int(1)), ("createdAt", .string(stamp())),
                ("receipts", .array((0..<receipts).map { .string("rcpt_\(runId)_\($0 + 1)") })),
                ("unknownActions", .int(unknownActions)),
            ]
            if ended { m.append(("endedAt", .string(stamp()))) }
            runs.append(.obj(m))
            appendEventLocked(runId, "run.started", .obj([("kind", .string(kind)), ("origin", .string(origin)),
                ("ownership", .string(platform ? "platform" : "external_client")),
                ("lifetime", .string(platform ? "platform_durable" : "connection_scoped")),
                ("desktopId", .string(desktopId)), ("sessionId", .string("ses_\(runId)"))]))
            return runId
        }
    }

    /// Records an `act` request with its receipt (or error) and the matching
    /// `action.*` events; returns the requestId.
    @discardableResult
    public func addAction(runId: String, delivery: String, execution: String, errorCode: String? = nil,
                          state: String? = nil) -> String {
        lock.withLock {
            let requestId = "req_" + String(format: "%03d", requests.count + 1)
            guard let run = runs.first(where: { $0["runId"]?.stringValue == runId }) else { return requestId }
            let accepted = stamp()
            appendEventLocked(runId, "action.accepted", .obj([("requestId", .string(requestId)), ("kind", .string("click"))]))
            let receipt = receiptJSON(run: run, requestId: requestId, delivery: delivery, execution: execution, acceptedAt: accepted)
            if delivery != "not_dispatched" {
                appendEventLocked(runId, "action.dispatched", .obj([("requestId", .string(requestId))]))
            }
            appendEventLocked(runId, "action.\(execution)", .obj([("receipt", receipt)]))
            var outcome: JSONValue = receipt
            if let errorCode {
                outcome = .obj([("error", RuntimeError(errorCode, Self.mockMessage(errorCode), phase: .handler,
                                                        notSent: delivery == "not_dispatched" ? true : nil,
                                                        details: .obj([("receipt", receipt)])).json)])
            }
            let recordState = state ?? (execution == "completed" ? "completed" : execution == "unknown" ? "unknown" : "failed")
            requests[requestId] = .obj([
                ("requestId", .string(requestId)), ("method", .string("act")), ("state", .string(recordState)),
                ("acceptedAt", .string(accepted)), ("finishedAt", .string(stamp())), ("outcome", outcome),
            ])
            return requestId
        }
    }

    /// A request accepted but not finished (no receipt yet).
    @discardableResult
    public func addAcceptedRequest(method: String = "act") -> String {
        lock.withLock {
            let requestId = "req_" + String(format: "%03d", requests.count + 1)
            requests[requestId] = .obj([("requestId", .string(requestId)), ("method", .string(method)),
                                        ("state", .string("accepted")), ("acceptedAt", .string(stamp()))])
            return requestId
        }
    }

    /// The execution side confirms a stopping Run is quiet: ended/confirmed.
    /// As `ExecutionCoordinator.settle`: the Run keeps the closing reason its
    /// stop recorded, and a Run with an unknown action ends unknown.
    public func confirmQuiescence(_ runId: String, outcome: String = "cancelled") {
        lock.withLock {
            updateRunLocked(runId) { r in
                r.setting("phase", .string("ended")).setting("quiescence", .string("confirmed"))
                    .setting("outcome", .string((r["unknownActions"]?.intValue ?? 0) > 0 ? "unknown" : outcome))
                    .setting("closingReason", r["closingReason"].flatMap { $0 == .null ? nil : $0 } ?? .string("stopped"))
                    .setting("endedAt", .string(stamp()))
            }
            let ended = runs.first(where: { $0["runId"]?.stringValue == runId })
            appendEventLocked(runId, "run.quiescent", .obj([("revision", ended?["revision"] ?? .int(1))]))
            appendEventLocked(runId, "run.ended", .obj([("phase", .string("ended")), ("outcome", ended?["outcome"] ?? .string(outcome)),
                                                       ("reason", ended?["closingReason"] ?? .string("stopped"))]))
        }
    }

    /// The next call of `method` fails with `code`.
    public func failNext(_ method: String, code: String) {
        lock.withLock { queuedFailures[method, default: []].append(RuntimeError(code, Self.mockMessage(code), phase: .handler)) }
    }

    /// Drops stored events up to `cursor` (to exercise events_cursor_expired).
    public func trimEvents(through cursor: Int) {
        lock.withLock {
            events.removeAll { $0.cursor <= cursor }
            eventFloor = max(eventFloor, cursor)
        }
    }

    public var latestCursor: Int { lock.withLock { events.last?.cursor ?? eventFloor } }

    /// Three neutral Desktops, two with an active Run, plus past Runs and
    /// actions in each delivery state. No business app (09 brief).
    public static func sample() -> MockRuntime {
        let m = MockRuntime()
        let form = m.addDesktop(name: "Web 表单验证", app: "Safari")
        let notes = m.addDesktop(name: "文本编辑", app: "TextEdit")
        _ = m.addDesktop(name: "计算器", app: "Calculator")
        m.addDisplay(id: 1, name: "内建显示器")
        m.addDisplay(id: 9, name: "Virtual Display", width: 1920, height: 1080, x: 1512, hiDPI: false, builtin: false,
                     origin: "virtual", detail: "an engine virtual display (vendor 0x3256, model 2)")
        m.addClient(name: "微信助手", apps: ["com.tencent.xinWeChat"])
        let past = m.addRun(desktopId: form, phase: "ended", outcome: "success", receipts: 1)
        m.addAction(runId: past, delivery: "dispatched", execution: "completed")
        let a = m.addRun(desktopId: form, receipts: 3)
        m.addAction(runId: a, delivery: "dispatched", execution: "completed")
        m.addAction(runId: a, delivery: "not_dispatched", execution: "failed", errorCode: "target_moved")
        m.addAction(runId: a, delivery: "dispatched", execution: "completed")
        let b = m.addRun(desktopId: notes, receipts: 2)
        m.addAction(runId: b, delivery: "dispatched", execution: "completed")
        m.addAction(runId: b, delivery: "unknown", execution: "unknown")
        return m
    }

    /// A window of a neutral app that is on no Desktop (to bind).
    @discardableResult
    public func addFreeWindow(app: String = "Probe", title: String = "Probe A", pid: Int = 4242, windowId: Int = 9001) -> Int {
        lock.withLock {
            freeWindows.append(.obj([
                ("windowId", .int(windowId)), ("process", .obj([("pid", .int(pid)), ("startedAt", .string(Timestamp.string(base)))])),
                ("appName", .string(app)), ("bundleId", .string("com.example.probe")), ("title", .string(title)),
                ("frame", .obj([("x", .int(100)), ("y", .int(100)), ("width", .int(400)), ("height", .int(328))])),
                ("onScreen", .bool(true)),
            ]))
            return windowId
        }
    }

    /// Optional pause before answering a method (shows in-flight states).
    public var delays: [String: UInt64] {
        get { lock.withLock { _delays } }
        set { lock.withLock { _delays = newValue } }
    }
    private var _delays: [String: UInt64] = [:]

    /// Number of observations taken (each has its own snapshotId).
    public var observations: Int { lock.withLock { observationCount } }

    // MARK: RuntimePort

    public func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        if let ns = delays[method] { try? await Task.sleep(nanoseconds: ns) }
        return try lock.withLock { try callLocked(method, params, context: context) }
    }

    public func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        try lock.withLock {
            callLog.append("events.subscribe")
            if _offline { throw RuntimeError.runtimeOffline("mock runtime is offline", endpoint: "mock") }
            guard subscriptionEnabled else { throw RuntimeError.capabilityMissing("method events.subscribe is not available in this Runtime") }
            let latest = events.last?.cursor ?? eventFloor
            if let after, after < eventFloor || after > latest {
                throw RuntimeError("events_cursor_expired", "cursor \(after) is outside the stored events",
                                   phase: .handler, details: .obj([("latest", .int(latest))]))
            }
            let start = after ?? latest
            let (stream, continuation) = AsyncThrowingStream<JSONValue, Error>.makeStream()
            for e in events where e.cursor > start { continuation.yield(frame(e)) }
            let key = UUID()
            subscribers[key] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { _ = self.subscribers.removeValue(forKey: key) }
            }
            return stream
        }
    }

    /// Ends every open subscription with an error (connection loss).
    public func dropSubscriptions(code: String = "connection_lost") {
        let conts = lock.withLock { () -> [AsyncThrowingStream<JSONValue, Error>.Continuation] in
            let c = Array(subscribers.values)
            subscribers.removeAll()
            return c
        }
        for c in conts { c.finish(throwing: RuntimeError(code, Self.mockMessage(code), phase: .transport)) }
    }

    public var subscriberCount: Int { lock.withLock { subscribers.count } }

    // MARK: Dispatch

    private func callLocked(_ method: String, _ params: JSONValue, context: RequestContext) throws -> JSONValue {
        callLog.append(method)
        if _offline { throw RuntimeError.runtimeOffline("mock runtime is offline", endpoint: "mock") }
        guard let spec = contract.method(method) else {
            throw RuntimeError.capabilityMissing("method \(method) is not available in this Runtime")
        }
        guard Self.modeled.contains(method) else {
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
        let violations = contract.validate(params, spec.params)
        guard violations.isEmpty else { throw RuntimeError.schemaInvalid("params break \(spec.params)", violations: violations) }
        if var queue = queuedFailures[method], !queue.isEmpty {
            let e = queue.removeFirst()
            queuedFailures[method] = queue
            throw e
        }
        let result = try handle(method, params, context: context)
        let broken = contract.validate(result, spec.result)
        guard broken.isEmpty else {
            contractViolations.append("\(method): \(broken.joined(separator: "; "))")
            throw RuntimeError("internal_error", "mock result breaks \(spec.result)", phase: .handler)
        }
        return result
    }

    private func handle(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        switch method {
        case "runtime.handshake":
            return .obj([
                ("product", .string("AgentDesktop")), ("productVersion", .string(RuntimeAPI.productVersion)),
                ("apiVersion", .string(RuntimeAPI.version)), ("apiVersions", .array([.string(RuntimeAPI.version)])),
                ("instanceId", .string("rt_mock")), ("pid", .int(1)), ("startedAt", .string(Timestamp.string(base))),
                ("endpoint", .string("mock")), ("platform", platformJSON),
                ("build", .obj([("source", .string("mock"))])),
            ])
        case "runtime.status":
            return .obj([
                ("instanceId", .string("rt_mock")), ("state", .string("running")), ("startedAt", .string(Timestamp.string(base))),
                ("uptimeSeconds", .double(clock)), ("connections", .int(1)), ("desktops", .int(desktops.count)),
                ("sessions", .int(0)), ("runs", .int(runs.filter { $0["phase"]?.stringValue != "ended" }.count)),
                ("inputAdmission", .string(admission)),
            ])
        case "runtime.capabilities":
            let offered = Set(Self.modeled).union(subscriptionEnabled ? ["events.subscribe", "events.unsubscribe"] : [])
            let methods: [JSONValue] = contract.methods.filter { offered.contains($0.method) }.map {
                .obj([("method", .string($0.method)), ("mutation", .bool($0.mutation)), ("stage", .string($0.stage))])
            }
            return .obj([
                ("apiVersion", .string(RuntimeAPI.version)),
                ("interface", .obj([("methods", .array(methods))])),
                ("backend", .obj([
                    ("platform", platformJSON),
                    ("permissions", .obj([("screenRecording", .string(screenRecording)), ("accessibility", .string(accessibility))])),
                    ("features", .array([])),
                ])),
            ])
        case "runtime.stopAll":
            admission = "stopped"
            var items: [JSONValue] = []
            var pending: [JSONValue] = []
            for r in runs where r["phase"]?.stringValue != "ended" {
                let id = r["runId"]!.stringValue!
                stopLocked(id, reason: "global_stop")
                items.append(.obj([("runId", .string(id)), ("accepted", .bool(true)), ("phase", .string("stopping")),
                                   ("quiescence", .string("pending")), ("outcome", .null)]))
                pending.append(.string(id))
            }
            return .obj([("admission", .string("stopped")), ("runs", .array(items)), ("pending", .array(pending))])
        case "runtime.enableInput":
            admission = "enabled"
            return .obj([("admission", .string("enabled"))])
        case "desktop.list":
            return .obj([("desktops", .array(desktops))])
        case "desktop.show":
            return try desktop(p["desktopId"]!.stringValue!)
        case "desktop.create":
            let name = p["name"]?.stringValue ?? "Desktop \(desktops.count + 1)"
            if desktops.contains(where: { $0["name"]?.stringValue == name }) {
                throw RuntimeError("conflict", "a Desktop named \(name) exists", phase: .handler)
            }
            let id = "desk_" + String(format: "%03d", desktops.count + 1)
            let d = desktopJSON(id: id, name: name, width: p["width"]?.intValue ?? 1280, height: p["height"]?.intValue ?? 800,
                                state: "ready", app: nil, windowId: 0)
            desktops.append(d)
            return d
        case "desktop.destroy":
            let id = p["desktopId"]!.stringValue!
            _ = try desktop(id)
            desktops.removeAll { $0["desktopId"]?.stringValue == id }
            return .obj([("desktopId", .string(id)), ("destroyed", .bool(true)), ("quitApps", .array([]))])
        case "hub.clients.list":
            return .obj([("clients", .array(clients)), ("pairings", .array([]))])
        case "hub.grants.list":
            return .obj([("grants", .array(clients.compactMap { $0["grant"] }))])
        case "hub.displays.list":
            return .obj([("displays", .array(displays.map { d in
                let attached = desktops.first { $0["kind"]?.stringValue == "physical" && $0["screen"]?["displayId"] == d["displayId"] }
                var out = d.setting("attachable", .bool(d["origin"]?.stringValue == "physical" && attached == nil))
                if let id = attached?["desktopId"] { out = out.setting("desktopId", id) }
                return out
            }))])
        case "hub.displays.attach":
            let displayId = p["displayId"]!.intValue!
            let clientId = p["clientId"]!.stringValue!
            guard let i = clients.firstIndex(where: { $0["clientId"]?.stringValue == clientId }) else {
                throw RuntimeError.notFound("no active client \(clientId)")
            }
            guard let d = displays.first(where: { $0["displayId"]?.intValue == displayId }) else {
                throw RuntimeError.notFound("display \(displayId) is not one of the active displays")
            }
            guard d["origin"]?.stringValue == "physical" else {
                throw RuntimeError("permission_denied", "display \(displayId) is not proved physical", phase: .handler, notSent: true,
                                   details: .obj([("reason", .string("display_not_physical"))]))
            }
            let existing = desktops.first { $0["kind"]?.stringValue == "physical" && $0["screen"]?["displayId"]?.intValue == displayId }
            let desktop: JSONValue = existing ?? .obj([
                ("desktopId", .string("desk_" + String(format: "%03d", desktops.count + 1))),
                ("name", .string(p["name"]?.stringValue ?? d["name"]!.stringValue!)), ("kind", .string("physical")),
                ("state", .string("ready")), ("createdAt", .string(stamp())),
                ("screen", .obj([("displayId", .int(displayId)), ("frame", d["frame"]!), ("hiDPI", d["hiDPI"]!)])),
                ("binding", .null), ("openSessions", .int(0)),
            ])
            if existing == nil { desktops.append(desktop) }
            var grant = clients[i]["grant"]!
            var list = grant["desktops"]?.arrayValue ?? []
            if !list.contains(desktop["desktopId"]!) { list.append(desktop["desktopId"]!) }
            grant = grant.setting("desktops", .array(list)).setting("revision", .int((grant["revision"]?.intValue ?? 0) + 1))
            clients[i] = clients[i].setting("grant", grant)
            return .obj([("desktop", desktop), ("grant", grant), ("created", .bool(existing == nil))])
        case "hub.displays.detach":
            let id = p["desktopId"]!.stringValue!
            let only = p["clientId"]?.stringValue
            guard let d = desktops.first(where: { $0["desktopId"]?.stringValue == id }) else { throw RuntimeError.notFound("no desktop \(id)") }
            guard d["kind"]?.stringValue == "physical" else { throw RuntimeError.invalidArgument("desktop \(id) is virtual") }
            var touched: [JSONValue] = []
            for i in clients.indices where only == nil || clients[i]["clientId"]?.stringValue == only {
                guard var grant = clients[i]["grant"], (grant["desktops"]?.arrayValue ?? []).contains(.string(id)) else { continue }
                grant = grant.setting("desktops", .array((grant["desktops"]?.arrayValue ?? []).filter { $0 != .string(id) }))
                    .setting("revision", .int((grant["revision"]?.intValue ?? 0) + 1))
                clients[i] = clients[i].setting("grant", grant)
                touched.append(grant)
            }
            if only == nil { desktops.removeAll { $0["desktopId"]?.stringValue == id } }
            return .obj([("desktopId", .string(id)), ("destroyed", .bool(only == nil)), ("grants", .array(touched))])
        case "app.list":
            var apps: [JSONValue] = desktops.compactMap { d -> JSONValue? in
                guard let b = d["binding"], !b.isNull else { return nil }
                return .obj([("process", b["process"]!), ("bundleId", .null), ("name", b["appName"]!),
                             ("active", .bool(false)), ("hidden", .bool(false))])
            }
            for w in freeWindows where !apps.contains(where: { $0["process"] == w["process"] }) {
                apps.append(.obj([("process", w["process"]!), ("bundleId", w["bundleId"]!), ("name", w["appName"]!),
                                  ("active", .bool(false)), ("hidden", .bool(false))]))
            }
            return .obj([("apps", .array(apps))])
        case "window.list":
            let bound: [JSONValue] = desktops.compactMap { d -> JSONValue? in
                guard let b = d["binding"], !b.isNull, let screen = d["screen"] else { return nil }
                return .obj([("windowId", b["windowId"]!), ("process", b["process"]!), ("appName", b["appName"]!),
                             ("bundleId", .null), ("title", .string(b["appName"]!.stringValue!)),
                             ("frame", screen["frame"]!), ("onScreen", .bool(true))])
            }
            var free = freeWindows
            if let pid = p["pid"]?.intValue { free = free.filter { $0["process"]?["pid"]?.intValue == pid } }
            return .obj([("windows", .array(bound + free))])
        case "app.launch":
            let id = p["desktopId"]!.stringValue!
            _ = try desktop(id)
            let name = p["bundleId"]?.stringValue ?? p["path"]?.stringValue ?? "app"
            guard launchable.contains(name) || p["path"] != nil else {
                throw RuntimeError("not_found", "no app \(name)", phase: .handler)
            }
            let windowId = 7000 + desktops.count * 10 + observationCount
            let pid = 6000 + windowId % 1000
            // Like the Runtime: the window is placed on the Desktop, not bound.
            freeWindows.append(.obj([
                ("windowId", .int(windowId)), ("process", .obj([("pid", .int(pid)), ("startedAt", .string(Timestamp.string(base)))])),
                ("appName", .string("Probe")), ("bundleId", .string("com.example.probe")), ("title", .string("Probe A")),
                ("frame", .obj([("x", .int(0)), ("y", .int(0)), ("width", .int(400)), ("height", .int(328))])),
                ("onScreen", .bool(true)),
            ]))
            return .obj([("desktopId", .string(id)), ("process", .obj([("pid", .int(pid)), ("startedAt", .string(stamp()))])),
                         ("windows", .array([.obj([("windowId", .int(windowId)), ("appName", .string("Probe")),
                                                   ("title", .string("Probe A")),
                                                   ("frame", .obj([("x", .int(0)), ("y", .int(0)), ("width", .int(400)), ("height", .int(328))]))])]))])
        case "window.bind":
            let id = p["desktopId"]!.stringValue!
            _ = try desktop(id)
            let pid = p["pid"]!.intValue!
            guard let w = freeWindows.first(where: { $0["process"]?["pid"]?.intValue == pid
                && (p["windowId"]?.intValue == nil || $0["windowId"]?.intValue == p["windowId"]?.intValue) }) else {
                throw RuntimeError("not_found", "no window of pid \(pid)", phase: .handler)
            }
            freeWindows.removeAll { $0["windowId"] == w["windowId"] }
            setBinding(id, app: w["appName"]!.stringValue!, pid: pid, windowId: w["windowId"]!.intValue!)
            return try desktop(id)
        case "observe":
            guard let id = context.desktopId else {
                throw RuntimeError.schemaInvalid("name the target with context.sessionId or context.desktopId")
            }
            let d = try desktop(id)
            observationCount += 1
            let snapshotId = "obs_" + String(format: "%04d", observationCount)
            let b = d["binding"]
            let bound = b != nil && !(b!.isNull)
            let w = bound ? 800 : (d["screen"]?["frame"]?["width"]?.intValue ?? 1280) * 2
            let h = bound ? 656 : (d["screen"]?["frame"]?["height"]?.intValue ?? 800) * 2
            var image: JSONValue = .null
            if p["screenshot"]?.boolValue ?? true {
                let artifactId = "art_" + snapshotId.dropFirst(4)
                let bytes = Self.png(width: w, height: h, seed: observationCount)
                let meta = JSONValue.obj([("artifactId", .string(artifactId)), ("mediaType", .string("image/png")),
                                          ("byteSize", .int(bytes.count)), ("sha256", .string(Self.sha256(bytes))),
                                          ("createdAt", .string(stamp()))])
                artifactsById[artifactId] = (meta, bytes)
                image = .obj([("artifactId", .string(artifactId)), ("mediaType", .string("image/png")),
                              ("width", .int(w)), ("height", .int(h)), ("byteSize", .int(bytes.count)),
                              ("sha256", .string(Self.sha256(bytes))),
                              ("transform", .obj([("originX", .int(0)), ("originY", .int(0)), ("scale", .int(2))]))])
            }
            let target: JSONValue = bound ? .obj([
                ("generation", b!["generation"]!), ("process", b!["process"]!), ("windowId", b!["windowId"]!),
                ("windowFrame", .obj([("x", .int(0)), ("y", .int(0)), ("width", .int(400)), ("height", .int(328))])),
                ("title", b!["appName"]!),
            ]) : .null
            return .obj([("snapshotId", .string(snapshotId)), ("desktopId", .string(id)), ("capturedAt", .string(stamp())),
                         ("screen", d["screen"]!), ("target", target), ("image", image), ("elements", .array([]))])
        case "artifact.show":
            guard let a = artifactsById[p["artifactId"]!.stringValue!] else { throw RuntimeError.notFound("no artifact") }
            return a.meta
        case "artifact.read":
            guard let a = artifactsById[p["artifactId"]!.stringValue!] else { throw RuntimeError.notFound("no artifact") }
            let offset = min(p["offset"]?.intValue ?? 0, a.bytes.count)
            let length = min(p["length"]?.intValue ?? 524_288, a.bytes.count - offset)
            let chunk = a.bytes.subdata(in: offset..<(offset + length))
            return .obj([("artifactId", p["artifactId"]!), ("offset", .int(offset)), ("length", .int(length)),
                         ("eof", .bool(offset + length >= a.bytes.count)), ("dataBase64", .string(chunk.base64EncodedString()))])
        case "run.list":
            var list = runs
            if let d = p["desktopId"]?.stringValue { list = list.filter { $0["desktopId"]?.stringValue == d } }
            if let o = p["origin"]?.stringValue { list = list.filter { $0["origin"]?.stringValue == o } }
            if let ph = p["phase"]?.stringValue { list = list.filter { $0["phase"]?.stringValue == ph } }
            if let c = p["clientId"]?.stringValue { list = list.filter { $0["clientId"]?.stringValue == c } }
            if let active = p["active"]?.boolValue { list = list.filter { ($0["phase"]?.stringValue != "ended") == active } }
            let limit = p["limit"]?.intValue ?? 50
            return .obj([("runs", .array(Array(list.reversed().prefix(limit)))), ("next", .null)])
        case "run.show":
            return try run(p["runId"]!.stringValue!)
        case "run.events":
            let id = p["runId"]!.stringValue!
            _ = try run(id)
            let after = p["after"]?.intValue ?? 0
            let limit = p["limit"]?.intValue ?? 100
            let mine = events.map(\.event).filter { $0["runId"]?.stringValue == id && ($0["sequence"]?.intValue ?? 0) > after }
            let page = Array(mine.prefix(limit))
            let next = page.last?["sequence"]?.intValue ?? after
            let ended = try run(id)["phase"]?.stringValue == "ended" && page.count == mine.count
            return .obj([("events", .array(page)), ("next", .int(next)), ("ended", .bool(ended))])
        case "run.cancel":
            let id = p["runId"]!.stringValue!
            var r = try run(id)
            let terminal = r["phase"]?.stringValue == "ended"
            if !terminal {
                stopLocked(id, reason: "stopped")
                r = try run(id)
            }
            var m: [(String, JSONValue)] = [
                ("cancelRequest", .obj([("accepted", .bool(true)), ("scope", .obj([("kind", .string("run")), ("id", .string(id))]))])),
                ("execution", .obj([("phase", r["phase"]!), ("quiescence", r["quiescence"]!), ("outcome", r["outcome"]!),
                                    ("revision", r["revision"]!)])),
            ]
            if terminal { m.append(("alreadyTerminal", .bool(true))) }
            return .obj(m)
        case "request.show":
            let id = p["requestId"]!.stringValue!
            guard let r = requests[id] else { throw RuntimeError.notFound("no request \(id)") }
            return r
        default:
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
    }

    // MARK: Helpers (lock held)

    private func setBinding(_ id: String, app: String, pid: Int, windowId: Int) {
        guard let i = desktops.firstIndex(where: { $0["desktopId"]?.stringValue == id }) else { return }
        let gen = (desktops[i]["binding"]?["generation"]?.intValue ?? 0) + 1
        let at = stamp()
        desktops[i] = desktops[i].setting("binding", .obj([
            ("generation", .int(gen)), ("process", .obj([("pid", .int(pid)), ("startedAt", .string(at))])),
            ("windowId", .int(windowId)), ("appName", .string(app)), ("boundAt", .string(at)),
        ]))
    }

    /// A small synthetic PNG (flat colour with a band), so pages can show a
    /// real decoded image; never a capture of anything.
    static func png(width: Int, height: Int, seed: Int) -> Data {
        let w = max(1, width / 8), h = max(1, height / 8)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        ctx.setFillColor(CGColor(srgbRed: 0.93, green: 0.95, blue: 0.92, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(srgbRed: 0.25, green: 0.42, blue: 0.33, alpha: 1))
        ctx.fill(CGRect(x: 0, y: h - max(2, h / 10), width: w, height: max(2, h / 10)))
        ctx.fill(CGRect(x: (seed * 7) % max(1, w - 8), y: h / 3, width: 8, height: 8))
        guard let img = ctx.makeImage() else { return Data() }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil) else { return Data() }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
        return data as Data
    }

    static func sha256(_ data: Data) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &digest) }
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private var platformJSON: JSONValue {
        .obj([("os", .string("macos")), ("osVersion", .string("15.0")), ("arch", .string("arm64"))])
    }

    private func stamp() -> String {
        clock += 1
        return Timestamp.string(base.addingTimeInterval(clock))
    }

    private func desktop(_ id: String) throws -> JSONValue {
        guard let d = desktops.first(where: { $0["desktopId"]?.stringValue == id }) else {
            throw RuntimeError.notFound("no Desktop \(id)")
        }
        return d
    }

    private func run(_ id: String) throws -> JSONValue {
        guard let r = runs.first(where: { $0["runId"]?.stringValue == id }) else { throw RuntimeError.notFound("no Run \(id)") }
        return r
    }

    /// Mirrors `ExecutionCoordinator.stop`: the first stop moves the Run to
    /// stopping/pending and records its closing reason (revision + 1); a
    /// later stop of a stopping Run changes nothing but is still reported,
    /// with its own reason at the unchanged revision. The event type follows
    /// the reason (`run.finishing` for finished/completed/exit*).
    private func stopLocked(_ id: String, reason: String) {
        guard let current = runs.first(where: { $0["runId"]?.stringValue == id }) else { return }
        if current["phase"]?.stringValue != "stopping" {
            updateRunLocked(id) {
                $0.setting("phase", .string("stopping")).setting("quiescence", .string("pending")).setting("closingReason", .string(reason))
            }
        }
        let type = ["finished", "completed"].contains(reason) || reason.hasPrefix("exit") ? "run.finishing" : "stop.accepted"
        appendEventLocked(id, type, .obj([("reason", .string(reason)), ("inFlight", .bool(false)), ("revision", revisionLocked(id))]))
    }

    private func revisionLocked(_ id: String) -> JSONValue {
        runs.first(where: { $0["runId"]?.stringValue == id })?["revision"] ?? .int(1)
    }

    private func updateRunLocked(_ id: String, _ change: (JSONValue) -> JSONValue) {
        guard let i = runs.firstIndex(where: { $0["runId"]?.stringValue == id }) else { return }
        let rev = (runs[i]["revision"]?.intValue ?? 1) + 1
        runs[i] = change(runs[i]).setting("revision", .int(rev))
    }

    private func desktopJSON(id: String, name: String, width: Int, height: Int, state: String, app: String?, windowId: Int) -> JSONValue {
        let created = stamp()
        let binding: JSONValue = app.map {
            .obj([("generation", .int(1)), ("process", .obj([("pid", .int(700 + windowId % 100)), ("startedAt", .string(created))])),
                  ("windowId", .int(windowId)), ("appName", .string($0)), ("boundAt", .string(created))])
        } ?? .null
        return .obj([
            ("desktopId", .string(id)), ("name", .string(name)), ("state", .string(state)), ("createdAt", .string(created)),
            ("screen", .obj([("displayId", .int(500 + desktops.count + 1)),
                             ("frame", .obj([("x", .int(0)), ("y", .int(0)), ("width", .int(width)), ("height", .int(height))])),
                             ("hiDPI", .bool(false))])),
            ("binding", binding), ("openSessions", .int(0)),
        ])
    }

    private func receiptJSON(run: JSONValue, requestId: String, delivery: String, execution: String, acceptedAt: String) -> JSONValue {
        let desk = desktops.first { $0["desktopId"] == run["desktopId"] }
        let b = desk?["binding"]
        let process = b?["process"] ?? .obj([("pid", .int(1)), ("startedAt", .null)])
        let windowId = b?["windowId"] ?? .int(1)
        let receiptNo = requests.count + 1
        return .obj([
            ("receiptId", .string("rcpt_\(receiptNo)")), ("requestId", .string(requestId)), ("runId", run["runId"]!),
            ("desktopId", run["desktopId"]!), ("sessionId", run["sessionId"]!), ("snapshotId", .string("snap_\(receiptNo)")),
            ("delivery", .string(delivery)), ("execution", .string(execution)), ("verification", .string("not_requested")),
            ("route", delivery == "not_dispatched" ? .null : .string("ax")),
            ("target", .obj([("generation", .int(1)), ("process", process), ("windowId", windowId), ("elementRef", .null),
                             ("point", .obj([("x", .int(120)), ("y", .int(80))]))])),
            ("timing", .obj([("acceptedAt", .string(acceptedAt)),
                             ("dispatchedAt", delivery == "not_dispatched" ? .null : .string(stamp())),
                             ("completedAt", .string(stamp()))])),
        ])
    }

    private func appendEventLocked(_ runId: String, _ type: String, _ data: JSONValue) {
        let seq = (runSequences[runId] ?? 0) + 1
        runSequences[runId] = seq
        let cursor = (events.last?.cursor ?? eventFloor) + 1
        let e = JSONValue.obj([("runId", .string(runId)), ("sequence", .int(seq)), ("at", .string(stamp())),
                               ("type", .string(type)), ("data", data)])
        events.append((cursor, e))
        for c in subscribers.values { c.yield(frame((cursor, e))) }
    }

    private func frame(_ e: (cursor: Int, event: JSONValue)) -> JSONValue {
        .obj([("apiVersion", .string(RuntimeAPI.version)), ("event", e.event), ("cursor", .int(e.cursor))])
    }

    static func mockMessage(_ code: String) -> String { "mock: \(code)" }
}
