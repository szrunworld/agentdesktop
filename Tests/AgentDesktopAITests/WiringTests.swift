import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopAI

// The model service on the configuration database: SQLite ledger,
// credential resolution and revocation, resolved profiles, model catalog,
// operations and usage. Case IDs refer to docs/ai-gui/tests/cases.csv.

extension ConfigStore {
    func rawRun(_ sql: String) throws -> Int { try db.run(sql) }
    func rawCount(_ sql: String) throws -> Int { Int(try db.row(sql)?[0].int ?? -1) }
}

/// A transport that parks requests until released, to hold a call in flight.
final class GateTransport: HTTPTransport, @unchecked Sendable {
    let inner: StubTransport
    private let gate = Locked<[CheckedContinuation<Void, Never>]>([])
    private let closed = Locked(true)
    init(_ inner: StubTransport) { self.inner = inner }
    func hold() { closed.with { $0 = true } }
    func open() {
        closed.with { $0 = false }
        let waiting = gate.with { w -> [CheckedContinuation<Void, Never>] in let all = w; w = []; return all }
        for c in waiting { c.resume() }
    }
    var parked: Int { gate.get().count }
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        if closed.get() {
            await withCheckedContinuation { c in
                let resumeNow = gate.with { w -> Bool in
                    if !closed.get() { return true }
                    w.append(c); return false
                }
                if resumeNow { c.resume() }
            }
        }
        try Task.checkCancellation()
        return try await inner.send(request, maxResponseBytes: maxResponseBytes)
    }
    func waitParked(_ n: Int = 1) async {
        for _ in 0..<3000 where parked < n { try? await Task.sleep(nanoseconds: 1_000_000) }
        #expect(parked >= n, "a request should be in flight")
    }
}

struct Wired {
    let h: Harness
    let http: StubTransport
    let runner: AiOperationRunner
    let app: AiApplicationHandlers

    init(http: StubTransport = StubTransport(body: okBody()), transport: HTTPTransport? = nil) throws {
        h = try Harness()
        self.http = http
        runner = AiOperationRunner()
        app = AiApplicationHandlers(store: h.store, http: transport ?? http, runner: runner)
    }

    func router(_ scope: String = "owner") -> RpcRouter {
        RpcRouter(handlers: app.handlers(callerScope: scope))
    }

    func call(_ command: String, _ params: JSONValue = .obj([]), scope: String = "owner", key: String? = nil) async throws -> JSONValue {
        try await h.call(command, params, key: key, router: router(scope))
    }

    func ok(_ command: String, _ params: JSONValue = .obj([]), scope: String = "owner", key: String? = nil) async throws -> JSONValue {
        let v = try await call(command, params, scope: scope, key: key)
        guard v["ok"]?.boolValue == true, let r = v["result"] else {
            Issue.record("\(command) failed: \(v.encoded())")
            throw CancellationError()
        }
        let op = ContractBundle.shared.operation(command)!
        #expect(try ContractBundle.shared.validateRpc(r, "\(op.defPrefix)_result").isEmpty, "\(command) result")
        return r
    }

    func errCode(_ command: String, _ params: JSONValue = .obj([]), scope: String = "owner", key: String? = nil) async throws -> String? {
        let v = try await call(command, params, scope: scope, key: key)
        #expect(v["ok"]?.boolValue == false, "\(command) should fail")
        return v["error"]?["code"]?.stringValue
    }

    /// connection → model profile → GUI profile, through the real router.
    func profile(apiKey: String = canaryKey, url: String = "https://ark.example.invalid/api/v3") async throws -> (conn: JSONValue, model: JSONValue, gui: JSONValue) {
        let conn = try await h.createConnection(apiKey: apiKey, url: url)
        let model = try await h.createModel(conn)
        let gui = try await h.createGui(model)
        return (conn, model, gui)
    }

