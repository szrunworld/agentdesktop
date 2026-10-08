import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopAI

// Case IDs refer to docs/ai-gui/tests/cases.csv. These cover the
// configuration service and its storage; GUI runs, real Keychain and the
// network are not involved.

final class TestClock: ConfigClock, @unchecked Sendable {
    private let lock = NSLock()
    private var t = Date(timeIntervalSince1970: 1_791_500_000)
    func now() -> Date { lock.lock(); defer { lock.unlock() }; return t }
    func advance(_ s: TimeInterval) { lock.lock(); t += s; lock.unlock() }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}

struct Harness {
    let dir: URL
    let path: String
    let creds: InMemoryCredentialStore
    let clock: TestClock
    let options: ConfigOptions
    let key = Data(repeating: 7, count: 32)
    let store: ConfigStore
    let service: ConfigApplicationService
    let router: RpcRouter
    let responses = Recorder()

    init(options: ConfigOptions = ConfigOptions(allowLoopbackHTTP: true), creds: InMemoryCredentialStore = InMemoryCredentialStore(),
         dir: URL? = nil, clock: TestClock = TestClock()) throws {
        let d = dir ?? FileManager.default.temporaryDirectory.appendingPathComponent("adcfg-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        self.dir = d
        self.path = d.appendingPathComponent("config.sqlite").path
        self.creds = creds
        self.clock = clock
        self.options = options
        self.store = try ConfigStore(path: path, credentials: creds, digestKey: Data(repeating: 7, count: 32),
                                     clock: clock, options: options)
        self.service = ConfigApplicationService(store: store)
        self.router = RpcRouter(handlers: service.handlers(callerScope: "owner"))
    }

    /// A second store over the same files: a restarted host.
    func reopened(options: ConfigOptions? = nil) throws -> Harness {
        try Harness(options: options ?? self.options, creds: creds, dir: dir, clock: clock)
    }

    @discardableResult
    func call(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil,
              router: RpcRouter? = nil) async throws -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("schemaVersion", .string("agentdesktop.ai/1")), ("requestId", .string(UUID().uuidString.lowercased())),
            ("command", .string(command)), ("params", params),
        ]
        let op = ContractBundle.shared.operation(command)!
        if op.requiresIdempotencyKey || key != nil {
            m.append(("context", .obj([("idempotencyKey", .string(key ?? "k-\(UUID().uuidString)"))])))
        }
        let out = await (router ?? self.router).respond(toBody: JSONValue.obj(m).encodedData())
        let text = String(decoding: out, as: UTF8.self)
        responses.add(text)
        var body = out; body.removeLast()
        return try StrictJSON.parse(body)
    }

    /// The result of a successful call, checked against `<command>_result`.
    func ok(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> JSONValue {
        let v = try await call(command, params, key: key)
        guard v["ok"]?.boolValue == true, let r = v["result"] else {
            Issue.record("\(command) failed: \(v.encoded())")
            throw CancellationError()
        }
        let op = ContractBundle.shared.operation(command)!
        #expect(try ContractBundle.shared.validateRpc(r, "\(op.defPrefix)_result").isEmpty)
        return r
    }

    func err(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> String? {
        let v = try await call(command, params, key: key)
        #expect(v["ok"]?.boolValue == false, "\(command) should fail")
        return v["error"]?["code"]?.stringValue
    }

    func createConnection(name: String = "Ark", apiKey: String = "sk-test-0001", url: String = "https://ark.cn-beijing.volces.com/api/v3",
                          key: String? = nil) async throws -> JSONValue {
        try await ok("ai.connections.create", .obj([
            ("name", .string(name)), ("protocol", .string("openai_chat")), ("baseUrl", .string(url)),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string(apiKey))])),
        ]), key: key)
    }

    func createModel(_ conn: JSONValue, modelId: String = "doubao-seed-2-1-lite-260915") async throws -> JSONValue {
        try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("Seed lite")), ("connectionId", conn["connectionId"]!),
            ("connectionRevision", conn["revision"]!), ("modelId", .string(modelId)),
            ("requestOptions", .obj([("temperature", .double(0)), ("seed", .int(7))])), ("maxOutputTokens", .int(1024)),
        ]))
    }

    static let limits: JSONValue = .obj([
        ("maxSteps", .int(20)), ("maxWallTimeMs", .int(120000)), ("maxModelAttemptsPerStep", .int(2)),
        ("maxTotalModelAttempts", .int(30)), ("maxOutputTokens", .int(1024)), ("maxWaitMs", .int(5000)),
        ("maxScreenshots", .int(5)), ("maxImageEncodedBytes", .int(8_388_608)), ("requireReportedUsage", .bool(false)),
    ])

    func guiParams(_ model: JSONValue, name: String = "UI-TARS", fallback: [JSONValue] = [], adapter: String = "uitars_v1") -> JSONValue {
        .obj([
            ("name", .string(name)), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
            ("adapterId", .string(adapter)), ("adapterVersion", .string("1")), ("promptVersion", .string("1")),
            ("parserVersion", .string("1")), ("coordinateProtocol", .string("normalized_1000")),
            ("limits", Harness.limits), ("allowedFallbackProfileRefs", .array(fallback)),
        ])
    }

    func createGui(_ model: JSONValue, name: String = "UI-TARS", fallback: [JSONValue] = []) async throws -> JSONValue {
        try await ok("ai.profiles.create", guiParams(model, name: name, fallback: fallback))
    }

    func ref(_ gui: JSONValue) -> JSONValue {
        .obj([("guiProfileId", gui["guiProfileId"]!), ("revision", gui["revision"]!)])
    }
}

