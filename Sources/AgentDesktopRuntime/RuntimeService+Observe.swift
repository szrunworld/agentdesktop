import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// The Desktop a request is aimed at: its open Session, else its
    /// desktopId. The Session must belong to the caller.
    func target(of request: RuntimeRequest, _ c: ConnectionState) -> Result<(DesktopRecord, RuntimeSession?), RuntimeError> {
        if let sid = request.context.sessionId {
            guard let s = sessions.find(sid, caller: c.peerUID) else { return .failure(.notFound("no session \(sid)")) }
            guard s.state == "open" else {
                return .failure(RuntimeError("conflict", "session \(sid) is closed", phase: .handler))
            }
            if let did = request.context.desktopId, did != s.desktopId {
                return .failure(.schemaInvalid("session \(sid) belongs to desktop \(s.desktopId), not \(did)"))
            }
            return desktop(.string(s.desktopId)).map { ($0, s) }
        }
        if let did = request.context.desktopId {
            return desktop(.string(did)).map { ($0, nil) }
        }
        return .failure(.schemaInvalid("name the target with context.sessionId or context.desktopId"))
    }

    /// Screenshot, elements of the bound window, and the transforms that
    /// tie both to global points, stored under a new snapshotId.
    func observe(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        let p = request.params
        let session: RuntimeSession?
        let d: DesktopRecord
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((desk, s)): d = desk; session = s
        }
        return withDesktop(.string(d.desktopId)) { d in
            let snapshotId = DesktopRegistry.newId(prefix: "obs")
            var stored = StoredObservation(snapshotId: snapshotId, desktopId: d.desktopId, capturedAt: nowString,
                                           screen: d.screen, binding: d.binding, windowFrame: nil, transform: nil,
                                           imageSize: nil, elements: [:], readElements: false)
            var image: JSONValue = .null
            if p["screenshot"]?.boolValue ?? true {
                let artifactId = "art_" + snapshotId.dropFirst(4)
                let path = artifacts.path(for: artifactId, ext: "png")
                let size = try platform.screenshot(d.screen, to: path)
                let scale = Double(size.width) / max(1, d.screen.frame.width)
                stored.transform = (d.screen.frame.x, d.screen.frame.y, scale)
                stored.imageSize = size
                image = .obj([
                    ("artifactId", .string(artifactId)), ("path", .string(path)), ("mediaType", .string("image/png")),
                    ("width", .int(size.width)), ("height", .int(size.height)),
                    ("transform", .obj([("originX", .double(d.screen.frame.x)), ("originY", .double(d.screen.frame.y)),
                                        ("scale", .double(scale))])),
                ])
            }
            var targetJSON: JSONValue = .null
            var elementsJSON: [JSONValue] = []
            if let b = d.binding {
                // The same launch of the same process, or the binding is stale.
                let now = backend.processIdentity(b.process.pid)
                guard now == b.process else {
                    throw RuntimeError("stale_observation",
                                       "the bound process \(b.process.pid) has exited or restarted; bind the window again",
                                       phase: .handler, details: .obj([("generation", .int(b.generation))]))
                }
                guard let window = platform.window(on: d.screen, pid: b.process.pid, windowId: b.windowId) else {
                    throw RuntimeError("stale_observation",
                                       "window \(b.windowId) is no longer on desktop \(d.desktopId); bind a window again",
                                       phase: .handler, details: .obj([("generation", .int(b.generation))]))
                }
                var frame = window.frame
                var title = window.title
                if p["elements"]?.boolValue ?? true {
                    let read = try platform.elements(on: d.screen, pid: b.process.pid, windowId: b.windowId,
                                                     query: p["query"]?.stringValue)
                    frame = read.window.frame
                    title = read.window.title
                    stored.readElements = true
                    for e in read.elements where e.index >= 0 {
                        let id = "el_\(e.index)"
                        stored.elements[id] = e
                        elementsJSON.append(.obj([
                            ("id", .string(id)), ("role", .string(e.role)),
                            ("label", e.label.map(JSONValue.string) ?? .null),
                            ("value", e.value.map(JSONValue.string) ?? .null),
                            ("actions", .array(e.actions.map(JSONValue.string))),
                            ("frame", e.frame?.json ?? .null),
                        ]))
                    }
                }
                stored.windowFrame = frame
                targetJSON = .obj([("generation", .int(b.generation)), ("process", b.process.json),
                                   ("windowId", .int(Int(b.windowId))), ("windowFrame", frame.json),
                                   ("title", .string(title))])
            }
            observations.store(stored)
            var m: [(String, JSONValue)] = [("snapshotId", .string(snapshotId)), ("desktopId", .string(d.desktopId))]
            if let session { m.append(("sessionId", .string(session.sessionId))) }
            m += [("capturedAt", .string(stored.capturedAt)), ("screen", DesktopRecord.screenJSON(d.screen)),
                  ("target", targetJSON), ("image", image), ("elements", .array(elementsJSON))]
            return .obj(m)
        }
    }
}
