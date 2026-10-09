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
            let e = RuntimeError("stale_observation", "snapshot \(snapshotId) is unknown or expired on desktop \(desk.desktopId); observe again",
                                 phase: .handler, notSent: true)
            runs.appendEvent(runId, "action.refused", .obj([("requestId", .string(request.requestId)),
                                                           ("reason", .obj([("code", .string(e.code)), ("message", .string(e.message))]))]))
            return .failure(e)
        }
        let action = request.params["action"] ?? .obj([])
        // G2: a key may need the target app's menu bar, read here, before
        // the Desktop's lock, so a slow app never holds the lock up.
        var menu: (pid: Int32, items: [PlatformMenuItem]?)?
        if let kind = PlatformAction.Kind(rawValue: action["kind"]?.stringValue ?? "") {
            var probe = PlatformAction(kind: kind)
            probe.key = action["key"]?.stringValue
            probe.modifiers = action["modifiers"]?.arrayValue?.compactMap(\.stringValue) ?? []
            if ClipboardPolicy.needsMenu(probe), let pid = desktops.find(desk.desktopId)?.boundPID {
                menu = (pid, platform.menuItems(pid: pid))
            }
        }

        let result = withDesktop(.string(desk.desktopId), until: request.deadline.flatMap(Timestamp.date)) { d -> JSONValue in
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
                // G0: the observed window is still the one input would reach.
                let window = try exposedTarget(d, b, notSent: true).window
                if let was = snap.windowFrame, !Self.sameFrame(was, window.frame) {
                    throw RuntimeError("stale_observation", "window \(b.windowId) moved or resized since snapshot \(snapshotId); observe again",
                                       phase: .handler, notSent: true)
                }
                var pa = try platformAction(action, snap: snap, window: window)
                if pa.modifiers.isEmpty { pa.modifiers = [] }
                // G2, the last check before sending: nothing goes through the
                // user's clipboard, whoever asks (ClipboardPolicy).
                let pressed = action["target"]?["elementRef"]?.stringValue.flatMap { snap.elements[$0] }
                if let path = ClipboardPolicy.refusal(pa, snapshotElement: pressed, pid: b.process.pid, windowId: b.windowId,
                                                      menu: menu, platform: platform) {
                    throw RuntimeError("permission_denied",
                                       "this input would or might use the system clipboard (\(path)); agents may not use the clipboard",
                                       phase: .handler, notSent: true,
                                       details: .obj([("reason", .string("clipboard_path_refused")), ("path", .string(path))]))
                }
                // #120 audit (Kevin 2026-10-09): keys and typing go to the
                // app's focused window, not to a window id. A floating panel of
                // the same process (not a normal-level window, so not in the
                // checks above) may hold focus, and input would reach a window
                // that was neither bound nor shown. Sent only when the focused
                // window is known to be the bound one; refused when it is
                // elsewhere or cannot be told (fail closed). With a menu open
                // nothing is sent (Kevin 2026-10-09: whose menu it is cannot be
                // proved); the agent closes it by clicking the bound window.
                if pa.kind == .key || pa.kind == .type {
                    try focusRefusal(pa, pid: b.process.pid, windowId: b.windowId, platform: platform)
                }
                if let deadline = request.deadline.flatMap(Timestamp.date), now() >= deadline {
                    throw RuntimeError("deadline_exceeded", "the deadline \(request.deadline!) passed before dispatch; nothing was sent",
                                       phase: .handler, notSent: true)
                }
                if let stopped = execution.beginAction(runId: runId) { throw stopped }

                // Delivery boundary: from here an interruption is unknown.
                do {
                    try ledger.markDispatching(caller: callerKey(c), requestId: request.requestId)
                    runs.appendEvent(runId, "action.dispatched", .obj([("requestId", .string(request.requestId))]))
                    try runs.checkWritable()
                } catch {
                    self.execution.endAction(runId: runId, receiptId: nil, deliveryUnknown: false)
                    self.execution.auditStorageFailed()
                    throw ExecutionCoordinator.auditError(notSent: true)
                }
                let dispatchedAt = nowString
                let receiptId = DesktopRegistry.newId(prefix: "rcpt")
                var delivery = "dispatched", execution = "completed"
                var route: String?
                var failure: RuntimeError?
                do {
                    route = try platform.perform(pa, on: d.screen, pid: b.process.pid, windowId: b.windowId)
                    // The OS cannot make check-then-send atomic. If the target
                    // stopped being exposed around the send (a window popped
                    // up), the input may have reached that window instead:
                    // unknown, never success, and the next input is refused
                    // by the check above.
                    do {
                        let after = try exposedTarget(d, b, notSent: false)
                        if !Self.sameFrame(after.window.frame, window.frame) {
                            throw RuntimeError("stale_observation", "window \(b.windowId) moved while input was sent",
                                               phase: .handler, details: .obj([("reason", .string("moved"))]))
                        }
                        // The focus check before the send and the send are not
                        // one step: focus that is known to have left the bound
                        // window right after makes the delivery unknown (the
                        // input may have gone with it). Residual: a change and
                        // a change back between two reads is not seen.
                        if pa.kind == .key || pa.kind == .type {
                            // No menu was open before the send (checked above),
                            // so a menu now, or a state that cannot be read, is
                            // this input's doing, and focus may have gone with
                            // it (Codex on b258049). Only with no menu is the
                            // focus read again.
                            guard platform.menuOpen(pid: b.process.pid) == false else {
                                throw RuntimeError("stale_observation", "a menu opened while input was sent",
                                                   phase: .handler, details: .obj([("reason", .string("menu_opened_by_action"))]))
                            }
                            // Dispatched only when focus is known to be still in
                            // the bound window; unreadable is unknown (Codex on
                            // 9ed802d).
                            guard let now = platform.focusedControl(pid: b.process.pid)?.windowId else {
                                throw RuntimeError("stale_observation", "keyboard focus could not be read after input was sent",
                                                   phase: .handler, details: .obj([("reason", .string("focus_unverified_after_send"))]))
                            }
                            if now != b.windowId {
                                throw RuntimeError("stale_observation", "keyboard focus moved to window \(now) while input was sent",
                                                   phase: .handler, details: .obj([("reason", .string("focus_moved"))]))
                            }
                        }
                    } catch let changed as RuntimeError {
                        delivery = "unknown"; execution = "unknown"
                        failure = RuntimeError("action_delivery_unknown",
                                               "the target changed while input was sent (\(changed.details?["reason"]?.stringValue ?? changed.code)); it may have reached another window. Observe before deciding on a new action",
                                               phase: .handler,
                                               details: .obj([("reason", .string("target_changed_during_dispatch"))]))
                    }
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
                var receipt = JSONValue.obj([
                    ("receiptId", .string(receiptId)), ("requestId", .string(request.requestId)), ("runId", .string(runId)),
                    ("desktopId", .string(d.desktopId)), ("sessionId", .string(session.sessionId)),
                    ("snapshotId", .string(snapshotId)), ("delivery", .string(delivery)), ("execution", .string(execution)),
                    ("verification", .string("not_requested")),
                    // Delivery is not effect: whether the app did what was meant
                    // is for a later observation (or the caller) to establish.
                    ("businessResult", .string("not_evaluated")),
                    ("route", route.map(JSONValue.string) ?? .null),
                    ("target", .obj([
                        ("generation", .int(b.generation)), ("process", b.process.json), ("windowId", .int(Int(b.windowId))),
                        ("elementRef", action["target"]?["elementRef"] ?? .null),
                        ("point", pa.point.map { .obj([("x", .double($0.x)), ("y", .double($0.y))]) } ?? .null),
                    ])),
                    ("timing", .obj([("acceptedAt", .string(acceptedAt)),
                                     ("dispatchedAt", delivery == "not_dispatched" ? .null : .string(dispatchedAt)),
                                     ("completedAt", .string(nowString))])),
                ])
                // Read back later (run.events, request.show), a receipt says why
                // it was not delivered, failed or is unknown.
                if let failure {
                    receipt = receipt.setting("reason", .obj([("code", .string(failure.code)),
                                                              ("message", .string(String(failure.message.prefix(512))))]))
                }
                self.execution.endAction(runId: runId, receiptId: receiptId, deliveryUnknown: delivery == "unknown")
                runs.appendEvent(runId, "action.\(execution)", .obj([("receipt", receipt)]))
                if var failure {
                    failure.details = (failure.details ?? .obj([])).setting("receipt", receipt)
                    throw failure
                }
                return receipt
            }
        }
        switch result {
        case .success:
            oneShotOutcome = .success
        case let .failure(e) where e.details?["receipt"] == nil:
            // Refused before any input (G0, a stale snapshot, a stop, a
            // deadline): the Run's history says so too, not only the reply.
            runs.appendEvent(runId, "action.refused", .obj([
                ("requestId", .string(request.requestId)),
                ("reason", .obj([("code", .string(e.code)), ("message", .string(String(e.message.prefix(512))))])),
            ]))
        case .failure:
            break
        }
        return result
    }

    /// Why a key or typing must not be sent to the bound window now (#120
    /// audit), or nothing. Every refusal is notSent and names its reason.
    func focusRefusal(_ pa: PlatformAction, pid: Int32, windowId: UInt32, platform: DesktopPlatform) throws {
        func refuse(_ reason: String, _ message: String, _ extra: [(String, JSONValue)] = []) -> RuntimeError {
            RuntimeError("stale_observation", message + "; nothing was sent", phase: .handler, notSent: true,
                         details: .obj([("reason", .string(reason))] + extra))
        }
        // Kevin 2026-10-09: menu authorization is the bound window's, not the
        // process's, and being placed over the bound window does not prove a
        // menu is its. Which window opened a menu cannot be proved, so while
        // the app shows any menu no key and no typing is sent, not even the
        // arrows or Escape. Clicks are judged by what is under the point (G2).
        switch platform.menuOpen(pid: pid) {
        case nil:
            throw refuse("menu_unverified", "whether the app shows a menu cannot be read")
        case true?:
            throw refuse("menu_open", "the app shows a menu, and whose it is cannot be proved; close it by clicking the bound window")
        case false?:
            break
        }
        guard let focus = platform.focusedControl(pid: pid) ?? platform.focusedControl(pid: pid) else {
            throw refuse("focus_unverified", "the app's keyboard focus cannot be read")
        }
        guard let focusWindow = focus.windowId else {
            throw refuse("focus_unverified", "the window holding the app's keyboard focus cannot be told")
        }
        guard focusWindow == windowId else {
            throw refuse("focus_outside_bound_window", "keyboard focus is in window \(focusWindow) of the app, not the bound window \(windowId)",
                         [("focusWindowId", .int(Int(focusWindow)))])
        }
        // Codex on 74278c9 (P1): typed text is sent one character at a time,
        // and focus is checked once before. A space typed into a focused
        // button presses it, a newline presses a default button; either may
        // open a menu or move focus, and the rest of the text would follow it
        // elsewhere. So typing goes only into editable text that has focus in
        // the bound window, and a newline only at the very end (nothing left
        // to send after what it may set off).
        if pa.kind == .type {
            let role = String(focus.role.split(separator: "/").first ?? "")
            guard focus.editable || ClipboardPolicy.textRoles.contains(role) else {
                throw refuse("type_focus_not_text", "keyboard focus is not on editable text in the bound window; typing there could press a control")
            }
            // At most one newline, and only as the last thing sent ("\n",
            // "\r" or "\r\n"): a second one would go wherever the first sent
            // focus (b9 on 4ec619b: "abc\n\n").
            var scalars = Array((pa.text ?? "").unicodeScalars)
            if scalars.suffix(2) == ["\r", "\n"] { scalars.removeLast(2) }
            else if let last = scalars.last, last == "\n" || last == "\r" { scalars.removeLast() }
            guard !scalars.contains(where: { $0 == "\n" || $0 == "\r" }) else {
                throw refuse("type_newline_not_last", "a newline may only end the text: what it sets off could take the rest elsewhere; send the lines as separate actions")
            }
        }
    }

    static func sameFrame(_ a: AgentDesktopProtocol.Rect, _ b: AgentDesktopProtocol.Rect) -> Bool {
        abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 && abs(a.width - b.width) < 0.5 && abs(a.height - b.height) < 0.5
    }

    /// Resolve the request's target against its snapshot.
    func platformAction(_ a: JSONValue, snap: StoredObservation, window: PlatformWindow) throws -> PlatformAction {
        guard let kind = PlatformAction.Kind(rawValue: a["kind"]?.stringValue ?? "") else {
            throw RuntimeError("invalid_argument", "unknown action kind \(a["kind"]?.stringValue ?? "none")", phase: .handler, notSent: true)
        }
        var pa = PlatformAction(kind: kind)
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
            guard px >= 0, py >= 0, px < Double(size.width), py < Double(size.height) else {
                throw RuntimeError("invalid_target", "(\(px), \(py)) is outside the \(size.width)x\(size.height) image",
                                   phase: .handler, notSent: true)
            }
            let gx = t.originX + px / t.scale, gy = t.originY + py / t.scale
            let f = window.frame
            guard gx >= f.x, gx < f.x + f.width, gy >= f.y, gy < f.y + f.height else {
                throw RuntimeError("invalid_target", "image point (\(px), \(py)) is (\(gx), \(gy)) in points, outside the bound window",
                                   phase: .handler, notSent: true)
            }
            // A window may reach past the screen edge; input there would not
            // land on the window the image shows.
            let sf = snap.screen.frame
            guard gx >= sf.x, gx < sf.x + sf.width, gy >= sf.y, gy < sf.y + sf.height else {
                throw RuntimeError("invalid_target", "image point (\(px), \(py)) is (\(gx), \(gy)) in points, off the Desktop's screen",
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
            // As in observe: checks under the lock, the read on the AX threads
            // without it, then the store under the lock.
            var bound: TargetBinding?
            let checked = withDesktop(.string(desk.desktopId), until: deadline) { d -> JSONValue in
                guard let b = d.binding else {
                    throw RuntimeError("stale_observation", "desktop \(d.desktopId) has no bound window", phase: .handler)
                }
                guard backend.processIdentity(b.process.pid) == b.process else {
                    throw RuntimeError("stale_observation", "process \(b.process.pid) exited or restarted", phase: .handler)
                }
                bound = b
                observations.invalidateElementRefs(desktopId: d.desktopId)
                return .null
            }
            if case let .failure(e) = checked { return .failure(e) }
            guard let b = bound else { return .failure(RuntimeError("internal_error", "no binding", phase: .handler)) }
            let readBy = min(deadline, now().addingTimeInterval(elementReadBudget))
            let screen = desk.screen
            var read: ElementRead?
            switch axReader.read(desktopId: desk.desktopId, deadline: readBy, {
                try platform.elements(on: screen, pid: b.process.pid, windowId: b.windowId, query: nil, deadline: readBy)
            }) {
            case let .read(r): read = r
            case .timedOut, .busy: read = nil
            case let .failed(e as PlatformError): return .failure(e.runtimeError)
            case let .failed(e): return .failure(RuntimeError("execution_failed", "\(e)", phase: .handler))
            }
            let poll = withDesktop(.string(desk.desktopId), until: deadline) { d -> JSONValue in
                guard d.binding?.generation == b.generation else {
                    throw RuntimeError("stale_observation", "the binding of desktop \(d.desktopId) changed", phase: .handler)
                }
                let snapshotId = DesktopRegistry.newId(prefix: "obs")
                var stored = StoredObservation(snapshotId: snapshotId, desktopId: d.desktopId, capturedAt: nowString,
                                               screen: d.screen, binding: b, windowFrame: read?.window.frame, transform: nil,
                                               imageSize: nil, elements: [:], readElements: true)
                var matches: [JSONValue] = []
                for e in read?.elements ?? [] where e.index >= 0 {
                    stored.elements["el_\(e.index)"] = e
                    if Self.matches(e, cond) { matches.append(Self.elementJSON(e)) }
                }
                observations.store(stored)
                // No read, no verdict: an unread window proves neither presence
                // nor absence.
                return .obj([("snapshotId", .string(snapshotId)), ("matches", .array(matches)),
                             ("read", .bool(read != nil))])
            }
            switch poll {
            case let .failure(e): return .failure(e)
            case let .success(v):
                lastSnapshot = v["snapshotId"]?.stringValue
                let found = !(v["matches"]?.arrayValue ?? []).isEmpty
                if v["read"]?.boolValue == true, found == wantPresent {
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
