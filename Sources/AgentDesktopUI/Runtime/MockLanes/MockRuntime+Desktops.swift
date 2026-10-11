import AgentDesktopProtocol
import Foundation

// Lane UI-B (Desktops 与控制; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.
//
// It models the A5 control methods the way RuntimeService+Control.swift and
// RuntimeService+Close.swift answer them (desktop.stop / takeover / handback
// / closePlan / resize, app.quit), and Desktop.control derived from the
// Desktop's gate, its holder Run and its last Run (docs/plan/03 §3.4). Every
// answer still passes the contract check of MockRuntime.callLocked.

/// Lane UI-B's mock state (read and written with the MockRuntime's lock held).
final class MockDesktopsLane: @unchecked Sendable {
    /// Desktops carry `control` only once a scenario turns it on, so the
    /// plain sample keeps showing the page without Desktop.control (U2b).
    var modelsControl = false
    /// The owner's gate per Desktop: "stopped" (desktop.stop) or "manual"
    /// (desktop.takeover), with when it closed.
    var gates: [String: (kind: String, at: String)] = [:]
    /// When the owner last handed a Desktop back: older Runs no longer
    /// colour its state.
    var clearedAt: [String: String] = [:]
    /// Runs with an action in flight: stopping them stays pending.
    var inFlight: Set<String> = []
    /// Desktops whose next takeover is overtaken by a handback or stop.
    var supersedeNext: Set<String> = []
    /// Reserved states a scenario forces (creating, error).
    var forced: [String: String] = [:]
    /// Processes app.launch started per Desktop (ClosePlanProcess shape
    /// without reason).
    var launched: [String: [JSONValue]] = [:]
    /// Whether app.quit sees the process exit within its wait.
    var quitExits = true
    /// How often each Desktop's observations were forgotten (handback,
    /// resize): an agent must observe again before acting.
    var forgotten: [String: Int] = [:]
    var nextPid = 6400
}

extension MockRuntime {
    /// Methods lane UI-B models (each must be in RuntimeCatalog.implemented).
    static let desktopsLaneMethods: [String] = [
        "desktop.stop", "desktop.takeover", "desktop.handback", "desktop.closePlan", "app.quit", "desktop.resize",
    ]

    static let controlStopReasons: Set<String> = ["stopped", "global_stop", "client_stop", "desktop_stop", "takeover"]

