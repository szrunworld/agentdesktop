import AgentDesktopAI
import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopGUI

// The SQLite run repository and audit port behind the real explorer and
// gui.runs service, and the same repository contract checked against the
// in-memory reference. Case IDs from docs/ai-gui/tests/cases.csv.

/// Forwards to the SQLite audit port and remembers what passed through.
actor RecordingAudit: GuiAuditPort {
    let inner: SQLiteGuiAuditPort
    private(set) var inferences: [GuiInferenceReceipt] = []
    private(set) var reservedActions: [String] = []

    init(_ inner: SQLiteGuiAuditPort) { self.inner = inner }

    func reserveInference(runId: String, stepIndex: Int, snapshotId: String) async throws {
        try await inner.reserveInference(runId: runId, stepIndex: stepIndex, snapshotId: snapshotId)
    }
    func recordInference(_ receipt: GuiInferenceReceipt) async throws {
        try await inner.recordInference(receipt)
        inferences.append(receipt)
    }
    func reserveAction(_ proposal: GuiProposal) async throws -> String {
        let id = try await inner.reserveAction(proposal)
        reservedActions.append(id)
        return id
    }
    func reserveAction(_ proposal: GuiProposal, target: TargetIdentity) async throws -> String {
        let id = try await inner.reserveAction(proposal, target: target)
        reservedActions.append(id)
        return id
    }
    func recordAction(_ receipt: GuiActionReceipt) async throws { try await inner.recordAction(receipt) }
}

final class SQLiteRunHarness: @unchecked Sendable {
    let path: String
    let form = NeutralForm()
    let store: ConfigStore
    let ai: StubAiService
    let observation: SpyObservation
    let executor: SpyExecutor
    let audit: RecordingAudit
    let repository: SQLiteGuiRunRepository
    let service: GuiRunService
    let owner: RpcRouter

    init(_ replies: [StubAiService.Reply], path: String? = nil) throws {
        if let path {
            self.path = path
        } else {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adruns-gui-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.path = dir.appendingPathComponent("config.sqlite").path
        }
        store = try Self.openStore(self.path)
        ai = StubAiService(replies)
        observation = SpyObservation(form: form)
        executor = SpyExecutor(form: form)
        let counter = IdCounter()
        audit = RecordingAudit(SQLiteGuiAuditPort(store: store, newActionId: { "act-\(UUID().uuidString.prefix(8).lowercased())" }))
        repository = SQLiteGuiRunRepository(store: store)
        let codecs = GuiCodecRegistry()
        let ports = GuiExplorerPorts(observation: observation, execution: executor, audit: audit)
        let backend = GuiExecutionBackend(ports: ports, sessions: SpySessions(),
                                          features: GuiBackendFeatures(actions: GuiActionKind.allCases,
                                                                       verificationPredicates: ["element_text_equals"]))
        service = GuiRunService(repository: repository, resolver: ConfigBindingResolver(store: store, codecs: codecs),
                                backend: backend, aiService: ai, codecs: codecs, clock: ManualClock(),
                                newId: { prefix in "\(prefix)-\(counter.next())" })
        var handlers = ConfigApplicationService(store: store).handlers(callerScope: "owner")
        handlers.merge(service.handlers(callerScope: "owner", trustedOwner: true)) { a, _ in a }
        owner = RpcRouter(handlers: handlers)
    }

    static func openStore(_ path: String) throws -> ConfigStore {
        try ConfigStore(path: path, credentials: sharedCredentials, digestKey: Data(repeating: 3, count: 32))
    }

    static let sharedCredentials = InMemoryCredentialStore()

    func call(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil, router: RpcRouter? = nil) async throws -> JSONValue {
        var m: [(String, JSONValue)] = [
            ("schemaVersion", .string("agentdesktop.ai/1")), ("requestId", .string(UUID().uuidString.lowercased())),
            ("command", .string(command)), ("params", params),
        ]
        if let key { m.append(("context", .obj([("idempotencyKey", .string(key))]))) }
        var line = await (router ?? owner).respond(toBody: JSONValue.obj(m).encodedData())
        line.removeLast()
        return try StrictJSON.parse(line)
    }

    func ok(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil, router: RpcRouter? = nil) async throws -> JSONValue {
        let r = try await call(command, params, key: key, router: router)
        guard r["ok"]?.boolValue == true, let result = r["result"] else {
            Issue.record("\(command) failed: \(r.encoded())")
            throw ContractError(.internalError, "call failed")
        }
        return result
    }

