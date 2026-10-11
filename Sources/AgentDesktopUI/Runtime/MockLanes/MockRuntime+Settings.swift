import AgentDesktopProtocol
import Foundation

// Lane UI-D (设置; docs/plan/11-parallel-lanes.md): this lane's mock
// methods and state. Only that lane edits this file.
//
// The `ai.*` methods are answered here the way the AI service answers them
// through the Runtime's single endpoint (RuntimeBridge): params and results
// are the service.schema.json definitions (MockRuntime checks both), and
// errors are runtime/1 codes with the service's code kept in
// `details.serviceCode`. A credential is never kept: the mock records only
// that one was written and hands out an opaque reference.

/// Lane UI-D's mock state (read and written with the MockRuntime's lock held).
final class MockSettingsLane: @unchecked Sendable {
    var connections: [JSONValue] = []
    var modelProfiles: [JSONValue] = []
    var profiles: [JSONValue] = []
    var defaultRevision = 1
    var defaultProfileId: String?
    /// Operations by id, with how many more reads they take to finish.
    var operations: [String: (op: JSONValue, readsLeft: Int, finish: JSONValue?, failure: JSONValue?)] = [:]
    var catalogs: [String: (items: [JSONValue], refreshedAt: String)] = [:]
    var usage: (attempts: Int, confirmed: Int, unknown: Int, missing: Int, totalTokens: Int?)?
    /// Level → "failed" makes the next capability tests fail there.
    var failingLevel: String?
    /// Reads an operation takes before it ends (0: done at the first read).
    var operationReads = 1
    /// Credentials written (create and rotate); the keys themselves are dropped.
    var credentialsWritten = 0
    var nextId = 1

    init() {}

    func id(_ prefix: String) -> String {
        defer { nextId += 1 }
        return prefix + "_" + String(format: "%03d", nextId)
    }
}

extension MockRuntime {
    /// Methods lane UI-D models (each must be in RuntimeCatalog.implemented).
    static let settingsLaneMethods: [String] = [
        "ai.connections.list", "ai.connections.get", "ai.connections.create", "ai.connections.update",
        "ai.connections.disable", "ai.connections.delete", "ai.credentials.rotate",
        "ai.models.list", "ai.models.refresh",
        "ai.modelProfiles.list", "ai.modelProfiles.get", "ai.modelProfiles.create", "ai.modelProfiles.update",
        "ai.modelProfiles.disable", "ai.modelProfiles.delete",
        "ai.profiles.list", "ai.profiles.get", "ai.profiles.create", "ai.profiles.update",
        "ai.profiles.disable", "ai.profiles.delete", "ai.profiles.default.get", "ai.profiles.setDefault",
        "ai.tests.start", "ai.operations.get", "ai.operations.cancel", "ai.usage.summary",
    ]

    // MARK: Scenario building (only contract fields)

    /// Adds an AI connection as the service would store it; returns its id.
    @discardableResult
    public func addAIConnection(name: String, baseUrl: String, enabled: Bool = true, revision: Int = 1,
                                timeoutMs: Int = 30000) -> String {
        lock.withLock {
            let s = lanes.settings
            let id = s.id("conn")
            s.credentialsWritten += 1
            let now = stamp()
            s.connections.append(.obj([
                ("connectionId", .string(id)), ("revision", .int(revision)), ("name", .string(name)),
                ("protocol", .string("openai_chat")), ("baseUrl", .string(baseUrl)),
                ("credentialRef", .string("cred_\(id)_1")), ("state", .string(enabled ? "enabled" : "disabled")),
                ("timeoutMs", .int(timeoutMs)), ("createdAt", .string(now)), ("updatedAt", .string(now)),
            ]))
            return id
        }
    }

