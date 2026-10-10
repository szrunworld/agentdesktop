import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// The Desktop a request is aimed at: its open Session, else its
    /// desktopId. The Session must belong to the caller.
    func target(of request: RuntimeRequest, _ c: ConnectionState) -> Result<(DesktopRecord, RuntimeSession?), RuntimeError> {
        if let sid = request.context.sessionId {
            guard let s = sessions.find(sid, caller: c.clientId) else { return .failure(.notFound("no session \(sid)")) }
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
    ///
    /// Three steps. Under the Desktop's lock: the G0 checks and the
    /// screenshot. Without it, on the AX threads: the element read, bounded
    /// by a deadline (a slow app delays only this observation, never the
    /// Desktop's other requests or another Desktop). Under the lock again:
    /// the window must still be the exposed bound window it was, and the
    /// observation is stored. An element read that ran out of time leaves the
    /// observation with its screenshot and `coverage.ax` partial or
    /// unavailable.
    func observe(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        let p = request.params
        let session: RuntimeSession?
        let desk: DesktopRecord
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((d, s)): desk = d; session = s
        }
        // Screenshots count against a quota bucket: the Run named in the
        // context, which must be one this connection owns or joined (a made-up
        // or another caller's runId neither gets a fresh quota nor spends
        // someone else's); otherwise the session, else the Desktop.
        let bucket: String
        // The GUI ports' own observation for a GUI Run: its own bucket, its
        // place already reserved by the ports.
        let reserved = takeQuotaBucket(requestId: request.requestId, connection: c)
        if let gui = reserved {
            bucket = gui
        } else if let runId = request.context.runId {
            if case let .failure(e) = execution.authorized(runId: runId, connection: c) { return .failure(e) }
            bucket = "run:" + runId
        } else if let session {
            bucket = "session:" + session.sessionId
        } else {
            bucket = "desktop:" + desk.desktopId
        }
        let requestDeadline = request.deadline.flatMap(Timestamp.date)
        let snapshotId = DesktopRegistry.newId(prefix: "obs")
        let wantsImage = p["screenshot"]?.boolValue ?? true
        let wantsElements = p["elements"]?.boolValue ?? true
        var stored = StoredObservation(snapshotId: snapshotId, desktopId: desk.desktopId, capturedAt: nowString,
                                       screen: desk.screen, binding: nil, windowFrame: nil, transform: nil,
                                       imageSize: nil, elements: [:], readElements: false)
        var image: JSONValue = .null
        var exposed: (window: PlatformWindow, stack: [StackEntry])?
        // The window grant this observation is made under (a paired app's
        // window it did not launch here), and whether it may keep the image.
        var windowGrant: HubStore.WindowGrant?
        // The grant the image was registered under, and what it needs from
        // it (persist when kept, observe when transient).
        var keptUnderGrant: HubStore.WindowGrant?
        var keptPermission = "observe"

        // 1. Under the lock: checks and screenshot.
        let first = withDesktop(.string(desk.desktopId), until: requestDeadline, as: c, method: "observe") { d -> JSONValue in
            stored.binding = d.binding
            /// The screen, or with a binding only the bound window's frame.
            func capture(_ crop: AgentDesktopProtocol.Rect?) throws {
                // Within the store's limits, before anything is captured.
                if reserved == nil { try artifacts.admit(bucket: bucket) }
                let artifactId = "art_" + snapshotId.dropFirst(4)
                let path = artifacts.path(for: artifactId, ext: "png")
                // The bound window alone, never the screen cut down afterwards:
                // no whole-screen image is written, even for a moment.
                let size: (width: Int, height: Int)
                do {
                    if let b = d.binding, crop != nil {
                        size = try platform.windowScreenshot(d.screen, pid: b.process.pid, windowId: b.windowId, to: path)
                    } else {
                        size = try platform.screenshot(d.screen, to: path)
                    }
                } catch {
                    // No half-written image is left behind, uncounted.
                    unlink(path)
                    // A place the ports reserved is theirs to give back.
                    if reserved == nil { artifacts.release(bucket: bucket) }
                    throw error
                }
                let origin = crop.map { ($0.x, $0.y) } ?? (d.screen.frame.x, d.screen.frame.y)
                let scale = Double(size.width) / max(1, crop?.width ?? d.screen.frame.width)
                // Kept as usual only with persist; else for a short while,
                // gone with the grant (window-grants.md).
                var transientUntil: Date?
                // Kept under whichever live grant for this window allows
                // persist, not only the one that allowed observe (Codex on
                // 9ea0dad); that grant is the one the image then answers to.
                var keptUnder = windowGrant
                if windowGrant != nil, let b = d.binding {
                    // Both chosen among the grants live now, after the
                    // capture (Codex on 5e30bb6 and a228d4d: the one that
                    // allowed observe may have run out meanwhile).
                    let live = liveWindowGrants(c, desktopId: d.desktopId, windowId: b.windowId, process: b.process)
                    let persisting = live.first { effectivePermissions($0).contains("persist") }
                    let observing = live.first { effectivePermissions($0).contains("observe") }
                    guard let g = persisting ?? observing else {
                        // Nothing written stays, uncounted (as for a failed register).
                        unlink(path)
                        if reserved == nil { artifacts.release(bucket: bucket) }
                        throw RuntimeError("grant_missing", "the window grant ended while the window was captured", phase: .handler,
                                           notSent: true, details: .obj([("reason", .string("window_grant_ended"))]))
                    }
                    keptUnder = g
                    keptPermission = persisting != nil ? "persist" : "observe"
                    if persisting != nil {
                        hub.audit(connectionId: c.connectionId, clientId: c.clientId, method: "window.persist", decision: "used",
                                  reason: "\(g.windowGrantId) observe")
                    } else {
                        // Never past the grant itself (Codex on 046a8c2).
                        let lifetime = now().addingTimeInterval(transientArtifactLifetime)
                        transientUntil = min(lifetime, Timestamp.date(g.expiresAt) ?? lifetime)
                    }
                    keptUnderGrant = g
                }
                let info: ArtifactStore.Info
                do {
                    info = try artifacts.register(artifactId, mediaType: "image/png", clientId: c.clientId,
                                                  runId: reserved.map { String($0.dropFirst("gui:".count)) } ?? request.context.runId,
                                                  createdAt: nowString, bucket: bucket, transientUntil: transientUntil,
                                                  windowGrantId: keptUnder?.windowGrantId)
                } catch {
                    unlink(path)
                    // A place the ports reserved is theirs to give back.
                    if reserved == nil { artifacts.release(bucket: bucket) }
                    throw error
                }
                // The reserved place is now the stored screenshot's, whatever
                // happens later in this observe: the ports must not give it back.
                if reserved != nil { markQuotaUsed(requestId: request.requestId, connection: c) }
                stored.transform = (origin.0, origin.1, scale)
                stored.imageSize = size
                var fields: [(String, JSONValue)] = [
                    ("artifactId", .string(artifactId)), ("mediaType", .string("image/png")),
                    ("width", .int(size.width)), ("height", .int(size.height)),
                    ("byteSize", .int(info.byteSize)), ("sha256", .string(info.sha256)),
                    ("transform", .obj([("originX", .double(origin.0)), ("originY", .double(origin.1)),
                                        ("scale", .double(scale))])),
                ]
                if let expiresAt = info.expiresAt { fields += [("transient", .bool(true)), ("expiresAt", .string(expiresAt))] }
                image = .obj(fields)
            }
            guard let b = d.binding else {
                if wantsImage && refusesScreenCaptureWithoutBinding {
                    throw RuntimeError("invalid_target",
                                       "desktop \(d.desktopId) has no bound window; a screenshot of the whole screen needs a screen-level grant",
                                       phase: .handler, notSent: true,
                                       details: .obj([("reason", .string("screen_capture_requires_grant"))]))
                }
                // A physical Desktop shows the user's own screen: without a
                // bound window there is nothing it may look at.
                guard d.kind == .virtual else {
                    throw RuntimeError("invalid_target",
                                       "desktop \(d.desktopId) is physical and has no bound window; bind the window to observe it",
                                       phase: .handler, notSent: true)
                }
                // A paired app sees a whole screen only of its own launches.
                if wantsImage, let e = wholeScreenRefusal(c, d) { throw e }
                if wantsImage { try capture(nil) }
                return .null
            }
            // Observe on this window, for this caller, as the grant is now
            // (before anything of the window is read).
            windowGrant = try windowUse(c, d, b, "observe", method: "observe")
            // The same launch of the same process, or the binding is stale.
            guard backend.processIdentity(b.process.pid) == b.process else {
                throw RuntimeError("stale_observation",
                                   "the bound process \(b.process.pid) has exited or restarted; bind the window again",
                                   phase: .handler, details: .obj([("generation", .int(b.generation))]))
            }
            // #139, before anything is captured or read: nothing was done.
            try refuseMirroring(b.process.pid, notSent: true)
            // G0: only the bound window is shown, and only while nothing
            // else could be seen or reached in its place.
            let e = try exposedTarget(d, b, notSent: false)
            exposed = e
            if wantsImage {
                // The window capture renders the whole window, also the part
                // reaching past the screen edge, so the image's origin and
                // scale are the window's own frame, never a frame cut at the
                // edge (that would shift every image point).
                try capture(e.window.frame)
            }
            // The read below replaces the backend's numbering: no element
            // reference of this Desktop holds until it is stored.
            if wantsElements { observations.invalidateElementRefs(desktopId: d.desktopId) }
            return .null
        }
        if case let .failure(e) = first { return .failure(e) }

        // 2. Without the lock, on the AX threads: the element read.
        var read: ElementRead?
        var ax: (state: String, reason: String?) = ("not_requested", nil)
        if let b = stored.binding, wantsElements {
            let budget = now().addingTimeInterval(elementReadBudget)
            let deadline = requestDeadline.map { min($0, budget) } ?? budget
            let screen = desk.screen
            let query = p["query"]?.stringValue
            switch axReader.read(desktopId: desk.desktopId, deadline: deadline, {
                try platform.elements(on: screen, pid: b.process.pid, windowId: b.windowId, query: query, deadline: deadline)
            }) {
            case let .read(r):
                read = r
                ax = r.truncated.map { ("partial", $0) } ?? ("complete", nil)
            case .timedOut: ax = ("unavailable", "deadline")
            case .busy: ax = ("unavailable", "busy")
            // A missing permission is for the user to fix: say so.
            case let .failed(e as PlatformError) where e.kind == .permission:
                // Not answered: an image taken under a window grant goes now (Codex on 5ae0e5e).
                if windowGrant != nil, let id = image["artifactId"]?.stringValue { artifacts.remove(id) }
                return .failure(e.runtimeError)
            // An app that does not answer accessibility (frozen, busy, or
            // hiding the window from it) still has its screenshot.
            case .failed: ax = ("unavailable", "error")
            }
        }

        // 3. Under the lock again: still the same exposed window; store.
        let stored3 = withDesktop(.string(desk.desktopId), until: requestDeadline, as: c, method: "observe") { d -> JSONValue in
            var targetJSON: JSONValue = .null
            var elementsJSON: [JSONValue] = []
            if let b = stored.binding, let before = exposed {
                // Still allowed to see it, right before it is stored and
                // answered; else the image taken goes too.
                do { _ = try windowUse(c, d, b, "observe", method: "observe", audit: false) } catch {
                    if let id = image["artifactId"]?.stringValue { artifacts.remove(id) }
                    throw error
                }
                // The grant the image is registered under must still hold too
                // (Codex on f726493, a228d4d); else nothing is answered (the
                // image goes with the failure below).
                if let p = keptUnderGrant,
                   !liveWindowGrants(c, desktopId: d.desktopId, windowId: b.windowId, process: b.process)
                       .contains(where: { $0.windowGrantId == p.windowGrantId && effectivePermissions($0).contains(keptPermission) }) {
                    throw RuntimeError("stale_observation", "the window grant this screenshot was taken under ended while the window was observed; observe again",
                                       phase: .handler,
                                       details: .obj([("reason", .string(keptPermission == "persist" ? "persist_grant_ended" : "window_grant_ended"))]))
                }
                guard d.binding?.generation == b.generation else {
                    throw RuntimeError("stale_observation", "the binding changed while desktop \(d.desktopId) was observed; observe again",
                                       phase: .handler, details: .obj([("reason", .string("changed_during_capture"))]))
                }
                let after = try exposedTarget(d, b, notSent: false)
                guard after.stack == before.stack, Self.sameFrame(after.window.frame, before.window.frame) else {
                    // Which windows differ, for diagnosis (ids and frames only).
                    func describe(_ s: [StackEntry]) -> JSONValue {
                        .array(s.map { .obj([("windowId", .int(Int($0.windowId))), ("frame", $0.frame.json)]) })
                    }
                    throw RuntimeError("stale_observation", "the windows on desktop \(d.desktopId) changed while it was observed; observe again",
                                       phase: .handler, details: .obj([("reason", .string("changed_during_capture")),
                                                                       ("generation", .int(b.generation)),
                                                                       ("stackBefore", describe(before.stack)),
                                                                       ("stackAfter", describe(after.stack)),
                                                                       ("frameBefore", before.window.frame.json),
                                                                       ("frameAfter", after.window.frame.json)]))
                }
                var frame = before.window.frame
                var title = before.window.title
                if wantsElements {
                    // Even an unfinished read counts as the latest: older
                    // references stay invalid, and only these are usable.
                    stored.readElements = true
                    if let read {
                        frame = read.window.frame
                        title = read.window.title
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
                }
                stored.windowFrame = frame
                targetJSON = .obj([("generation", .int(b.generation)), ("process", b.process.json),
                                   ("windowId", .int(Int(b.windowId))), ("windowFrame", frame.json),
                                   ("title", .string(title))])
            }
            observations.store(stored)
            var m: [(String, JSONValue)] = [("snapshotId", .string(snapshotId)), ("desktopId", .string(d.desktopId))]
            if let session { m.append(("sessionId", .string(session.sessionId))) }
            var coverage: [(String, JSONValue)] = [("screenshot", .string(wantsImage ? "complete" : "not_requested")),
                                                   ("ax", .string(stored.binding == nil ? "not_requested" : ax.state))]
            if let reason = ax.reason { coverage.append(("axReason", .string(reason))) }
            m += [("capturedAt", .string(stored.capturedAt)), ("screen", DesktopRecord.screenJSON(d.screen)),
                  ("target", targetJSON), ("image", image), ("elements", .array(elementsJSON)),
                  ("coverage", .obj(coverage))]
            return .obj(m)
        }
        // Taken under a window grant and not answered (revoked meanwhile, the
        // window changed, …): the image goes now, not at its expiry (Codex on
        // 0232db6).
        if case .failure = stored3, windowGrant != nil, let id = image["artifactId"]?.stringValue { artifacts.remove(id) }
        return stored3
    }
}

extension RuntimeService {
    /// A quota bucket set in process for one request of one connection (the
    /// GUI ports' observation of a GUI Run). Nothing on the socket can set
    /// one: only code in this module calls `setQuotaBucket`.
    func setQuotaBucket(_ bucket: String, requestId: String, connection: ConnectionState) {
        quotaBucketLock.withLock { quotaBuckets[connection.connectionId + "|" + requestId] = bucket }
    }

    func takeQuotaBucket(requestId: String, connection: ConnectionState) -> String? {
        quotaBucketLock.withLock { quotaBuckets.removeValue(forKey: connection.connectionId + "|" + requestId) }
    }

    func markQuotaUsed(requestId: String, connection: ConnectionState) {
        _ = quotaBucketLock.withLock { quotaBucketsUsed.insert(connection.connectionId + "|" + requestId) }
    }

    /// Whether that request's observe registered a screenshot in its reserved
    /// place; asked once, by the ports, after the observe returns.
    func takeQuotaUsed(requestId: String, connection: ConnectionState) -> Bool {
        quotaBucketLock.withLock { quotaBucketsUsed.remove(connection.connectionId + "|" + requestId) != nil }
    }
}