    func waitTerminal(_ op: String, scope: String = "owner") async throws -> JSONValue {
        await runner.wait(op)
        for _ in 0..<2000 {
            let v = try await ok("ai.operations.get", .obj([("operationId", .string(op))]), scope: scope)
            if ["succeeded", "failed", "cancelled"].contains(v["state"]?.stringValue ?? "") { return v }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        Issue.record("operation \(op) never ended")
        throw CancellationError()
    }
}

func guiContext(_ attempt: String = ConfigStore.randomId("att"), run: String = "run-1", scope: String = "owner",
                clock: MonotonicClock) -> AiCallContext {
    AiCallContext(inferenceAttemptId: attempt,
                  purpose: .guiStep(GuiStepCallPurpose(runId: run, stepIndex: 0, snapshotId: "snap-1", bindingEpoch: 1, currentGeneration: 1)),
                  callerScopeRef: scope, budgetScopeRef: run,
                  deadlineMonotonicNanoseconds: clock.nowNanoseconds() + 60_000_000_000)
}

func testContext(_ attempt: String = ConfigStore.randomId("att"), op: String = "op-1", scope: String = "owner",
                 clock: MonotonicClock) -> AiCallContext {
    AiCallContext(inferenceAttemptId: attempt,
                  purpose: .capabilityTest(CapabilityTestCallPurpose(operationId: op, level: .authModel, syntheticSnapshotId: "syn",
                                                                     fixtureId: "synthetic_gui_v1", guiProfileId: "gp", guiProfileRevision: 1)),
                  callerScopeRef: scope, budgetScopeRef: op,
                  deadlineMonotonicNanoseconds: clock.nowNanoseconds() + 60_000_000_000)
}

@Suite("Ledger and resolution")
struct LedgerWiringTests {
    func setup(_ http: StubTransport = StubTransport(body: okBody())) async throws -> (Wired, ResolvedGuiProfile, DefaultAiService, FakeClock) {
        let w = try Wired(http: http)
        let p = try await w.profile()
        let resolved = try await w.h.store.resolveGuiProfile(p.gui["guiProfileId"]!.stringValue!, revision: 1, callerScope: "owner")
        let clock = FakeClock()
        let admission = CredentialRevocationAdmission(store: w.h.store)
        await admission.register()
        let svc = DefaultAiService(http: http, credentials: StoreCredentialResolver(store: w.h.store),
                                   ledger: SQLiteAiCallLedger(store: w.h.store), admission: admission, clock: clock)
        return (w, resolved, svc, clock)
    }

