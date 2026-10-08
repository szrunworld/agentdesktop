import AgentDesktopAI
import AgentDesktopCLI
import AgentDesktopProtocol
import AgentDesktopGUI
import Foundation
import Testing
@testable import AgentDesktopService

// The first vertical slice of AGENT_START_HERE.md, end to end through the
// composed service: one openai_chat connection, one model profile, one
// uitars_v1 GUI profile, the four-level capability test, then a run on the
// neutral form that types Ada, presses Apply and is confirmed by a fresh
// observation. The model is a scripted HTTP upstream; the desktop is a
// stand-in for the neutral form. Real native input is NOT exercised here
// (that is G0/T01): these tests prove the service wiring and its contract.

let goal = "在指定中立表单的姓名中输入 Ada，然后点击应用"
let expected = "已保存：Ada / MAC-001-A / 提交次数 1"
let canary = "sk-canary-vertical-slice"

/// The neutral form in source-screenshot pixels (1000×800).
final class NeutralForm: @unchecked Sendable {
    private let lock = NSLock()
    private var name = ""
    private var focused = false
    private(set) var submissions = 0
    private(set) var inputs = 0
    static let nameField = (x: 200.0...800.0, y: 160.0...240.0)
    static let applyButton = (x: 200.0...600.0, y: 560.0...640.0)

    var status: String {
        lock.withLock { submissions == 0 ? "未提交" : "已保存：\(name) / MAC-001-A / 提交次数 \(submissions)" }
    }
    var fieldText: String { lock.withLock { name } }
    var inputCount: Int { lock.withLock { inputs } }

    func apply(_ action: GuiAction) {
        lock.withLock {
            inputs += 1
            switch action {
            case let .click(p):
                if Self.nameField.x.contains(p.x), Self.nameField.y.contains(p.y) { focused = true }
                else if Self.applyButton.x.contains(p.x), Self.applyButton.y.contains(p.y) { submissions += 1; focused = false }
                else { focused = false }
            case let .type(t): if focused { name += t }
            default: break
            }
        }
    }
}

let formTarget = TargetIdentity(appId: "com.agentdesktop.neutral-form", processId: 4242, processStartId: "ps-1",
                                windowId: "win-1", windowGeometryRevision: 1, backendId: "stand-in",
                                windowFrameDesktopLogical: GuiRect(x: 0, y: 0, width: 500, height: 400))

/// The model sees the 1000×800 source shrunk to 500×400 (a real transform).
func formTransform() throws -> ScreenshotTransform {
    try .pipeline(sourceSize: Size(width: 1000, height: 800), resizedSize: Size(width: 500, height: 400))
}

actor FormObservation: GuiObservationPort {
    let form: NeutralForm
    private(set) var count = 0
    init(form: NeutralForm) { self.form = form }

    func observe(runId: String, expectedGeneration: UInt64) throws -> ObservationBundle {
        count += 1
        let shot = try ScreenshotDescriptor(screenshotId: "shot-\(count)", artifactRef: "art-\(count)",
                                            sha256: String(repeating: "b", count: 64), mimeType: "image/png",
                                            transformVersion: "t1", sourceToDesktop: .scale(0.5, 0.5),
                                            transform: formTransform())
        let obs = Observation(observationId: "obs-\(count)",
                              stamp: ObservationStamp(sessionId: "sess-a", desktopId: "desk-a", snapshotId: "snap-\(count)",
                                                      bindingEpoch: 1, runGeneration: expectedGeneration),
                              target: formTarget, observedAt: Date(), screenshots: [shot])
        return ObservationBundle(observation: obs,
                                 authorizedImages: [AiImageContent(screenshotId: shot.screenshotId, mimeType: "image/png",
                                                                   bytes: Data(repeating: 7, count: 2048))],
                                 elements: [ObservedElement(role: "static_text", text: form.status),
                                            ObservedElement(role: "text_field", text: form.fieldText)])
    }
}