func cid(_ v: JSONValue) -> String { v["connectionId"]!.stringValue! }
func rev(_ v: JSONValue) -> Int { v["revision"]!.intValue! }

@Suite("Configuration service")
struct ConfigServiceTests {
    @Test func cfg001_threeLayersStoredSeparately() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let m = try await h.createModel(c)
        let g = try await h.createGui(m)
        #expect(rev(c) == 1 && rev(m) == 1 && rev(g) == 1)
        #expect(Set([cid(c), m["modelProfileId"]!.stringValue!, g["guiProfileId"]!.stringValue!]).count == 3)
        #expect(m["connectionId"] == c["connectionId"] && m["connectionRevision"] == .int(1))
        #expect(g["modelProfileId"] == m["modelProfileId"] && g["modelProfileRevision"] == .int(1))
        #expect(c["credentialRef"]?.stringValue?.contains("sk-") == false)
        #expect(c["baseUrl"]?.stringValue == "https://ark.cn-beijing.volces.com/api/v3/")

        let r = try h.reopened()
        #expect(try await r.ok("ai.connections.get", .obj([("connectionId", c["connectionId"]!)])) == c)
        #expect(try await r.ok("ai.modelProfiles.get", .obj([("modelProfileId", m["modelProfileId"]!)])) == m)
        #expect(try await r.ok("ai.profiles.get", .obj([("guiProfileId", g["guiProfileId"]!)])) == g)
    }

    @Test func cfg002_casUpdateForEachLayer() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let m = try await h.createModel(c)
        let g = try await h.createGui(m)
        let layers: [(String, String, JSONValue)] = [
            ("ai.connections.update", "connectionId", c), ("ai.modelProfiles.update", "modelProfileId", m),
            ("ai.profiles.update", "guiProfileId", g),
        ]
        for (command, idField, obj) in layers {
            let a = try await h.ok(command, .obj([(idField, obj[idField]!), ("expectedRevision", .int(1)),
                                                  ("patch", .obj([("name", .string("A"))]))]))
            #expect(rev(a) == 2)
            let b = try await h.call(command, .obj([(idField, obj[idField]!), ("expectedRevision", .int(1)),
                                                    ("patch", .obj([("name", .string("B"))]))]))
            #expect(b["error"]?["code"]?.stringValue == "CONFIG_CONFLICT")
            #expect(b["error"]?["details"]?["currentRevision"]?.intValue == 2)
            let getCommand = command.replacingOccurrences(of: ".update", with: ".get")
            #expect(try await h.ok(getCommand, .obj([(idField, obj[idField]!)]))["name"]?.stringValue == "A")
        }
    }

    @Test func cfg003_defaultPointerHasItsOwnRevision() async throws {
        let h = try Harness()
        let m = try await h.createModel(try await h.createConnection())
        let p1 = try await h.createGui(m, name: "P1")
        let p2 = try await h.createGui(m, name: "P2")
        let d0 = try await h.ok("ai.profiles.default.get")
        #expect(d0["default"]?["revision"]?.intValue == 1 && d0["default"]?["guiProfileId"]?.isNull == true)
        let d1 = try await h.ok("ai.profiles.setDefault", .obj([("guiProfileId", p1["guiProfileId"]!),
                                                               ("expectedDefaultRevision", .int(1)), ("expectedProfileRevision", .int(1))]))
        #expect(d1["default"]?["revision"]?.intValue == 2)
        #expect(try await h.err("ai.profiles.setDefault", .obj([("guiProfileId", p2["guiProfileId"]!),
                                                                ("expectedDefaultRevision", .int(1)), ("expectedProfileRevision", .int(1))])) == "CONFIG_CONFLICT")
        _ = try await h.ok("ai.profiles.update", .obj([("guiProfileId", p1["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                       ("patch", .obj([("name", .string("P1 renamed"))]))]))
        let d2 = try await h.ok("ai.profiles.default.get")
        #expect(d2["default"]?["revision"]?.intValue == 2, "a profile edit is not a default CAS")
        #expect(d2["resolvedProfile"]?["revision"]?.intValue == 2)
        #expect(try await h.err("ai.profiles.setDefault", .obj([("guiProfileId", p2["guiProfileId"]!),
                                                                ("expectedDefaultRevision", .int(2)), ("expectedProfileRevision", .int(9))])) == "CONFIG_CONFLICT")
        let cleared = try await h.ok("ai.profiles.setDefault", .obj([("guiProfileId", .null), ("expectedDefaultRevision", .int(2))]))
        #expect(cleared["resolvedProfile"]?.isNull == true && cleared["default"]?["revision"]?.intValue == 3)
    }

    @Test func cfg004_snapshotsStayAndDisableBlocksNewBindings() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let m = try await h.createModel(c)
        let p = try await h.createGui(m)
        let snapshot = try await h.store.revisionBody(.guiProfile, p["guiProfileId"]!.stringValue!, 1)
        _ = try await h.ok("ai.profiles.update", .obj([("guiProfileId", p["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                       ("patch", .obj([("promptVersion", .string("2"))]))]))
        #expect(try await h.store.revisionBody(.guiProfile, p["guiProfileId"]!.stringValue!, 1) == snapshot)
        #expect(snapshot?["promptVersion"]?.stringValue == "1")

        _ = try await h.ok("ai.profiles.disable", .obj([("guiProfileId", p["guiProfileId"]!), ("expectedRevision", .int(2))]))
        #expect(try await h.err("ai.profiles.setDefault", .obj([("guiProfileId", p["guiProfileId"]!),
                                                                ("expectedDefaultRevision", .int(1)), ("expectedProfileRevision", .int(3))])) == "RESOURCE_DISABLED")
        _ = try await h.ok("ai.modelProfiles.disable", .obj([("modelProfileId", m["modelProfileId"]!), ("expectedRevision", .int(1))]))
        #expect(try await h.err("ai.profiles.create", h.guiParams(m.setting("revision", .int(2)))) == "RESOURCE_DISABLED")
        _ = try await h.ok("ai.connections.disable", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1))]))
        #expect(try await h.err("ai.modelProfiles.create", .obj([
            ("name", .string("x")), ("connectionId", c["connectionId"]!), ("connectionRevision", .int(2)),
            ("modelId", .string("m")), ("requestOptions", .obj([])), ("maxOutputTokens", .int(10)),
        ])) == "RESOURCE_DISABLED")
        // A disabled resource is hidden from the ordinary list but listed on request.
        #expect(try await h.ok("ai.profiles.list")["items"]?.arrayValue?.count == 0)
        #expect(try await h.ok("ai.profiles.list", .obj([("includeDisabled", .bool(true))]))["items"]?.arrayValue?.count == 1)
    }

    @Test func cfg005_referenceProtectionAndTombstones() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let m = try await h.createModel(c)
        let p = try await h.createGui(m, name: "P")
        let f = try await h.createGui(m, name: "F")
        let withFallback = try await h.createGui(m, name: "W", fallback: [h.ref(f)])
        _ = try await h.ok("ai.profiles.setDefault", .obj([("guiProfileId", p["guiProfileId"]!),
                                                           ("expectedDefaultRevision", .int(1)), ("expectedProfileRevision", .int(1))]))
        #expect(try await h.err("ai.connections.delete", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1))])) == "RESOURCE_IN_USE")
        #expect(try await h.err("ai.connections.delete", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(9))])) == "CONFIG_CONFLICT")
        #expect(try await h.err("ai.modelProfiles.delete", .obj([("modelProfileId", m["modelProfileId"]!), ("expectedRevision", .int(1))])) == "RESOURCE_IN_USE")
        #expect(try await h.err("ai.profiles.delete", .obj([("guiProfileId", p["guiProfileId"]!), ("expectedRevision", .int(1))])) == "RESOURCE_IN_USE")
        #expect(try await h.err("ai.profiles.delete", .obj([("guiProfileId", f["guiProfileId"]!), ("expectedRevision", .int(1))])) == "RESOURCE_IN_USE")

        let busy = withFallback["guiProfileId"]!.stringValue!
        await h.store.setActiveRunCheck { kind, id in kind == .guiProfile && id == busy }
        #expect(try await h.err("ai.profiles.delete", .obj([("guiProfileId", withFallback["guiProfileId"]!), ("expectedRevision", .int(1))])) == "RESOURCE_IN_USE")
        await h.store.setActiveRunCheck { _, _ in false }

        let q = try await h.createGui(m, name: "Q")
        let before = try await h.ok("ai.profiles.list", .obj([("limit", .int(100))]))["items"]!.arrayValue!.count
        let t = try await h.ok("ai.profiles.delete", .obj([("guiProfileId", q["guiProfileId"]!), ("expectedRevision", .int(1))]))
        #expect(t["resourceType"]?.stringValue == "guiAiProfile" && t["revision"]?.intValue == 2)
        #expect(try await h.err("ai.profiles.get", .obj([("guiProfileId", q["guiProfileId"]!)])) == "NOT_FOUND")
        let after = try await h.ok("ai.profiles.list", .obj([("limit", .int(100))]))["items"]!.arrayValue!
        #expect(after.count == before - 1 && !after.contains { $0["guiProfileId"] == q["guiProfileId"] })
        #expect(try await h.store.revisionBody(.guiProfile, q["guiProfileId"]!.stringValue!, 1)?["name"]?.stringValue == "Q",
                "history stays traceable")
        #expect(try await h.err("ai.profiles.delete", .obj([("guiProfileId", q["guiProfileId"]!), ("expectedRevision", .int(2))])) == "NOT_FOUND")
    }

    @Test func cfg006_invalidReferencesFailBeforeAnyUpstream() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let m = try await h.createModel(c)
        let missing = m.setting("modelProfileId", .string("mp_missing"))
        #expect(try await h.err("ai.profiles.create", h.guiParams(missing)) == "NOT_FOUND")
        _ = try await h.ok("ai.connections.update", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                          ("patch", .obj([("timeoutMs", .int(60000))]))]))
        #expect(try await h.err("ai.modelProfiles.create", .obj([
            ("name", .string("stale")), ("connectionId", c["connectionId"]!), ("connectionRevision", .int(1)),
            ("modelId", .string("m")), ("requestOptions", .obj([])), ("maxOutputTokens", .int(10)),
        ])) == "CONFIG_CONFLICT")
        // The existing profile keeps its pin until the user adopts the new revision.
        #expect(try await h.ok("ai.modelProfiles.get", .obj([("modelProfileId", m["modelProfileId"]!)]))["connectionRevision"]?.intValue == 1)

        let a = try await h.createGui(m, name: "A")
        let b = try await h.createGui(m, name: "B", fallback: [h.ref(a)])
        #expect(try await h.err("ai.profiles.update", .obj([("guiProfileId", a["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                            ("patch", .obj([("allowedFallbackProfileRefs", .array([h.ref(b)]))]))])) == "VALIDATION_ERROR")
        #expect(try await h.err("ai.profiles.update", .obj([("guiProfileId", a["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                            ("patch", .obj([("allowedFallbackProfileRefs", .array([h.ref(a)]))]))])) == "VALIDATION_ERROR")
        #expect(try await h.err("ai.profiles.create", h.guiParams(m, fallback: [h.ref(a), h.ref(b)])) == "VALIDATION_ERROR")
        #expect(try await h.err("ai.profiles.create", h.guiParams(m, adapter: "fixture_json_v1")) == "CAPABILITY_MISMATCH")
        let testBuild = try Harness(options: ConfigOptions(allowLoopbackHTTP: true, allowFixtureAdapter: true))
        let m2 = try await testBuild.createModel(try await testBuild.createConnection())
        _ = try await testBuild.ok("ai.profiles.create", testBuild.guiParams(m2, adapter: "fixture_json_v1"))
    }

    @Test func cfg007_limitsAndProtocols() async throws {
        let h = try Harness()
        let m = try await h.createModel(try await h.createConnection())
        for (k, v) in [("maxSteps", 21), ("maxWallTimeMs", 120001), ("maxModelAttemptsPerStep", 3), ("maxTotalModelAttempts", 31),
                       ("maxOutputTokens", 1025), ("maxWaitMs", 5001), ("maxSteps", 0), ("maxWaitMs", -1)] {
            let p = h.guiParams(m).setting("limits", Harness.limits.setting(k, .int(v)))
            #expect(try await h.err("ai.profiles.create", p) == "VALIDATION_ERROR", "\(k)=\(v)")
        }
        let tighter = h.guiParams(m).setting("limits", Harness.limits.setting("maxSteps", .int(1)).setting("maxWaitMs", .int(0)))
        _ = try await h.ok("ai.profiles.create", tighter)
        // Over RPC the schema answers first; the service also refuses on its own.
        #expect(try await h.err("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("anthropic_messages")), ("baseUrl", .string("https://a.example/v1")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string("k"))])),
        ])) == "VALIDATION_ERROR")
        await #expect(throws: ContractError(.unsupportedProtocol, "only openai_chat is implemented in this version")) {
            _ = try await h.store.createConnection(name: "x", protocol: "gemini_generate_content",
                                                   baseUrl: "https://a.example/v1", timeoutMs: 1000, apiKey: "k")
        }
    }

    @Test func cfg008_capabilityEvidenceIsPerLayerAndPerRevision() async throws {
        let h = try Harness()
        let m = try await h.createModel(try await h.createConnection())
        let id = m["modelProfileId"]!.stringValue!
        for layer in ["network", "authModel", "imageInput", "guiContract"] {
            #expect(m["capabilities"]?[layer]?["status"]?.stringValue == "unknown")
        }
        try await h.store.recordCapabilityEvidence(modelProfileId: id, revision: 1, layer: .network, status: "verified", operationId: "op-1", reasonCode: nil)
        try await h.store.recordCapabilityEvidence(modelProfileId: id, revision: 1, layer: .authModel, status: "verified", operationId: "op-1", reasonCode: nil)
        try await h.store.recordCapabilityEvidence(modelProfileId: id, revision: 1, layer: .imageInput, status: "failed", operationId: "op-1", reasonCode: "CAPABILITY_MISMATCH")
        let now = try await h.ok("ai.modelProfiles.get", .obj([("modelProfileId", .string(id))]))
        #expect(now["capabilities"]?["authModel"]?["status"]?.stringValue == "verified")
        #expect(now["capabilities"]?["imageInput"]?["status"]?.stringValue == "failed")
        #expect(now["capabilities"]?["imageInput"]?["reasonCode"]?.stringValue == "CAPABILITY_MISMATCH")
        #expect(now["capabilities"]?["guiContract"]?["status"]?.stringValue == "unknown", "auth success never verifies the GUI layer")
        let changed = try await h.ok("ai.modelProfiles.update", .obj([("modelProfileId", .string(id)), ("expectedRevision", .int(1)),
                                                                      ("patch", .obj([("modelId", .string("other-model"))]))]))
        for layer in ["network", "authModel", "imageInput", "guiContract"] {
            #expect(changed["capabilities"]?[layer]?["status"]?.stringValue == "unknown", "old evidence does not carry to \(layer) of revision 2")
        }
        #expect(try await h.store.revisionBody(.modelProfile, id, 1)?["capabilities"]?["authModel"]?["status"]?.stringValue == "verified")
    }

    @Test func listsPageWithCursorsBoundToTheFilter() async throws {
        let h = try Harness()
        for i in 0..<25 { _ = try await h.createConnection(name: "c\(i)") }
        let first = try await h.ok("ai.connections.list")
        #expect(first["items"]?.arrayValue?.count == 20)
        let cursor = first["nextCursor"]!
        let second = try await h.ok("ai.connections.list", .obj([("cursor", cursor)]))
        #expect(second["items"]?.arrayValue?.count == 5 && second["nextCursor"]?.isNull == true)
        let names = (first["items"]!.arrayValue! + second["items"]!.arrayValue!).compactMap { $0["name"]?.stringValue }
        #expect(Set(names).count == 25)
        #expect(try await h.err("ai.connections.list", .obj([("cursor", cursor), ("includeDisabled", .bool(true))])) == "VALIDATION_ERROR")
        #expect(try await h.err("ai.connections.list", .obj([("limit", .int(101))])) == "VALIDATION_ERROR")
        #expect(try await h.err("ai.connections.list", .obj([("cursor", .string("bm9wZQ=="))])) == "VALIDATION_ERROR")
    }
}