    @discardableResult
    func setUpProfile() async throws -> JSONValue {
        let conn = try await ok("ai.connections.create", .obj([
            ("name", .string("Ark")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("https://ark.example.com/api/v3")), ("timeoutMs", .int(30000)),
            ("credential", .obj([("apiKey", .string("sk-canary-gui"))])),
        ]), key: "conn-\(UUID().uuidString.prefix(8))")
        let model = try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("Seed")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
            ("modelId", .string("doubao-seed-2-1-lite-260915")), ("requestOptions", .obj([("temperature", .double(0))])),
            ("maxOutputTokens", .int(1024)),
        ]), key: "model-\(UUID().uuidString.prefix(8))")
        let gui = try await ok("ai.profiles.create", .obj([
            ("name", .string("UI-TARS")), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
            ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("1.0.0")),
            ("promptVersion", .string("uitars-prompt-1")), ("parserVersion", .string("uitars-parser-1")),
            ("coordinateProtocol", .string("image_pixels")), ("limits", GuiLimits.ceiling.json),
            ("allowedFallbackProfileRefs", .array([])),
        ]), key: "gui-\(UUID().uuidString.prefix(8))")
        let def = try await ok("ai.profiles.default.get")
        _ = try await ok("ai.profiles.setDefault", .obj([
            ("guiProfileId", gui["guiProfileId"]!), ("expectedDefaultRevision", def["default"]!["revision"]!),
            ("expectedProfileRevision", gui["revision"]!),
        ]), key: "def-\(UUID().uuidString.prefix(8))")
        return gui
    }

    func start(key: String = "run-key-0001") async throws -> String {
        let params: JSONValue = .obj([
            ("desktopId", .string("desk-a")), ("goal", .string(GuiHarness.goal)),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                   ("text", .string(GuiHarness.expected))])),
            ("allowedActions", .array([.string("click"), .string("type"), .string("key")])),
        ])
        return try await ok("gui.runs.start", params, key: key)["runId"]!.stringValue!
    }

    func finished(_ runId: String) async { await service.task(for: runId)?.value }

    func run(_ runId: String, router: RpcRouter? = nil) async throws -> JSONValue {
        try await ok("gui.runs.get", .obj([("runId", .string(runId))]), router: router)
    }

    /// A gui.runs.get router over a freshly opened store on the same file,
    /// as a restarted Runtime would have (no execution backend).
    func reopenedRouter() throws -> (ConfigStore, RpcRouter) {
        let s = try Self.openStore(path)
        let svc = GuiRunService(repository: SQLiteGuiRunRepository(store: s), resolver: ConfigBindingResolver(store: s),
                                backend: nil, aiService: ai)
        return (s, RpcRouter(handlers: svc.handlers(callerScope: "owner", trustedOwner: true)))
    }
}

@Suite("Runs on SQLite")
struct RunsSQLiteTests {
    enum Kind: String, CaseIterable { case memory, sqlite }

    func repository(_ kind: Kind) throws -> (GuiRunRepository, (String, Int) async throws -> Void) {
        switch kind {
        case .memory:
            let r = InMemoryGuiRunRepository(maxEventsPerRun: 5)
            return (r, { await r.prune(runId: $0, keepFrom: $1) })
        case .sqlite:
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adruns-contract-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let r = SQLiteGuiRunRepository(store: try SQLiteRunHarness.openStore(dir.appendingPathComponent("c.sqlite").path),
                                           maxEventsPerRun: 5)
            return (r, { try await r.prune(runId: $0, keepFrom: $1) })
        }
    }

    static func stored(_ id: String, scope: String = "owner") -> StoredGuiRun {
        StoredGuiRun(runId: id, callerScope: scope, binding: .obj([("runId", .string(id))]),
                     startResult: .obj([("runId", .string(id))]),
                     snapshot: .obj([("runId", .string(id)), ("state", .string("queued"))]))
    }