actor FormExecutor: GuiExecutionPort {
    let form: NeutralForm
    private(set) var executed: [GuiProposal] = []
    /// When set, the n-th input (1-based) is delivered but its outcome is unknown.
    var unknownAt: Int?
    init(form: NeutralForm) { self.form = form }
    func set(unknownAt n: Int?) { unknownAt = n }

    func execute(_ proposal: GuiProposal, actionId: String) throws -> GuiActionReceipt {
        executed.append(proposal)
        guard case let .action(action) = proposal.body else { throw ContractError(.invalidAction, "not an action") }
        form.apply(action)
        let t = Date()
        if unknownAt == executed.count {
            return GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                                    actionType: action.kind, deliveryState: .unknown, executionTarget: formTarget,
                                    inputPath: "stand-in.event", startedAt: t, endedAt: nil, evidenceRefs: [],
                                    createdAt: t, updatedAt: t, confirmationObservationId: nil, reasonCode: "ACTION_OUTCOME_UNKNOWN")
        }
        return GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                                actionType: action.kind, deliveryState: .confirmed, executionTarget: formTarget,
                                inputPath: "stand-in.event", startedAt: t, endedAt: t, evidenceRefs: ["ev-\(actionId)"],
                                createdAt: t, updatedAt: t, confirmationObservationId: "conf-\(actionId)", reasonCode: nil)
    }
}

actor CountingAudit: GuiAuditPort {
    private(set) var inferences = 0
    private(set) var actions = 0
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) { inferences += 1 }
    func reserveAction(_ proposal: GuiProposal) -> String { actions += 1; return "act-\(actions)" }
    func recordAction(_ receipt: GuiActionReceipt) {}
}

struct OwnerSessions: GuiSessionAuthority {
    func authorize(sessionId: String?, desktopId: String, callerScope: String, trustedOwner: Bool,
                   runId: String) throws -> (sessionId: String, bindingEpoch: UInt64) {
        guard desktopId == "desk-a", sessionId == nil ? trustedOwner : sessionId == "sess-a" else {
            throw ContractError(.forbidden, "not authorized for this desktop")
        }
        return ("sess-a", 1)
    }
}

