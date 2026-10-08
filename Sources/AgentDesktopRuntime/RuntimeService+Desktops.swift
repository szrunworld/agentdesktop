import AgentDesktopContracts
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
    func withDesktop(_ id: JSONValue?, until: Date? = nil, _ body: (DesktopRecord) throws -> JSONValue) -> Result<JSONValue, RuntimeError> {
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

    func createDesktop(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        createLock.lock()
        defer { createLock.unlock() }
        let id = DesktopRegistry.newId(prefix: "d")
        let name = p["name"]?.stringValue ?? id
        if desktops.names().contains(name) {
            return .failure(RuntimeError("conflict", "a desktop named \(name) exists", phase: .handler))
        }
        do {
            let screen = try platform.createScreen(name: id, width: p["width"]?.intValue, height: p["height"]?.intValue)
            let d = desktops.add(desktopId: id, name: name, screen: screen, createdAt: nowString)
            return .success(desktopJSON(d))
        } catch let e as PlatformError {
            return .failure(e.runtimeError)
        } catch {
            return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
        }
    }

    func destroyDesktop(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"]) { d in
            if let holder = execution.holder(of: d.desktopId) {
                throw RuntimeError("conflict", "run \(holder) controls desktop \(d.desktopId); cancel it first",
                                   phase: .handler, details: .obj([("holderRunId", .string(holder))]))
            }
            let open = sessions.openCount(desktopId: d.desktopId)
            guard open == 0 else {
                throw RuntimeError("conflict", "desktop \(d.desktopId) has \(open) open session(s); close them first",
                                   phase: .handler, details: .obj([("openSessions", .int(open))]))
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

    func launchApp(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"]) { d in
            let (pid, windows) = try platform.launch(on: d.screen, bundleId: p["bundleId"]?.stringValue,
                                                     path: p["path"]?.stringValue,
                                                     newInstance: p["newInstance"]?.boolValue ?? false)
            d.launched.append(backend.processIdentity(pid))
            return .obj([
                ("desktopId", .string(d.desktopId)),
                ("process", backend.processIdentity(pid).json),
                ("windows", .array(windows.map(Self.placedJSON))),
            ])
        }
    }

    static func placedJSON(_ w: PlatformWindow) -> JSONValue {
        .obj([("windowId", .int(Int(w.windowId))), ("appName", .string(w.appName)),
              ("title", .string(w.title)), ("frame", w.frame.json)])
    }

    /// Move the window onto the Desktop and make it the Desktop's target.
    func bindWindow(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"]) { d in
            guard let pid = p["pid"]?.intValue.map(Int32.init) else { throw RuntimeError.schemaInvalid("pid is required") }
            let wanted = p["windowId"]?.intValue.map(UInt32.init)
            let process = backend.processIdentity(pid)
            guard process.startedAt != nil else { throw RuntimeError.notFound("no process \(pid)") }
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

    func unbindWindow(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        withDesktop(p["desktopId"]) { d in
            if d.binding != nil {
                d.generation += 1
                d.binding = nil
            }
            return d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
        }
    }

    func openSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        withDesktop(p["desktopId"]) { d in
            sessions.open(desktopId: d.desktopId, caller: c.peerUID, at: nowString).json
        }
    }

    func showSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["sessionId"]?.stringValue ?? ""
        guard let s = sessions.find(id, caller: c.peerUID) else { return .failure(.notFound("no session \(id)")) }
        return .success(s.json)
    }

    func closeSession(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["sessionId"]?.stringValue ?? ""
        guard sessions.find(id, caller: c.peerUID) != nil, let s = sessions.close(id, at: nowString) else {
            return .failure(.notFound("no session \(id)"))
        }
        return .success(s.json)
    }

    func showRequest(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        let id = p["requestId"]?.stringValue ?? ""
        guard let r = try? ledger.record(caller: c.peerUID, requestId: id) else {
            return .failure(.notFound("no request \(id) within the last \(RequestLedger.retentionDays) days"))
        }
        var m: [(String, JSONValue)] = [("requestId", .string(r.requestId)), ("method", .string(r.method)),
                                        ("state", .string(r.state.rawValue)), ("acceptedAt", .string(r.acceptedAt))]
        if let f = r.finishedAt { m.append(("finishedAt", .string(f))) }
        if let o = r.outcome { m.append(("outcome", o)) }
        return .success(.obj(m))
    }
}