@Suite("Idempotency")
struct IdempotencyTests {
    // RPC-006 (configuration part): ten concurrent creates with one key.
    @Test func rpc006_concurrentSameKeyCreatesOnce() async throws {
        let h = try Harness()
        let params: JSONValue = .obj([
            ("name", .string("Ark")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://ark.example/api/v3")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-once"))])),
        ])
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 {
                group.addTask { try await h.ok("ai.connections.create", params, key: "create-ark-1")["connectionId"]!.stringValue! }
            }
            return try await group.reduce(into: [String]()) { $0.append($1) }
        }
        #expect(ids.count == 10 && Set(ids).count == 1)
        #expect(try await h.ok("ai.connections.list")["items"]?.arrayValue?.count == 1)
        #expect(h.creds.storedIds.count == 1, "one secret written")
    }

    // RPC-007 (configuration part).
    @Test func rpc007_sameKeyDifferentBodyAndOtherCaller() async throws {
        let h = try Harness()
        let c = try await h.createConnection(name: "first", key: "shared-key-1")
        #expect(try await h.err("ai.connections.create", .obj([
            ("name", .string("second")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://ark.example/api/v3")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-test-0001"))])),
        ]), key: "shared-key-1") == "IDEMPOTENCY_CONFLICT")
        // Same visible fields, different secret: still a different request.
        #expect(try await h.err("ai.connections.create", .obj([
            ("name", .string("first")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-test-0002"))])),
        ]), key: "shared-key-1") == "IDEMPOTENCY_CONFLICT")
        #expect(try await h.ok("ai.connections.list")["items"]?.arrayValue?.count == 1)

        let other = RpcRouter(handlers: h.service.handlers(callerScope: "other-caller"))
        let mine = try await h.call("ai.connections.create", .obj([
            ("name", .string("theirs")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://x.example/v1")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-other"))])),
        ]), key: "shared-key-1", router: other)
        #expect(mine["ok"]?.boolValue == true)
        #expect(mine["result"]?["connectionId"] != c["connectionId"], "no leak of the first caller's result")
    }

    @Test func recordsExpireAfterRetention() async throws {
        let h = try Harness()
        _ = try await h.createConnection(name: "a", key: "expiring-key")
        h.clock.advance(24 * 3600 + 1)
        let again = try await h.createConnection(name: "b", key: "expiring-key")
        #expect(again["name"]?.stringValue == "b")
    }

    @Test func failedValidationDoesNotPoisonTheKey() async throws {
        let h = try Harness()
        let c = try await h.createConnection()
        let p: JSONValue = .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(5)), ("patch", .obj([("name", .string("x"))]))])
        #expect(try await h.err("ai.connections.update", p, key: "upd-key-1") == "CONFIG_CONFLICT")
        let fixed = p.setting("expectedRevision", .int(1))
        _ = try await h.ok("ai.connections.update", fixed, key: "upd-key-2")
        #expect(try await h.err("ai.connections.update", p, key: "upd-key-1") == "CONFIG_CONFLICT")
    }
}