/// A scripted OpenAI-compatible upstream. It answers the capability-test
/// prompts with what a working UI-TARS model would, and the run with the
/// neutral-form steps. It records every request it sees.
final class ScriptedUpstream: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var runStep = 0
    private(set) var requests: [URLRequest] = []
    private(set) var authorizations: [String] = []

    /// Run replies in model-input pixels of a normalized_1000 profile:
    /// name field centre source (500,200) → model (250,100) → (500,250);
    /// Apply centre source (400,600) → model (200,300) → (400,750).
    static let runReplies = [
        "Thought: focus the name field.\nAction: click(start_box='(500,250)')",
        "Thought: type the name.\nAction: type(content='Ada')",
        "Thought: apply.\nAction: click(start_box='(400,750)')",
        "Thought: the form shows the saved state.\nAction: finished(content='saved')",
    ]

    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        lock.withLock {
            requests.append(request)
            authorizations.append(request.value(forHTTPHeaderField: "Authorization") ?? "")
        }
        if request.url?.path.hasSuffix("/models") == true {
            return HTTPResult(status: 200, body: Data(#"{"object":"list","data":[{"id":"doubao-seed-2-1-lite-260915","object":"model"}]}"#.utf8))
        }
        let reply: String
        if body.contains(SyntheticGuiFixture.authPrompt) {
            reply = "OK"
        } else if body.contains(SyntheticGuiFixture.colorQuestion) {
            reply = SyntheticGuiFixture.colorAnswer
        } else if body.contains(SyntheticGuiFixture.guiTask) {
            // Button centre (600,390) of the 800×500 synthetic screen, normalized.
            reply = "Thought: the blue button.\nAction: click(start_box='(750,780)')"
        } else if body.contains("Ada") {
            reply = lock.withLock {
                defer { runStep += 1 }
                return Self.runReplies[min(runStep, Self.runReplies.count - 1)]
            }
        } else {
            return HTTPResult(status: 400, body: Data(#"{"error":{"message":"unexpected prompt"}}"#.utf8))
        }
        let response = JSONValue.obj([
            ("id", .string("up-\(UUID().uuidString.prefix(8))")),
            ("model", .string("doubao-seed-2-1-lite-260915")),
            ("choices", .array([.obj([
                ("index", .int(0)),
                ("message", .obj([("role", .string("assistant")), ("content", .string(reply))])),
                ("finish_reason", .string("stop")),
            ])])),
            ("usage", .obj([("prompt_tokens", .int(900)), ("completion_tokens", .int(20)), ("total_tokens", .int(920))])),
        ])
        return HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: response.encodedData())
    }

    var chatAuthorizations: [String] {
        lock.withLock { zip(requests, authorizations).filter { $0.0.url?.path.hasSuffix("/chat/completions") == true }.map(\.1) }
    }
    var chatRequests: Int { lock.withLock { requests.filter { $0.url?.path.hasSuffix("/chat/completions") == true }.count } }
    var runRequests: Int { lock.withLock { runStep } }
}

final class Slice: @unchecked Sendable {
    let dir: URL
    let form = NeutralForm()
    let upstream = ScriptedUpstream()
    let observation: FormObservation
    let executor: FormExecutor
    let audit = CountingAudit()
    let credentials: InMemoryCredentialStore
    let service: AgentDesktopService
    let router: ServiceRouter

    init(backend: Bool = true, reopening dir: URL? = nil, credentials: InMemoryCredentialStore? = nil) async throws {
        self.dir = dir ?? URL(fileURLWithPath: "/tmp/ads-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: self.dir, withIntermediateDirectories: true)
        self.credentials = credentials ?? InMemoryCredentialStore()
        observation = FormObservation(form: form)
        executor = FormExecutor(form: form)
        let be = GuiExecutionBackend(
            ports: GuiExplorerPorts(observation: observation, execution: executor, audit: audit),
            sessions: OwnerSessions(),
            features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]))
        service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
            databasePath: self.dir.appendingPathComponent("config.sqlite").path,
            credentials: self.credentials, http: upstream, executionBackend: backend ? be : nil))
        router = service.router(callerScope: "owner", trustedOwner: true)
    }

    /// One call through the router, as `{ok, result | error}` (test shape).
    func call(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> JSONValue {
        switch await router.answer(method: command, params: params, idempotencyKey: key) {
        case let .success(v): return .obj([("ok", .bool(true)), ("result", v)])
        case let .failure(e): return .obj([("ok", .bool(false)), ("error", e.json)])
        }
    }

    func ok(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> JSONValue {
        let r = try await call(command, params, key: key)
        guard r["ok"]?.boolValue == true, let result = r["result"] else {
            throw ContractError(.internalError, "\(command) failed: \(r.encoded())")
        }
        return result
    }

    func waitFor(_ check: () async throws -> Bool) async throws {
        for _ in 0..<400 {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw ContractError(.deadlineExceeded, "condition not reached")
    }

    /// E02–E06: connection, model profile, GUI profile, capability test, default.
    func configure() async throws -> (gui: JSONValue, test: JSONValue) {
        let conn = try await ok("ai.connections.create", .obj([
            ("name", .string("Ark")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")), ("timeoutMs", .int(30000)),
            ("credential", .obj([("apiKey", .string(canary))])),
        ]), key: "conn-create-1")
        let refresh = try await ok("ai.models.refresh", .obj([("connectionId", conn["connectionId"]!),
                                                            ("expectedRevision", conn["revision"]!)]), key: "models-refresh-1")
        try await waitFor {
            let op = try await ok("ai.operations.get", .obj([("operationId", refresh["operationId"]!)]))
            return ["succeeded", "failed"].contains(op["state"]?.stringValue ?? "")
        }
        let models = try await ok("ai.models.list", .obj([("connectionId", conn["connectionId"]!)]))
        #expect(models["items"]?.arrayValue?.first?["modelId"]?.stringValue == "doubao-seed-2-1-lite-260915")

        let model = try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("Seed lite")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
            ("modelId", .string("doubao-seed-2-1-lite-260915")), ("requestOptions", .obj([("temperature", .int(0))])),
            ("maxOutputTokens", .int(1024)),
        ]), key: "model-create-1")
        let gui = try await ok("ai.profiles.create", .obj([
            ("name", .string("UI-TARS")), ("modelProfileId", model["modelProfileId"]!),
            ("modelProfileRevision", model["revision"]!),
            ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("1.0.0")),
            ("promptVersion", .string("uitars-prompt-1")), ("parserVersion", .string("uitars-parser-1")),
            ("coordinateProtocol", .string("normalized_1000")), ("limits", GuiLimits.ceiling.json),
            ("allowedFallbackProfileRefs", .array([])),
        ]), key: "gui-create-1")

        let started = try await ok("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!),
                                                          ("expectedRevision", gui["revision"]!),
                                                          ("fixtureId", .string("synthetic_gui_v1"))]), key: "tests-start-1")
        var test: JSONValue = .null
        try await waitFor {
            test = try await ok("ai.operations.get", .obj([("operationId", started["operationId"]!)]))
            return ["succeeded", "failed", "cancelled"].contains(test["state"]?.stringValue ?? "")
        }

        let def = try await ok("ai.profiles.default.get")
        _ = try await ok("ai.profiles.setDefault", .obj([
            ("guiProfileId", gui["guiProfileId"]!), ("expectedDefaultRevision", def["default"]!["revision"]!),
            ("expectedProfileRevision", gui["revision"]!),
        ]), key: "default-set-1")
        return (gui, test)
    }

    static func startParams() -> JSONValue {
        .obj([
            ("desktopId", .string("desk-a")), ("goal", .string(goal)),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                   ("text", .string(expected))])),
            ("allowedActions", .array([.string("click"), .string("type"), .string("key")])),
        ])
    }
}

