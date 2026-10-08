import Foundation
import Testing
@testable import AgentDesktopProtocol

// Case IDs refer to docs/ai-gui/tests/cases.csv. These tests cover the
// service side of the runtime/1 contract only (parsing, schema, routing);
// the envelope, transport and idempotency against a real Runtime are
// proven in AgentDesktopClientTests and AgentDesktopIntegrationTests.

let contract = ContractBundle.shared
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

let goodConnection: JSONValue = .obj([
    ("connectionId", .string("conn-1")),
    ("revision", .int(1)),
    ("name", .string("Ark")),
    ("protocol", .string("openai_chat")),
    ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")),
    ("credentialRef", .string("cred-1")),
    ("state", .string("enabled")),
    ("timeoutMs", .int(30000)),
    ("createdAt", .string("2026-10-08T03:00:00Z")),
    ("updatedAt", .string("2026-10-08T03:00:00Z")),
])

@Suite("Contract files")
struct ContractBundleTests {
    // The service methods: every ai/1 operation but its capabilities (now
    // runtime.capabilities `gui`), each with params and result definitions.
    @Test func catalogHasTheServiceMethodsWithSchemas() throws {
        #expect(contract.operations.count == 31)
        #expect(Set(contract.operations.map(\.command)).count == 31)
        for op in contract.operations {
            for suffix in ["params", "result"] {
                _ = try contract.registry.schema(documentId: RuntimeContract.serviceSchemaId,
                                                 pointer: "/$defs/\(op.defPrefix)_\(suffix)")
            }
            #expect(op.requiresIdempotencyKey == op.mutation, "\(op.command): every write is keyed")
        }
    }

