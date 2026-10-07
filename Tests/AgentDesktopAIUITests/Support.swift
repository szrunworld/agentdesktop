import AgentDesktopAI
import AgentDesktopAIUI
import AgentDesktopContracts
import AgentDesktopGUI
import AgentDesktopService
import Foundation

// Stand-ins adapted from Tests/AgentDesktopServiceTests (vertical slice):
// a scripted OpenAI-compatible upstream and the neutral form in place of a
// desktop. Real native input and a real model are not exercised here.

let canary = "sk-canary-ui-pages"
let neutralExpected = RunStartModel.neutralExpected

final class NeutralForm: @unchecked Sendable {
    private let lock = NSLock()
    private var name = ""
    private var focused = false
    private(set) var submissions = 0
    private(set) var inputs = 0
    static let nameField = (x: 200.0...800.0, y: 160.0...240.0)
    static let applyButton = (x: 200.0...600.0, y: 560.0...640.0)

    var status: String { lock.withLock { submissions == 0 ? "未提交" : "已保存：\(name) / MAC-001-A / 提交次数 \(submissions)" } }
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
                                windowFrameDesktopLogical: Rect(x: 0, y: 0, width: 500, height: 400))

actor FormObservation: GuiObservationPort {
    let form: NeutralForm
    private(set) var count = 0
    init(form: NeutralForm) { self.form = form }

    func observe(runId: String, expectedGeneration: UInt64) throws -> ObservationBundle {
        count += 1
        let shot = try ScreenshotDescriptor(screenshotId: "shot-\(count)", artifactRef: "art-\(count)",
                                            sha256: String(repeating: "b", count: 64), mimeType: "image/png",
                                            transformVersion: "t1", sourceToDesktop: .scale(0.5, 0.5),
                                            transform: .pipeline(sourceSize: Size(width: 1000, height: 800),
                                                                 resizedSize: Size(width: 500, height: 400)))
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
    enum Mode { case confirm, unknown, hang }
    let form: NeutralForm
    var mode: Mode = .confirm
    private(set) var executed = 0
    private var hung: CheckedContinuation<Void, Never>?
    init(form: NeutralForm) { self.form = form }

    func set(mode: Mode) { self.mode = mode }
    var isHanging: Bool { hung != nil }
    func release() { hung?.resume(); hung = nil }

    func execute(_ proposal: GuiProposal, actionId: String) async throws -> GuiActionReceipt {
        executed += 1
        guard case let .action(action) = proposal.body else { throw ContractError(.invalidAction, "not an action") }
        if mode == .hang { await withCheckedContinuation { hung = $0 } }
        form.apply(action)
        let t = Date()
        let state: DeliveryState = mode == .unknown ? .unknown : .confirmed
        return GuiActionReceipt(actionId: actionId, proposalId: proposal.proposalId, runId: proposal.runId, stamp: proposal.stamp,
                                actionType: action.kind, deliveryState: state, executionTarget: formTarget,
                                inputPath: "stand-in.event", startedAt: t, endedAt: state == .confirmed ? t : nil,
                                evidenceRefs: state == .confirmed ? ["ev-\(actionId)"] : [],
                                createdAt: t, updatedAt: t,
                                confirmationObservationId: state == .confirmed ? "conf-\(actionId)" : nil, reasonCode: nil)
    }
}

actor NoAudit: GuiAuditPort {
    private var n = 0
    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
    func recordInference(_ receipt: GuiInferenceReceipt) {}
    func reserveAction(_ proposal: GuiProposal) -> String { n += 1; return "act-\(n)" }
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

final class ScriptedUpstream: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var runStep = 0
    var colorAnswer = SyntheticGuiFixture.colorAnswer
    var usageReported = true
    var delayMs = 0

    static let runReplies = [
        "Thought: focus the name field.\nAction: click(start_box='(500,250)')",
        "Thought: type the name.\nAction: type(content='Ada')",
        "Thought: apply.\nAction: click(start_box='(400,750)')",
        "Thought: the form shows the saved state.\nAction: finished(content='saved')",
    ]

    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        let delay = lock.withLock { delayMs }
        if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000) }
        if request.url?.path.hasSuffix("/models") == true {
            return HTTPResult(status: 200, body: Data(#"{"object":"list","data":[{"id":"doubao-seed-2-1-lite-260915","object":"model"}]}"#.utf8))
        }
        let reply: String
        if body.contains(SyntheticGuiFixture.authPrompt) {
            reply = "OK"
        } else if body.contains(SyntheticGuiFixture.colorQuestion) {
            reply = lock.withLock { colorAnswer }
        } else if body.contains(SyntheticGuiFixture.guiTask) {
            reply = "Thought: the blue button.\nAction: click(start_box='(750,780)')"
        } else if body.contains("Ada") {
            reply = lock.withLock {
                defer { runStep += 1 }
                return Self.runReplies[min(runStep, Self.runReplies.count - 1)]
            }
        } else {
            return HTTPResult(status: 400, body: Data(#"{"error":{"message":"unexpected prompt"}}"#.utf8))
        }
        var m: [(String, JSONValue)] = [
            ("id", .string("up-1")), ("model", .string("doubao-seed-2-1-lite-260915")),
            ("choices", .array([.obj([("index", .int(0)),
                                      ("message", .obj([("role", .string("assistant")), ("content", .string(reply))])),
                                      ("finish_reason", .string("stop"))])])),
        ]
        if lock.withLock({ usageReported }) {
            m.append(("usage", .obj([("prompt_tokens", .int(900)), ("completion_tokens", .int(20)), ("total_tokens", .int(920))])))
        }
        return HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: JSONValue.obj(m).encodedData())
    }
}

struct FastClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 2_000_000) }
}