@Suite("Credentials")
struct CredentialTests {
    // SEC-001 (local part): the key appears only in the credential store.
    @Test func sec001_canaryNeverLeaves() async throws {
        let canary1 = "sk-CANARY-\(UUID().uuidString)"
        let canary2 = "sk-CANARY-\(UUID().uuidString)"
        let h = try Harness()
        let c = try await h.createConnection(apiKey: canary1)
        let m = try await h.createModel(c)
        _ = try await h.createGui(m)
        let rotated = try await h.ok("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                                    ("credential", .obj([("apiKey", .string(canary2))]))]))
        _ = try await h.ok("ai.connections.list")
        _ = try await h.ok("ai.connections.get", .obj([("connectionId", c["connectionId"]!)]))
        _ = try await h.call("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                            ("credential", .obj([("apiKey", .string(canary1))]))]))
        _ = try await h.call("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")), ("baseUrl", .string("http://evil.example/v1")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string(canary1))])), ("leak", .string(canary2)),
        ]))
        _ = try await h.call("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://evil.example/v1/chat/completions")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string(canary1))])),
        ]))
        #expect(rotated["credentialRef"] != c["credentialRef"])
        for text in h.responses.all {
            #expect(!text.contains("CANARY"), "a response carried the key")
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: h.dir.path)
        #expect(files.contains("config.sqlite"))
        for f in files {
            let bytes = try Data(contentsOf: h.dir.appendingPathComponent(f))
            #expect(bytes.range(of: Data("CANARY".utf8)) == nil, "\(f) holds the key")
        }
        #expect(try await h.store.resolveSecret(credentialId: rotated["credentialRef"]!.stringValue!) == canary2)
    }

    // SEC-002 (local part): survives restart; a missing secret never falls back.
    @Test func sec002_secretSurvivesRestartAndMissingSecretFails() async throws {
        let h = try Harness()
        let c = try await h.createConnection(apiKey: "sk-persist")
        let credentialId = c["credentialRef"]!.stringValue!
        let restarted = try h.reopened()
        #expect(try await restarted.store.resolveSecret(credentialId: credentialId) == "sk-persist")
        h.creds.drop(credentialId)
        await #expect(throws: ContractError.self) { _ = try await restarted.store.resolveSecret(credentialId: credentialId) }
        do { _ = try await restarted.store.resolveSecret(credentialId: credentialId); Issue.record("resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRequired)
        }
        do { _ = try await restarted.store.resolveSecret(credentialId: "cred_unknown"); Issue.record("resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRequired)
        }
        h.creds.fail(.read)
        do { _ = try await restarted.store.resolveSecret(credentialId: credentialId); Issue.record("resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRequired)
        }
    }

    // SEC-004 (storage part): rotation revokes the old identity for good.
    @Test func sec004_rotationRevokesAndNotifies() async throws {
        let h = try Harness()
        let revoked = Recorder()
        await h.store.onCredentialRevoked { revoked.add($0) }
        let c = try await h.createConnection(apiKey: "sk-K1")
        let k1 = c["credentialRef"]!.stringValue!
        let r = try await h.ok("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                              ("credential", .obj([("apiKey", .string("sk-K2"))]))]))
        let k2 = r["credentialRef"]!.stringValue!
        #expect(rev(r) == 2 && k1 != k2)
        #expect(revoked.all == [k1])
        #expect(!h.creds.storedIds.contains(k1))
        do { _ = try await h.store.resolveSecret(credentialId: k1); Issue.record("K1 resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRevoked)
        }
        #expect(try await h.store.resolveSecret(credentialId: k2) == "sk-K2")
        #expect(try await h.store.credentialId(connectionId: cid(c), revision: 1) == k1)
        #expect(try await h.store.credentialId(connectionId: cid(c), revision: 2) == k2)
        // A stale rotate is a conflict and leaves no trace.
        #expect(try await h.err("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                               ("credential", .obj([("apiKey", .string("sk-K3"))]))])) == "CONFIG_CONFLICT")
        #expect(h.creds.storedIds == [k2])
    }

    @Test func secretWriteFailureLeavesNothing() async throws {
        let h = try Harness()
        h.creds.fail(.write)
        let v = try await h.call("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://a.example/v1")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string("sk-x"))])),
        ]), key: "write-fail-key")
        #expect(v["error"]?["code"]?.stringValue == "INTERNAL_ERROR" && v["error"]?["retryable"]?.boolValue == true)
        h.creds.fail(.write, false)
        #expect(try await h.ok("ai.connections.list")["items"]?.arrayValue?.isEmpty == true)
        _ = try await h.createConnection(name: "x", apiKey: "sk-x", url: "https://a.example/v1", key: "write-fail-key")
    }

    @Test func crashAfterSecretWriteIsRecovered() async throws {
        let h = try Harness()
        await h.store.setFaultHook { if $0 == .afterSecretWrite { throw SimulatedCrash() } }
        _ = try await h.call("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://a.example/v1")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string("sk-orphan"))])),
        ]), key: "crash-key-1")
        #expect(h.creds.storedIds.count == 1, "the orphan secret exists before recovery")
        let r = try h.reopened()
        try await r.store.recover()
        #expect(h.creds.storedIds.isEmpty, "recovery removes the orphan secret")
        #expect(try await r.ok("ai.connections.list")["items"]?.arrayValue?.isEmpty == true)
        // The interrupted key reports the interruption instead of redoing it.
        let again = try await r.call("ai.connections.create", .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://a.example/v1")),
            ("timeoutMs", .int(1000)), ("credential", .obj([("apiKey", .string("sk-orphan"))])),
        ]), key: "crash-key-1")
        #expect(again["error"]?["code"]?.stringValue == "INTERNAL_ERROR")
    }

    @Test func crashBeforeOutboxIsReplayed() async throws {
        let h = try Harness()
        let c = try await h.createConnection(apiKey: "sk-old")
        let k1 = c["credentialRef"]!.stringValue!
        await h.store.setFaultHook { if $0 == .afterActivate { throw SimulatedCrash() } }
        _ = try await h.call("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                            ("credential", .obj([("apiKey", .string("sk-new"))]))]))
        #expect(h.creds.storedIds.contains(k1), "the old secret is still there before recovery")
        do { _ = try await h.store.resolveSecret(credentialId: k1); Issue.record("revoked K1 resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRevoked, "revoked before the outbox runs")
        }
        let r = try h.reopened()
        let revoked = Recorder()
        await r.store.onCredentialRevoked { revoked.add($0) }
        try await r.store.recover()
        #expect(revoked.all == [k1])
        #expect(!h.creds.storedIds.contains(k1))
    }

    @Test func failedSecretCleanupStaysPendingButRevoked() async throws {
        let h = try Harness()
        let c = try await h.createConnection(apiKey: "sk-old")
        let k1 = c["credentialRef"]!.stringValue!
        h.creds.fail(.delete)
        _ = try await h.ok("ai.credentials.rotate", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1)),
                                                          ("credential", .obj([("apiKey", .string("sk-new"))]))]))
        #expect(h.creds.storedIds.contains(k1))
        do { _ = try await h.store.resolveSecret(credentialId: k1); Issue.record("K1 resolved") } catch let e as ContractError {
            #expect(e.code == .credentialRevoked)
        }
        h.creds.fail(.delete, false)
        #expect(await h.store.applyOutbox() == 1)
        #expect(!h.creds.storedIds.contains(k1))
    }

    @Test func deletingAConnectionRevokesItsCredential() async throws {
        let h = try Harness()
        let c = try await h.createConnection(apiKey: "sk-gone")
        _ = try await h.ok("ai.connections.delete", .obj([("connectionId", c["connectionId"]!), ("expectedRevision", .int(1))]))
        #expect(h.creds.storedIds.isEmpty)
        #expect(try await h.store.credentialState(c["credentialRef"]!.stringValue!) == "revoked")
    }

    @Test func keychainStoreRoundTrip() throws {
        guard ProcessInfo.processInfo.environment["AGENTDESKTOP_KEYCHAIN_TEST"] == "1" else { return }
        let store = KeychainCredentialStore(service: "com.agentdesktop.ai.test")
        let id = "cred_test_\(UUID().uuidString)"
        try store.write(credentialId: id, secret: "sk-keychain")
        #expect(try store.read(credentialId: id) == "sk-keychain")
        try store.delete(credentialId: id)
        #expect(try store.read(credentialId: id) == nil)
        try store.delete(credentialId: id)
    }
}

