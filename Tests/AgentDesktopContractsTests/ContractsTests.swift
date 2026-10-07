import Foundation
import Testing
@testable import AgentDesktopContracts

// Case IDs refer to docs/ai-gui/tests/cases.csv. These tests cover the
// contract layer only (framing, parsing, schema, routing); service-level
// parts of the same cases (CAS, idempotency, executor counts against a
// real Runtime) are proven elsewhere.

let contract = ContractBundle.shared
let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

func uuid() -> String { UUID().uuidString.lowercased() }

func request(_ command: String, params: JSONValue = .obj([]), id: String = uuid(),
             context: JSONValue? = nil) -> JSONValue {
    var m: [(String, JSONValue)] = [
        ("schemaVersion", .string("agentdesktop.ai/1")),
        ("requestId", .string(id)),
        ("command", .string(command)),
        ("params", params),
    ]
    if let context { m.append(("context", context)) }
    return .obj(m)
}

func idem(_ key: String = "key-\(UUID().uuidString.prefix(8))") -> JSONValue {
    .obj([("idempotencyKey", .string(key))])
}

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

func errorCode(_ response: Data) throws -> String? {
    var body = response
    #expect(body.last == 0x0A)
    body.removeLast()
    #expect(!body.contains(0x0A), "a response is exactly one line")
    let v = try StrictJSON.parse(body)
    return v["error"]?["code"]?.stringValue
}

func decodeLine(_ response: Data) throws -> JSONValue {
    var body = response
    body.removeLast()
    return try StrictJSON.parse(body)
}

@Suite("Contract files")
struct ContractBundleTests {
    @Test func bundledCopiesMatchTheContractDirectory() throws {
        for name in ["domain.schema.json", "rpc.schema.json", "operations.json"] {
            let canonical = try Data(contentsOf: repoRoot.appendingPathComponent("contracts/ai-gui/v1/\(name)"))
            let bundled = try Data(contentsOf: repoRoot.appendingPathComponent("Sources/AgentDesktopContracts/Resources/\(name)"))
            #expect(canonical == bundled, "\(name) in Resources differs from contracts/ai-gui/v1")
        }
    }

    @Test func catalogHasThe32OperationsWithSchemas() throws {
        #expect(contract.operations.count == 32)
        #expect(Set(contract.operations.map(\.command)).count == 32)
        for op in contract.operations {
            for suffix in ["params", "result", "request"] {
                _ = try contract.registry.schema(documentId: ContractBundle.rpcSchemaId,
                                                 pointer: "/$defs/\(op.defPrefix)_\(suffix)")
            }
            // Every mutation needs an idempotency key in context.
            let req = try contract.registry.schema(documentId: ContractBundle.rpcSchemaId,
                                                   pointer: "/$defs/\(op.defPrefix)_request")
            let required = req["properties"]?["context"]?["required"]?.arrayValue ?? []
            if op.requiresIdempotencyKey {
                #expect(required.contains(.string("idempotencyKey")), "\(op.command) must require idempotencyKey")
            }
        }
    }

