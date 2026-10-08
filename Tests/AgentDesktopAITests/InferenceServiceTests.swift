import Foundation
import Testing
@testable import AgentDesktopAI
@testable import AgentDesktopProtocol

@Suite("Model service")
struct InferenceServiceTests {

    // TRN-005: the image budget counts base64 bytes; equal passes, +4 does not.
    @Test func trn005_imageBudget() async throws {
        let limit = AiInferenceRequest.hardMaxImageEncodedBytes
        // Five images whose base64 adds up to exactly the limit.
        let rawTotal = limit / 4 * 3
        let sizes = [1_258_290, 1_258_290, 1_258_290, 1_258_290, rawTotal - 4 * 1_258_290]
        func request(_ sizes: [Int]) -> AiInferenceRequest {
            AiInferenceRequest(messages: [AiMessage(role: .user, content: [.text("go")] + sizes.enumerated().map {
                .image(AiImageContent(screenshotId: "s\($0.offset)", mimeType: "image/png", bytes: Data(count: $0.element)))
            })])
        }
        #expect(request(sizes).images.reduce(0) { $0 + $1.encodedByteCount } == limit)
        let stub = StubTransport(body: okBody())
        let clock = FakeClock()
        let svc = service(stub, clock: clock)
        _ = try await svc.infer(request(sizes), resolvedModel: model(), context: context(clock: clock))
        #expect(stub.count == 1)
        let sent = try StrictJSON.parse(stub.captured[0].httpBody!)
        let urls = sent["messages"]!.arrayValue![0]["content"]!.arrayValue!.compactMap { $0["image_url"]?["url"]?.stringValue }
        #expect(urls.count == 5)
        #expect(urls.reduce(0) { $0 + $1.utf8.count - "data:image/png;base64,".utf8.count } == limit)

        var over = sizes; over[0] += 3   // +4 base64 bytes
        await expectCode(.limitExceeded) { _ = try await svc.infer(request(over), resolvedModel: model(), context: context(clock: clock)) }
        await expectCode(.limitExceeded) {
            _ = try await svc.infer(request([3, 3, 3, 3, 3, 3]), resolvedModel: model(), context: context(clock: clock))
        }
        #expect(stub.count == 1, "refused requests reach no network")
    }