    /// Lane UI-B's answer to one of `desktopsLaneMethods` (lock held).
    func desktopsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        let lane = lanes.desktops
        let id = p["desktopId"]?.stringValue ?? ""
        let d = try desktop(id)
        defer { syncControlsLocked() }
        switch method {
        case "desktop.stop":
            lane.gates[id] = ("stopped", stamp())
            var stopped: JSONValue = .null
            if let h = holderLocked(id), let runId = h["runId"]?.stringValue {
                stopLocked(runId, reason: "desktop_stop")
                if !lane.inFlight.contains(runId) { settleLocked(runId, outcome: "cancelled") }
                stopped = stopStateLocked(runId)
            }
            return .obj([("desktopId", .string(id)), ("accepted", .bool(true)), ("run", stopped),
                         ("control", controlLocked(d))])
        case "desktop.takeover":
            if let h = holderLocked(id), h["origin"]?.stringValue == "user", h["phase"]?.stringValue == "running" {
                return takeoverAnswerLocked(id, run: h, stopped: .null)
            }
            if lane.supersedeNext.remove(id) != nil {
                throw RuntimeError("conflict", "desktop \(id) was handed back or stopped while this takeover waited; nothing was taken over",
                                   phase: .handler, notSent: true,
                                   details: .obj([("desktopId", .string(id)), ("reason", .string("superseded"))]))
            }
            lane.gates[id] = ("manual", stamp())
            var stopped: JSONValue = .null
            if let h = holderLocked(id), let runId = h["runId"]?.stringValue {
                stopLocked(runId, reason: "takeover")
                if lane.inFlight.contains(runId) {
                    throw RuntimeError("stop_pending",
                                       "takeover accepted: run \(runId) is still finishing an action; agents' input on desktop \(id) stays closed. Ask again with a new requestId once it is quiescent",
                                       phase: .handler, retryable: true, notSent: false,
                                       details: .obj([("desktopId", .string(id)), ("holderRunId", .string(runId))]))
                }
                settleLocked(runId, outcome: "cancelled")
                stopped = stopStateLocked(runId)
            }
            let run = startUserRunLocked(id)
            return takeoverAnswerLocked(id, run: run, stopped: stopped)
        case "desktop.handback":
            let state = controlLocked(d)["state"]?.stringValue ?? ""
            let holder = holderLocked(id)
            let settled = holder == nil && admission == "enabled" && ["stopped", "disconnected", "unknown"].contains(state)
            guard lane.gates[id] != nil || settled else {
                return .obj([("desktopId", .string(id)), ("handedBack", .bool(false)), ("endedRunId", .null),
                             ("observationsCleared", .bool(false)), ("control", controlLocked(d))])
            }
            var ended: JSONValue = .null
            if let h = holder, h["origin"]?.stringValue == "user", let runId = h["runId"]?.stringValue {
                stopLocked(runId, reason: "handback")
                settleLocked(runId, outcome: "success")
                ended = .string(runId)
            }
            lane.gates[id] = nil
            lane.clearedAt[id] = stamp()
            lane.forgotten[id, default: 0] += 1
            return .obj([("desktopId", .string(id)), ("handedBack", .bool(true)), ("endedRunId", ended),
                         ("observationsCleared", .bool(true)), ("control", controlLocked(try desktop(id)))])
        case "desktop.closePlan":
            let physical = d["kind"]?.stringValue == "physical"
            var blockers: [JSONValue] = []
            if let h = holderLocked(id) {
                blockers.append(.obj([("kind", .string("run")), ("runId", h["runId"]!), ("origin", h["origin"] ?? .null)]))
            }
            if let open = d["openSessions"]?.intValue, open > 0 {
                blockers.append(.obj([("kind", .string("sessions")), ("count", .int(open))]))
            }
            let quit = physical ? [] : (lane.launched[id] ?? [])
            var keep: [JSONValue] = []
            if let b = d["binding"], !b.isNull, !quit.contains(where: { $0["process"] == b["process"] }) {
                keep.append(.obj([("process", b["process"]!), ("appName", b["appName"] ?? .null), ("bundleId", .null),
                                  ("reason", .string(physical ? "physical_desktop" : "not_launched_here"))]))
            }
            return .obj([("desktopId", .string(id)), ("kind", .string(physical ? "physical" : "virtual")),
                         ("display", .string(physical ? "kept" : "destroyed")), ("canClose", .bool(blockers.isEmpty)),
                         ("blockers", .array(blockers)), ("quit", .array(quit)), ("keep", .array(keep))])
        case "app.quit":
            let pid = p["pid"]!.intValue!
            guard let process = lane.launched[id]?.first(where: { $0["process"]?["pid"]?.intValue == pid })?["process"] else {
                throw RuntimeError("permission_denied", "app.quit ends only a process app.launch started on desktop \(id)",
                                   phase: .handler, notSent: true, details: .obj([("reason", .string("not_launched_here"))]))
            }
            if lane.quitExits {
                lane.launched[id]?.removeAll { $0["process"]?["pid"]?.intValue == pid }
                if d["binding"]?["process"]?["pid"]?.intValue == pid, let i = desktops.firstIndex(where: { $0["desktopId"] == d["desktopId"] }) {
                    desktops[i] = desktops[i].setting("binding", .null)
                }
            }
            return .obj([("desktopId", .string(id)), ("process", process), ("quitRequested", .bool(true)),
                         ("exited", .bool(lane.quitExits))])
        case "desktop.resize":
            guard d["kind"]?.stringValue != "physical" else {
                throw RuntimeError("invalid_target", "desktop \(id) is physical: its display is the user's and keeps its size",
                                   phase: .handler, notSent: true)
            }
            let w = p["width"]!.intValue!, h = p["height"]!.intValue!
            guard w <= 6016, h <= 3384 else {
                throw RuntimeError("execution_failed", "the display reserved no room for \(w)x\(h)", phase: .handler)
            }
            guard let i = desktops.firstIndex(where: { $0["desktopId"]?.stringValue == id }), let screen = d["screen"] else {
                throw RuntimeError.notFound("no Desktop \(id)")
            }
            let frame = (screen["frame"] ?? .obj([])).setting("width", .int(w)).setting("height", .int(h))
            desktops[i] = desktops[i].setting("screen", screen.setting("frame", frame))
            lane.forgotten[id, default: 0] += 1
            return desktops[i]
        default:
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
    }

