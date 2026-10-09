import AgentDesktopProtocol
import Foundation

// Desktop lifecycle, app placement, window binding, sessions and requests.
// Every change to one Desktop happens under its lock, so writes to one
// Desktop are ordered and different Desktops proceed in parallel.
extension RuntimeService {
    func desktop(_ id: JSONValue?) -> Result<DesktopRecord, RuntimeError> {
        let id = id?.stringValue ?? ""
        guard let d = desktops.find(id) else { return .failure(.notFound("no desktop \(id)")) }
        return .success(d)
    }

    func desktopJSON(_ d: DesktopRecord) -> JSONValue {
        d.lock.withLock { d.json(openSessions: sessions.openCount(desktopId: d.desktopId)) }
    }

    /// Run `body` with the Desktop locked; a destroyed Desktop is not found.
    /// How long a request without a deadline waits for a busy Desktop.
    static let desktopLockWait: TimeInterval = 30

    /// Run `body` holding the Desktop's lock. The wait for the lock ends at
    /// `until` (the request's deadline) or after `desktopLockWait`: a
    /// Desktop held by a slow operation delays its callers only that long,
    /// and nothing is done when the wait ends.
    /// Run `body` under the Desktop's lock. With a caller, its access is
    /// checked once more after the lock is held, right before anything is
    /// done (A4 R3): a request that waited for the lock while the owner
    /// revoked or narrowed its access does nothing.
    func withDesktop(_ id: JSONValue?, until: Date? = nil, as c: ConnectionState? = nil, method: String = "",
                     _ body: (DesktopRecord) throws -> JSONValue) -> Result<JSONValue, RuntimeError> {
        switch desktop(id) {
        case let .failure(e): return .failure(e)
        case let .success(d):
            let limit = until ?? now().addingTimeInterval(Self.desktopLockWait)
            guard d.lock.lock(before: limit) else {
                return .failure(RuntimeError("deadline_exceeded",
                                             "desktop \(d.desktopId) stayed busy past the deadline; nothing was done",
                                             phase: .handler, notSent: true))
            }
            defer { d.lock.unlock() }
            guard d.state != "destroyed" else { return .failure(.notFound("no desktop \(d.desktopId)")) }
            if let c, let e = recheckAct(c, desktopId: d.desktopId, method: method) {
                hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: method, decision: "denied",
                          reason: "after_lock: " + (e.details?["reason"]?.stringValue ?? e.code))
                return .failure(e)
            }
            do {
                return .success(try body(d))
            } catch let e as RuntimeError {
                return .failure(e)
            } catch let e as PlatformError {
                return .failure(e.runtimeError)
            } catch {
                return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
            }
        }
    }

    func createDesktop(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        createLock.lock()
        defer { createLock.unlock() }
        // Waited for the lock: access is checked again (round-four review L2).
        if c.role == .paired {
            if let reason = c.cutReason { return .failure(Self.cutError(c, reason)) }
            if let e = accessError(c, method: "desktop.create") { return .failure(e) }
        }
        let id = DesktopRegistry.newId(prefix: "d")
        let name = p["name"]?.stringValue ?? id
        // Names are unique per creator: a client can neither probe nor take
        // another's Desktop names (#153 parity).
        if desktops.names(createdBy: c.clientId).contains(name) {
            return .failure(RuntimeError("conflict", "a desktop named \(name) exists", phase: .handler))
        }
        do {
            if let physical = p["physical"] {
                guard physicalDesktopsEnabled else {
                    return .failure(RuntimeError("permission_denied",
                                                 "physical Desktops are disabled until per-window grants exist: attaching your screen and binding its windows needs your authorization for each window",
                                                 phase: .handler, notSent: true,
                                                 details: .obj([("reason", .string("physical_desktop_requires_grant"))])))
                }
                // A physical Desktop: attach one of the user's displays; nothing is created.
                guard p["width"] == nil, p["height"] == nil else {
                    return .failure(.invalidArgument("a physical Desktop takes the display's size; leave out width and height"))
                }
                let wanted: UInt32?
                if let value = physical["displayId"] {
                    guard let raw = value.intValue, let id = UInt32(exactly: raw) else {
                        return .failure(.invalidArgument("physical.displayId must fit an unsigned 32-bit display ID"))
                    }
                    wanted = id
                } else {
                    wanted = nil
                }
                let screen = try platform.attachDisplay(wanted)
                if desktops.physical(displayId: screen.displayId) != nil {
                    return .failure(RuntimeError("conflict", "another desktop already attaches display \(screen.displayId)",
                                                 phase: .handler))
                }
                let d = desktops.add(desktopId: id, name: name, screen: screen, createdAt: nowString, kind: .physical, createdBy: c.clientId)
                return .success(desktopJSON(d))
            }
            let screen = try platform.createScreen(name: id, width: p["width"]?.intValue, height: p["height"]?.intValue)
            let d = desktops.add(desktopId: id, name: name, screen: screen, createdAt: nowString, createdBy: c.clientId)
            return .success(desktopJSON(d))
        } catch let e as PlatformError {
            return .failure(e.runtimeError)
        } catch {
            return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
        }
    }

    func destroyDesktop(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"], as: c, method: "desktop.destroy") { d in
            if let holder = execution.holder(of: d.desktopId) {
                throw RuntimeError("conflict", "run \(holder) controls desktop \(d.desktopId); cancel it first",
                                   phase: .handler, details: .obj([("holderRunId", .string(holder))]))
            }
            let open = sessions.openCount(desktopId: d.desktopId)
            guard open == 0 else {
                throw RuntimeError("conflict", "desktop \(d.desktopId) has \(open) open session(s); close them first",
                                   phase: .handler, details: .obj([("openSessions", .int(open))]))
            }
            if d.kind == .physical {
                // The display and every window on it are the user's: drop
                // the binding and the record, nothing else.
                d.state = "destroyed"
                d.generation += 1
                d.binding = nil
                desktops.remove(d.desktopId)
                observations.forget(desktopId: d.desktopId)
                return .obj([("desktopId", .string(d.desktopId)), ("destroyed", .bool(true)), ("quitApps", .array([]))])
            }
            d.state = "destroying"
            // Apps launched onto this Desktop belong to it: ask them to quit
            // first, or macOS moves their windows onto the user's screens.
            // Windows the user's own apps lent by bind go back to them.
            var closed: [JSONValue] = []
            for proc in d.launched where backend.processIdentity(proc.pid) == proc {
                if platform.quit(pid: proc.pid) { closed.append(proc.json) }
            }
            if !closed.isEmpty { Thread.sleep(forTimeInterval: 0.5) }
            do {
                try platform.destroyScreen(name: d.screen.name)
            } catch let e as PlatformError where e.kind == .notFound {
                // Already gone underneath: the record goes too.
            } catch {
                d.state = "ready"
                throw error
            }
            d.state = "destroyed"
            desktops.remove(d.desktopId)
            observations.forget(desktopId: d.desktopId)
            return .obj([("desktopId", .string(d.desktopId)), ("destroyed", .bool(true)), ("quitApps", .array(closed))])
        }
    }

    func launchApp(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"], as: c, method: "app.launch") { d in
            // The app itself is checked again under the lock (round-four review L2).
            if c.role == .paired, p["path"] != nil || !appAllowed(c, bundleId: p["bundleId"]?.stringValue) {
                throw RuntimeError("grant_missing", "starting this app needs a launch grant for it, which this client does not have",
                                   phase: .request, notSent: true, details: .obj([("reason", .string("launch_requires_grant"))]))
            }
            guard d.kind == .virtual else {
                throw RuntimeError("invalid_target",
                                   "desktop \(d.desktopId) is physical: it binds windows the user's apps already show; app.launch is for virtual Desktops",
                                   phase: .handler, notSent: true)
            }
            // #139: refused by name or by path, for every caller. A path
            // inside an app whose bundle id cannot be read is refused too.
            if Self.isBlocked(bundleId: p["bundleId"]?.stringValue) { throw Self.blockedAppError() }
            if let path = p["path"]?.stringValue {
                switch Self.bundle(atPath: path) {
                case let .bundle(id) where Self.isBlocked(bundleId: id): throw Self.blockedAppError()
                case .unreadable: throw Self.blockedAppError(unverified: true)
                default: break
                }
            }
            let (pid, windows) = try platform.launch(on: d.screen, bundleId: p["bundleId"]?.stringValue,
                                                     path: p["path"]?.stringValue,
                                                     newInstance: p["newInstance"]?.boolValue ?? false)
            let process = backend.processIdentity(pid)
            // Checked again on the process itself: iPhone Mirroring, or an
            // app that cannot be identified, is never kept as this Desktop's
            // app. The platform returns only a process this launch provably
            // started (its launch token, not a time or a list), so it is
            // asked to quit, as long as the pid is still that process. A
            // launch that could not prove its process throws above and
            // nothing is quit. Known residue: quit finds the process by pid
            // again (no launch handle reaches the Runtime), and a quit
            // request is not proof that it exited.
            let check = mirroringCheck(pid)
            if check != .other {
                let requested = process.startedAt != nil && backend.processIdentity(pid) == process && platform.quit(pid: pid)
                throw Self.blockedAppError(notSent: false, unverified: check == .unverified, launched: process,
                                           quitRequested: requested)
            }
            d.launched.append(process)
            return .obj([
                ("desktopId", .string(d.desktopId)),
                ("process", process.json),
                ("windows", .array(windows.map(Self.placedJSON))),
            ])
        }
    }

    static func placedJSON(_ w: PlatformWindow) -> JSONValue {
        .obj([("windowId", .int(Int(w.windowId))), ("appName", .string(w.appName)),
              ("title", .string(w.title)), ("frame", w.frame.json)])
    }

    /// Move the window onto the Desktop and make it the Desktop's target.
    func bindWindow(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"], as: c, method: "window.bind") { d in
            guard let pid = p["pid"]?.intValue.map(Int32.init) else { throw RuntimeError.schemaInvalid("pid is required") }
            let wanted = p["windowId"]?.intValue.map(UInt32.init)
            // The app is checked again under the lock, naming nothing (round-four review L2).
            if c.role == .paired,
               !appAllowed(c, bundleId: backend.applications(includeBackground: true).first { $0.process.pid == pid }?.bundleId) {
                throw RuntimeError("grant_missing", "binding this window needs a grant for its app, which this client does not have",
                                   phase: .request, notSent: true, details: .obj([("reason", .string("bind_requires_grant"))]))
            }
            // #139, after the grant check so a refusal names no app the
            // caller may not see.
            try refuseMirroring(pid)
            let process = backend.processIdentity(pid)
            // The grant check comes first: a refusal says nothing about
            // whether a process with that pid exists.
            if d.kind == .virtual && bindsOnlyLaunchedProcesses && !d.launched.contains(process) {
                throw RuntimeError("permission_denied",
                                   "only an app launched on desktop \(d.desktopId) can be bound until per-window grants exist; launch it there with app.launch",
                                   phase: .handler, notSent: true,
                                   details: .obj([("reason", .string("bind_requires_grant"))]))
            }
            guard process.startedAt != nil else { throw RuntimeError.notFound("no process \(pid)") }
            if d.kind == .physical {
                // Never move the user's window: it must already be on this display.
                guard let wanted else {
                    throw RuntimeError.invalidArgument("binding on a physical Desktop needs windowId (the window stays where the user put it)")
                }
                guard let window = platform.window(on: d.screen, pid: pid, windowId: wanted) else {
                    throw RuntimeError("invalid_target",
                                       "window \(wanted) of pid \(pid) is not on display \(d.screen.displayId); a physical Desktop does not move windows",
                                       phase: .handler, notSent: true)
                }
                d.generation += 1
                d.binding = TargetBinding(generation: d.generation, process: process, windowId: window.windowId,
                                          appName: window.appName, boundAt: nowString)
                return d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
            }
            let moved = try platform.moveWindows(to: d.screen, pid: pid, windowId: wanted)
            guard let chosen = wanted ?? moved.first?.windowId,
                  let window = platform.window(on: d.screen, pid: pid, windowId: chosen)
            else {
                throw RuntimeError.notFound("pid \(pid) has no window on desktop \(d.desktopId) after the move")
            }
            d.generation += 1
            d.binding = TargetBinding(generation: d.generation, process: process, windowId: window.windowId,
                                      appName: window.appName, boundAt: nowString)
            return d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
        }
    }

    func unbindWindow(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        withDesktop(p["desktopId"], as: c, method: "window.unbind") { d in
            if d.binding != nil {
                d.generation += 1
                d.binding = nil
            }
            return d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
        }
    }

    func openSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        withDesktop(p["desktopId"], as: c, method: "session.open") { d in
            sessions.open(desktopId: d.desktopId, caller: c.clientId, at: nowString).json
        }
    }

    func showSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["sessionId"]?.stringValue ?? ""
        guard let s = sessions.find(id, caller: c.clientId) else { return .failure(.notFound("no session \(id)")) }
        return .success(s.json)
    }

    func closeSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["sessionId"]?.stringValue ?? ""
        guard sessions.find(id, caller: c.clientId) != nil, let s = sessions.close(id, at: nowString) else {
            return .failure(.notFound("no session \(id)"))
        }
        return .success(s.json)
    }

    func showRequest(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["requestId"]?.stringValue ?? ""
        guard let r = try? ledger.record(caller: c.clientId, requestId: id) else {
            return .failure(.notFound("no request \(id) within the last \(RequestLedger.retentionDays) days"))
        }
        var m: [(String, JSONValue)] = [("requestId", .string(r.requestId)), ("method", .string(r.method)),
                                        ("state", .string(r.state.rawValue)), ("acceptedAt", .string(r.acceptedAt))]
        if let f = r.finishedAt { m.append(("finishedAt", .string(f))) }
        if let o = r.outcome { m.append(("outcome", o)) }
        return .success(.obj(m))
    }
}