@Suite("Vertical slice")
struct VerticalSliceTests {
    @Test func everyCommandOfTheContractHasAHandler() async throws {
        let s = try await Slice()
        let handlers = s.service.handlers(callerScope: "owner", trustedOwner: true)
        #expect(Set(handlers.keys) == Set(ContractBundle.shared.operations.map(\.command)))
    }

    // E01–E12 with a scripted model and a stand-in desktop.
    @Test func neutralFormHappyPath() async throws {
        let s = try await Slice()
        let (gui, test) = try await s.configure()

        // E05: the four levels passed and no desktop input happened.
        #expect(test["state"]?.stringValue == "succeeded", "\(test.encoded())")
        #expect(s.form.inputCount == 0, "capability tests never touch the desktop")
        let capabilityCalls = s.upstream.chatRequests

        // E07: start against the default profile.
        let start = try await s.ok("gui.runs.start", Slice.startParams(), key: "neutral-MAC-001-A")
        let runId = try #require(start["runId"]?.stringValue)
        var run: JSONValue = .null
        try await s.waitFor {
            run = try await s.ok("gui.runs.get", .obj([("runId", .string(runId))]))
            return ["succeeded", "failed", "cancelled", "waiting_user"].contains(run["state"]?.stringValue ?? "")
        }

        // E10: succeeded only through the bound verification on a newer observation.
        #expect(run["state"]?.stringValue == "succeeded", "\(run.encoded())")
        #expect(run["goalVerification"]?["status"]?.stringValue == "passed")
        let verifiedOn = try #require(run["goalVerification"]?["observationId"]?.stringValue)
        #expect(Int(verifiedOn.split(separator: "-").last ?? "") ?? 0 > 1)
        #expect(s.form.status == expected)
        #expect(s.form.submissions == 1)
        #expect(await s.executor.executed.count == 3, "click, type, click")
        #expect(run["binding"]?["primary"]?["guiProfile"]?["guiProfileId"] == gui["guiProfileId"])
        #expect(try ContractBundle.shared.validate(run, "gui_runs_get_result").isEmpty)

        // The run used the shared model service. The check after Apply
        // already sees the saved state, so no finish turn is needed (§06.3):
        // three model calls for three inputs.
        #expect(s.upstream.runRequests == 3)
        #expect(s.upstream.chatRequests == capabilityCalls + 3)
        #expect(s.upstream.chatAuthorizations.allSatisfy { $0 == "Bearer \(canary)" })

        // E12: usage covers capability tests and the run; known tokens add up.
        let usage = try await s.ok("ai.usage.summary", .obj([("from", .string("2026-01-01T00:00:00Z")),
                                                             ("to", .string("2099-01-01T00:00:00Z"))]))
        #expect(usage["inferenceAttempts"]?.intValue == s.upstream.chatRequests)
        #expect(usage["attemptsMissingUsage"]?.intValue == 0)
        #expect(usage["confirmedActions"]?.intValue == 3)
        #expect(usage["unknownActionOutcomes"]?.intValue == 0)

        // Events are strictly increasing and replayable from a cursor.
        let events = try await s.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0))]))
        let seq = events["events"]?.arrayValue?.compactMap { $0["sequence"]?.intValue } ?? []
        #expect(!seq.isEmpty && seq == seq.sorted() && Set(seq).count == seq.count)

        // The same start key returns the same run and starts nothing new.
        let again = try await s.ok("gui.runs.start", Slice.startParams(), key: "neutral-MAC-001-A")
        #expect(again["runId"]?.stringValue == runId)
        #expect(await s.executor.executed.count == 3)
    }

    // GUI-003 at the service: the same steps against a verification the form
    // never shows end without success, whatever the model claims.
    @Test func wrongVerificationNeverSucceeds() async throws {
        let s = try await Slice()
        _ = try await s.configure()
        let params = Slice.startParams().setting("verification", .obj([
            ("kind", .string("element_text_equals")), ("role", .string("static_text")),
            ("text", .string("已保存：Bob / MAC-001-A / 提交次数 1"))]))
        let start = try await s.ok("gui.runs.start", params, key: "neutral-wrong-text")
        let runId = start["runId"]!.stringValue!
        var run: JSONValue = .null
        try await s.waitFor {
            run = try await s.ok("gui.runs.get", .obj([("runId", .string(runId))]))
            return ["succeeded", "failed", "cancelled", "waiting_user"].contains(run["state"]?.stringValue ?? "")
        }
        #expect(run["state"]?.stringValue != "succeeded", "\(run.encoded())")
        #expect(run["goalVerification"]?["status"]?.stringValue != "passed")
    }

    // §07.4 at the service: a reopened service still answers for the run,
    // with the same events, and the same start key starts nothing new.
    @Test func runsSurviveAServiceRestart() async throws {
        let s = try await Slice()
        _ = try await s.configure()
        let start = try await s.ok("gui.runs.start", Slice.startParams(), key: "restart-run-0001")
        let runId = start["runId"]!.stringValue!
        try await s.waitFor {
            try await s.ok("gui.runs.get", .obj([("runId", .string(runId))]))["state"]?.stringValue == "succeeded"
        }
        let events = try await s.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0))]))
        let reopened = try await Slice(reopening: s.dir, credentials: s.credentials)
        #expect(reopened.service.recovery.quarantinedRuns.isEmpty)
        let run = try await reopened.ok("gui.runs.get", .obj([("runId", .string(runId))]))
        #expect(run["state"]?.stringValue == "succeeded")
        let again = try await reopened.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0))]))
        #expect(again["events"] == events["events"])
        let dup = try await reopened.ok("gui.runs.start", Slice.startParams(), key: "restart-run-0001")
        #expect(dup["runId"]?.stringValue == runId)
        #expect(await reopened.executor.executed.isEmpty)
    }

    // RET-004 / USG at the service: an input with an unknown outcome stops
    // the run for a person, is never resent, and shows up in usage.
    @Test func unknownOutcomeWaitsAndIsCounted() async throws {
        let s = try await Slice()
        _ = try await s.configure()
        await s.executor.set(unknownAt: 2)
        let start = try await s.ok("gui.runs.start", Slice.startParams(), key: "unknown-run-0001")
        let runId = start["runId"]!.stringValue!
        var run: JSONValue = .null
        try await s.waitFor {
            run = try await s.ok("gui.runs.get", .obj([("runId", .string(runId))]))
            return ["succeeded", "failed", "cancelled", "waiting_user"].contains(run["state"]?.stringValue ?? "")
        }
        #expect(run["state"]?.stringValue == "waiting_user")
        #expect(run["waitingReasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(await s.executor.executed.count == 2, "nothing after the unknown input, and it is not resent")
        let usage = try await s.ok("ai.usage.summary", .obj([("from", .string("2026-01-01T00:00:00Z")),
                                                             ("to", .string("2099-01-01T00:00:00Z"))]))
        #expect(usage["confirmedActions"]?.intValue == 1)
        #expect(usage["unknownActionOutcomes"]?.intValue == 1)
        // Another caller sees none of it.
        let stranger = s.service.router(callerScope: "stranger", trustedOwner: false)
        let other: JSONValue = .obj([("result", try await stranger.answer(method: "ai.usage.summary", params: .obj([
            ("from", .string("2026-01-01T00:00:00Z")), ("to", .string("2099-01-01T00:00:00Z"))])).get())])
        #expect(other["result"]?["confirmedActions"]?.intValue == 0)
        #expect(other["result"]?["unknownActionOutcomes"]?.intValue == 0)
    }

    // SEC-001 (service part): the key never appears in any response or in
    // the database files.
    @Test func theKeyStaysInTheCredentialStore() async throws {
        let s = try await Slice()
        _ = try await s.configure()
        let start = try await s.ok("gui.runs.start", Slice.startParams(), key: "neutral-run-sec")
        let runId = start["runId"]!.stringValue!
        try await s.waitFor {
            let r = try await s.ok("gui.runs.get", .obj([("runId", .string(runId))]))
            return r["state"]?.stringValue == "succeeded"
        }
        var seen: [String] = []
        for cmd in ["ai.connections.list", "ai.modelProfiles.list", "ai.profiles.list"] {
            seen.append(try await s.call(cmd).encoded())
        }
        seen.append(s.service.runs.capabilities().encoded())
        seen.append(try await s.call("ai.usage.summary", .obj([("from", .string("2026-01-01T00:00:00Z")),
                                                               ("to", .string("2099-01-01T00:00:00Z"))])).encoded())
        seen.append(try await s.call("gui.runs.get", .obj([("runId", .string(runId))])).encoded())
        seen.append(try await s.call("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0))])).encoded())
        #expect(!seen.contains { $0.contains(canary) })
        for file in try FileManager.default.contentsOfDirectory(atPath: s.dir.path) {
            let bytes = try Data(contentsOf: s.dir.appendingPathComponent(file))
            #expect(bytes.range(of: Data(canary.utf8)) == nil, "\(file) holds the key")
        }
    }

    // MAC-007 (service part) / G0 gate: without an execution backend the
    // AI side still works and GUI input stays closed.
    @Test func withoutABackendRealInputStaysClosed() async throws {
        let s = try await Slice(backend: false)
        let (_, test) = try await s.configure()
        #expect(test["state"]?.stringValue == "succeeded")
        let caps = s.service.runs.capabilities()
        #expect(caps["features"]?["nativeIsolationEvidence"]?.stringValue == "NOT_RUN")
        let r = try await s.call("gui.runs.start", Slice.startParams(), key: "no-backend-1")
        #expect(r["error"]?["code"]?.stringValue == "CAPABILITY_MISMATCH")
        #expect(s.form.inputCount == 0)
    }

    // The CLI reaches the composed service through the Runtime's one
    // endpoint, in runtime/1.
    @Test func cliOverTheRuntimeEndpoint() async throws {
        let s = try await Slice()
        let path = s.dir.appendingPathComponent("runtime.sock").path
        let server = try runtimeEndpoint(for: s.service, at: path)
        defer { server.stop() }

        var mode = stat()
        #expect(stat(path, &mode) == 0)
        #expect(mode.st_mode & 0o777 == 0o600)

        let out = LinesBox()
        let request = #"{"apiVersion":"agentdesktop.runtime/1","requestId":"cli-caps-0001","method":"runtime.capabilities","params":{}}"#
        let cli = ContractCLI(stdout: out.add, stderr: { _ in }, readFile: { _ in Data(request.utf8) },
                              environment: ["HOME": NSHomeDirectory()])
        let code = await onThread { cli.run(["--json", "--socket", path, "rpc", "--request-file", "r.json"]) }
        #expect(code == .ok)
        let reply = try StrictJSON.parse(try #require(out.lines.first))
        #expect(reply["apiVersion"]?.stringValue == RuntimeAPI.version)
        #expect(reply["requestId"]?.stringValue == "cli-caps-0001")
        #expect(reply["data"]?["gui"]?["implementedAiProtocols"] == .array([.string("openai_chat")]))

        // A request in the retired ai/1 envelope is refused before sending.
        let old = #"{"schemaVersion":"agentdesktop.ai/1","requestId":"44444444-4444-4444-8444-444444444444","command":"ai.connections.list","params":{}}"#
        let out3 = LinesBox()
        let cli3 = ContractCLI(stdout: out3.add, stderr: { _ in }, readFile: { _ in Data(old.utf8) },
                               environment: ["HOME": NSHomeDirectory()])
        #expect(await onThread { cli3.run(["--socket", path, "rpc", "--request-file", "r.json"]) } == .localValidation)
        #expect(try StrictJSON.parse(try #require(out3.lines.first))["error"]?["code"]?.stringValue == "invalid_argument")

        // A client that sends a request and leaves before the answer does not
        // end the server; the next request still succeeds.
        for _ in 0..<3 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &addr.sun_path) { b in let p = Array(path.utf8); b.copyBytes(from: p); b[p.count] = 0 }
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
            let line = Data((request + "\n").utf8)
            _ = line.withUnsafeBytes { write(fd, $0.baseAddress, line.count) }
            close(fd)
        }
        try await Task.sleep(nanoseconds: 100_000_000)
        let out2 = LinesBox()
        let cli2 = ContractCLI(stdout: out2.add, stderr: { _ in }, readFile: { _ in Data(request.utf8) },
                               environment: ["HOME": NSHomeDirectory()])
        #expect(await onThread { cli2.run(["--socket", path, "rpc", "--request-file", "r.json"]) } == .ok)

        // Nothing listens: the CLI says the runtime is unavailable (exit 3).
        let cli4 = ContractCLI(stdout: { _ in }, stderr: { _ in }, readFile: { _ in Data(request.utf8) },
                               environment: ["HOME": NSHomeDirectory()])
        let none = s.dir.appendingPathComponent("none.sock").path
        #expect(await onThread { cli4.run(["--socket", none, "rpc", "--request-file", "r.json"]) } == .runtimeUnavailable)
    }
}

final class LinesBox: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String] = []
    func add(_ s: String) { lock.withLock { items.append(s) } }
    var lines: [String] { lock.withLock { items } }
}