    // MARK: Scenario building (lane UI-B)

    /// From now on every Desktop carries Desktop.control, derived as the
    /// Runtime derives it.
    public func enableDesktopControl() {
        lock.withLock {
            lanes.desktops.modelsControl = true
            syncControlsLocked()
        }
    }

    /// Re-derives Desktop.control after scenario changes made outside this
    /// lane (addRun, confirmQuiescence, run.cancel).
    public func syncDesktopControls() {
        lock.withLock { syncControlsLocked() }
    }

    /// An action of the Run is in flight: stopping it stays pending until
    /// `finishInFlight`.
    public func markActionInFlight(_ runId: String) {
        lock.withLock { _ = lanes.desktops.inFlight.insert(runId) }
    }

    /// The in-flight action ended; a stopping Run becomes quiescent.
    public func finishInFlight(_ runId: String, outcome: String = "cancelled") {
        lock.withLock {
            lanes.desktops.inFlight.remove(runId)
            if runs.first(where: { $0["runId"]?.stringValue == runId })?["phase"]?.stringValue == "stopping" {
                settleLocked(runId, outcome: outcome)
            }
            syncControlsLocked()
        }
    }

    /// The next desktop.takeover of this Desktop finds that the owner handed
    /// it back or stopped it meanwhile (conflict, reason superseded).
    public func supersedeNextTakeover(_ desktopId: String) {
        lock.withLock { _ = lanes.desktops.supersedeNext.insert(desktopId) }
    }

    /// Forces a reserved control state (creating, error) on a Desktop.
    public func forceControlState(_ desktopId: String, _ state: String?) {
        lock.withLock {
            lanes.desktops.forced[desktopId] = state
            syncControlsLocked()
        }
    }

    /// The Run's caller becomes a paired client (its name shows as the
    /// controller).
    public func setRunClient(_ runId: String, clientId: String) {
        lock.withLock {
            updateRunLocked(runId) { $0.setting("clientId", .string(clientId)) }
            syncControlsLocked()
        }
    }

    /// The control connection of an agent's Run is lost: it ends with
    /// closingReason owner_lost (the Desktop shows disconnected).
    public func loseControlConnection(_ runId: String) {
        lock.withLock {
            stopLocked(runId, reason: "owner_lost")
            settleLocked(runId, outcome: "cancelled")
            syncControlsLocked()
        }
    }

    /// The last Run's action ended unknown: the Run ends with outcome
    /// unknown (the Desktop shows unknown).
    public func endWithUnknownAction(_ runId: String) {
        lock.withLock {
            updateRunLocked(runId) { r in r.setting("unknownActions", .int(max(1, r["unknownActions"]?.intValue ?? 0))) }
            stopLocked(runId, reason: "finished")
            settleLocked(runId, outcome: "unknown")
            syncControlsLocked()
        }
    }