    // USG-001: both purposes land in one durable ledger, once each.
    @Test func usg001_attemptsOfBothPurposesPersist() async throws {
        let (w, resolved, svc, clock) = try await setup()
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(clock: clock))
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: testContext(clock: clock))
        let reopened = try w.h.reopened()
        let rows = try await reopened.store.usageRows(callerScope: "owner")
        #expect(rows.count == 2)
        #expect(rows.allSatisfy { $0.usage?.inputTokens == 100 })
        #expect(try await reopened.store.rawCount("SELECT COUNT(*) FROM inference_attempts WHERE purpose='gui_step' AND run_id='run-1' AND operation_id IS NULL") == 1)
        #expect(try await reopened.store.rawCount("SELECT COUNT(*) FROM inference_attempts WHERE purpose='capability_test' AND operation_id='op-1' AND run_id IS NULL") == 1)
        // The purpose CHECK refuses a row that claims both a run and an operation.
        await #expect(throws: (any Error).self) {
            _ = try await reopened.store.rawRun("""
                INSERT INTO inference_attempts(attempt_id,purpose,run_id,operation_id,caller_scope,budget_scope,connection_id,
                  connection_revision,model_profile_id,model_profile_revision,credential_id,requested_model_id,state,reserved_at)
                VALUES('x','gui_step','r','o','s','b','c',1,'m',1,'k','id','reserved','2026-10-08T00:00:00Z')
                """)
        }
        // No key, prompt, image or response text is stored.
        let bytes = try Data(contentsOf: URL(fileURLWithPath: w.h.path)) + ((try? Data(contentsOf: URL(fileURLWithPath: w.h.path + "-wal"))) ?? Data())
        #expect(bytes.range(of: Data(canaryKey.utf8)) == nil)
        #expect(bytes.range(of: Data("Type Ada into Name".utf8)) == nil)
    }

    @Test func usg001_finishingTwiceCountsOnce() async throws {
        let (w, resolved, _, clock) = try await setup()
        let ledger = SQLiteAiCallLedger(store: w.h.store)
        let ctx = guiContext(clock: clock)
        let id = try await ledger.reserve(context: ctx, target: resolved.model)
        let record = AiCallRecord(reservationId: id, context: ctx, target: resolved.model, requestedModelId: "m", actualModelId: "m",
                                  upstreamRequestId: nil, httpStatus: 200, finishReason: "stop", startedAt: clock.wallNow(),
                                  endedAt: clock.wallNow(), latencyMs: 1, state: .succeeded,
                                  usage: UsageTokens(inputTokens: 5, outputTokens: 1, totalTokens: 6), cost: nil, error: nil, discarded: false)
        try await ledger.finish(record)
        try await ledger.finish(AiCallRecord(reservationId: id, context: ctx, target: resolved.model, requestedModelId: "m", actualModelId: "m",
                                             upstreamRequestId: nil, httpStatus: 200, finishReason: "stop", startedAt: clock.wallNow(),
                                             endedAt: clock.wallNow(), latencyMs: 1, state: .succeeded,
                                             usage: UsageTokens(inputTokens: 500, outputTokens: 100), cost: nil, error: nil, discarded: false))
        let rows = try await w.h.store.usageRows(callerScope: "owner")
        #expect(rows.count == 1)
        #expect(rows.first?.usage?.inputTokens == 5)
        await expectCode(.validationError) { _ = try await ledger.reserve(context: ctx, target: resolved.model) }
    }

    // §09.3: no ledger row, no call; an unrecorded end stops that scope.
    @Test func auditFailuresStopProgress() async throws {
        let (w, resolved, svc, clock) = try await setup()
        await w.h.store.setLedgerFault(.reserve, true)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(clock: clock)) }
        #expect(w.http.count == 0)
        await w.h.store.setLedgerFault(.reserve, false)

        await w.h.store.setLedgerFault(.finish, true)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(run: "run-A", clock: clock)) }
        #expect(w.http.count == 1)
        await w.h.store.setLedgerFault(.finish, false)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(run: "run-A", clock: clock)) }
        #expect(w.http.count == 1, "no further model call in the blocked run")
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(run: "run-B", clock: clock))
        #expect(w.http.count == 2, "another run is unaffected")
    }

    // §09.3, §07.4: a reservation without an end survives a restart as
    // interrupted, counts as unknown usage, and blocks its scope.
    @Test func crashLeavesAnInterruptedAttempt() async throws {
        let (w, resolved, _, clock) = try await setup()
        _ = try await SQLiteAiCallLedger(store: w.h.store).reserve(context: guiContext(run: "run-C", clock: clock), target: resolved.model)
        let restarted = try w.h.reopened()
        #expect(try await restarted.store.recoverLedger() == 1)
        #expect(try await restarted.store.attempts(budgetScope: "run-C").map(\.state) == ["interrupted"])
        let ledger = SQLiteAiCallLedger(store: restarted.store)
        await expectCode(.auditUnavailable) { _ = try await ledger.reserve(context: guiContext(run: "run-C", clock: clock), target: resolved.model) }
        let summary = UsageSummaryBuilder.summarize(rows: try await restarted.store.usageRows(callerScope: "owner"),
                                                    from: .distantPast, to: .distantFuture)
        #expect(summary["inferenceAttempts"]?.intValue == 1)
        #expect(summary["attemptsMissingUsage"]?.intValue == 1)
        #expect(summary["reportedTokens"]?.isNull == true, "unknown usage is not zero")
        try await restarted.store.resolveInterruptedAttempts(budgetScope: "run-C")
        _ = try await ledger.reserve(context: guiContext(run: "run-C", clock: clock), target: resolved.model)
    }

    // SEC-002 (resolver side): only an active identity resolves; no fallback.
    @Test func sec002_resolverReadsOnlyActiveIdentities() async throws {
        let w = try Wired()
        let conn = try await w.h.createConnection(apiKey: canaryKey)
        let resolver = StoreCredentialResolver(store: w.h.store)
        let first = conn["credentialRef"]!.stringValue!
        #expect(try await resolver.resolveKey(credentialIdentity: first) == canaryKey)
        await expectCode(.credentialRequired) { _ = try await resolver.resolveKey(credentialIdentity: "cred_unknown") }
        let rotated = try await w.h.ok("ai.credentials.rotate", .obj([
            ("connectionId", conn["connectionId"]!), ("expectedRevision", conn["revision"]!),
            ("credential", .obj([("apiKey", .string(canaryKey + "-2"))])),
        ]))
        await expectCode(.credentialRevoked) { _ = try await resolver.resolveKey(credentialIdentity: first) }
        let second = rotated["credentialRef"]!.stringValue!
        #expect(try await resolver.resolveKey(credentialIdentity: second) == canaryKey + "-2")
        w.h.creds.drop(second)
        await expectCode(.credentialRequired) { _ = try await resolver.resolveKey(credentialIdentity: second) }
    }

    // SEC-004: a rotation while a call is in flight voids its result; the
    // old identity makes no further upstream call; a profile that adopts
    // the new connection revision binds the new identity.
    @Test func sec004_rotationVoidsInFlightCall() async throws {
        let stub = StubTransport(body: okBody())
        let gate = GateTransport(stub)
        let w = try Wired(http: stub)
        let p = try await w.profile()
        let store = w.h.store
        let gui = p.gui["guiProfileId"]!.stringValue!
        let resolved = try await store.resolveGuiProfile(gui, revision: 1, callerScope: "owner")
        let clock = FakeClock()
        let admission = CredentialRevocationAdmission(store: store)
        await admission.register()
        let svc = DefaultAiService(http: gate, credentials: StoreCredentialResolver(store: store),
                                   ledger: SQLiteAiCallLedger(store: store), admission: admission, clock: clock)
        let ctx = guiContext(clock: clock)
        let call = Task { try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: ctx) }
        await gate.waitParked()
        let rotated = try await w.h.ok("ai.credentials.rotate", .obj([
            ("connectionId", p.conn["connectionId"]!), ("expectedRevision", p.conn["revision"]!),
            ("credential", .obj([("apiKey", .string(canaryKey + "-K2"))])),
        ]))
        gate.open()
        await #expect(throws: ContractError.self) { _ = try await call.value }
        #expect(try await store.rawCount("SELECT COUNT(*) FROM inference_attempts WHERE attempt_id='\(ctx.inferenceAttemptId)' AND discarded=1") == 1)
        let before = stub.count
        await expectCode(.credentialRevoked) {
            _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(clock: clock))
        }
        #expect(stub.count == before, "K1 makes no upstream call after its revocation")
        #expect(stub.captured.allSatisfy { !($0.value(forHTTPHeaderField: "Authorization") ?? "").hasSuffix("-K2") })

        // Adopting the new connection revision explicitly binds K2.
        let model = try await w.h.ok("ai.modelProfiles.update", .obj([
            ("modelProfileId", p.model["modelProfileId"]!), ("expectedRevision", p.model["revision"]!),
            ("patch", .obj([("connectionRevision", rotated["revision"]!)])),
        ]))
        let gui2 = try await w.h.ok("ai.profiles.update", .obj([
            ("guiProfileId", .string(gui)), ("expectedRevision", .int(1)),
            ("patch", .obj([("modelProfileRevision", model["revision"]!)])),
        ]))
        let r2 = try await store.resolveGuiProfile(gui, revision: rev(gui2), callerScope: "owner")
        #expect(r2.model.connection.credentialIdentityRef == rotated["credentialRef"]!.stringValue!)
        gate.hold(); gate.open()
        _ = try await svc.infer(screenshotRequest(), resolvedModel: r2.model, context: guiContext(run: "run-2", clock: clock))
        #expect(stub.captured.last?.value(forHTTPHeaderField: "Authorization") == "Bearer \(canaryKey)-K2")
    }

    // CFG-004/006 (resolution side): exact pinned snapshots, stale and
    // disabled references refused before any call.
    @Test func resolutionPinsRevisionsAndRefusesDisabled() async throws {
        let w = try Wired()
        let p = try await w.profile()
        let store = w.h.store
        let gui = p.gui["guiProfileId"]!.stringValue!
        let r = try await store.resolveGuiProfile(gui, revision: 1, callerScope: "owner")
        #expect(r.model.model.modelId == "doubao-seed-2-1-lite-260915")
        #expect(r.model.model.requestOptions == ModelRequestOptions(temperature: 0, seed: 7))
        #expect(r.model.connection.revision == 1 && r.model.model.revision == 1)
        #expect(r.model.connection.credentialIdentityRef == p.conn["credentialRef"]!.stringValue!)
        await expectCode(.configConflict) { _ = try await store.resolveGuiProfile(gui, revision: 2, callerScope: "owner") }
        await expectCode(.notFound) { _ = try await store.resolveGuiProfile("gp_missing", revision: 1, callerScope: "owner") }
        _ = try await w.h.ok("ai.connections.disable", .obj([("connectionId", p.conn["connectionId"]!), ("expectedRevision", .int(1))]))
        await expectCode(.resourceDisabled) { _ = try await store.resolveGuiProfile(gui, revision: 1, callerScope: "owner") }
    }
}

