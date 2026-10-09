import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import ImageIO
import Testing
@testable import AgentDesktopGUI

// T08 four-layer capability tests (spec §11), through the real ServiceRouter.
// Case IDs refer to docs/ai-gui/tests/cases.csv. No real network, no real
// key, no desktop: the upstream is a stub keyed on what each layer asks.

let testKey = "sk-canary-capability-0001"

final class Box<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var v: T
    init(_ v: T) { self.v = v }
    func get() -> T { lock.withLock { v } }
    func with<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&v) } }
}

/// Answers each layer: GET (network), "OK", the colour, the click.
final class FakeUpstream: HTTPTransport, @unchecked Sendable {
    enum Layer { case network, auth, image, gui }
    let requests = Box<[URLRequest]>([])
    let replies = Box<[Layer: @Sendable () throws -> HTTPResult]>([:])
    let held = Box<Set<Layer>>([])
    let parked = Box<[CheckedContinuation<Void, Never>]>([])

    static func chat(_ text: String, usage: Bool = true) -> HTTPResult {
        let content = String(data: try! JSONSerialization.data(withJSONObject: [text]), encoding: .utf8)!.dropFirst().dropLast()
        let u = usage ? #","usage":{"prompt_tokens":40,"completion_tokens":4,"total_tokens":44}"# : ""
        return HTTPResult(status: 200, headers: ["Content-Type": "application/json"],
                          body: Data(#"{"id":"up-1","model":"ui-tars-actual","choices":[{"index":0,"message":{"role":"assistant","content":\#(content)},"finish_reason":"stop"}]\#(u)}"#.utf8))
    }

    init() {
        replies.with {
            $0[.network] = { @Sendable in HTTPResult(status: 404, body: Data()) }
            $0[.auth] = { @Sendable in FakeUpstream.chat("OK") }
            $0[.image] = { @Sendable in FakeUpstream.chat("red") }
            // Button centre (600,390) of 800x500 in normalized_1000.
            $0[.gui] = { @Sendable in FakeUpstream.chat("Thought: the blue button.\nAction: click(start_box='(750,780)')") }
        }
    }

    func layer(_ r: URLRequest) -> Layer {
        guard r.httpMethod == "POST", let body = r.httpBody.flatMap({ String(data: $0, encoding: .utf8) }) else { return .network }
        if body.contains("Reply with the single word OK") { return .auth }
        if body.contains("What color is the left half") { return .image }
        return .gui
    }

    func set(_ l: Layer, _ reply: @escaping @Sendable () throws -> HTTPResult) { replies.with { $0[l] = reply } }
    func hold(_ l: Layer) { _ = held.with { $0.insert(l) } }
    func release() {
        held.with { $0 = [] }
        let w = parked.with { p -> [CheckedContinuation<Void, Never>] in let a = p; p = []; return a }
        for c in w { c.resume() }
    }
    func count(_ l: Layer) -> Int { requests.get().filter { layer($0) == l }.count }
    var modelCalls: Int { requests.get().filter { $0.httpMethod == "POST" }.count }

    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        requests.with { $0.append(request) }
        let l = layer(request)
        if held.get().contains(l) {
            await withCheckedContinuation { c in
                let now = parked.with { p -> Bool in
                    if !held.get().contains(l) { return true }
                    p.append(c); return false
                }
                if now { c.resume() }
            }
        }
        try Task.checkCancellation()
        return try replies.get()[l]!()
    }

    func waitParked() async {
        for _ in 0..<3000 where parked.get().isEmpty { try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(!parked.get().isEmpty, "a request should be in flight")
    }
}

struct Rig {
    let dir: URL
    let store: ConfigStore
    let creds = InMemoryCredentialStore()
    let upstream = FakeUpstream()
    let runner = AiOperationRunner()
    let tests: CapabilityTestService
    let app: AiApplicationHandlers

    init(fixtureCodec: Bool = false) throws {
        dir = ScratchDirectory.url("adcap")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        store = try ConfigStore(path: dir.appendingPathComponent("config.sqlite").path, credentials: creds,
                                digestKey: Data(repeating: 3, count: 32),
                                options: ConfigOptions(allowLoopbackHTTP: true, allowFixtureAdapter: true))
        let ai = DefaultAiService(http: upstream, credentials: StoreCredentialResolver(store: store),
                                  ledger: SQLiteAiCallLedger(store: store))
        tests = CapabilityTestService(store: store, ai: ai, http: upstream, runner: runner,
                                      codecs: GuiCodecRegistry(fixtureAdapterEnabled: fixtureCodec))
        app = AiApplicationHandlers(store: store, http: upstream, runner: runner)
    }

    func router(_ scope: String = "owner") -> ServiceRouter {
        ServiceRouter(handlers: app.handlers(callerScope: scope, extra: tests.handlers(callerScope: scope)))
    }

    func call(_ command: String, _ params: JSONValue, scope: String = "owner", key: String? = nil) async throws -> JSONValue {
        let key = ContractBundle.shared.operation(command)!.requiresIdempotencyKey || key != nil ? (key ?? "k-\(UUID().uuidString)") : nil
        let out: JSONValue
        switch await router(scope).answer(method: command, params: params, idempotencyKey: key) {
        case let .success(v): out = .obj([("ok", .bool(true)), ("result", v)])
        case let .failure(e): out = .obj([("ok", .bool(false)), ("error", e.json)])
        }
        #expect(!out.encoded().contains(testKey), "no response carries the key")
        return out
    }

    func ok(_ command: String, _ params: JSONValue, scope: String = "owner", key: String? = nil) async throws -> JSONValue {
        let v = try await call(command, params, scope: scope, key: key)
        guard v["ok"]?.boolValue == true, let r = v["result"] else {
            Issue.record("\(command) failed: \(v.encoded())")
            throw CancellationError()
        }
        #expect(try ContractBundle.shared.validate(r, "\(ContractBundle.shared.operation(command)!.defPrefix)_result").isEmpty)
        return r
    }

    /// connection → model profile → GUI profile through the router.
    func profile(adapter: String = "uitars_v1") async throws -> JSONValue {
        let conn = try await ok("ai.connections.create", .obj([
            ("name", .string("Ark")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("https://ark.example.invalid/api/v3")), ("timeoutMs", .int(30000)),
            ("credential", .obj([("apiKey", .string(testKey))])),
        ]))
        let model = try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("UI-TARS")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
            ("modelId", .string("Doubao-Seed-UI-TARS")), ("requestOptions", .obj([])), ("maxOutputTokens", .int(1024)),
        ]))
        return try await ok("ai.profiles.create", .obj([
            ("name", .string("GUI")), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
            ("adapterId", .string(adapter)), ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("uitars-prompt-1")),
            ("parserVersion", .string("uitars-parser-1")), ("coordinateProtocol", .string("normalized_1000")),
            ("limits", .obj([
                ("maxSteps", .int(20)), ("maxWallTimeMs", .int(120000)), ("maxModelAttemptsPerStep", .int(2)),
                ("maxTotalModelAttempts", .int(30)), ("maxOutputTokens", .int(1024)), ("maxWaitMs", .int(5000)),
                ("maxScreenshots", .int(5)), ("maxImageEncodedBytes", .int(8_388_608)), ("requireReportedUsage", .bool(false)),
            ])),
            ("allowedFallbackProfileRefs", .array([])),
        ]))
    }

    func start(_ gui: JSONValue, scope: String = "owner", key: String? = nil) async throws -> String {
        try await ok("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!),
                                             ("fixtureId", .string("synthetic_gui_v1"))]), scope: scope, key: key)["operationId"]!.stringValue!
    }

    func finished(_ op: String, scope: String = "owner") async throws -> JSONValue {
        await runner.wait(op)
        let v = try await ok("ai.operations.get", .obj([("operationId", .string(op))]), scope: scope)
        #expect(["succeeded", "failed", "cancelled"].contains(v["state"]?.stringValue ?? ""), "\(v.encoded())")
        return v
    }

    func levels(_ op: JSONValue) -> [String: String] {
        Dictionary(uniqueKeysWithValues: (op["result"]?["levels"]?.arrayValue ?? []).map {
            ($0["level"]!.stringValue!, $0["status"]!.stringValue!)
        })
    }
}

