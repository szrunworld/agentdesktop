import AgentDesktopAI
import AgentDesktopProtocol
import AgentDesktopGUI
import AgentDesktopService
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A6: unit.run end to end in one process. A client asks the Runtime; the
// Runtime admits a Delegated unit Run; the AI service's explorer drives it
// through the Runtime's own observe and act, inside that Run; the model is
// a scripted Ark. One Run, one input, every fact on the Run's timeline.

struct UnitStack {
    let platform: FormPlatform
    let runtime: RuntimeService
    let client: ConnectionState
    let desktop: String
    let service: AgentDesktopService
    let upstream: Upstream
    let dir: URL

    /// A runtime/1 call off the cooperative pool (unit.run waits for the
    /// executor's admission there, as on the server's threads).
    func call(_ method: String, _ params: String = "{}", id: String = RuntimeRequest.newId()) async -> RuntimeResponse {
        let line = Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(id)","method":"\#(method)","params":\#(params)}"#.utf8)
        let runtime = runtime, client = client
        return await withCheckedContinuation { cont in
            DispatchQueue.global().async { cont.resume(returning: runtime.respond(to: line, on: client)) }
        }
    }
}

func unitStack(configure: Bool = true, contractTest: Bool = true) async throws -> UnitStack {
    let platform = FormPlatform()
    let runtime = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_unit", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: "/tmp/unit.sock", buildSource: "unknown"),
                                 backend: Backend(), platform: platform); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    let c = ConnectionState(peerUID: getuid())
    func rt(_ method: String, _ params: String = "{}") -> JSONValue? {
        let r = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(RuntimeRequest.newId())","method":"\#(method)","params":\#(params)}"#.utf8), on: c)
        if case let .success(d) = r.result { return d }
        return nil
    }
    _ = rt("runtime.handshake", #"{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}"#)
    let desktop = try #require(rt("desktop.create")?["desktopId"]?.stringValue)
    #expect(rt("window.bind", #"{"desktopId":"\#(desktop)","pid":101}"#) != nil)

    let ports = RuntimeGuiPorts(service: runtime)
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adt-unit-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let upstream = Upstream()
    let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir.appendingPathComponent("config.sqlite").path, credentials: InMemoryCredentialStore(), http: upstream,
        executionBackend: GuiExecutionBackend(
            ports: GuiExplorerPorts(observation: ports, execution: ports, audit: UnitTestNoAudit()),
            features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]))))
    runtime.registerUnitExecutor(try #require(service.units), ports: ports)
    if configure { try await configureArk(service, contractTest: contractTest) }
    return UnitStack(platform: platform, runtime: runtime, client: c, desktop: desktop, service: service, upstream: upstream, dir: dir)
}

struct UnitTestNoAudit: GuiAuditPort {
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) {}
    func reserveAction(_ proposal: GuiProposal) -> String { "act-" + UUID().uuidString.prefix(8).lowercased() }
    func recordAction(_ receipt: GuiActionReceipt) {}
}