@Suite("Model catalog and operations")
struct CatalogOperationTests {
    static let models = #"{"object":"list","data":[{"id":"Doubao-Seed-UI-TARS","object":"model"},{"id":"doubao-seed-2-1-lite-260915"},{"id":"Doubao-Seed-UI-TARS"},{"id":"vision-pro"}]}"#

    // ai.models.refresh → operation → ai.models.list; a list never verifies capabilities.
    @Test func refreshThenList() async throws {
        let w = try Wired(http: StubTransport(body: Self.models))
        let p = try await w.profile()
        let conn = p.conn["connectionId"]!.stringValue!
        let empty = try await w.ok("ai.models.list", .obj([("connectionId", .string(conn))]))
        #expect(empty["items"]?.arrayValue?.isEmpty == true)
        #expect(empty["refreshedAt"]?.isNull == true)
        let started = try await w.ok("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(1))]))
        let op = try await w.waitTerminal(started["operationId"]!.stringValue!)
        #expect(op["state"]?.stringValue == "succeeded")
        #expect(op["kind"]?.stringValue == "model_refresh")
        #expect(op["result"]?["modelCount"]?.intValue == 3)
        let req = w.http.captured.last!
        #expect(req.httpMethod == "GET")
        #expect(req.url?.absoluteString == "https://ark.example.invalid/api/v3/models")
        #expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer \(canaryKey)")
        let page1 = try await w.ok("ai.models.list", .obj([("connectionId", .string(conn)), ("limit", .int(2))]))
        #expect(page1["items"]?.arrayValue?.map { $0["modelId"]!.stringValue! } == ["Doubao-Seed-UI-TARS", "doubao-seed-2-1-lite-260915"])
        #expect(page1["items"]?.arrayValue?.allSatisfy { $0["imageInput"]?.stringValue == "unknown" } == true)
        let page2 = try await w.ok("ai.models.list", .obj([("connectionId", .string(conn)), ("limit", .int(2)), ("cursor", page1["nextCursor"]!)]))
        #expect(page2["items"]?.arrayValue?.map { $0["modelId"]!.stringValue! } == ["vision-pro"])
        #expect(page2["nextCursor"]?.isNull == true)
        let model = try await w.ok("ai.modelProfiles.get", .obj([("modelProfileId", p.model["modelProfileId"]!)]))
        for layer in ["network", "authModel", "imageInput", "guiContract"] {
            #expect(model["capabilities"]?[layer]?["status"]?.stringValue == "unknown", "\(layer) stays unknown")
        }
    }

    @Test func failedRefreshKeepsTheOldListAsStale() async throws {
        let stub = StubTransport(body: Self.models)
        let w = try Wired(http: stub)
        let p = try await w.profile()
        let conn = p.conn["connectionId"]!.stringValue!
        _ = try await w.waitTerminal(try await w.ok("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(1))]))["operationId"]!.stringValue!)
        for (status, code) in [(500, "UPSTREAM_UNAVAILABLE"), (401, "AUTH_FAILED"), (302, "UPSTREAM_PROTOCOL_ERROR")] {
            stub.setHandler { _, _ in HTTPResult(status: status, body: Data(#"{"error":{"message":"echo sk-upstream-secret"}}"#.utf8)) }
            let op = try await w.waitTerminal(try await w.ok("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(1))]))["operationId"]!.stringValue!)
            #expect(op["state"]?.stringValue == "failed")
            #expect(op["result"]?.isNull == true)
            #expect(op["error"]?["code"]?.stringValue == code)
            #expect(!op.encoded().contains("sk-upstream-secret"))
        }
        let list = try await w.ok("ai.models.list", .obj([("connectionId", .string(conn))]))
        #expect(list["items"]?.arrayValue?.count == 3)
        #expect(try await w.h.store.catalog(connectionId: conn)?.stale == true)
        #expect(try await w.errCode("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(9))])) == "CONFIG_CONFLICT")
    }

    // CAN-004 and scoping for operations.
    @Test func can004_operationCancelSemantics() async throws {
        let stub = StubTransport(body: Self.models)
        let gate = GateTransport(stub)
        let w = try Wired(http: stub, transport: gate)
        let p = try await w.profile()
        let conn = p.conn["connectionId"]!.stringValue!
        let op = try await w.ok("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(1))]))["operationId"]!.stringValue!
        await gate.waitParked()
        #expect(try await w.errCode("ai.operations.get", .obj([("operationId", .string(op))]), scope: "intruder") == "NOT_FOUND")
        let c1 = try await w.ok("ai.operations.cancel", .obj([("operationId", .string(op))]))
        #expect(c1["accepted"]?.boolValue == true)
        #expect(c1["terminal"]?.boolValue == false || c1["state"]?.stringValue == "cancelled")
        gate.open()
        let end = try await w.waitTerminal(op)
        #expect(end["state"]?.stringValue == "cancelled")
        #expect(end["result"]?.isNull == true)
        for _ in 0..<3 {
            let again = try await w.ok("ai.operations.cancel", .obj([("operationId", .string(op))]))
            #expect(again["state"]?.stringValue == "cancelled")
            #expect(again["terminal"]?.boolValue == true)
        }
        let done = try await w.waitTerminal(try await w.ok("ai.models.refresh", .obj([("connectionId", .string(conn)), ("expectedRevision", .int(1))]))["operationId"]!.stringValue!)
        #expect(done["state"]?.stringValue == "succeeded")
        let requests = stub.count
        for _ in 0..<3 {
            let c = try await w.ok("ai.operations.cancel", .obj([("operationId", done["operationId"]!)]))
            #expect(c["accepted"]?.boolValue == false)
            #expect(c["state"]?.stringValue == "succeeded")
        }
        #expect(try await w.ok("ai.operations.get", .obj([("operationId", done["operationId"]!)]))["state"]?.stringValue == "succeeded")
        #expect(stub.count == requests)
    }

    @Test func restartEndsUnfinishedOperations() async throws {
        let w = try Wired()
        let p = try await w.profile()
        let store = w.h.store
        let a = try await store.createOperation(kind: .modelRefresh, callerScope: "owner", resourceId: cid(p.conn), resourceRevision: 1)
        let b = try await store.createOperation(kind: .modelRefresh, callerScope: "owner", resourceId: cid(p.conn), resourceRevision: 1)
        _ = try await store.requestOperationCancel(b, callerScope: "owner")
        let restarted = try w.h.reopened()
        try await restarted.store.recoverOperations()
        #expect(try await restarted.store.operationState(a) == .failed)
        #expect(try await restarted.store.operationState(b) == .cancelled)
        let v = try await restarted.store.operation(a, callerScope: "owner")
        #expect(try ContractBundle.shared.validateDomain(v, "AiOperation").isEmpty)
    }
}

@Suite("Usage summary")
struct UsageServiceTests {
    // USG-003/004: from/to and connection filters, caller scope, unknown not zero.
    @Test func usg004_summaryFromTheLedger() async throws {
        let w = try Wired(http: StubTransport(body: okBody()))
        let p = try await w.profile()
        let resolved = try await w.h.store.resolveGuiProfile(p.gui["guiProfileId"]!.stringValue!, revision: 1, callerScope: "owner")
        let clock = FakeClock()
        let svc = DefaultAiService(http: w.http, credentials: StoreCredentialResolver(store: w.h.store),
                                   ledger: SQLiteAiCallLedger(store: w.h.store), clock: clock)
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(clock: clock))
        w.http.setHandler { _, _ in HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: Data(okBody(usage: nil).utf8)) }
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(clock: clock))
        _ = try await svc.infer(screenshotRequest(), resolvedModel: resolved.model, context: guiContext(scope: "someone-else", clock: clock))

        let all = try await w.ok("ai.usage.summary", .obj([("from", .string("2020-01-01T00:00:00Z")), ("to", .string("2100-01-01T00:00:00Z"))]))
        #expect(all["inferenceAttempts"]?.intValue == 2, "only the caller's own attempts")
        #expect(all["attemptsMissingUsage"]?.intValue == 1)
        #expect(all["reportedTokens"]?["inputTokens"]?.intValue == 100, "known values only")
        #expect(all["isFinalBill"]?.boolValue == false)
        let other = try await w.ok("ai.usage.summary", .obj([("from", .string("2020-01-01T00:00:00Z")), ("to", .string("2100-01-01T00:00:00Z"))]), scope: "someone-else")
        #expect(other["inferenceAttempts"]?.intValue == 1)
        let filtered = try await w.ok("ai.usage.summary", .obj([("from", .string("2020-01-01T00:00:00Z")), ("to", .string("2100-01-01T00:00:00Z")),
                                                                 ("connectionId", .string("conn_other"))]))
        #expect(filtered["inferenceAttempts"]?.intValue == 0)
        let past = try await w.ok("ai.usage.summary", .obj([("from", .string("2000-01-01T00:00:00Z")), ("to", .string("2001-01-01T00:00:00Z"))]))
        #expect(past["inferenceAttempts"]?.intValue == 0)
        #expect(try await w.errCode("ai.usage.summary", .obj([("from", .string("2030-01-01T00:00:00Z")), ("to", .string("2020-01-01T00:00:00Z"))])) == "VALIDATION_ERROR")
    }
}