    /// One script of repository calls; both implementations must answer it identically.
    func transcript(_ kind: Kind) async throws -> [String] {
        let (repo, prune) = try repository(kind)
        var out: [String] = []
        func note(_ s: String) { out.append(s) }
        func outcome(_ o: GuiRunCreateOutcome) -> String {
            switch o { case let .created(r): return "created \(r.runId)"; case let .existing(r): return "existing \(r.runId)" }
        }
        func code(_ body: () async throws -> Void) async -> String {
            do { try await body(); return "ok" } catch let e as ContractError { return e.code.rawValue } catch { return "other" }
        }
        note(outcome(try await repo.create(Self.stored("r1"), idempotencyKey: "key-0001", digest: "d1")))
        note(outcome(try await repo.create(Self.stored("r2"), idempotencyKey: "key-0001", digest: "d1")))
        note(await code { _ = try await repo.create(Self.stored("r3"), idempotencyKey: "key-0001", digest: "d2") })
        note(outcome(try await repo.create(Self.stored("r4", scope: "other"), idempotencyKey: "key-0001", digest: "d1")))
        note("load own \(try await repo.load(runId: "r1", callerScope: "owner")?.runId ?? "nil")")
        note("load other \(try await repo.load(runId: "r1", callerScope: "other")?.runId ?? "nil")")
        note("load missing \(try await repo.load(runId: "zz", callerScope: "owner")?.runId ?? "nil")")
        note(await code { try await repo.saveSnapshot(runId: "zz", snapshot: .obj([])) })
        try await repo.saveSnapshot(runId: "r1", snapshot: .obj([("state", .string("observing"))]))
        note("snapshot \(try await repo.load(runId: "r1", callerScope: "owner")?.snapshot["state"]?.stringValue ?? "nil")")
        for _ in 0..<5 {
            note("seq \(try await repo.appendEvent(runId: "r1") { .obj([("sequence", .int($0))]) })")
        }
        note(await code { _ = try await repo.appendEvent(runId: "r1") { .obj([("sequence", .int($0))]) } })
        note(await code { _ = try await repo.appendEvent(runId: "zz") { .obj([("sequence", .int($0))]) } })
        let page = try await repo.events(runId: "r1", afterSequence: 2, limit: 2)
        note("page \(page.events.compactMap { $0["sequence"]?.intValue }) last \(page.lastSequence) kept \(String(describing: page.oldestRetained))")
        try await prune("r1", 3)
        let afterPrune = try await repo.events(runId: "r1", afterSequence: 0, limit: 10)
        note("pruned \(afterPrune.events.compactMap { $0["sequence"]?.intValue }) kept \(String(describing: afterPrune.oldestRetained))")
        note(await code { _ = try await repo.events(runId: "zz", afterSequence: 0, limit: 10) })
        return out
    }

    // The SQLite repository behaves exactly like the in-memory reference.
    @Test func repositoryContractMatchesTheInMemoryReference() async throws {
        let reference = try await transcript(.memory)
        let sqlite = try await transcript(.sqlite)
        #expect(sqlite == reference)
        #expect(reference.contains("IDEMPOTENCY_CONFLICT"))
        #expect(reference.contains("load other nil"))
    }