@Suite("Endpoints")
struct EndpointTests {
    // SEC-005 (service part).
    @Test(arguments: [
        ("https://api.example.com/v1", true, "https://api.example.com/v1/"),
        ("https://ark.cn-beijing.volces.com/api/v3/", true, "https://ark.cn-beijing.volces.com/api/v3/"),
        ("https://api.example.com", true, "https://api.example.com/"),
        ("http://127.0.0.1:8080/v1", true, "http://127.0.0.1:8080/v1/"),
        ("http://[::1]:9000", true, "http://[::1]:9000/"),
        ("http://api.example.com/v1", false, ""),
        ("https://u:p@api.example.com/v1", false, ""),
        ("https://api.example.com/v1?x=1", false, ""),
        ("https://api.example.com/v1#f", false, ""),
        ("ftp://api.example.com", false, ""),
        ("https://api.example.com/v1/chat/completions", false, ""),
        ("https://api.example.com/v1/chat/completions/", false, ""),
        ("api.example.com/v1", false, ""),
    ])
    func sec005_rules(url: String, ok: Bool, normalized: String) throws {
        if ok {
            #expect(try EndpointPolicy.normalize(url, allowLoopbackHTTP: true).absoluteString == normalized)
        } else {
            #expect(throws: ContractError.self) { try EndpointPolicy.normalize(url, allowLoopbackHTTP: true) }
        }
    }