    /// An app launched on the Desktop by app.launch (closePlan quits it);
    /// it becomes the Desktop's binding when `bind`. Returns its pid.
    @discardableResult
    public func addLaunchedApp(_ desktopId: String, name: String, bundleId: String = "com.example.probe", bind: Bool = false) -> Int {
        lock.withLock {
            let lane = lanes.desktops
            lane.nextPid += 1
            let pid = lane.nextPid
            let process: JSONValue = .obj([("pid", .int(pid)), ("startedAt", .string(Timestamp.string(base)))])
            lane.launched[desktopId, default: []].append(.obj([("process", process), ("appName", .string(name)),
                                                               ("bundleId", .string(bundleId))]))
            if bind { setBinding(desktopId, app: name, pid: pid, windowId: 8000 + pid % 1000) }
            if bind, let i = desktops.firstIndex(where: { $0["desktopId"]?.stringValue == desktopId }) {
                desktops[i] = desktops[i].setting("binding", desktops[i]["binding"]!.setting("process", process))
            }
            syncControlsLocked()
            return pid
        }
    }

    /// Whether app.quit sees processes exit within its wait.
    public var quitExits: Bool {
        get { lock.withLock { lanes.desktops.quitExits } }
        set { lock.withLock { lanes.desktops.quitExits = newValue } }
    }

    /// How often a Desktop's observations were forgotten.
    public func observationsForgotten(_ desktopId: String) -> Int {
        lock.withLock { lanes.desktops.forgotten[desktopId] ?? 0 }
    }

    /// What an agent gets when it starts a Run on the Desktop now: a new
    /// Run, or the refusal the Runtime gives (gate closed by the owner).
    public func agentStartsRun(_ desktopId: String) throws -> String {
        let refusal: RuntimeError? = lock.withLock {
            switch lanes.desktops.gates[desktopId]?.kind {
            case "manual":
                return RuntimeError("control_busy", "the owner controls desktop \(desktopId) by hand", phase: .handler,
                                    retryable: true, notSent: true, details: .obj([("reason", .string("manual_control"))]))
            case "stopped":
                return RuntimeError("input_disabled", "the owner stopped desktop \(desktopId)", phase: .handler,
                                    notSent: true, details: .obj([("reason", .string("desktop_stopped"))]))
            default:
                return nil
            }
        }
        if let refusal { throw refusal }
        let id = addRun(desktopId: desktopId)
        syncDesktopControls()
        return id
    }

    // MARK: Derivation (lock held)

    func syncControlsLocked() {
        guard lanes.desktops.modelsControl else { return }
        for i in desktops.indices { desktops[i] = desktops[i].setting("control", controlLocked(desktops[i])) }
    }

    /// The Run holding the Desktop: its newest Run that has not ended.
    func holderLocked(_ desktopId: String) -> JSONValue? {
        runs.last { $0["desktopId"]?.stringValue == desktopId && $0["phase"]?.stringValue != "ended" }
    }

    /// Desktop.control as RuntimeService.controlJSON derives it.
    func controlLocked(_ d: JSONValue) -> JSONValue {
        let lane = lanes.desktops
        let id = d["desktopId"]?.stringValue ?? ""
        var state: String
        var run: JSONValue?
        var since = d["createdAt"]?.stringValue ?? stamp()
        if let h = holderLocked(id) {
            run = h
            state = h["phase"]?.stringValue == "stopping" ? "stopping" : (h["origin"]?.stringValue == "user" ? "manual" : "running")
            since = h["createdAt"]?.stringValue ?? since
        } else if let gate = lane.gates[id] {
            state = "stopped"
            since = gate.at
        } else if admission != "enabled" {
            state = "stopped"
        } else {
            let cleared = lane.clearedAt[id]
            let last = runs.last { r in
                guard r["desktopId"]?.stringValue == id else { return false }
                guard let cleared, let ended = r["endedAt"]?.stringValue else { return true }
                return ended > cleared
            }
            if let last, last["outcome"]?.stringValue == "unknown" { state = "unknown" }
            else if let last, last["closingReason"]?.stringValue == "owner_lost" { state = "disconnected" }
            else if let last, Self.controlStopReasons.contains(last["closingReason"]?.stringValue ?? "") { state = "stopped" }
            else { state = "ready" }
            if let last {
                if state != "ready" { run = last }
                since = last["endedAt"]?.stringValue ?? last["createdAt"]?.stringValue ?? since
            } else if let cleared {
                since = cleared
            }
        }
        if let forced = lane.forced[id] { state = forced }
        var m: [(String, JSONValue)] = [("state", .string(state)), ("since", .string(since)),
                                        ("actionCount", .int(run?["receipts"]?.arrayValue?.count ?? 0))]
        if let run, let runId = run["runId"]?.stringValue {
            m.append(("controllerRunId", .string(runId)))
            if let clientId = run["clientId"]?.stringValue {
                m.append(("clientId", .string(clientId)))
                if let name = clients.first(where: { $0["clientId"]?.stringValue == clientId })?["agentName"]?.stringValue {
                    m.append(("clientName", .string(name)))
                }
            }
        }
        return .obj(m)
    }

