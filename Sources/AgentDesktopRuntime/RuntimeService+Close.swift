import AgentDesktopProtocol
import Foundation

// A5: what closing a Desktop would end and keep (Design P18), quitting one
// app the Desktop launched, and resizing a virtual Desktop. Closing never
// ends what the Desktop did not start: the user's own apps that only lent
// a window, and everything on a physical Desktop, stay as they are.
extension RuntimeService {
    /// How long app.quit waits for the process to exit before answering
    /// that it was only asked to; tests shorten it.
    static let quitWait: TimeInterval = 3

    /// desktop.closePlan: what desktop.destroy would do now, without doing it.
    func closePlan(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard isOwner(c) else { return .failure(Self.ownerOnly("desktop.closePlan")) }
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"]) { d in
            var blockers: [JSONValue] = []
            if let holder = execution.holder(of: d.desktopId) {
                blockers.append(.obj([("kind", .string("run")), ("runId", .string(holder)),
                                      ("origin", runs.find(holder).map { .string($0.origin.rawValue) } ?? .null)]))
            }
            let open = sessions.openCount(desktopId: d.desktopId)
            if open > 0 { blockers.append(.obj([("kind", .string("sessions")), ("count", .int(open))])) }
            let apps = backend.applications(includeBackground: true)
            func describe(_ process: ProcessIdentity, reason: String? = nil) -> JSONValue {
                let app = apps.first { $0.process.pid == process.pid }
                var m: [(String, JSONValue)] = [("process", process.json), ("appName", app.map { .string($0.name) } ?? .null),
                                                ("bundleId", app?.bundleId.map(JSONValue.string) ?? .null)]
                if let reason { m.append(("reason", .string(reason))) }
                return .obj(m)
            }
            // What destroy asks to quit: launches made here that still run.
            let quit = d.kind == .virtual ? d.launched.filter { backend.processIdentity($0.pid) == $0 } : []
            // Everything else showing a window on the surface stays.
            var kept: [ProcessIdentity] = []
            for w in platform.stack(on: d.screen) {
                let process = backend.processIdentity(w.pid)
                if !quit.contains(process), !kept.contains(process) { kept.append(process) }
            }
            if let b = d.binding, !quit.contains(b.process), !kept.contains(b.process) { kept.append(b.process) }
            let keepReason = d.kind == .physical ? "physical_desktop" : "not_launched_here"
            return .obj([
                ("desktopId", .string(d.desktopId)), ("kind", .string(d.kind.rawValue)),
                ("display", .string(d.kind == .physical ? "kept" : "destroyed")),
                ("canClose", .bool(blockers.isEmpty)), ("blockers", .array(blockers)),
                ("quit", .array(quit.map { describe($0) })),
                ("keep", .array(kept.map { describe($0, reason: keepReason) })),
            ])
        }
    }

    /// app.quit: end one process app.launch started on this Desktop (a
    /// paired app: one it launched itself). Answered once the process exited,
    /// or after `quitWait` with exited false: asking is not proof.
    func quitApp(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"], as: c, method: "app.quit") { d in
            guard let raw = p["pid"]?.intValue, let pid = Int32(exactly: raw) else {
                throw RuntimeError.invalidArgument("pid must fit a process ID")
            }
            let process = backend.processIdentity(pid)
            // The same refusal whether the pid exists, is the user's or is
            // another client's launch: it names nothing.
            guard process.startedAt != nil, d.launched.contains(process),
                  c.role != .paired || d.launchedBy[process]?.clientId == c.clientId else {
                throw RuntimeError("permission_denied",
                                   "app.quit ends only a process app.launch started on desktop \(d.desktopId)\(c.role == .paired ? " for this client" : "")",
                                   phase: .handler, notSent: true, details: .obj([("reason", .string("not_launched_here"))]))
            }
            if let holder = execution.holder(of: d.desktopId), !isOwner(c), runs.find(holder)?.clientId != c.clientId {
                throw RuntimeError("control_busy", "run \(holder) controls desktop \(d.desktopId)", phase: .handler,
                                   retryable: true, notSent: true,
                                   details: .obj([("desktopId", .string(d.desktopId)), ("holderRunId", .string(holder))]))
            }
            let requested = platform.quit(pid: pid)
            var exited = false
            let until = now().addingTimeInterval(requested ? quitWait : 0)
            repeat {
                if backend.processIdentity(pid) != process { exited = true; break }
                Thread.sleep(forTimeInterval: 0.05)
            } while now() < until
            if exited {
                d.launched.removeAll { $0 == process }
                d.launchedBy[process] = nil
                if d.binding?.process == process {
                    d.generation += 1
                    d.binding = nil
                }
            }
            return .obj([("desktopId", .string(d.desktopId)), ("process", process.json),
                         ("quitRequested", .bool(requested)), ("exited", .bool(exited))])
        }
    }

    /// desktop.resize: a virtual Desktop's size, changed in place. Every
    /// observation of it is forgotten (its geometry no longer holds).
    func resizeDesktop(_ p: JSONValue, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        return withDesktop(p["desktopId"], as: c, method: "desktop.resize") { d in
            guard d.kind == .virtual else {
                throw RuntimeError("invalid_target", "desktop \(d.desktopId) is physical: its display is the user's and keeps its size",
                                   phase: .handler, notSent: true)
            }
            if let holder = execution.holder(of: d.desktopId), !isOwner(c), runs.find(holder)?.clientId != c.clientId {
                throw RuntimeError("control_busy", "run \(holder) controls desktop \(d.desktopId)", phase: .handler,
                                   retryable: true, notSent: true,
                                   details: .obj([("desktopId", .string(d.desktopId)), ("holderRunId", .string(holder))]))
            }
            let width = p["width"]?.intValue ?? 0, height = p["height"]?.intValue ?? 0
            let screen = try platform.resizeScreen(name: d.screen.name, width: width, height: height)
            d.resized(to: screen)
            observations.forget(desktopId: d.desktopId)
            return d.json(openSessions: sessions.openCount(desktopId: d.desktopId))
        }
    }
}