@Suite("Capability tests")
struct CapabilityTests {
    // TRN-008 happy path: four layers pass, three model calls, all recorded.
    @Test func trn008_allFourLayersPass() async throws {
        let rig = try Rig()
        let gui = try await rig.profile()
        let op = try await rig.start(gui)
        let v = try await rig.finished(op)
        #expect(v["state"]?.stringValue == "succeeded")
        #expect(v["kind"]?.stringValue == "capability_test")
        #expect(rig.levels(v) == ["network": "passed", "auth_model": "passed", "image_input": "passed", "gui_contract": "passed"])
        #expect(v["result"]?["performedDesktopInput"]?.boolValue == false)
        #expect(rig.upstream.modelCalls == 3)
        let attempts = try await rig.store.attempts(budgetScope: op)
        #expect(attempts.map(\.state) == ["succeeded", "succeeded", "succeeded"])
        #expect(attempts.map(\.level) == ["auth_model", "image_input", "gui_contract"])
        // The network probe carries no key; model calls carry it only in Authorization.
        let probe = rig.upstream.requests.get().first { $0.httpMethod == "GET" }!
        #expect(probe.value(forHTTPHeaderField: "Authorization") == nil)
        let caps = v["result"]!["capabilities"]!
        for layer in ["network", "authModel", "imageInput", "guiContract"] {
            #expect(caps[layer]?["status"]?.stringValue == "verified", "\(layer)")
            #expect(caps[layer]?["testOperationId"]?.stringValue == op)
        }
        #expect(caps["guiContract"]?["scope"]?["parserVersion"]?.stringValue == UITarsCodec.parserVersion)
        // Images sent are the synthetic fixture, not a capture.
        let guiBody = String(data: rig.upstream.requests.get().last!.httpBody!, encoding: .utf8)!
        #expect(guiBody.contains(try SyntheticGuiFixture.screenImage().base64EncodedString()))
    }