    @Test func errorCodesMatchTheSchemaEnum() throws {
        let schema = try contract.registry.schema(documentId: ContractBundle.domainSchemaId, pointer: "/$defs/ErrorCode")
        let fromSchema = Set(schema["enum"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        #expect(fromSchema == Set(ErrorCode.allCases.map(\.rawValue)))
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
        #expect(try contract.validateDomain(goodConnection, "AiConnection").isEmpty)
    }

    @Test func unknownMembersAreRefused() throws {
        let v = try contract.validateDomain(goodConnection.setting("apiKey", .string("sk-canary")), "AiConnection")
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
        let v = try contract.validateDomain(goodConnection.setting("baseUrl", .string(url)), "AiConnection")
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
        #expect(try contract.validateDomain(defaults, "GuiLimits").isEmpty)
        for (key, max) in ceiling {
            for bad: JSONValue in [.int(max + 1), .int(-1), .double(1.5), .string("1")] {
                let v = try contract.validateDomain(defaults.setting(key, bad), "GuiLimits")
                #expect(!v.isEmpty, "\(key)=\(bad.encoded()) must be refused")
            }
        }
        #expect(!(try contract.validateDomain(defaults.setting("maxSteps", .int(0)), "GuiLimits")).isEmpty)
    }

    @Test func dependentRequiredOnRunStart() throws {
        let base: JSONValue = .obj([
            ("desktopId", .string("desk-a")),
            ("goal", .string("在姓名中输入 Ada，然后点击应用")),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                   ("text", .string("已保存：Ada / MAC-001-A / 提交次数 1"))])),
            ("allowedActions", .array([.string("click"), .string("type")])),
        ])
        #expect(try contract.validateRpc(base, "gui_runs_start_params").isEmpty)
        let half = base.setting("guiProfileId", .string("gp-1"))
        #expect(try contract.validateRpc(half, "gui_runs_start_params").contains { $0.keyword == "dependentRequired" })
        let dup = base.setting("allowedActions", .array([.string("click"), .string("click")]))
        #expect(try contract.validateRpc(dup, "gui_runs_start_params").contains { $0.keyword == "uniqueItems" })
        let drag = base.setting("allowedActions", .array([.string("drag")]))
        #expect(!(try contract.validateRpc(drag, "gui_runs_start_params")).isEmpty)
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

@Suite("Envelope and routing")
struct EnvelopeTests {
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var value: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    func router(_ calls: Counter, legacy: Bool = true) -> RpcRouter {
        let list: RpcHandler = { _ in
            calls.bump()
            return .obj([("items", .array([goodConnection])), ("nextCursor", .null)])
        }
        let broken: RpcHandler = { _ in
            calls.bump()
            return .obj([("items", .array([goodConnection.setting("apiKey", .string("sk-canary"))])), ("nextCursor", .null)])
        }
        let legacyHandler: (@Sendable (JSONValue) async -> Data)? = legacy ? { @Sendable _ in Data("{\"ok\":true}\n".utf8) } : nil
        return RpcRouter(handlers: ["ai.connections.list": list, "ai.modelProfiles.list": broken], legacy: legacyHandler)
    }

    // RPC-001: correlation, single line, ok/result vs ok/error exclusive.
    @Test func successCorrelatesAndIsOneLine() async throws {
        let calls = Counter()
        let id = uuid()
        let out = await router(calls).respond(toBody: request("ai.connections.list", params: .obj([("limit", .int(20))]), id: id).encodedData())
        let v = try decodeLine(out)
        #expect(v["schemaVersion"]?.stringValue == "agentdesktop.ai/1")
        #expect(v["requestId"]?.stringValue == id)
        #expect(v["ok"]?.boolValue == true)
        #expect(v["error"] == nil)
        #expect(try contract.validateRpc(v, "SuccessResponse").isEmpty)
        #expect(calls.value == 1)
    }