    @Test func errorCodesMatchTheSchemaEnum() throws {
        let schema = try contract.registry.schema(documentId: RuntimeContract.serviceSchemaId, pointer: "/$defs/ErrorCode")
        let fromSchema = Set(schema["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(fromSchema == Set(ErrorCode.allCases.map(\.rawValue)))
    }

    // Nothing of the ai/1 envelope is left in the contract this build uses.
    @Test func noEnvelopeDefinitionsRemain() throws {
        let text = RuntimeContract.embedded.service
        #expect(text.contains("agentdesktop.ai/1") == false)
        let defs = try StrictJSON.parse(Data(text.utf8))["$defs"]?.objectMembers?.map(\.key) ?? []
        #expect(defs.allSatisfy { !$0.hasSuffix("_request") && !$0.hasSuffix("_response") })
        #expect(!defs.contains("Request") && !defs.contains("Response") && !defs.contains("ErrorResponse"))
    }
}

@Suite("Strict JSON")
struct StrictJSONTests {
    @Test func rejectsDuplicateKeysAtAnyDepth() {
        for text in [#"{"a":1,"a":2}"#, #"{"p":{"x":1,"x":1}}"#, #"[{"k":true,"k":false}]"#] {
            #expect(throws: StrictJSONError.self) { try StrictJSON.parse(text) }
        }
    }

    @Test func rejectsMalformedInput() {
        for text in ["", "{", "{\"a\":}", "[1,]", "{\"a\":1}x", "01", "1.", "NaN", "\"\\ud800\"",
                     "\"tab\there\"", "1e999", "{\"a\":1} {\"b\":2}"] {
            #expect(throws: StrictJSONError.self, "\(text)") { try StrictJSON.parse(text) }
        }
    }

    @Test func rejectsInvalidUTF8() {
        let bad = Data([0x22, 0xC3, 0x28, 0x22])
        #expect(throws: StrictJSONError.self) { try StrictJSON.parse(bad) }
    }

    @Test func limitsNesting() throws {
        let deep = String(repeating: "[", count: 70) + String(repeating: "]", count: 70)
        #expect(throws: StrictJSONError.self) { try StrictJSON.parse(deep) }
        _ = try StrictJSON.parse(String(repeating: "[", count: 60) + String(repeating: "]", count: 60))
    }

    @Test func roundTripsAndKeepsOrderAndEscapes() throws {
        let text = #"{"z":1,"a":[true,null,-0.5,"😀\n\"\u2028"],"m":{"k":9007199254740991}}"#
        let v = try StrictJSON.parse(text)
        let again = try StrictJSON.parse(v.encoded())
        #expect(v == again)
        #expect(v.encoded().hasPrefix(#"{"z":1,"a""#))
        #expect(!v.encoded().contains("\n"))
        #expect(v["m"]?["k"]?.intValue == 9_007_199_254_740_991)
    }
}

@Suite("Schema validation")
struct SchemaTests {
    @Test func validConnectionPasses() throws {
        #expect(try contract.validate(goodConnection, "AiConnection").isEmpty)
    }

    @Test func unknownMembersAreRefused() throws {
        let v = try contract.validate(goodConnection.setting("apiKey", .string("sk-canary")), "AiConnection")
        #expect(v.contains { $0.keyword == "additionalProperties" && $0.path == "/apiKey" })
    }

    // SEC-005 (schema part): only https, or http to an explicit loopback name.
    @Test(arguments: [
        ("https://api.example.com/v1", true),
        ("http://127.0.0.1:8080/v1", true),
        ("http://localhost:11434", true),
        ("http://[::1]:9000/api", true),
        ("http://api.example.com/v1", false),
        ("https://user:pw@api.example.com/v1", false),
        ("https://api.example.com/v1?key=1", false),
        ("https://api.example.com/v1#frag", false),
        ("file:///etc/passwd", false),
        ("https://", false),
    ])
    func endpointRule(url: String, ok: Bool) throws {
        let v = try contract.validate(goodConnection.setting("baseUrl", .string(url)), "AiConnection")
        #expect(v.isEmpty == ok, "\(url): \(v)")
    }

    // CFG-007 (schema part): limits may only tighten the server ceiling.
    @Test func guiLimitCeilings() throws {
        let ceiling: [(String, Int)] = [
            ("maxSteps", 20), ("maxWallTimeMs", 120000), ("maxModelAttemptsPerStep", 2),
            ("maxTotalModelAttempts", 30), ("maxOutputTokens", 1024), ("maxWaitMs", 5000),
            ("maxScreenshots", 5), ("maxImageEncodedBytes", 8_388_608),
        ]
        let defaults: JSONValue = .obj(ceiling.map { ($0.0, JSONValue.int($0.1)) } + [("requireReportedUsage", .bool(false))])
        #expect(try contract.validate(defaults, "GuiLimits").isEmpty)
        for (key, max) in ceiling {
            for bad: JSONValue in [.int(max + 1), .int(-1), .double(1.5), .string("1")] {
                let v = try contract.validate(defaults.setting(key, bad), "GuiLimits")
                #expect(!v.isEmpty, "\(key)=\(bad.encoded()) must be refused")
            }
        }
        #expect(!(try contract.validate(defaults.setting("maxSteps", .int(0)), "GuiLimits")).isEmpty)
    }

    @Test func dependentRequiredOnRunStart() throws {
        let base: JSONValue = .obj([
            ("desktopId", .string("desk-a")),
            ("goal", .string("在姓名中输入 Ada，然后点击应用")),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                   ("text", .string("已保存：Ada / MAC-001-A / 提交次数 1"))])),
            ("allowedActions", .array([.string("click"), .string("type")])),
        ])
        #expect(try contract.validate(base, "gui_runs_start_params").isEmpty)
        let half = base.setting("guiProfileId", .string("gp-1"))
        #expect(try contract.validate(half, "gui_runs_start_params").contains { $0.keyword == "dependentRequired" })
        let dup = base.setting("allowedActions", .array([.string("click"), .string("click")]))
        #expect(try contract.validate(dup, "gui_runs_start_params").contains { $0.keyword == "uniqueItems" })
        let drag = base.setting("allowedActions", .array([.string("drag")]))
        #expect(!(try contract.validate(drag, "gui_runs_start_params")).isEmpty)
    }

    @Test func formats() {
        #expect(Formats.check("uuid", "11111111-1111-4111-8111-111111111111"))
        #expect(!Formats.check("uuid", "11111111-1111-4111-8111-11111111111"))
        #expect(Formats.check("date-time", "2026-10-08T03:00:00.123+08:00"))
        #expect(!Formats.check("date-time", "2026-02-30T03:00:00Z"))
        #expect(!Formats.check("date-time", "2026-10-08 03:00:00Z"))
    }

    @Test func unsupportedKeywordIsRefusedAtLoad() {
        let doc: JSONValue = .obj([("$id", .string("https://x.invalid/s.json")),
                                   ("$defs", .obj([("A", .obj([("type", .string("string")), ("contentEncoding", .string("base64"))]))]))])
        #expect(throws: SchemaError.self) { try SchemaRegistry().add(doc) }
    }
}