/// The composed service behind an in-process ContractClient.
/// Counts and optionally fails calls on the way to the real client.
final class SpyClient: ContractClient, @unchecked Sendable {
    let inner: ContractClient
    private let lock = NSLock()
    private var calls: [String] = []
    private var failing: Set<String> = []
    init(_ inner: ContractClient) { self.inner = inner }
    func fail(_ command: String, _ on: Bool = true) { lock.withLock { if on { failing.insert(command) } else { failing.remove(command) } } }
    var commands: [String] { lock.withLock { calls } }
    func count(_ command: String) -> Int { commands.filter { $0 == command }.count }
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        let fails = lock.withLock { calls.append(command); return failing.contains(command) }
        if fails { throw ContractError(.upstreamUnavailable, "service unreachable", retryable: true) }
        return try await inner.send(command, params, idempotencyKey: idempotencyKey)
    }
}

final class Harness: @unchecked Sendable {
    let dir: URL
    let form = NeutralForm()
    let upstream = ScriptedUpstream()
    let observation: FormObservation
    let executor: FormExecutor
    let service: AgentDesktopService
    let router: RpcRouter
    let client: InProcessContractClient

    init(backend: Bool = true) async throws {
        dir = URL(fileURLWithPath: "/tmp/adui-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        observation = FormObservation(form: form)
        executor = FormExecutor(form: form)
        let be = GuiExecutionBackend(
            ports: GuiExplorerPorts(observation: observation, execution: executor, audit: NoAudit()),
            sessions: OwnerSessions(),
            features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]))
        service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
            databasePath: dir.appendingPathComponent("config.sqlite").path,
            credentials: InMemoryCredentialStore(), http: upstream, executionBackend: backend ? be : nil))
        router = service.router(callerScope: "owner", trustedOwner: true)
        client = InProcessContractClient(router: router)
    }

    /// Every String reachable from a model's stored properties, to prove
    /// a secret does not linger anywhere in it.
    static func strings(in value: Any, depth: Int = 0) -> [String] {
        guard depth < 6 else { return [] }
        if let s = value as? String { return [s] }
        if let v = value as? JSONValue { return [v.encoded()] }
        var out: [String] = []
        for child in Mirror(reflecting: value).children {
            out += strings(in: child.value, depth: depth + 1)
        }
        return out
    }
}