/// The owner's model configuration: Ark connection, model, UI-TARS GUI
/// profile set as default (the local owner's scope is uid:<n>), and, unless
/// told otherwise, the capability test it must pass to run (F40-06 row 12).
func configureArk(_ service: AgentDesktopService, contractTest: Bool = true) async throws {
    let router = service.router(callerScope: "uid:\(getuid())")
    func ai(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> JSONValue {
        switch await router.answer(method: command, params: params, idempotencyKey: key) {
        case let .success(v): return v
        case let .failure(e): throw ContractError(.internalError, "\(command): \(e.json.encoded())")
        }
    }
    let conn = try await ai("ai.connections.create", .obj([
        ("name", .string("Ark")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")),
        ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string(integrationKey))]))]), key: "unit-config-c1")
    let model = try await ai("ai.modelProfiles.create", .obj([
        ("name", .string("Seed lite")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
        ("modelId", .string("doubao-seed-2-1-lite-260915")), ("requestOptions", .obj([("temperature", .int(0))])), ("maxOutputTokens", .int(1024))]), key: "unit-config-m1")
    let gui = try await ai("ai.profiles.create", .obj([
        ("name", .string("UI-TARS")), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
        ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("uitars-prompt-1")),
        ("parserVersion", .string("uitars-parser-1")), ("coordinateProtocol", .string("normalized_1000")), ("limits", GuiLimits.ceiling.json),
        ("allowedFallbackProfileRefs", .array([]))]), key: "unit-config-g1")
    if contractTest {
        func until(_ check: () async throws -> Bool) async throws {
            for _ in 0..<500 { if try await check() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw ContractError(.deadlineExceeded, "condition not reached")
        }
        let refresh = try await ai("ai.models.refresh", .obj([("connectionId", conn["connectionId"]!), ("expectedRevision", conn["revision"]!)]),
                                   key: "unit-config-r1")
        try await until { ["succeeded", "failed"].contains(try await ai("ai.operations.get", .obj([("operationId", refresh["operationId"]!)]))["state"]?.stringValue ?? "") }
        let test = try await ai("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!),
                                                        ("fixtureId", .string("synthetic_gui_v1"))]), key: "unit-config-t1")
        var state = ""
        try await until {
            state = try await ai("ai.operations.get", .obj([("operationId", test["operationId"]!)]))["state"]?.stringValue ?? ""
            return ["succeeded", "failed", "cancelled"].contains(state)
        }
        #expect(state == "succeeded", "the capability test must pass for unit.run")
    }
    let def = try await ai("ai.profiles.default.get")
    _ = try await ai("ai.profiles.setDefault", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedDefaultRevision", def["default"]!["revision"]!),
                                                    ("expectedProfileRevision", gui["revision"]!)]), key: "unit-config-d1")
}

// F40-06 row 12 end to end: a GUI profile whose model profile revision has
// not passed the GUI contract test runs nothing (no Run, no input).
@Test func aProfileThatHasNotPassedTheContractTestRunsNothing() async throws {
    let s = try await unitStack(contractTest: false)
    defer { try? FileManager.default.removeItem(at: s.dir) }
    let r = await s.call("unit.run", unitRunParams(s.desktop))
    guard case let .failure(e) = r.result else { Issue.record("must be refused"); return }
    #expect(e.code == "capability_mismatch" && e.details?["reason"]?.stringValue == "gui_contract_not_passed")
    #expect(s.runtime.runs.list(RunStore.ListFilter(), after: nil, limit: 10).runs.isEmpty)
    #expect(s.platform.inputs.isEmpty && s.upstream.runCalls == 0)
}

func unitRunParams(_ desktop: String, text: String = saved, extra: String = "") -> String {
    #"{"desktopId":"\#(desktop)","mode":"explore","goal":{"description":"\#(integrationGoal)"},"verification":{"all":[{"kind":"element_text_equals","role":"static_text","text":"\#(text)"}]},"allowedActions":["click","wait"]\#(extra)}"#
}