    @Test func loopbackHttpNeedsTheLocalOption() {
        #expect(throws: ContractError.self) { try EndpointPolicy.normalize("http://127.0.0.1:8080", allowLoopbackHTTP: false) }
    }

    @Test func localhostMustResolveToLoopback() throws {
        #expect(throws: ContractError.self) {
            try EndpointPolicy.normalize("http://localhost:11434", allowLoopbackHTTP: true, resolve: { _ in ["127.0.0.1", "10.0.0.5"] })
        }
        #expect(try EndpointPolicy.normalize("http://localhost:11434", allowLoopbackHTTP: true,
                                             resolve: { _ in ["127.0.0.1", "::1"] }).absoluteString == "http://localhost:11434/")
    }

    // TRN-002 (path part): one chat/completions, base path kept.
    @Test func chatCompletionsKeepsTheBasePath() throws {
        for (base, want) in [("https://ark.cn-beijing.volces.com/api/v3", "https://ark.cn-beijing.volces.com/api/v3/chat/completions"),
                             ("https://ark.cn-beijing.volces.com/api/v3/", "https://ark.cn-beijing.volces.com/api/v3/chat/completions"),
                             ("https://api.openai.com/v1", "https://api.openai.com/v1/chat/completions")] {
            let url = try EndpointPolicy.normalize(base, allowLoopbackHTTP: false)
            #expect(EndpointPolicy.chatCompletionsURL(base: url).absoluteString == want)
        }
    }
}