    // MAC-001-A on the SQLite store: every model call and input is on disk,
    // and a reopened store answers gui.runs.get with the same run.
    @Test func mac001_happyPathIsDurable() async throws {
        let h = try SQLiteRunHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        await h.observation.set(statusLag: 1)
        let runId = try await h.start()
        await h.finished(runId)
        let live = try await h.run(runId)
        #expect(live["state"]?.stringValue == "succeeded")
        #expect(await h.executor.executed.count == 3)

        let actions = await h.audit.reservedActions
        #expect(actions.count == 3)
        for id in actions { #expect(try await h.store.actionReceipt(actionId: id)?.state == "confirmed") }
        #expect(try await h.store.inferenceReceiptCount(runId: runId) == 4)
        // USG-001: recording the same inference again does not add a row.
        if let first = await h.audit.inferences.first { try await h.audit.recordInference(first) }
        #expect(try await h.store.inferenceReceiptCount(runId: runId) == 4)

        let (_, reopened) = try h.reopenedRouter()
        let again = try await h.run(runId, router: reopened)
        #expect(again == live)
        #expect(try schemaClean(again, "gui_runs_get_result", domain: false))
        let events = try await h.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0)), ("limit", .int(100))]),
                                    router: reopened)["events"]!.arrayValue!
        #expect(events.compactMap { $0["sequence"]?.intValue } == Array(1...events.count))
        #expect(!String(decoding: try Data(contentsOf: URL(fileURLWithPath: h.path)), as: UTF8.self).contains("sk-canary-gui"))
    }

    // §09.3: when the pending input row cannot be written, no input is sent.
    @Test func pendingRowFailureSendsNoInput() async throws {
        let h = try SQLiteRunHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        await h.store.setRunStoreFault(.actionReservation, true)
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(await h.executor.executed.isEmpty)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "AUDIT_UNAVAILABLE")
    }

    // A6: an event that cannot be written is not swallowed; the run stops
    // before the next model call or input.
    @Test func eventWriteFailureStopsBeforeInput() async throws {
        let h = try SQLiteRunHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        await h.store.setRunStoreFault(.event, true)
        let runId = try await h.start()
        await h.finished(runId)
        let run = try await h.run(runId)
        #expect(await h.executor.executed.isEmpty)
        #expect(run["state"]?.stringValue == "failed")
        #expect(run["error"]?["code"]?.stringValue == "AUDIT_UNAVAILABLE")
    }

    // EXE-003 / RET-004 end to end: the process dies while the executor
    // holds the input. After reopening, recovery records unknown, the run
    // waits, the snapshot is still a valid GuiRun, and nothing is resent.
    @Test func exe003_crashDuringInputRecoversAsUnknown() async throws {
        let h = try SQLiteRunHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        try await h.setUpProfile()
        await h.executor.set(mode: .hang)
        let runId = try await h.start()
        await eventually("executor holds the input") { await h.executor.isHanging }
        let actionId = try #require(await h.audit.reservedActions.first)
        #expect(try await h.store.actionReceipt(actionId: actionId)?.state == "pending")

        // "Restart": a new store on the same file; the old process is gone.
        let (store, router) = try h.reopenedRouter()
        let report = try await RunRecovery(store: store).recover()
        #expect(report.quarantinedRuns == [runId])
        #expect(report.unknownActions == [actionId])
        if let snap = try await SQLiteGuiRunRepository(store: store).load(runId: runId, callerScope: "owner")?.snapshot {
            #expect(try schemaClean(snap, "gui_runs_get_result", domain: false))
        }
        let run = try await h.run(runId, router: router)
        #expect(run["state"]?.stringValue == "waiting_user")
        #expect(run["waitingReasonCode"]?.stringValue == "ACTION_OUTCOME_UNKNOWN")
        #expect(run["latestActionReceipt"]?["deliveryState"]?.stringValue == "unknown")
        #expect(run["latestActionReceipt"]?["executionTarget"]?["windowId"] == target.json["windowId"], "the target recorded with the pending row")
        #expect(run["latestActionReceipt"]?["inputPath"]?.stringValue == ConfigStore.unrecordedInputPath)
        #expect(try schemaClean(run, "gui_runs_get_result", domain: false))
        #expect(try await store.unresolvedActions(desktopId: "desk-a").map(\.actionId) == [actionId])
        #expect(await h.executor.executed.count == 1, "nothing is sent again")
        let events = try await h.ok("gui.runs.events", .obj([("runId", .string(runId)), ("afterSequence", .int(0)), ("limit", .int(100))]),
                                    router: router)["events"]!.arrayValue!
        #expect(events.compactMap { $0["sequence"]?.intValue } == Array(1...events.count))
        for e in events { #expect(try schemaClean(e, "RunEvent")) }
        await h.executor.release()
    }

    // CFG-005: a profile pinned by an active run cannot be deleted; once
    // the run ends it can.
    @Test func cfg005_activeRunProtectsItsProfile() async throws {
        let h = try SQLiteRunHarness([click(200, 100), typeText("Ada"), click(200, 300), finish])
        let gui = try await h.setUpProfile()
        // Clear the default so only the run references the profile.
        let def = try await h.ok("ai.profiles.default.get")
        _ = try await h.ok("ai.profiles.setDefault", .obj([("guiProfileId", .null), ("expectedDefaultRevision", def["default"]!["revision"]!)]),
                           key: "clear-default")
        await h.executor.set(mode: .hang)
        let params: JSONValue = .obj([
            ("desktopId", .string("desk-a")), ("guiProfileId", gui["guiProfileId"]!), ("expectedProfileRevision", gui["revision"]!),
            ("goal", .string(GuiHarness.goal)),
            ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                   ("text", .string(GuiHarness.expected))])),
            ("allowedActions", .array([.string("click"), .string("type")])),
        ])
        let runId = try await h.ok("gui.runs.start", params, key: "run-pinned-1")["runId"]!.stringValue!
        await eventually("run is executing") { await h.executor.isHanging }
        let delete: JSONValue = .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!)])
        let refused = try await h.call("ai.profiles.delete", delete, key: "del-gui-1")
        #expect(refused["error"]?["code"]?.stringValue == "RESOURCE_IN_USE")

        _ = try await h.ok("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "cancel-run-1")
        await h.executor.release()
        await h.finished(runId)
        #expect(try await h.run(runId)["state"]?.stringValue == "cancelled")
        let deleted = try await h.call("ai.profiles.delete", delete, key: "del-gui-2")
        #expect(deleted["ok"]?.boolValue == true, "\(deleted.encoded())")
    }
}
