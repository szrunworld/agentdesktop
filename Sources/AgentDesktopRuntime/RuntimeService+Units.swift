import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// GUI units (CLI plan §07 GUI 单元实现): verify first; replay known steps
/// with no model; explore with a model only when allowed and needed; learn
/// steps that reached the verified state. Success is only ever decided by
/// the Runtime evaluating the unit's conditions on a fresh observation.
extension RuntimeService {
    struct UnitFailure: Error { let phase: String; let error: RuntimeError }

    func runUnit(_ request: RuntimeRequest, _ c: ConnectionState) -> Result<JSONValue, RuntimeError> {
        guard platform != nil else { return .failure(.capabilityMissing("no desktop platform")) }
        guard let sid = request.context.sessionId else {
            return .failure(.schemaInvalid("unit.run needs context.sessionId"))
        }
        let p = request.params
        let verification = p["verification"] ?? .obj([])
        let deadline = now().addingTimeInterval(Double(p["timeoutMs"]?.intValue ?? 60_000) / 1000)
        let unitId = DesktopRegistry.newId(prefix: "unit")
        let desk: DesktopRecord
        switch target(of: request, c) {
        case let .failure(e): return .failure(e)
        case let .success((d, _)): desk = d
        }
        guard let binding = desk.lock.withLock({ desk.binding }) else {
            return .failure(RuntimeError("stale_observation", "desktop \(desk.desktopId) has no bound window", phase: .handler, notSent: true))
        }
        let app = backend.applications(includeBackground: true).first { $0.process.pid == binding.process.pid }?.bundleId ?? binding.appName

        // The procedure to replay, fixed now: its version cannot change under the unit.
        var procedureRef: JSONValue = .null
        var steps: [JSONValue]? = p["steps"]?.arrayValue
        if let pid = p["procedureId"]?.stringValue {
            guard let proc = try? procedures.find(pid) else { return .failure(.notFound("no procedure \(pid)")) }
            guard proc["app"]?.stringValue == app else {
                return .failure(RuntimeError("invalid_target", "procedure \(pid) is for \(proc["app"]?.stringValue ?? "?"), the bound window is \(app)",
                                             phase: .handler, notSent: true))
            }
            steps = proc["steps"]?.arrayValue
            procedureRef = .obj([("procedureId", .string(pid)), ("version", proc["version"] ?? .int(1))])
        }
        if p["explore"] != nil, unitExplorer == nil, steps == nil {
            return .failure(.capabilityMissing("model exploration is not available on this Runtime (real GUI input is off or no model is configured)"))
        }

        var path: [String] = []
        var receipts: [String] = []
        var modelCalls = 0
        var failure: JSONValue = .null
        var learned: JSONValue = .null
        let ctx = RequestContext(sessionId: sid)

        func check() -> Result<(Bool, String), RuntimeError> {
            observeElements(ctx, c).map { (Conditions.evaluate(verification, $0.elements), $0.snapshotId) }
        }
        func result(_ ok: Bool, _ snap: String) -> JSONValue {
            .obj([("unitId", .string(unitId)), ("state", .string(ok ? "succeeded" : "failed")),
                  ("path", .array(path.map(JSONValue.string))),
                  ("verification", .obj([("satisfied", .bool(ok)), ("snapshotId", .string(snap))])),
                  ("receipts", .array(receipts.map(JSONValue.string))), ("modelCalls", .int(modelCalls)),
                  ("procedure", procedureRef), ("learned", learned), ("failure", ok ? .null : failure)])
        }
        func learn(_ s: [JSONValue], source: String) {
            guard let name = p["learnAs"]?.stringValue, !s.isEmpty,
                  let saved = try? procedures.save(name: name, app: app, source: source, steps: s, verification: verification)
            else { return }
            learned = .obj([("procedureId", saved["procedureId"]!), ("version", saved["version"]!)])
        }

        // 1. Already there: nothing to do.
        var last: String
        switch check() {
        case let .failure(e): return .failure(e)
        case let .success((ok, snap)):
            last = snap
            if ok { path.append("already_satisfied"); return .success(result(true, snap)) }
        }

        // 2. Deterministic replay, zero model calls.
        if let steps {
            path.append("replay")
            do {
                for (i, step) in steps.enumerated() {
                    guard now() < deadline else {
                        throw UnitFailure(phase: "replay", error: RuntimeError("deadline_exceeded", "the unit's time ran out before step \(i + 1)", phase: .handler))
                    }
                    if let r = try replay(step, index: i, unitRequest: request.requestId, ctx: ctx, c: c, deadline: deadline) { receipts.append(r) }
                }
            } catch let f as UnitFailure {
                failure = .obj([("phase", .string(f.phase)), ("code", .string(f.error.code)), ("message", .string(f.error.message))])
            } catch {}
            switch check() {
            case let .failure(e): return .failure(e)
            case let .success((ok, snap)):
                last = snap
                if ok {
                    if procedureRef.isNull { learn(steps, source: "explicit") }
                    return .success(result(true, snap))
                }
                if failure.isNull {
                    failure = .obj([("phase", .string("verification")), ("code", .string("execution_failed")),
                                    ("message", .string("the steps ran but the verification does not hold"))])
                }
            }
        }

        // 3. Exploration with a model, when asked for and available.
        if let explore = p["explore"] {
            guard let explorer = unitExplorer, let goalTarget = Conditions.explorerTarget(verification) else {
                failure = .obj([("phase", .string("explore")), ("code", .string("capability_missing")),
                                ("message", .string(unitExplorer == nil ? "model exploration is not available on this Runtime"
                                                    : "exploration needs an elementTextEquals condition to aim for"))])
                return .success(result(false, last))
            }
            path.append("explore")
            let outcome = explorer.explore(desktopId: desk.desktopId, sessionId: sid, goal: explore["goal"]?.stringValue ?? "",
                                           target: goalTarget, maxSteps: explore["maxSteps"]?.intValue, deadline: deadline)
            modelCalls += outcome.modelCalls
            switch check() {
            case let .failure(e): return .failure(e)
            case let .success((ok, snap)):
                if ok {
                    failure = .null
                    if let run = outcome.guiRunId, let s = guiRunSteps?(run) { learn(s, source: "explore") }
                    return .success(result(true, snap))
                }
                last = snap
                failure = .obj([("phase", .string("explore")), ("code", .string(outcome.state == "succeeded" ? "verification_failed" : "execution_failed")),
                                ("message", .string(outcome.message ?? "exploration ended \(outcome.state) and the verification does not hold"))])
            }
        }
        return .success(result(false, last))
    }