    // TRN-008: each layer can stop the test; later layers are skipped,
    // completed layers stay in the report, no desktop is involved.
    @Test(arguments: ["network", "auth_model", "image_input", "gui_contract"])
    func trn008_stopsAtEachLayer(_ failing: String) async throws {
        let rig = try Rig()
        switch failing {
        case "network": rig.upstream.set(.network) { throw HTTPTransportError.network(code: -1004) }
        case "auth_model": rig.upstream.set(.auth) { HTTPResult(status: 401, body: Data(#"{"error":"bad key \#(testKey)"}"#.utf8)) }
        case "image_input": rig.upstream.set(.image) { FakeUpstream.chat("blue") }
        default: rig.upstream.set(.gui) { FakeUpstream.chat("Action: click(start_box='(100,100)')") }
        }
        let gui = try await rig.profile()
        let v = try await rig.finished(try await rig.start(gui))
        #expect(v["state"]?.stringValue == "failed")
        #expect(v["error"]?["code"]?.stringValue != nil)
        let order = ["network", "auth_model", "image_input", "gui_contract"]
        let i = order.firstIndex(of: failing)!
        let levels = rig.levels(v)
        for (j, l) in order.enumerated() {
            #expect(levels[l] == (j < i ? "passed" : j == i ? "failed" : "skipped"), "\(failing): \(l)")
        }
        #expect(rig.upstream.modelCalls == max(0, i), "no model call after the failing layer")
        #expect(!v.encoded().contains(testKey))
        if failing == "auth_model" { #expect(v["error"]?["code"]?.stringValue == "AUTH_FAILED") }
        if failing == "gui_contract" {
            let level = v["result"]!["levels"]!.arrayValue!.first { $0["level"]?.stringValue == "gui_contract" }!
            #expect(level["reasonCode"]?.stringValue == "TARGET_MISSED")
        }
    }

    // Only a schema-valid UI-TARS reply passes gui_contract.
    @Test func trn008_invalidGuiReplyFailsTheContract() async throws {
        for reply in ["click there", "Action: drag(start_box='(1,1)', end_box='(2,2)')",
                      "Action: click(start_box='(750,780)')\nAction: click(start_box='(750,780)')"] {
            let rig = try Rig()
            rig.upstream.set(.gui) { FakeUpstream.chat(reply) }
            let v = try await rig.finished(try await rig.start(try await rig.profile()))
            #expect(rig.levels(v)["gui_contract"] == "failed", "\(reply)")
            let level = v["result"]!["levels"]!.arrayValue!.first { $0["level"]?.stringValue == "gui_contract" }!
            #expect(level["reasonCode"]?.stringValue == "INVALID_ACTION")
        }
    }

    // TRN-008 / UI-004: cancel a delayed test; nothing runs afterwards.
    @Test func trn008_cancelDelayedTest() async throws {
        let rig = try Rig()
        rig.upstream.hold(.auth)
        let gui = try await rig.profile()
        let op = try await rig.start(gui)
        await rig.upstream.waitParked()
        let c = try await rig.ok("ai.operations.cancel", .obj([("operationId", .string(op))]))
        #expect(c["accepted"]?.boolValue == true)
        #expect(c["state"]?.stringValue == "cancelling")
        #expect(c["terminal"]?.boolValue == false)
        rig.upstream.release()
        let v = try await rig.finished(op)
        #expect(v["state"]?.stringValue == "cancelled")
        #expect(v["result"]?.isNull == true)
        #expect(rig.upstream.count(.image) == 0 && rig.upstream.count(.gui) == 0)
        #expect(try await rig.store.attempts(budgetScope: op).map(\.state) == ["cancelled"])
    }

    // RPC-006/007: concurrent starts with one key make one operation.
    @Test func rpc006_startIsIdempotent() async throws {
        let rig = try Rig()
        let gui = try await rig.profile()
        let ids = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<10 { group.addTask { try await rig.start(gui, key: "same-test-key") } }
            return try await group.reduce(into: Set<String>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        let op = ids.first!
        _ = try await rig.finished(op)
        #expect(rig.upstream.modelCalls == 3, "the same attempts as a single start")
        #expect(try await rig.store.attempts(budgetScope: op).count == 3)

        let conflict = try await rig.call("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                                   ("fixtureId", .string("synthetic_gui_v1")), ]), key: "same-test-key")
        #expect(conflict["error"]?["code"]?.stringValue == nil, "same body, same key: same answer")
        #expect(conflict["result"]?["operationId"]?.stringValue == op)
        let changed = try await rig.call("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", .int(2)),
                                                                  ("fixtureId", .string("synthetic_gui_v1"))]), key: "same-test-key")
        #expect(changed["error"]?["code"]?.stringValue == "IDEMPOTENCY_CONFLICT")
        // Another caller's identical key is its own, and cannot see ours.
        let theirs = try await rig.call("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                                 ("fixtureId", .string("synthetic_gui_v1"))]), scope: "other", key: "same-test-key")
        #expect(theirs["result"]?["operationId"]?.stringValue != op)
        let peek = try await rig.call("ai.operations.get", .obj([("operationId", .string(op))]), scope: "other")
        #expect(peek["error"]?["code"]?.stringValue == "NOT_FOUND")
        await rig.runner.wait(theirs["result"]!["operationId"]!.stringValue!)
    }

    // CAN-004: cancelling a finished test changes nothing and calls nothing.
    @Test func can004_repeatedCancelOnFinishedTest() async throws {
        let rig = try Rig()
        let op = try await rig.start(try await rig.profile())
        _ = try await rig.finished(op)
        let calls = rig.upstream.requests.get().count
        for _ in 0..<3 {
            let c = try await rig.ok("ai.operations.cancel", .obj([("operationId", .string(op))]))
            #expect(c["accepted"]?.boolValue == false)
            #expect(c["state"]?.stringValue == "succeeded")
            #expect(c["terminal"]?.boolValue == true)
        }
        #expect(rig.upstream.requests.get().count == calls)
        #expect(try await rig.store.attempts(budgetScope: op).count == 3)
    }

    // CFG-008: evidence belongs to the tested revision; a new revision starts unknown.
    @Test func cfg008_evidenceFollowsTheRevision() async throws {
        let rig = try Rig()
        rig.upstream.set(.image) { FakeUpstream.chat("blue") }
        let gui = try await rig.profile()
        _ = try await rig.finished(try await rig.start(gui))
        let mpId = gui["modelProfileId"]!
        let m1 = try await rig.ok("ai.modelProfiles.get", .obj([("modelProfileId", mpId)]))
        #expect(m1["capabilities"]?["authModel"]?["status"]?.stringValue == "verified")
        #expect(m1["capabilities"]?["imageInput"]?["status"]?.stringValue == "failed")
        #expect(m1["capabilities"]?["guiContract"]?["status"]?.stringValue == "unknown", "skipped is not evidence")
        let m2 = try await rig.ok("ai.modelProfiles.update", .obj([("modelProfileId", mpId), ("expectedRevision", .int(1)),
                                                                   ("patch", .obj([("modelId", .string("Doubao-Seed-UI-TARS-2"))]))]))
        for layer in ["network", "authModel", "imageInput", "guiContract"] {
            #expect(m2["capabilities"]?[layer]?["status"]?.stringValue == "unknown", "\(layer) resets on a new revision")
        }
        let old = try await rig.store.revisionBody(.modelProfile, mpId.stringValue!, 1)
        #expect(old?["capabilities"]?["authModel"]?["status"]?.stringValue == "verified", "old evidence is kept")
    }

    // A stale profile revision or a fixture adapter outside test mode is
    // refused before any operation or model call exists.
    @Test func startRefusesStaleOrUnavailableProfiles() async throws {
        let rig = try Rig()
        let gui = try await rig.profile()
        let stale = try await rig.call("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", .int(7)),
                                                                ("fixtureId", .string("synthetic_gui_v1"))]))
        #expect(stale["error"]?["code"]?.stringValue == "CONFIG_CONFLICT")
        let fixture = try await rig.profile(adapter: "fixture_json_v1")
        let refused = try await rig.call("ai.tests.start", .obj([("guiProfileId", fixture["guiProfileId"]!), ("expectedRevision", .int(1)),
                                                                  ("fixtureId", .string("synthetic_gui_v1"))]))
        #expect(refused["error"]?["code"]?.stringValue == "CAPABILITY_MISMATCH")
        #expect(rig.upstream.requests.get().isEmpty)
        #expect(await rig.runner.running == 0)
    }

    // executor/capture = 0 by construction: the service holds no desktop port.
    @Test func serviceHoldsNoDesktopCapability() throws {
        let rig = try Rig()
        let held = Mirror(reflecting: rig.tests).children.map { "\(type(of: $0.value))" }
        let allowed = ["ConfigStore", "DefaultAiService", "FakeUpstream", "AiOperationRunner", "GuiCodecRegistry", "SystemMonotonicClock"]
        for t in held {
            #expect(allowed.contains(t), "unexpected dependency \(t)")
            #expect(!t.contains("Execut") && !t.contains("Observ") && !t.contains("Capture") && !t.contains("Input"))
        }
    }

    @Test func fixtureImagesAreWhatTheTestsClaim() throws {
        for (data, w, h) in [(try SyntheticGuiFixture.colorImage(), 256, 128), (try SyntheticGuiFixture.screenImage(), 800, 500)] {
            let src = CGImageSourceCreateWithData(data as CFData, nil)!
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as! [CFString: Any]
            #expect(props[kCGImagePropertyPixelWidth] as? Int == w)
            #expect(props[kCGImagePropertyPixelHeight] as? Int == h)
        }
        #expect(try SyntheticGuiFixture.colorImage() == (try SyntheticGuiFixture.colorImage()), "deterministic material")
    }

    // End to end through one router: configure, test, poll, then usage.
    @Test func endToEndThroughTheRouter() async throws {
        let rig = try Rig()
        rig.upstream.set(.image) { FakeUpstream.chat("red", usage: false) }
        let gui = try await rig.profile()
        let op = try await rig.start(gui)
        var state = "queued"
        for _ in 0..<5000 where !["succeeded", "failed", "cancelled"].contains(state) {
            state = try await rig.ok("ai.operations.get", .obj([("operationId", .string(op))]))["state"]!.stringValue!
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        #expect(state == "succeeded")
        let usage = try await rig.ok("ai.usage.summary", .obj([("from", .string("2020-01-01T00:00:00Z")), ("to", .string("2100-01-01T00:00:00Z"))]))
        #expect(usage["inferenceAttempts"]?.intValue == 3)
        #expect(usage["attemptsMissingUsage"]?.intValue == 1)
        #expect(usage["reportedTokens"]?["inputTokens"]?.intValue == 80)
        #expect(usage["isFinalBill"]?.boolValue == false)
        // Nothing in the database holds the key.
        let path = rig.dir.appendingPathComponent("config.sqlite").path
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path)) + ((try? Data(contentsOf: URL(fileURLWithPath: path + "-wal"))) ?? Data())
        #expect(bytes.range(of: Data(testKey.utf8)) == nil)
    }
}