func untilEnded(_ s: UnitStack, _ runId: String) async throws -> RunRecord {
    for _ in 0..<1000 {
        if let r = s.runtime.runs.find(runId), r.isEnded { return r }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    throw ContractError(.deadlineExceeded, "run \(runId) did not end")
}

@Test func aUnitRunFromTheWireIsDrivenInsideItsRun() async throws {
    let s = try await unitStack()
    defer { try? FileManager.default.removeItem(at: s.dir) }
    let r = await s.call("unit.run", unitRunParams(s.desktop), id: "unit-run-1")
    guard case let .success(run) = r.result else { Issue.record("\(r.json.encoded())"); return }
    #expect(RuntimeContract.shared.validate(run, "Run").isEmpty, "\(run.encoded())")
    #expect(run["origin"]?.stringValue == "agent_hub" && run["lifetime"]?.stringValue == "connection_scoped")
    let runId = try #require(run["runId"]?.stringValue)

    let ended = try await untilEnded(s, runId)
    #expect(ended.outcome == .success && ended.closingReason == "goal_verified", "\(ended.json.encoded())")
    #expect(ended.unit?.verification == .matched)
    #expect(ended.receipts.count == 1 && ended.unknownActions == 0)
    #expect(s.platform.status == saved && s.platform.inputs.count == 1)
    #expect(s.upstream.runCalls == 1)
    // One Run: the input went into the unit Run, not a one-action Run.
    #expect(s.runtime.runs.list(RunStore.ListFilter(), after: nil, limit: 10).runs.map(\.runId) == [runId])

    // The terminal row and its final event are separate writes. Wait for
    // the event we assert, rather than racing the terminal row update.
    let eventDeadline = Date().addingTimeInterval(10)
    while !s.runtime.runs.events(runId, after: 0, limit: 1000).contains(where: { $0["type"]?.stringValue == "run.ended" }), Date() < eventDeadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    let events = s.runtime.runs.events(runId, after: 0, limit: 1000)
    let types = events.compactMap { $0["type"]?.stringValue }
    for t in ["run.started", "unit.observation", "unit.progress", "unit.inference.attempt", "unit.step.proposed",
              "action.accepted", "action.dispatched", "action.completed", "unit.action", "unit.verification",
              "run.finishing", "run.quiescent", "run.ended"] {
        #expect(types.contains(t), "\(t) missing from \(types)")
    }
    #expect(types.last == "run.ended")
    #expect(events.map { $0["sequence"]?.intValue ?? 0 } == Array(1...events.count))
    for e in events {
        let t = e["type"]?.stringValue ?? ""
        let def = t.hasPrefix("unit.") ? "UnitRunEvent" : "PlatformRunEvent"
        #expect(RuntimeContract.shared.validate(e, def).isEmpty, "\(e.encoded())")
        // No goal, verification text or model reply on the timeline.
        if t.hasPrefix("unit.") {
            let text = e.encoded()
            #expect(!text.contains("保存") && !text.contains("Thought"), "\(text)")
        }
    }
    // The unit.action names the act request the receipt is under.
    let action = try #require(events.first { $0["type"]?.stringValue == "unit.action" })
    let requestId = try #require(action["data"]?["requestId"]?.stringValue)
    #expect(events.contains { $0["type"]?.stringValue == "action.accepted" && $0["data"]?["requestId"]?.stringValue == requestId })
}

@Test func aUnitRunThatNeverSeesItsGoalFailsWithoutSucceeding() async throws {
    let s = try await unitStack()
    defer { try? FileManager.default.removeItem(at: s.dir) }
    // The text never shows up; the run uses its steps and fails.
    let r = await s.call("unit.run", unitRunParams(s.desktop, text: "从未出现", extra: #","limits":{"maxSteps":2}"#))
    let runId = try #require((try? r.result.get())?["runId"]?.stringValue, "\(r.json.encoded())")
    let ended = try await untilEnded(s, runId)
    #expect(ended.outcome == .failed && ended.closingReason == "limit_exceeded", "\(ended.json.encoded())")
    #expect(ended.unit?.verification == .contradicted)
    #expect(s.upstream.runCalls == 2)
}

@Test func withoutAGuiProfileNoRunIsCreated() async throws {
    let s = try await unitStack(configure: false)
    defer { try? FileManager.default.removeItem(at: s.dir) }
    let r = await s.call("unit.run", unitRunParams(s.desktop))
    guard case let .failure(e) = r.result else { Issue.record("must be refused"); return }
    #expect(e.code == "not_found" && e.details?["reason"]?.stringValue == "no_default_gui_profile")
    #expect(s.runtime.runs.list(RunStore.ListFilter(), after: nil, limit: 10).runs.isEmpty)
    #expect(s.platform.inputs.isEmpty)
}

@Test func cancellingAUnitRunStopsTheExplorer() async throws {
    let s = try await unitStack()
    defer { try? FileManager.default.removeItem(at: s.dir) }
    s.upstream.holdRunCalls = true
    let r = await s.call("unit.run", unitRunParams(s.desktop))
    let runId = try #require((try? r.result.get())?["runId"]?.stringValue)
    for _ in 0..<500 where s.upstream.heldCalls == 0 { try await Task.sleep(nanoseconds: 10_000_000) }
    let cancel = await s.call("run.cancel", #"{"runId":"\#(runId)"}"#)
    #expect((try? cancel.result.get()) != nil)
    let ended = try await untilEnded(s, runId)
    #expect(ended.outcome == .cancelled && ended.closingReason == "stopped")
    #expect(s.platform.inputs.isEmpty)
    s.upstream.holdRunCalls = false
}