    // RET-001: 429 with Retry-After=2 s and 5 s left: no retry before 2000 ms,
    // one retry at 2000 ms; with 1.5 s left, no retry at all.
    @Test func ret001_retryAfterWithinDeadline() async throws {
        let clock = FakeClock()
        let calls = Locked(0)
        let stub = StubTransport { _, _ in
            let n = calls.with { $0 += 1; return $0 }
            return n == 1
                ? HTTPResult(status: 429, headers: ["Retry-After": "2"], body: Data("{}".utf8))
                : HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let svc = service(stub, clock: clock)
        let step = StepInference(service: svc, budget: AttemptBudget(), clock: clock)
        let deadline = clock.ms(5000)
        let retryAt = clock.ms(2000)
        let task = Task {
            try await step.run(screenshotRequest(), step: 0, candidates: [model()], deadlineNs: deadline) { _, _ in
                AiCallContext(inferenceAttemptId: UUID().uuidString,
                              purpose: .guiStep(GuiStepCallPurpose(runId: "r", stepIndex: 0, snapshotId: "s", bindingEpoch: 1, currentGeneration: 1)),
                              callerScopeRef: "c", budgetScopeRef: "r", deadlineMonotonicNanoseconds: deadline)
            }
        }
        await clock.waitForSleeper(at: retryAt)
        clock.advance(ms: 1999)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(stub.count == 1, "no second request before Retry-After elapses")
        clock.advance(ms: 1)
        let r = try await task.value
        #expect(r.outputText.hasPrefix("click"))
        #expect(stub.count == 2)

        // Only 1.5 s left: the retry could not start in time.
        let clock2 = FakeClock()
        let stub2 = StubTransport(status: 429, headers: ["Retry-After": "2"], body: "{}")
        let step2 = StepInference(service: service(stub2, clock: clock2), budget: AttemptBudget(), clock: clock2)
        let d2 = clock2.ms(1500)
        await expectCode(.rateLimited) {
            _ = try await step2.run(screenshotRequest(), step: 0, candidates: [model()], deadlineNs: d2) { _, _ in
                context(clock: clock2, deadlineMs: 1500)
            }
        }
        #expect(stub2.count == 1)
    }

    // RET-002: only transient failures retry, at most 2 attempts per step,
    // across primary and fallback together.
    @Test(arguments: [
        (503, 2, ErrorCode.upstreamUnavailable),
        (401, 1, .authFailed),
        (400, 1, .upstreamProtocolError),
        (200, 1, .upstreamProtocolError),   // 200 with a broken body
    ])
    func ret002_whatRetries(status: Int, expectedRequests: Int, code: ErrorCode) async throws {
        let clock = FakeClock()
        let stub = StubTransport(status: status, body: status == 200 ? "not json" : "{}")
        let step = StepInference(service: service(stub, clock: clock), budget: AttemptBudget(), clock: clock)
        await expectCode(code) {
            _ = try await step.run(screenshotRequest(), step: 0, candidates: [model(), model(base: "https://fallback.example.invalid/v1", credential: "cred-2")],
                                   deadlineNs: clock.ms(60_000)) { _, _ in context(clock: clock) }
        }
        #expect(stub.count == expectedRequests)
    }

    // RET-002/RET-003: a transient failure moves to the frozen fallback, and
    // the step never exceeds two attempts.
    @Test func ret003_fallbackIsTheFrozenCandidate() async throws {
        let clock = FakeClock()
        let stub = StubTransport { req, _ in
            req.url?.host == "primary.example.invalid"
                ? HTTPResult(status: 502, body: Data("{}".utf8))
                : HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let ledger = InMemoryAiCallLedger()
        let budget = AttemptBudget()
        let step = StepInference(service: service(stub, ledger: ledger, clock: clock), budget: budget, clock: clock)
        let primary = model(base: "https://primary.example.invalid/v1")
        let fallback = model(base: "https://fallback.example.invalid/v1", modelId: "fallback-model", connectionId: "conn-2", credential: "cred-2")
        let r = try await step.run(screenshotRequest(), step: 4, candidates: [primary, fallback], deadlineNs: clock.ms(60_000)) { _, _ in
            context(clock: clock, step: 4)
        }
        #expect(stub.captured.map { $0.url!.host! } == ["primary.example.invalid", "fallback.example.invalid"])
        #expect(stub.captured[1].value(forHTTPHeaderField: "Authorization") == "Bearer \(canaryKey)-fallback")
        #expect(r.record.target == fallback)
        #expect(await budget.attempts(step: 4) == 2)
        let rows = await ledger.records()
        #expect(rows.map(\.state) == [.failed, .succeeded])

        // Both candidates failing: still only two requests.
        stub.setHandler { _, _ in HTTPResult(status: 503, body: Data("{}".utf8)) }
        await expectCode(.upstreamUnavailable) {
            _ = try await step.run(screenshotRequest(), step: 5, candidates: [primary, fallback], deadlineNs: clock.ms(60_000)) { _, _ in
                context(clock: clock, step: 5)
            }
        }
        #expect(stub.count == 4)
    }

    // RET-004 (model side): a retryable model error never re-sends anything
    // but the model request; action replay is not this layer's to do. Here:
    // the service has no input port at all.
    @Test func ret004_serviceHasNoInputPath() {
        let mirror = Mirror(reflecting: service(StubTransport(body: okBody())))
        let names = mirror.children.compactMap(\.label)
        #expect(Set(names) == ["transport", "credentials", "ledger", "admission", "clock", "prices"])
    }

    @Test func budgetCeilings() async throws {
        let b = AttemptBudget(maxAttemptsPerStep: 5, maxTotalAttempts: 99)
        #expect(b.maxAttemptsPerStep == 2 && b.maxTotalAttempts == 30, "a profile cannot raise the ceilings")
        // 40 concurrent reservations across 20 steps: exactly 30 succeed.
        let ok = await withTaskGroup(of: Bool.self) { g in
            for i in 0..<40 { g.addTask { (try? await b.reserve(step: i % 20)) != nil } }
            var n = 0
            for await r in g where r { n += 1 }
            return n
        }
        #expect(ok == 30)
        #expect(await b.totalAttempts == 30)
        let s = AttemptBudget()
        try await s.reserve(step: 1); try await s.reserve(step: 1)
        await #expect(throws: ContractError.self) { try await s.reserve(step: 1) }
    }

    // Cancellation mid-call: the row is recorded as cancelled and the late
    // answer is never returned.
    @Test func cancelDuringTheCall() async throws {
        let clock = FakeClock()
        let release = Locked<CheckedContinuation<Void, Never>?>(nil)
        let stub = StubTransport { _, _ in
            await withCheckedContinuation { c in release.with { $0 = c } }
            return HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let ledger = InMemoryAiCallLedger()
        let svc = service(stub, ledger: ledger, clock: clock)
        let task = Task { try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock)) }
        for _ in 0..<500 where release.get() == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        task.cancel()
        try await Task.sleep(nanoseconds: 20_000_000)
        release.get()?.resume()   // the late answer arrives
        do {
            _ = try await task.value
            Issue.record("a cancelled call returned a result")
        } catch {
            #expect(error is CancellationError)
        }
        let rows = await ledger.allRows()
        #expect(rows.count == 1)
        #expect(rows[0].record?.state == .cancelled)
        #expect(rows[0].record?.error?.code == .cancelled)
    }

    // A result whose run moved on (generation bumped, credential rotated) is
    // recorded as discarded and refused.
    @Test func staleGenerationDiscardsTheResult() async throws {
        let clock = FakeClock()
        let admission = TestAdmission()
        let stub = StubTransport { _, _ in
            admission.current.with { $0 = false }
            return HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let ledger = InMemoryAiCallLedger()
        await expectCode(.staleGeneration) {
            _ = try await service(stub, ledger: ledger, admission: admission, clock: clock)
                .infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
        }
        let rec = try #require(await ledger.records().first)
        #expect(rec.state == .succeeded && rec.discarded)
        #expect(rec.usage?.inputTokens == 100, "the call's usage is still counted")
    }

    // Deadline: none left → no call; runs out mid-call → recorded failure.
    @Test func deadlines() async throws {
        let clock = FakeClock()
        let stub = StubTransport(body: okBody())
        let ctx = context(clock: clock, deadlineMs: 100)
        clock.advance(ms: 100)
        await expectCode(.deadlineExceeded) { _ = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: ctx) }
        #expect(stub.count == 0)

        let clock2 = FakeClock()
        let hang = StubTransport { _, _ in
            try await Task.sleep(nanoseconds: 10_000_000_000)
            return HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let ledger = InMemoryAiCallLedger()
        let ctx2 = context(clock: clock2, deadlineMs: 3000)
        let task = Task { try await service(hang, ledger: ledger, clock: clock2).infer(screenshotRequest(), resolvedModel: model(), context: ctx2) }
        await clock2.waitForSleeper(at: ctx2.deadlineMonotonicNanoseconds)
        clock2.advance(ms: 3000)
        do { _ = try await task.value; Issue.record("expected deadline") } catch let e as ContractError {
            #expect(e.code == .deadlineExceeded)
        }
        #expect(await ledger.records().first?.state == .failed)
    }

    // USG-001 (audit): no ledger row → no call; a lost finish → stop.
    @Test func usg001_auditFailuresStopProgress() async throws {
        let clock = FakeClock()
        let stub = StubTransport(body: okBody())
        let ledger = InMemoryAiCallLedger()
        let svc = service(stub, ledger: ledger, clock: clock)
        await ledger.setFailReserve(true)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock)) }
        #expect(stub.count == 0)
        await ledger.setFailReserve(false)
        await ledger.setFailFinish(true)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock)) }
        #expect(stub.count == 1)
        await ledger.setFailFinish(false)
        await expectCode(.auditUnavailable) { _ = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock)) }
        #expect(stub.count == 1, "after an unrecorded call, no further call starts until recovery")
    }

    // SEC-002 (resolver side): revoked or missing credentials stop before any
    // network or ledger traffic; nothing falls back to another key.
    @Test func credentialsMustResolve() async throws {
        let clock = FakeClock()
        let stub = StubTransport(body: okBody())
        let ledger = InMemoryAiCallLedger()
        await expectCode(.credentialRevoked) {
            _ = try await service(stub, ledger: ledger, credentials: TestCredentials(revoked: ["cred-1"]), clock: clock)
                .infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
        }
        await expectCode(.credentialRequired) {
            _ = try await service(stub, ledger: ledger, credentials: TestCredentials(keys: [:]), clock: clock)
                .infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock))
        }
        #expect(stub.count == 0)
        #expect(await ledger.allRows().isEmpty)
    }

    @Test func disabledConnectionIsRefused() async throws {
        let clock = FakeClock()
        let stub = StubTransport(body: okBody())
        var m = model()
        m = AiResolvedModel(connection: AiConnectionSnapshot(connectionId: "c", revision: 1, name: "x", apiProtocol: .openaiChat,
                                                             baseUrl: m.connection.baseUrl, credentialIdentityRef: "cred-1",
                                                             timeoutMs: 1000, state: .disabled),
                            model: m.model, authorizationScopeRef: "a", dataScopeRef: "d")
        await expectCode(.resourceDisabled) { _ = try await service(stub, clock: clock).infer(screenshotRequest(), resolvedModel: m, context: context(clock: clock)) }
        #expect(stub.count == 0)
    }

    // The canary key appears only in the Authorization header: never in
    // records, errors or summaries.
    @Test func canaryStaysInTheAuthorizationHeader() async throws {
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        let statuses = [200, 401, 429, 500]
        let i = Locked(0)
        let stub = StubTransport { _, _ in
            let s = statuses[i.with { v -> Int in defer { v += 1 }; return v } % statuses.count]
            return HTTPResult(status: s, body: Data((s == 200 ? okBody() : #"{"error":{"message":"bad key \#(canaryKey)"}}"#).utf8))
        }
        let svc = service(stub, ledger: ledger, clock: clock)
        var texts: [String] = []
        for _ in statuses {
            do { _ = try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock)) }
            catch { texts.append(String(reflecting: error)) }
        }
        for r in await ledger.records() { texts.append(String(reflecting: r)) }
        texts.append(UsageSummaryBuilder.summarize(await ledger.records(), from: .distantPast, to: .distantFuture).encoded())
        #expect(texts.count == 3 + 4 + 1)
        #expect(texts.allSatisfy { !$0.contains(canaryKey) })
        #expect(stub.captured.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer \(canaryKey)" })
        #expect(stub.captured.allSatisfy { !String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains(canaryKey) })
    }

    // Diagnostics share the same path but stay an operation, not a GUI run.
    @Test func capabilityTestPurpose() async throws {
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        let ctx = AiCallContext(inferenceAttemptId: "att-diag",
                                purpose: .capabilityTest(CapabilityTestCallPurpose(operationId: "op-1", level: .imageInput,
                                    syntheticSnapshotId: "synthetic-1", fixtureId: "fx-1", guiProfileId: "gp-1", guiProfileRevision: 2)),
                                callerScopeRef: "caller", budgetScopeRef: "op-1",
                                deadlineMonotonicNanoseconds: clock.ms(10_000))
        _ = try await service(StubTransport(body: okBody()), ledger: ledger, clock: clock).infer(screenshotRequest(), resolvedModel: model(), context: ctx)
        let rec = try #require(await ledger.records().first)
        #expect(rec.context.purpose.persistedName == "capability_test")
        #expect(rec.context.purpose.runId == nil && rec.context.purpose.operationId == "op-1")
    }
}