    /// Adds a model profile on a connection; `verified` marks all four
    /// capability levels as proven by a past test.
    @discardableResult
    public func addAIModelProfile(connectionId: String, modelId: String, verified: Bool = false) -> String {
        lock.withLock {
            let s = lanes.settings
            let id = s.id("mp")
            let connRev = s.connections.first { $0["connectionId"]?.stringValue == connectionId }?["revision"]?.intValue ?? 1
            let now = stamp()
            s.modelProfiles.append(.obj([
                ("modelProfileId", .string(id)), ("revision", .int(1)), ("name", .string(modelId)),
                ("state", .string("enabled")), ("connectionId", .string(connectionId)),
                ("connectionRevision", .int(connRev)), ("modelId", .string(modelId)),
                ("requestOptions", .obj([])), ("maxOutputTokens", .int(1024)),
                ("capabilities", Self.evidence(verified ? "verified" : "unknown", connectionRevision: connRev,
                                               checkedAt: verified ? now : nil, operationId: verified ? "op_seed" : nil)),
                ("createdAt", .string(now)), ("updatedAt", .string(now)),
            ]))
            return id
        }
    }

    /// Adds a GUI profile over a model profile; returns its id.
    @discardableResult
    public func addAIGuiProfile(name: String, modelProfileId: String, revision: Int = 1, makeDefault: Bool = false) -> String {
        lock.withLock {
            let s = lanes.settings
            let id = s.id("gui")
            let mpRev = s.modelProfiles.first { $0["modelProfileId"]?.stringValue == modelProfileId }?["revision"]?.intValue ?? 1
            let now = stamp()
            s.profiles.append(.obj([
                ("guiProfileId", .string(id)), ("revision", .int(revision)), ("name", .string(name)),
                ("state", .string("enabled")), ("modelProfileId", .string(modelProfileId)),
                ("modelProfileRevision", .int(mpRev)), ("adapterId", .string("uitars_v1")),
                ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("uitars-prompt-1")),
                ("parserVersion", .string("uitars-parser-1")), ("coordinateProtocol", .string("normalized_1000")),
                ("limits", Self.ceilingLimits), ("allowedFallbackProfileRefs", .array([])),
                ("createdAt", .string(now)), ("updatedAt", .string(now)),
            ]))
            if makeDefault {
                s.defaultProfileId = id
                s.defaultRevision += 1
            }
            return id
        }
    }

    /// What `ai.usage.summary` reports; nil tokens means "not reported".
    public func setAIUsage(attempts: Int, confirmedActions: Int, unknownOutcomes: Int = 0, attemptsMissingUsage: Int = 0,
                           totalTokens: Int?) {
        lock.withLock {
            lanes.settings.usage = (attempts, confirmedActions, unknownOutcomes, attemptsMissingUsage, totalTokens)
        }
    }

    /// Capability tests fail at `level` (network, auth_model, image_input, gui_contract).
    public func failAITests(at level: String?) { lock.withLock { lanes.settings.failingLevel = level } }

    /// How many `ai.operations.get` reads an operation takes to finish.
    public func setAIOperationReads(_ n: Int) { lock.withLock { lanes.settings.operationReads = max(0, n) } }

    /// Credentials written so far (the keys themselves are never kept).
    public var aiCredentialsWritten: Int { lock.withLock { lanes.settings.credentialsWritten } }

    /// Changes a connection behind the page's back (another window or the
    /// CLI): its revision goes up, so the page's next write conflicts.
    public func touchAIConnection(_ id: String, name: String) {
        lock.withLock {
            guard let i = lanes.settings.connections.firstIndex(where: { $0["connectionId"]?.stringValue == id }) else { return }
            let c = lanes.settings.connections[i]
            lanes.settings.connections[i] = c.setting("name", .string(name))
                .setting("revision", .int((c["revision"]?.intValue ?? 1) + 1)).setting("updatedAt", .string(stamp()))
        }
    }

    /// The Settings sample of the wireframes (P23–P26, P30): two neutral
    /// connections (one disabled), a verified model, the default GUI profile
    /// at r7, and usage with unreported tokens. No real endpoint or key.
    public func seedSettingsSample() {
        let local = addAIConnection(name: "本地 GUI 连接", baseUrl: "http://127.0.0.1:8000/v1", revision: 3)
        let custom = addAIConnection(name: "自定义兼容服务", baseUrl: "https://api.example.invalid/v1", enabled: false)
        let mp = addAIModelProfile(connectionId: local, modelId: "gui-model-v1", verified: true)
        addAIModelProfile(connectionId: custom, modelId: "vision-model-demo")
        addAIGuiProfile(name: "默认 GUI 配置", modelProfileId: mp, revision: 7, makeDefault: true)
        setAIUsage(attempts: 4, confirmedActions: 2, attemptsMissingUsage: 1, totalTokens: 2108)
    }

    // MARK: Answers

    /// Lane UI-D's answer to one of `settingsLaneMethods` (lock held).
    func settingsLane(_ method: String, _ p: JSONValue, context: RequestContext) throws -> JSONValue {
        let s = lanes.settings
        switch method {
        case "ai.connections.list":
            let all = p["includeDisabled"]?.boolValue == true
            return page(s.connections.filter { all || $0["state"]?.stringValue == "enabled" }, p)
        case "ai.connections.get":
            return try find(s.connections, "connectionId", p, "aiConnection").value
        case "ai.connections.create":
            if s.connections.contains(where: { $0["name"] == p["name"] }) {
                throw Self.serviceError("conflict", "CONFIG_CONFLICT", "a connection with this name exists")
            }
            let id = s.id("conn")
            s.credentialsWritten += 1
            let now = stamp()
            let c = JSONValue.obj([
                ("connectionId", .string(id)), ("revision", .int(1)), ("name", p["name"]!), ("protocol", p["protocol"]!),
                ("baseUrl", p["baseUrl"]!), ("credentialRef", .string("cred_\(id)_1")), ("state", .string("enabled")),
                ("timeoutMs", p["timeoutMs"]!), ("createdAt", .string(now)), ("updatedAt", .string(now)),
            ])
            s.connections.append(c)
            return c
        case "ai.connections.update":
            return try revise(&s.connections, "connectionId", p, "aiConnection") { c in
                var c = c
                for (k, v) in p["patch"]?.objectMembers ?? [] { c = c.setting(k, v) }
                return c
            }
        case "ai.connections.disable":
            return try revise(&s.connections, "connectionId", p, "aiConnection") { $0.setting("state", .string("disabled")) }
        case "ai.connections.delete":
            let id = p["connectionId"]?.stringValue ?? ""
            if s.modelProfiles.contains(where: { $0["connectionId"]?.stringValue == id }) {
                throw Self.serviceError("conflict", "RESOURCE_IN_USE", "model profiles still use this connection",
                                        reason: "in_use", resourceId: id)
            }
            return try remove(&s.connections, "connectionId", p, type: "aiConnection")
        case "ai.credentials.rotate":
            s.credentialsWritten += 1
            let n = s.credentialsWritten
            return try revise(&s.connections, "connectionId", p, "aiConnection") { c in
                c.setting("credentialRef", .string("cred_\(c["connectionId"]!.stringValue!)_\(n)"))
            }
        case "ai.models.list":
            let c = try find(s.connections, "connectionId", p, "aiConnection").value
            let id = c["connectionId"]!.stringValue!
            let cat = s.catalogs[id]
            return .obj([("connectionId", .string(id)), ("connectionRevision", c["revision"]!),
                         ("items", .array(cat?.items ?? [])), ("nextCursor", .null),
                         ("refreshedAt", cat.map { .string($0.refreshedAt) } ?? .null)])
        case "ai.models.refresh":
            let c = try find(s.connections, "connectionId", p, "aiConnection").value
            try expect(c, p["expectedRevision"], "connectionId")
            let id = c["connectionId"]!.stringValue!
            let now = stamp()
            let items: [JSONValue] = ["gui-model-v1", "vision-model-demo"].map {
                .obj([("modelId", .string($0)), ("displayName", .string($0)), ("imageInput", .string("unknown")),
                      ("source", .string("upstream_models")), ("discoveredAt", .string(now))])
            }
            let result = JSONValue.obj([("connectionId", .string(id)), ("connectionRevision", c["revision"]!),
                                        ("modelCount", .int(items.count)), ("refreshedAt", .string(now))])
            s.catalogs[id] = (items, now)
            return startOperation("model_refresh", resource: c, revisionKey: "revision", finish: result, failure: nil)
        case "ai.modelProfiles.list":
            let all = p["includeDisabled"]?.boolValue == true
            let conn = p["connectionId"]?.stringValue
            return page(s.modelProfiles.filter {
                (all || $0["state"]?.stringValue == "enabled") && (conn == nil || $0["connectionId"]?.stringValue == conn)
            }, p)
        case "ai.modelProfiles.get":
            return try find(s.modelProfiles, "modelProfileId", p, "aiModelProfile").value
        case "ai.modelProfiles.create":
            let c = try find(s.connections, "connectionId", p, "aiConnection").value
            try expect(c, p["connectionRevision"], "connectionId")
            guard c["state"]?.stringValue == "enabled" else {
                throw Self.serviceError("conflict", "RESOURCE_DISABLED", "the connection is disabled", reason: "disabled",
                                        resourceId: c["connectionId"]?.stringValue)
            }
            let id = s.id("mp")
            let now = stamp()
            let rev = c["revision"]!.intValue!
            let mp = JSONValue.obj([
                ("modelProfileId", .string(id)), ("revision", .int(1)), ("name", p["name"]!), ("state", .string("enabled")),
                ("connectionId", p["connectionId"]!), ("connectionRevision", .int(rev)), ("modelId", p["modelId"]!),
                ("requestOptions", p["requestOptions"]!), ("maxOutputTokens", p["maxOutputTokens"]!),
                ("capabilities", Self.evidence("unknown", connectionRevision: rev, checkedAt: nil, operationId: nil)),
                ("createdAt", .string(now)), ("updatedAt", .string(now)),
            ])
            s.modelProfiles.append(mp)
            return mp
        case "ai.modelProfiles.update":
            return try revise(&s.modelProfiles, "modelProfileId", p, "aiModelProfile") { m in
                var m = m
                for (k, v) in p["patch"]?.objectMembers ?? [] { m = m.setting(k, v) }
                return m
            }
        case "ai.modelProfiles.disable":
            return try revise(&s.modelProfiles, "modelProfileId", p, "aiModelProfile") { $0.setting("state", .string("disabled")) }
        case "ai.modelProfiles.delete":
            let id = p["modelProfileId"]?.stringValue ?? ""
            if s.profiles.contains(where: { $0["modelProfileId"]?.stringValue == id }) {
                throw Self.serviceError("conflict", "RESOURCE_IN_USE", "GUI profiles still use this model profile",
                                        reason: "in_use", resourceId: id)
            }
            return try remove(&s.modelProfiles, "modelProfileId", p, type: "aiModelProfile")
        case "ai.profiles.list":
            let all = p["includeDisabled"]?.boolValue == true
            return page(s.profiles.filter { all || $0["state"]?.stringValue == "enabled" }, p)
        case "ai.profiles.get":
            return try find(s.profiles, "guiProfileId", p, "guiAiProfile").value
        case "ai.profiles.create":
            let mp = try find(s.modelProfiles, "modelProfileId", p, "aiModelProfile").value
            try expect(mp, p["modelProfileRevision"], "modelProfileId")
            let id = s.id("gui")
            let now = stamp()
            var members = p.objectMembers ?? []
            members.insert(contentsOf: [("guiProfileId", .string(id)), ("revision", .int(1))], at: 0)
            members.append(contentsOf: [("state", .string("enabled")), ("createdAt", .string(now)), ("updatedAt", .string(now))])
            let profile = JSONValue.obj(members)
            s.profiles.append(profile)
            return profile
        case "ai.profiles.update":
            return try revise(&s.profiles, "guiProfileId", p, "guiAiProfile") { g in
                var g = g
                for (k, v) in p["patch"]?.objectMembers ?? [] { g = g.setting(k, v) }
                return g
            }
        case "ai.profiles.disable":
            let id = p["guiProfileId"]?.stringValue
            let out = try revise(&s.profiles, "guiProfileId", p, "guiAiProfile") { $0.setting("state", .string("disabled")) }
            if s.defaultProfileId == id { s.defaultProfileId = nil; s.defaultRevision += 1 }
            return out
        case "ai.profiles.delete":
            let id = p["guiProfileId"]?.stringValue
            let out = try remove(&s.profiles, "guiProfileId", p, type: "guiAiProfile")
            if s.defaultProfileId == id { s.defaultProfileId = nil; s.defaultRevision += 1 }
            return out
        case "ai.profiles.default.get":
            return defaultResult()
        case "ai.profiles.setDefault":
            guard p["expectedDefaultRevision"]?.intValue == s.defaultRevision else {
                throw Self.serviceError("conflict", "CONFIG_CONFLICT", "the default changed", currentRevision: s.defaultRevision)
            }
            if let id = p["guiProfileId"]?.stringValue {
                let g = try find(s.profiles, "guiProfileId", p, "guiAiProfile").value
                try expect(g, p["expectedProfileRevision"], "guiProfileId")
                guard g["state"]?.stringValue == "enabled" else {
                    throw Self.serviceError("conflict", "RESOURCE_DISABLED", "the profile is disabled", reason: "disabled", resourceId: id)
                }
            }
            s.defaultProfileId = p["guiProfileId"]?.stringValue
            s.defaultRevision += 1
            return defaultResult()
        case "ai.tests.start":
            let g = try find(s.profiles, "guiProfileId", p, "guiAiProfile").value
            try expect(g, p["expectedRevision"], "guiProfileId")
            let mpId = g["modelProfileId"]?.stringValue
            let mp = s.modelProfiles.first { $0["modelProfileId"]?.stringValue == mpId }
            let connRev = mp?["connectionRevision"]?.intValue ?? 1
            var failed = false
            let levels: [JSONValue] = ["network", "auth_model", "image_input", "gui_contract"].map { level in
                let status = failed ? "skipped" : (s.failingLevel == level ? "failed" : "passed")
                if status == "failed" { failed = true }
                return .obj([("level", .string(level)), ("status", .string(status)),
                             ("latencyMs", status == "skipped" ? .null : .int(120)),
                             ("reasonCode", status == "failed" ? .string("model_rejected_image") : .null),
                             ("httpStatus", status == "skipped" ? .null : .int(status == "failed" ? 400 : 200))])
            }
            let opId = s.id("op")
            let caps = JSONValue.obj(zip(["network", "authModel", "imageInput", "guiContract"], levels).map { key, level in
                let st = level["status"]!.stringValue!
                return (key, Self.evidenceLevel(st == "passed" ? "verified" : st == "failed" ? "failed" : "unknown",
                                                connectionRevision: connRev, checkedAt: st == "skipped" ? nil : stamp(),
                                                operationId: st == "skipped" ? nil : opId,
                                                reason: st == "failed" ? "model_rejected_image" : nil))
            })
            let result = JSONValue.obj([("guiProfileId", g["guiProfileId"]!), ("guiProfileRevision", g["revision"]!),
                                        ("levels", .array(levels)), ("capabilities", caps),
                                        ("performedDesktopInput", .bool(false))])
            return startOperation("capability_test", resource: g, revisionKey: "revision", finish: result, failure: nil, id: opId)
        case "ai.operations.get":
            guard let id = p["operationId"]?.stringValue, var entry = s.operations[id] else {
                throw Self.serviceError("not_found", "NOT_FOUND", "no such operation")
            }
            let state = entry.op["state"]?.stringValue ?? "queued"
            if ["queued", "running"].contains(state) {
                if entry.readsLeft > 0 {
                    entry.readsLeft -= 1
                    entry.op = entry.op.setting("state", .string("running")).setting("updatedAt", .string(stamp()))
                } else {
                    entry.op = entry.op.setting("state", .string(entry.failure == nil ? "succeeded" : "failed"))
                        .setting("result", entry.finish ?? .null).setting("error", entry.failure ?? .null)
                        .setting("updatedAt", .string(stamp()))
                    applyTestEvidence(entry.op)
                }
                s.operations[id] = entry
            }
            return entry.op
        case "ai.operations.cancel":
            guard let id = p["operationId"]?.stringValue, var entry = s.operations[id] else {
                throw Self.serviceError("not_found", "NOT_FOUND", "no such operation")
            }
            let state = entry.op["state"]?.stringValue ?? "queued"
            if ["queued", "running"].contains(state) {
                entry.op = entry.op.setting("state", .string("cancelled")).setting("updatedAt", .string(stamp()))
                s.operations[id] = entry
                return .obj([("operationId", .string(id)), ("accepted", .bool(true)), ("state", .string("cancelled")),
                             ("terminal", .bool(true))])
            }
            let terminal = ["succeeded", "failed", "cancelled"].contains(state)
            return .obj([("operationId", .string(id)), ("accepted", .bool(false)),
                         ("state", .string(state == "cancelling" ? "cancelling" : state)), ("terminal", .bool(terminal))])
        case "ai.usage.summary":
            let u = s.usage
            let tokens: JSONValue = u?.totalTokens.map { total in
                .obj([("inputTokens", .null), ("outputTokens", .null), ("cacheReadTokens", .null),
                      ("cacheWriteTokens", .null), ("totalTokens", .int(total))])
            } ?? .null
            return .obj([
                ("from", p["from"]!), ("to", p["to"]!),
                ("inferenceAttempts", .int(u?.attempts ?? 0)), ("confirmedActions", .int(u?.confirmed ?? 0)),
                ("unknownActionOutcomes", .int(u?.unknown ?? 0)), ("attemptsMissingUsage", .int(u?.missing ?? 0)),
                ("reportedTokens", tokens), ("knownCostSubtotal", .null), ("costCoverage", .string("unknown")),
                ("isFinalBill", .bool(false)),
            ])
        default:
            throw RuntimeError.capabilityMissing("the mock does not model \(method)")
        }
    }

    // MARK: Helpers (lock held)

    static let ceilingLimits: JSONValue = .obj([
        ("maxSteps", .int(20)), ("maxWallTimeMs", .int(120_000)), ("maxModelAttemptsPerStep", .int(2)),
        ("maxTotalModelAttempts", .int(30)), ("maxOutputTokens", .int(1024)), ("maxWaitMs", .int(5000)),
        ("maxScreenshots", .int(5)), ("maxImageEncodedBytes", .int(8_388_608)), ("requireReportedUsage", .bool(false)),
    ])

    static func evidenceLevel(_ status: String, connectionRevision: Int, checkedAt: String?, operationId: String?,
                              reason: String? = nil) -> JSONValue {
        .obj([("status", .string(status)), ("checkedAt", checkedAt.map(JSONValue.string) ?? .null),
              ("testOperationId", operationId.map(JSONValue.string) ?? .null),
              ("scope", .obj([("connectionRevision", .int(connectionRevision))])),
              ("reasonCode", reason.map(JSONValue.string) ?? .null)])
    }

    static func evidence(_ status: String, connectionRevision: Int, checkedAt: String?, operationId: String?) -> JSONValue {
        let level = evidenceLevel(status, connectionRevision: connectionRevision, checkedAt: checkedAt, operationId: operationId)
        return .obj([("network", level), ("authModel", level), ("imageInput", level), ("guiContract", level)])
    }

    /// A service refusal as the Runtime bridge passes it on (freeze §6).
    static func serviceError(_ code: String, _ serviceCode: String, _ message: String, reason: String? = nil,
                             resourceId: String? = nil, currentRevision: Int? = nil) -> RuntimeError {
        var d: [(String, JSONValue)] = []
        if let currentRevision { d.append(("currentRevision", .int(currentRevision))) }
        if let resourceId { d.append(("resourceId", .string(resourceId))) }
        if let reason { d.append(("reason", .string(reason))) }
        d.append(("serviceCode", .string(serviceCode)))
        return RuntimeError(code, message, phase: .handler, details: .obj(d))
    }

    private func page(_ items: [JSONValue], _ p: JSONValue) -> JSONValue {
        .obj([("items", .array(Array(items.prefix(p["limit"]?.intValue ?? 100)))), ("nextCursor", .null)])
    }

    private func find(_ list: [JSONValue], _ key: String, _ p: JSONValue, _ type: String) throws -> (index: Int, value: JSONValue) {
        let id = p[key]?.stringValue ?? ""
        guard let i = list.firstIndex(where: { $0[key]?.stringValue == id }) else {
            throw Self.serviceError("not_found", "NOT_FOUND", "no \(type) \(id)", resourceId: id.isEmpty ? nil : id)
        }
        return (i, list[i])
    }

    private func expect(_ current: JSONValue, _ expected: JSONValue?, _ key: String) throws {
        let rev = current["revision"]?.intValue ?? 1
        guard let e = expected?.intValue, e == rev else {
            throw Self.serviceError("conflict", "CONFIG_CONFLICT", "the resource changed since it was read",
                                    resourceId: current[key]?.stringValue, currentRevision: rev)
        }
    }

    /// expectedRevision check, change, revision + 1.
    private func revise(_ list: inout [JSONValue], _ key: String, _ p: JSONValue, _ type: String,
                        _ change: (JSONValue) -> JSONValue) throws -> JSONValue {
        let (i, current) = try find(list, key, p, type)
        try expect(current, p["expectedRevision"], key)
        let next = change(current).setting("revision", .int((current["revision"]?.intValue ?? 1) + 1))
            .setting("updatedAt", .string(stamp()))
        list[i] = next
        return next
    }

    private func remove(_ list: inout [JSONValue], _ key: String, _ p: JSONValue, type: String) throws -> JSONValue {
        let (i, current) = try find(list, key, p, type)
        try expect(current, p["expectedRevision"], key)
        list.remove(at: i)
        return .obj([("resourceType", .string(type)), ("resourceId", current[key]!),
                     ("revision", .int((current["revision"]?.intValue ?? 1) + 1)), ("deletedAt", .string(stamp()))])
    }

    private func defaultResult() -> JSONValue {
        let s = lanes.settings
        let resolved = s.defaultProfileId.flatMap { id in s.profiles.first { $0["guiProfileId"]?.stringValue == id } }
        return .obj([("default", .obj([("revision", .int(s.defaultRevision)),
                                       ("guiProfileId", s.defaultProfileId.map(JSONValue.string) ?? .null)])),
                     ("resolvedProfile", resolved ?? .null)])
    }

    private func startOperation(_ kind: String, resource: JSONValue, revisionKey: String, finish: JSONValue?,
                                failure: JSONValue?, id: String? = nil) -> JSONValue {
        let s = lanes.settings
        let opId = id ?? s.id("op")
        let now = stamp()
        let resourceId = resource["guiProfileId"] ?? resource["connectionId"] ?? .string("unknown")
        let op = JSONValue.obj([
            ("operationId", .string(opId)), ("kind", .string(kind)), ("state", .string("queued")),
            ("resourceId", resourceId), ("resourceRevision", resource[revisionKey] ?? .int(1)),
            ("createdAt", .string(now)), ("updatedAt", .string(now)), ("result", .null), ("error", .null),
        ])
        s.operations[opId] = (op, s.operationReads, finish, failure)
        return .obj([("operationId", .string(opId)), ("state", .string("queued"))])
    }

    /// A finished capability test records its evidence on the model profile.
    private func applyTestEvidence(_ op: JSONValue) {
        let s = lanes.settings
        guard op["kind"]?.stringValue == "capability_test", op["state"]?.stringValue == "succeeded",
              let gid = op["result"]?["guiProfileId"]?.stringValue,
              let mpId = s.profiles.first(where: { $0["guiProfileId"]?.stringValue == gid })?["modelProfileId"]?.stringValue,
              let i = s.modelProfiles.firstIndex(where: { $0["modelProfileId"]?.stringValue == mpId }),
              let caps = op["result"]?["capabilities"] else { return }
        s.modelProfiles[i] = s.modelProfiles[i].setting("capabilities", caps)
    }
}