@Suite("Service routing")
struct ServiceRouterTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func router(_ calls: Counter) -> ServiceRouter {
        let list: ServiceHandler = { _ in
            calls.bump()
            return .obj([("items", .array([goodConnection])), ("nextCursor", .null)])
        }
        let broken: ServiceHandler = { _ in
            calls.bump()
            return .obj([("items", .array([goodConnection.setting("apiKey", .string("sk-canary"))])), ("nextCursor", .null)])
        }
        let create: ServiceHandler = { req in
            calls.bump()
            #expect(req.idempotencyKey == "conn-create-0001")
            return goodConnection
        }
        return ServiceRouter(handlers: ["ai.connections.list": list, "ai.modelProfiles.list": broken,
                                        "ai.connections.create": create])
    }

    @Test func aValidCallReachesItsHandlerOnce() async throws {
        let calls = Counter()
        let r = try await router(calls).answer(method: "ai.connections.list", params: .obj([("limit", .int(20))])).get()
        #expect(r["items"]?.arrayValue?.count == 1)
        #expect(calls.value == 1)
    }

    // Params outside the contract never reach a handler; the refusal names
    // the pointer and the keyword, never the value.
    @Test func badParamsAreRefusedWithoutValues() async throws {
        let calls = Counter()
        let r = await router(calls).answer(method: "ai.connections.create", params: .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("http://evil.example.com")), ("timeoutMs", .int(1000)),
            ("credential", .obj([("apiKey", .string("sk-canary-123"))])), ("extra", .string("sk-canary-456")),
        ]), idempotencyKey: "conn-create-0001")
        guard case let .failure(e) = r else { Issue.record("must be refused"); return }
        #expect(e.code == .validationError)
        let text = e.json.encoded()
        #expect(!text.contains("sk-canary"))
        #expect(!text.contains("evil.example.com"))
        #expect(text.contains("baseUrl"))
        #expect(calls.value == 0)
    }

    // A write needs its key (the runtime/1 requestId) of 8–128 characters.
    @Test func aWriteWithoutItsKeyIsRefused() async throws {
        let calls = Counter()
        let params: JSONValue = .obj([("name", .string("Ark")), ("protocol", .string("openai_chat")),
                                      ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")), ("timeoutMs", .int(30000)),
                                      ("credential", .obj([("apiKey", .string("sk-x"))]))])
        for key in [nil, "short", String(repeating: "k", count: 129), "has space 1"] as [String?] {
            guard case let .failure(e) = await router(calls).answer(method: "ai.connections.create", params: params, idempotencyKey: key)
            else { Issue.record("\(key ?? "nil") must be refused"); continue }
            #expect(e.code == .validationError)
        }
        #expect(calls.value == 0)
        _ = try await router(calls).answer(method: "ai.connections.create", params: params, idempotencyKey: "conn-create-0001").get()
        #expect(calls.value == 1)
    }

    // A handler result that breaks the contract (here: a secret field)
    // never reaches the caller.
    @Test func resultsAreCheckedAgainstTheContract() async throws {
        let calls = Counter()
        guard case let .failure(e) = await router(calls).answer(method: "ai.modelProfiles.list", params: .obj([])) else {
            Issue.record("a result outside the contract must not pass"); return
        }
        #expect(e.code == .internalError)
        #expect(!e.json.encoded().contains("sk-canary"))
    }

    @Test func unknownAndUnhandledMethods() async throws {
        let calls = Counter()
        for m in ["ai.connections.purge", "runtime.capabilities", "ai.connections.get"] {
            guard case let .failure(e) = await router(calls).answer(method: m, params: .obj([("connectionId", .string("c"))]))
            else { Issue.record("\(m) must be refused"); continue }
            #expect(e.code == .unsupportedCommand, "\(m)")
        }
        #expect(calls.value == 0)
    }
}

// The params and success results printed for each operation in the
// implementation plan (Fixtures/spec-examples.json, which still holds them
// in the old envelope): the params and results must pass this contract.
@Suite("Specification examples")
struct SpecExampleTests {
    let examples: JSONValue = {
        let url = repoRoot.appendingPathComponent("Tests/AgentDesktopContractsTests/Fixtures/spec-examples.json")
        return try! StrictJSON.parse(Data(contentsOf: url))
    }()

    @Test func everyExampleMatchesItsParamsAndResult() throws {
        let pairs = (examples["pairs"]?.arrayValue ?? []).filter { $0["command"]?.stringValue != "runtime.capabilities" }
        #expect(pairs.count == 31)
        for p in pairs {
            let command = p["command"]!.stringValue!
            guard let op = contract.operation(command) else { Issue.record("unknown \(command)"); continue }
            let pv = try contract.validate(p["request"]!["params"] ?? .obj([]), "\(op.defPrefix)_params")
            #expect(pv.isEmpty, "\(command) params: \(pv)")
            let rv = try contract.validate(p["success"]!["result"]!, "\(op.defPrefix)_result")
            #expect(rv.isEmpty, "\(command) result: \(rv)")
        }
    }
}

@Suite("Service errors")
struct ServiceErrorTests {
    // Internal detail members never leave the service; the message is cut
    // to the contract's length.
    @Test func internalDetailsAreProjected() throws {
        let long = String(repeating: "长", count: 600)
        let e = ContractError(.upstreamUnavailable, long, details: .obj([
            ("httpStatus", .int(503)), ("retryAfterMs", .int(2000)), ("encodedBytes", .int(9)), ("field", .string("baseUrl")),
        ]))
        let j = e.json
        #expect(try contract.validate(j, "RpcError").isEmpty)
        let d = j["details"]
        #expect(d?["httpStatus"] == nil)
        #expect(d?["retryAfterMs"]?.intValue == 2000)
        #expect(d?["fieldErrors"]?.arrayValue?.first?["path"]?.stringValue == "/params/baseUrl")
        #expect((j["message"]?.stringValue?.unicodeScalars.count ?? 0) <= 512)
        let bad = ContractError(.notFound, "x", details: .obj([("runId", .string("bad id with spaces"))]))
        #expect(bad.json["details"] == nil)
    }
}
