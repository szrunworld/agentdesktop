import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

extension RuntimeService {
    /// One action against a snapshot (CLI plan §07 ActHandler):
    /// identity and dedup (ledger) → session, Run and lease → Desktop queue
    /// (its lock) and process lock → re-check binding, process, window
    /// geometry and the target against the snapshot → delivery boundary →
    /// platform → ActionReceipt.
    func act(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        guard request.context.sessionId != nil else {
            return .failure(.schemaInvalid("act needs context.sessionId: input without a session is refused"))
        }
        let acceptedAt = nowString
        let session: RuntimeSession
        let desk: DesktopRecord
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((d, s)): desk = d; session = s!
        }

        // The Run: an exec Run this connection owns or joined, or a new
        // one-action Run that ends with this request.
        let runId: String
        var oneShot = false
        if let rid = request.context.runId {
            switch execution.authorized(runId: rid, connection: c) {
            case let .failure(e): return .failure(e)
            case let .success(r):
                guard r.desktopId == desk.desktopId else {
                    return .failure(.schemaInvalid("run \(rid) is on desktop \(r.desktopId), not \(desk.desktopId)"))
                }
                runId = rid
            }
        } else {
            switch execution.start(kind: "act", session: session, owner: c) {
            case let .failure(e): return .failure(e)
            case let .success((r, _)): runId = r.runId; oneShot = true
            }
        }
        // A one-action Run ends with this request: success if its input was
        // delivered, failed if refused; an unknown delivery makes it unknown.
        var oneShotOutcome: RunRecord.Outcome = .failed
        defer {
            if oneShot {
                execution.stop(runId: runId, reason: "completed", endAs: oneShotOutcome)
                c.ownedRuns.remove(runId)
            }
        }
        runs.appendEvent(runId, "action.accepted", .obj([("requestId", .string(request.requestId)),
                                                         ("kind", .string(request.params["action"]?["kind"]?.stringValue ?? ""))]))

        let snapshotId = request.params["snapshotId"]?.stringValue ?? ""
        guard let snap = observations.find(snapshotId), snap.desktopId == desk.desktopId else {
            return .failure(RuntimeError("stale_observation", "snapshot \(snapshotId) is unknown or expired on desktop \(desk.desktopId); observe again",
                                         phase: .handler, notSent: true))
        }
        let action = request.params["action"] ?? .obj([])