    func stopStateLocked(_ runId: String) -> JSONValue {
        guard let r = runs.first(where: { $0["runId"]?.stringValue == runId }) else { return .null }
        return .obj([("runId", .string(runId)), ("phase", r["phase"]!), ("quiescence", r["quiescence"]!),
                     ("outcome", r["outcome"] ?? .null)])
    }

    /// As confirmQuiescence, with the lock already held.
    func settleLocked(_ runId: String, outcome: String) {
        updateRunLocked(runId) { r in
            r.setting("phase", .string("ended")).setting("quiescence", .string("confirmed"))
                .setting("outcome", .string((r["unknownActions"]?.intValue ?? 0) > 0 ? "unknown" : outcome))
                .setting("closingReason", r["closingReason"].flatMap { $0 == .null ? nil : $0 } ?? .string("stopped"))
                .setting("endedAt", .string(stamp()))
        }
        let ended = runs.first { $0["runId"]?.stringValue == runId }
        appendEventLocked(runId, "run.quiescent", .obj([("revision", ended?["revision"] ?? .int(1))]))
        appendEventLocked(runId, "run.ended", .obj([("phase", .string("ended")), ("outcome", ended?["outcome"] ?? .string(outcome)),
                                                   ("reason", ended?["closingReason"] ?? .string("stopped"))]))
    }

    /// The user's takeover Run: origin user, kind exec, platform_durable.
    func startUserRunLocked(_ desktopId: String) -> JSONValue {
        let runId = "run_" + String(format: "%03d", runs.count + 1)
        let run: JSONValue = .obj([
            ("runId", .string(runId)), ("kind", .string("exec")), ("origin", .string("user")),
            ("ownership", .string("platform")), ("lifetime", .string("platform_durable")),
            ("clientId", .null), ("connectionId", .null), ("sessionId", .string("ses_\(runId)")),
            ("desktopId", .string(desktopId)), ("phase", .string("running")), ("outcome", .null),
            ("quiescence", .string("not_confirmed")), ("closingReason", .null), ("revision", .int(1)),
            ("createdAt", .string(stamp())), ("receipts", .array([])), ("unknownActions", .int(0)),
        ])
        runs.append(run)
        appendEventLocked(runId, "run.started", .obj([("kind", .string("exec")), ("origin", .string("user")),
            ("ownership", .string("platform")), ("lifetime", .string("platform_durable")),
            ("desktopId", .string(desktopId)), ("sessionId", .string("ses_\(runId)"))]))
        return run
    }

    func takeoverAnswerLocked(_ desktopId: String, run: JSONValue, stopped: JSONValue) -> JSONValue {
        syncControlsLocked()
        let d = desktops.first { $0["desktopId"]?.stringValue == desktopId } ?? .obj([("desktopId", .string(desktopId))])
        let current = runs.first { $0["runId"] == run["runId"] } ?? run
        return .obj([("desktopId", .string(desktopId)), ("run", current), ("stopped", stopped), ("control", controlLocked(d))])
    }
}