    // RPC-002: version routing.
    @Test func versionRouting() async throws {
        let calls = Counter()
        let r = router(calls)
        // Legacy ControlRequest (no schemaVersion) goes to the legacy decoder.
        let legacy = await r.respond(toBody: Data(#"{"command":"screen.list"}"#.utf8))
        #expect(String(decoding: legacy, as: UTF8.self) == "{\"ok\":true}\n")
        // Unknown version.
        var req = request("ai.connections.list").setting("schemaVersion", .string("agentdesktop.ai/2"))
        #expect(try errorCode(await r.respond(toBody: req.encodedData())) == "UNSUPPORTED_SCHEMA")
        // `op` in place of `command`.
        req = .obj([("schemaVersion", .string("agentdesktop.ai/1")), ("requestId", .string(uuid())),
                    ("op", .string("ai.connections.list")), ("params", .obj([]))])
        #expect(try errorCode(await r.respond(toBody: req.encodedData())) == "VALIDATION_ERROR")
        #expect(calls.value == 0)
        // Without a legacy decoder, a version-less frame is refused.
        let strict = router(calls, legacy: false)
        #expect(try errorCode(await strict.respond(toBody: Data(#"{"command":"screen.list"}"#.utf8))) == "UNSUPPORTED_SCHEMA")
    }

    // RPC-003: hostile inputs are refused, nothing is called, and the next
    // valid request still succeeds.
    @Test func hostileInputsThenAValidOne() async throws {
        let calls = Counter()
        let r = router(calls)
        let id = uuid()
        let start = request("gui.runs.start", params: .obj([
            ("desktopId", .string("desk-a")), ("goal", .string("x")),
            ("allowedActions", .array([.string("click")])),
        ]), context: idem())
        let cases: [(String, Data, String)] = [
            ("malformed", Data("{\"schemaVersion\":".utf8), "VALIDATION_ERROR"),
            ("duplicate command", Data(#"{"schemaVersion":"agentdesktop.ai/1","requestId":"\#(id)","command":"ai.connections.list","command":"gui.runs.cancel","params":{}}"#.utf8), "VALIDATION_ERROR"),
            ("bad uuid", request("ai.connections.list", id: "not-a-uuid").encodedData(), "VALIDATION_ERROR"),
            ("unknown command", request("gui.runs.resume").encodedData(), "UNSUPPORTED_COMMAND"),
            ("extra control field", request("ai.connections.list").setting("lease", .string("forged")).encodedData(), "VALIDATION_ERROR"),
            ("start without verification", start.encodedData(), "VALIDATION_ERROR"),
            ("model script as verification", start.setting("params", start["params"]!.setting("verification", .obj([("kind", .string("script")), ("code", .string("return true"))]))).encodedData(), "VALIDATION_ERROR"),
            ("mutation without idempotency key", request("ai.connections.disable", params: .obj([("connectionId", .string("c")), ("expectedRevision", .int(1))])).encodedData(), "VALIDATION_ERROR"),
            ("array frame", Data("[]".utf8), "VALIDATION_ERROR"),
        ]
        for (name, body, code) in cases {
            #expect(try errorCode(await r.respond(toBody: body)) == code, "\(name)")
        }
        #expect(calls.value == 0, "no handler runs for a refused request")
        let ok = try decodeLine(await r.respond(toBody: request("ai.connections.list").encodedData()))
        #expect(ok["ok"]?.boolValue == true)
        #expect(calls.value == 1)
    }

    // RPC-003: a refused request echoes its id when it was readable.
    @Test func correlatableErrorsEchoTheRequestId() async throws {
        let calls = Counter()
        let id = uuid()
        let out = try decodeLine(await router(calls).respond(toBody: request("gui.runs.resume", id: id).encodedData()))
        #expect(out["requestId"]?.stringValue == id)
        let malformed = try decodeLine(await router(calls).respond(toBody: Data("{".utf8)))
        #expect(malformed["requestId"]?.isNull == true)
    }

    // RPC-004: frame size boundary, and screenshots never travel inline.
    @Test func frameBoundary() async throws {
        let calls = Counter()
        let r = router(calls)
        let base = request("ai.connections.list", params: .obj([("cursor", .string("c"))]))
        let baseLen = base.encodedData().count
        // Pad with insignificant whitespace before the closing brace so the
        // frame (body + LF) is exactly the limit.
        func padded(_ total: Int) -> Data {
            var text = base.encoded()
            text.removeLast()
            text += String(repeating: " ", count: total - 1 - baseLen) + "}"
            return Data(text.utf8)
        }
        let exact = padded(Envelope.maxFrameBytes)
        #expect(exact.count + 1 == Envelope.maxFrameBytes)
        var framed = exact; framed.append(0x0A)
        guard case let .frame(body) = FrameReader.split(framed) else { Issue.record("exact frame refused"); return }
        #expect(try decodeLine(await r.respond(toBody: body))["ok"]?.boolValue == true)

        var over = padded(Envelope.maxFrameBytes + 1); over.append(0x0A)
        #expect(FrameReader.split(over) == .tooLarge)
        #expect(try errorCode(await r.respond(to: .tooLarge)) == "IPC_FRAME_TOO_LARGE")

        let inline = request("ai.connections.list", params: .obj([("screenshot", .string(String(repeating: "A", count: 1000)))]))
        #expect(try errorCode(await r.respond(toBody: inline.encodedData())) == "VALIDATION_ERROR")
        #expect(calls.value == 1)
    }

    @Test func frameReaderOnASocketPair() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        defer { close(fds[0]); close(fds[1]) }
        let payload = Data((request("ai.connections.list").encoded() + "\n").utf8)
        _ = payload.withUnsafeBytes { write(fds[1], $0.baseAddress, payload.count) }
        shutdown(fds[1], SHUT_WR)
        guard case let .frame(body) = FrameReader.read(fd: fds[0]) else { Issue.record("no frame"); return }
        #expect(body.count + 1 == payload.count)
    }

    @Test func multipleRequestsInOneConnectionAreRefused() async throws {
        let calls = Counter()
        let two = Data((request("ai.connections.list").encoded() + "\n" + request("ai.connections.list").encoded() + "\n").utf8)
        let read = FrameReader.split(two)
        #expect(try errorCode(await router(calls).respond(to: read)) == "VALIDATION_ERROR")
        #expect(calls.value == 0)
    }

    // A handler result that breaks the contract (here: a secret field)
    // never reaches the caller.
    @Test func resultsAreCheckedAgainstTheContract() async throws {
        let calls = Counter()
        let out = await router(calls).respond(toBody: request("ai.modelProfiles.list").encodedData())
        #expect(try errorCode(out) == "INTERNAL_ERROR")
        #expect(!String(decoding: out, as: UTF8.self).contains("sk-canary"))
    }

    @Test func knownCommandWithoutHandler() async throws {
        let calls = Counter()
        #expect(try errorCode(await router(calls).respond(toBody: request("runtime.capabilities").encodedData())) == "UNSUPPORTED_COMMAND")
    }

    // Validation details name the failing pointer, never the value.
    @Test func validationDetailsCarryNoValues() async throws {
        let calls = Counter()
        let req = request("ai.connections.create", params: .obj([
            ("name", .string("x")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("http://evil.example.com")), ("timeoutMs", .int(1000)),
            ("credential", .obj([("apiKey", .string("sk-canary-123"))])), ("extra", .string("sk-canary-456")),
        ]), context: idem())
        let out = await router(calls).respond(toBody: req.encodedData())
        let text = String(decoding: out, as: UTF8.self)
        #expect(try errorCode(out) == "VALIDATION_ERROR")
        #expect(!text.contains("sk-canary"))
        #expect(!text.contains("evil.example.com"))
        #expect(text.contains("/params/baseUrl"))
    }
}

// The complete request and success examples printed for each of the 32
// operations in the implementation plan, extracted verbatim into
// Fixtures/spec-examples.json. They must all pass this validator.
@Suite("Specification examples")
struct SpecExampleTests {
    let examples: JSONValue = {
        let url = repoRoot.appendingPathComponent("Tests/AgentDesktopContractsTests/Fixtures/spec-examples.json")
        return try! StrictJSON.parse(Data(contentsOf: url))
    }()

    @Test func everyRequestExampleDecodes() throws {
        let pairs = examples["pairs"]?.arrayValue ?? []
        let requests = pairs.compactMap { $0["request"] } + (examples["extraRequests"]?.arrayValue ?? [])
        #expect(Set(pairs.compactMap { $0["command"]?.stringValue }).count == 32)
        for r in requests {
            switch Envelope.decode(r.encodedData()) {
            case .request: break
            case let .rejected(_, e): Issue.record("\(r["command"]?.stringValue ?? "?"): \(e) \(e.details?.encoded() ?? "")")
            case .legacy: Issue.record("example decoded as legacy")
            }
        }
    }

    @Test func everySuccessExampleMatchesItsResultSchema() throws {
        let pairs = examples["pairs"]?.arrayValue ?? []
        #expect(pairs.count == 32)
        for p in pairs {
            let command = p["command"]!.stringValue!
            let s = p["success"]!
            #expect(s["requestId"] == p["request"]!["requestId"], "\(command): example ids differ")
            #expect(try contract.validateRpc(s, "SuccessResponse").isEmpty)
            guard let op = contract.operation(command) else { Issue.record("unknown \(command)"); continue }
            let v = try contract.validateRpc(s["result"]!, "\(op.defPrefix)_result")
            #expect(v.isEmpty, "\(command): \(v)")
        }
    }

    @Test func errorExampleMatchesTheErrorEnvelope() throws {
        for e in examples["errors"]?.arrayValue ?? [] {
            #expect(try contract.validateRpc(e, "ErrorResponse").isEmpty)
        }
    }
}