// SEC-01: the configuration database and its directory are owner-only,
// also when an earlier build left them readable.
@Suite("Config store file modes")
struct ConfigStoreFileModeTests {
    func mode(_ path: String) throws -> Int {
        (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    @Test func newStoreIsOwnerOnly() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("adsec-\(UUID().uuidString)")
        let dir = parent.appendingPathComponent("records")
        defer { try? FileManager.default.removeItem(at: parent) }
        let path = dir.appendingPathComponent("ai.sqlite").path
        let store = try ConfigStore(path: path, credentials: InMemoryCredentialStore(), digestKey: Data(repeating: 7, count: 32))
        _ = store
        #expect(try mode(dir.path) == 0o700)
        #expect(try mode(path) == 0o600)
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path + suffix) {
            #expect(try mode(path + suffix) == 0o600, "\(suffix)")
        }
    }

    @Test func readableLeftoversAreTightened() async throws {
        let h = try Harness()
        defer { try? FileManager.default.removeItem(at: h.dir) }
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.dir.path)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: h.path)
        let wal = h.path + "-wal"
        if fm.fileExists(atPath: wal) { try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: wal) }
        let reopened = try h.reopened()
        _ = reopened
        #expect(try mode(h.dir.path) == 0o700)
        #expect(try mode(h.path) == 0o600)
        if fm.fileExists(atPath: wal) { #expect(try mode(wal) == 0o600) }
    }
}