        let result = withDesktop(.string(desk.desktopId)) { d -> JSONValue in
            guard let b = d.binding else {
                throw RuntimeError("stale_observation", "desktop \(d.desktopId) has no bound window", phase: .handler, notSent: true)
            }
            return try conflicts.withProcess(b.process.pid) {
                // The snapshot must describe the target as it is now.
                guard let sb = snap.binding, sb.generation == b.generation else {
                    throw RuntimeError("stale_observation", "the binding changed since snapshot \(snapshotId); observe again",
                                       phase: .handler, notSent: true, details: .obj([("generation", .int(b.generation))]))
                }
                guard backend.processIdentity(b.process.pid) == b.process else {
                    throw RuntimeError("stale_observation", "process \(b.process.pid) exited or restarted; bind again",
                                       phase: .handler, notSent: true)
                }
                guard let window = platform.window(on: d.screen, pid: b.process.pid, windowId: b.windowId) else {
                    throw RuntimeError("stale_observation", "window \(b.windowId) left desktop \(d.desktopId)",
                                       phase: .handler, notSent: true)
                }
                if let was = snap.windowFrame, !Self.sameFrame(was, window.frame) {
                    throw RuntimeError("stale_observation", "window \(b.windowId) moved or resized since snapshot \(snapshotId); observe again",
                                       phase: .handler, notSent: true)
                }
                var pa = try platformAction(action, snap: snap, window: window)
                if pa.modifiers.isEmpty { pa.modifiers = [] }
                if let deadline = request.deadline.flatMap(Timestamp.date), now() >= deadline {
                    throw RuntimeError("deadline_exceeded", "the deadline \(request.deadline!) passed before dispatch; nothing was sent",
                                       phase: .handler, notSent: true)
                }
                if let stopped = execution.beginAction(runId: runId) { throw stopped }

                // Delivery boundary: from here an interruption is unknown.
                ledger.markDispatching(caller: c.peerUID, requestId: request.requestId)
                let dispatchedAt = nowString
                runs.appendEvent(runId, "action.dispatched", .obj([("requestId", .string(request.requestId))]))
                let receiptId = DesktopRegistry.newId(prefix: "rcpt")
                var delivery = "dispatched", execution = "completed"
                var route: String?
                var failure: RuntimeError?
                do {
                    route = try platform.perform(pa, on: d.screen, pid: b.process.pid, windowId: b.windowId)
                } catch let e as PlatformError {
                    if e.beforeDispatch {
                        delivery = "not_dispatched"; execution = "failed"
                        failure = RuntimeError(e.kind == .permission ? "permission_denied" : "execution_failed", e.message,
                                               phase: .handler, notSent: true)
                    } else {
                        delivery = "unknown"; execution = "unknown"
                        failure = RuntimeError("action_delivery_unknown",
                                               "\(e.message); input may have reached the app, check before deciding on a new action",
                                               phase: .handler)
                    }
                }
                let receipt = JSONValue.obj([
                    ("receiptId", .string(receiptId)), ("requestId", .string(request.requestId)), ("runId", .string(runId)),
                    ("desktopId", .string(d.desktopId)), ("sessionId", .string(session.sessionId)),
                    ("snapshotId", .string(snapshotId)), ("delivery", .string(delivery)), ("execution", .string(execution)),
                    ("verification", .string("not_requested")), ("route", route.map(JSONValue.string) ?? .null),
                    ("target", .obj([
                        ("generation", .int(b.generation)), ("process", b.process.json), ("windowId", .int(Int(b.windowId))),
                        ("elementRef", action["target"]?["elementRef"] ?? .null),
                        ("point", pa.point.map { .obj([("x", .double($0.x)), ("y", .double($0.y))]) } ?? .null),
                    ])),
                    ("timing", .obj([("acceptedAt", .string(acceptedAt)),
                                     ("dispatchedAt", delivery == "not_dispatched" ? .null : .string(dispatchedAt)),
                                     ("completedAt", .string(nowString))])),
                ])
                self.execution.endAction(runId: runId, receiptId: receiptId, deliveryUnknown: delivery == "unknown")
                runs.appendEvent(runId, "action.\(execution)", .obj([("receipt", receipt)]))
                if var failure {
                    failure.details = .obj([("receipt", receipt)])
                    throw failure
                }
                return receipt
            }
        }
        if case .success = result { oneShotOutcome = .success }
        return result
    }

    static func sameFrame(_ a: AgentDesktopProtocol.Rect, _ b: AgentDesktopProtocol.Rect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Resolve the request's target against its snapshot.
    func platformAction(_ a: JSONValue, snap: StoredObservation, window: PlatformWindow) throws -> PlatformAction {
        var pa = PlatformAction(kind: PlatformAction.Kind(rawValue: a["kind"]?.stringValue ?? "") ?? .click)
        pa.text = a["text"]?.stringValue
        pa.key = a["key"]?.stringValue
        pa.modifiers = a["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
        pa.button = a["button"]?.stringValue
        pa.count = a["count"]?.intValue
        pa.direction = a["direction"]?.stringValue
        pa.amount = a["amount"]?.intValue
        if let ref = a["target"]?["elementRef"]?.stringValue {
            // Element numbers are valid only while this snapshot is the
            // latest read of the window.
            guard snap.readElements, observations.isLatestElementRead(snap.snapshotId, desktopId: snap.desktopId) else {
                throw RuntimeError("stale_observation", "a newer observation re-read the window after \(snap.snapshotId); use its element refs",
                                   phase: .handler, notSent: true)
            }
            guard let e = snap.elements[ref] else {
                throw RuntimeError("invalid_target", "snapshot \(snap.snapshotId) has no element \(ref)", phase: .handler, notSent: true)
            }
            pa.elementIndex = e.index
        } else if let ip = a["target"]?["imagePoint"] {
            guard let t = snap.transform, let size = snap.imageSize else {
                throw RuntimeError("invalid_target", "snapshot \(snap.snapshotId) has no screenshot to place an image point on",
                                   phase: .handler, notSent: true)
            }
            let px = ip["x"]?.doubleValue ?? -1, py = ip["y"]?.doubleValue ?? -1
            guard px < Double(size.width), py < Double(size.height) else {
                throw RuntimeError("invalid_target", "(\(px), \(py)) is outside the \(size.width)x\(size.height) image",
                                   phase: .handler, notSent: true)
            }
            let gx = t.originX + px / t.scale, gy = t.originY + py / t.scale
            let f = window.frame
            guard gx >= f.x, gx < f.x + f.width, gy >= f.y, gy < f.y + f.height else {
                throw RuntimeError("invalid_target", "image point (\(px), \(py)) is (\(gx), \(gy)) in points, outside the bound window",
                                   phase: .handler, notSent: true)
            }
            pa.point = (gx, gy)
        }
        return pa
    }

    /// Wait, on the Runtime, for an element condition in the bound window.
    /// Each poll is a fresh element read stored as a snapshot.
    func wait(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard let platform else { return .failure(.capabilityMissing("no desktop platform")) }
        let desk: DesktopRecord
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((d, _)): desk = d
        }
        let cond = request.params["condition"] ?? .obj([])
        let wantPresent = cond["kind"]?.stringValue == "elementPresent"
        let deadline = now().addingTimeInterval(Double(request.params["timeoutMs"]?.intValue ?? 1000) / 1000)
        var lastSnapshot: String?
        while true {
            let poll = withDesktop(.string(desk.desktopId)) { d -> JSONValue in
                guard let b = d.binding else {
                    throw RuntimeError("stale_observation", "desktop \(d.desktopId) has no bound window", phase: .handler)
                }
                guard backend.processIdentity(b.process.pid) == b.process else {
                    throw RuntimeError("stale_observation", "process \(b.process.pid) exited or restarted", phase: .handler)
                }
                let read = try platform.elements(on: d.screen, pid: b.process.pid, windowId: b.windowId, query: nil)
                let snapshotId = DesktopRegistry.newId(prefix: "obs")
                var stored = StoredObservation(snapshotId: snapshotId, desktopId: d.desktopId, capturedAt: nowString,
                                               screen: d.screen, binding: b, windowFrame: read.window.frame, transform: nil,
                                               imageSize: nil, elements: [:], readElements: true)
                var matches: [JSONValue] = []
                for e in read.elements where e.index >= 0 {
                    stored.elements["el_\(e.index)"] = e
                    if Self.matches(e, cond) { matches.append(Self.elementJSON(e)) }
                }
                observations.store(stored)
                return .obj([("snapshotId", .string(snapshotId)), ("matches", .array(matches))])
            }
            switch poll {
            case let .failure(e): return .failure(e)
            case let .success(v):
                lastSnapshot = v["snapshotId"]?.stringValue
                let found = !(v["matches"]?.arrayValue ?? []).isEmpty
                if found == wantPresent {
                    return .success(.obj([("satisfied", .bool(true)), ("snapshotId", v["snapshotId"]!),
                                          ("matches", wantPresent ? v["matches"]! : .array([]))]))
                }
            }
            if now() >= deadline {
                return .failure(RuntimeError("wait_timeout", "the condition did not hold within \(request.params["timeoutMs"]?.intValue ?? 0) ms",
                                             phase: .handler, details: .obj([("lastSnapshotId", lastSnapshot.map(JSONValue.string) ?? .null)])))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
    }

    static func matches(_ e: PlatformElement, _ cond: JSONValue) -> Bool {
        if let role = cond["role"]?.stringValue, e.role != role, !e.role.hasPrefix(role + "/") { return false }
        if let label = cond["label"]?.stringValue, e.label != label { return false }
        if let part = cond["labelContains"]?.stringValue, !((e.label ?? "") + " " + (e.value ?? "")).contains(part) { return false }
        return true
    }

    static func elementJSON(_ e: PlatformElement) -> JSONValue {
        .obj([("id", .string("el_\(e.index)")), ("role", .string(e.role)),
              ("label", e.label.map(JSONValue.string) ?? .null), ("value", e.value.map(JSONValue.string) ?? .null),
              ("actions", .array(e.actions.map(JSONValue.string))), ("frame", e.frame?.json ?? .null)])
    }
}