    /// A fresh element read (no screenshot) as a stored snapshot.
    func observeElements(_ ctx: RequestContext, _ c: ConnectionState) -> Result<(snapshotId: String, elements: [PlatformElement]), RuntimeError> {
        var r = RuntimeRequest(.observe, params: .obj([("screenshot", .bool(false))]))
        r.context = ctx
        return observe(r, c).flatMap { v in
            guard let id = v["snapshotId"]?.stringValue, let stored = observations.find(id) else {
                return .failure(RuntimeError("internal_error", "observation was not stored", phase: .handler))
            }
            return .success((id, stored.elements.values.sorted { $0.index < $1.index }))
        }
    }

    /// One step: wait for its element (unique), then act through the same
    /// path as any caller. The receipt id, or nil for a step without input.
    private func replay(_ step: JSONValue, index: Int, unitRequest: String, ctx: RequestContext, c: ConnectionState,
                        deadline: Date) throws -> String? {
        let kind = step["action"]?.stringValue ?? ""
        var snapshot: String
        var ref: String?
        let until = min(deadline, now().addingTimeInterval(Double(step["waitMs"]?.intValue ?? 3000) / 1000))
        while true {
            let read: (snapshotId: String, elements: [PlatformElement])
            switch observeElements(ctx, c) {
            case let .failure(e): throw UnitFailure(phase: "replay", error: e)
            case let .success(v): read = v
            }
            snapshot = read.snapshotId
            guard let match = step["element"] else { break }
            let found = read.elements.filter { Conditions.matches($0, match) }
            if found.count == 1 { ref = "el_\(found[0].index)"; break }
            if now() >= until {
                throw UnitFailure(phase: "replay", error: RuntimeError(
                    "invalid_target", found.isEmpty ? "step \(index + 1): no element matches \(match.encoded())"
                                                    : "step \(index + 1): \(found.count) elements match \(match.encoded()); make it unique",
                    phase: .handler, notSent: true))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        var action: [(String, JSONValue)] = [("kind", .string(kind))]
        if let ref { action.append(("target", .obj([("elementRef", .string(ref))]))) }
        if let t = step["text"] { action.append(("text", t)) }
        if let k = step["key"] { action.append(("key", k)) }
        if let m = step["modifiers"] { action.append(("modifiers", m)) }
        var act = RuntimeRequest(.act, requestId: "\(unitRequest)-s\(index + 1)",
                                 params: .obj([("snapshotId", .string(snapshot)), ("action", .obj(action))]))
        act.context = ctx
        switch ledgeredAct(act, c) {
        case let .success(r): return r["receiptId"]?.stringValue
        case let .failure(e): throw UnitFailure(phase: "replay", error: e)
        }
    }

    func listProcedures(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        do { return .success(.obj([("procedures", .array(try procedures.list(app: p["app"]?.stringValue)))])) } catch {
            return .failure(RuntimeError("internal_error", "\(error)", phase: .handler))
        }
    }

    func showProcedure(_ p: JSONValue) -> Result<JSONValue, RuntimeError> {
        let id = p["procedureId"]?.stringValue ?? ""
        guard let proc = try? procedures.find(id) else { return .failure(.notFound("no procedure \(id)")) }
        return .success(proc)
    }
}
