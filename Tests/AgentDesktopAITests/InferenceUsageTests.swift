import Foundation
import Testing
@testable import AgentDesktopAI
@testable import AgentDesktopContracts

@Suite("Usage and ledger")
struct InferenceUsageTests {
    func validates(_ summary: JSONValue) throws {
        let v = try ContractBundle.shared.validateRpc(summary, "ai_usage_summary_result")
        #expect(v.isEmpty, "\(v)")
    }

    // USG-001: primary failure, fallback success and a cancelled attempt are
    // three rows with unique ids; a repeated finish is not counted twice.
    @Test func usg001_everyStartedAttemptIsARow() async throws {
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        let stub = StubTransport { req, _ in
            req.url?.host == "primary.example.invalid"
                ? HTTPResult(status: 503, body: Data("{}".utf8))
                : HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let step = StepInference(service: service(stub, ledger: ledger, clock: clock), budget: AttemptBudget(), clock: clock)
        _ = try await step.run(screenshotRequest(), step: 0,
                               candidates: [model(base: "https://primary.example.invalid/v1"), model(base: "https://fallback.example.invalid/v1", credential: "cred-2")],
                               deadlineNs: clock.ms(60_000)) { _, _ in context(clock: clock) }

        let gate = Locked<CheckedContinuation<Void, Never>?>(nil)
        stub.setHandler { _, _ in
            await withCheckedContinuation { c in gate.with { $0 = c } }
            return HTTPResult(status: 200, body: Data(okBody().utf8))
        }
        let svc = service(stub, ledger: ledger, clock: clock)
        let t = Task { try await svc.infer(screenshotRequest(), resolvedModel: model(), context: context(clock: clock, step: 1)) }
        for _ in 0..<500 where gate.get() == nil { try await Task.sleep(nanoseconds: 1_000_000) }
        t.cancel()
        try await Task.sleep(nanoseconds: 10_000_000)
        gate.get()?.resume()
        _ = try? await t.value

        let rows = await ledger.records()
        #expect(rows.count == 3)
        #expect(Set(rows.map(\.context.inferenceAttemptId)).count == 3)
        #expect(rows.map(\.state) == [.failed, .succeeded, .cancelled])
        #expect(rows.allSatisfy { $0.context.purpose.runId == "run-1" && $0.target.model.revision == 2 && $0.target.connection.revision == 3 })

        // Finishing an attempt again does not add a row or a count.
        try await ledger.finish(rows[1])
        #expect(await ledger.records().count == 3)
        let summary = UsageSummaryBuilder.summarize(await ledger.records() + [rows[1]], from: .distantPast, to: .distantFuture)
        #expect(summary["inferenceAttempts"]?.intValue == 3)
        #expect(summary["confirmedActions"]?.intValue == 0, "model attempts never count as actions")
        try validates(summary)
    }

    // USG-002: known tokens add up; unknown stays null; actual model kept.
    @Test func usg002_unknownIsNotZero() async throws {
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        let bodies = [
            okBody(model: "m-a", usage: #"{"prompt_tokens":100,"completion_tokens":10}"#),
            okBody(model: "m-b", usage: #"{"prompt_tokens":200}"#),
            okBody(model: "returned-model-c", usage: nil),
        ]
        let i = Locked(0)
        let stub = StubTransport { _, _ in
            HTTPResult(status: 200, body: Data(bodies[i.with { v -> Int in defer { v += 1 }; return v }].utf8))
        }
        let svc = service(stub, ledger: ledger, clock: clock)
        for _ in bodies { _ = try await svc.infer(screenshotRequest(), resolvedModel: model(modelId: "configured-model"), context: context(clock: clock)) }
        let rows = await ledger.records()
        #expect(rows[0].usage == UsageTokens(inputTokens: 100, outputTokens: 10))
        #expect(rows[1].usage?.outputTokens == nil)
        #expect(rows[2].usage == nil)
        #expect(rows[2].actualModelId == "returned-model-c")
        #expect(rows[2].requestedModelId == "configured-model")

        let s = UsageSummaryBuilder.summarize(rows, from: .distantPast, to: .distantFuture)
        #expect(s["reportedTokens"]?["inputTokens"]?.intValue == 300)
        #expect(s["reportedTokens"]?["outputTokens"]?.intValue == 10)
        #expect(s["reportedTokens"]?["cacheWriteTokens"]?.isNull == true)
        #expect(s["attemptsMissingUsage"]?.intValue == 2)
        #expect(s["knownCostSubtotal"]?.isNull == true)
        #expect(s["costCoverage"]?.stringValue == "unknown")
        #expect(s["isFinalBill"] == .bool(false))
        try validates(s)
    }

    // USG-003: with requireReportedUsage, a call that reported none blocks the
    // next model attempt; without it, work goes on.
    @Test(arguments: [true, false])
    func usg003_requireReportedUsage(required: Bool) async throws {
        let clock = FakeClock()
        let stub = StubTransport(body: okBody(usage: nil))
        let budget = AttemptBudget(requireReportedUsage: required)
        let step = StepInference(service: service(stub, clock: clock), budget: budget, clock: clock)
        let first = try await step.run(screenshotRequest(), step: 0, candidates: [model()], deadlineNs: clock.ms(60_000)) { _, _ in context(clock: clock) }
        #expect(first.record.usage == nil, "missing usage is recorded as missing")
        if required {
            await expectCode(.usageUnavailable) {
                _ = try await step.run(screenshotRequest(), step: 1, candidates: [model()], deadlineNs: clock.ms(60_000)) { _, _ in context(clock: clock, step: 1) }
            }
            #expect(stub.count == 1)
        } else {
            _ = try await step.run(screenshotRequest(), step: 1, candidates: [model()], deadlineNs: clock.ms(60_000)) { _, _ in context(clock: clock, step: 1) }
            #expect(stub.count == 2)
        }
    }

    // USG-004: filters, estimated labels, unknown not turned into zero.
    @Test func usg004_filtersAndEstimates() async throws {
        let clock = FakeClock()
        let ledger = InMemoryAiCallLedger()
        let prices = AiPriceTable(pricingRevision: "price-2026-10", currency: "CNY",
                                  prices: ["doubao-ui-tars-actual": .init(inputPerMillion: 3, outputPerMillion: 9)])
        let stub = StubTransport { req, _ in
            HTTPResult(status: 200, body: Data((req.url?.host == "b.example.invalid" ? okBody(usage: nil) : okBody()).utf8))
        }
        let svc = service(stub, ledger: ledger, clock: clock, prices: prices)
        _ = try await svc.infer(screenshotRequest(), resolvedModel: model(base: "https://a.example.invalid/v1", connectionId: "conn-a"), context: context(clock: clock))
        let mid = clock.wallNow()
        clock.advance(ms: 60_000)
        _ = try await svc.infer(screenshotRequest(), resolvedModel: model(base: "https://b.example.invalid/v1", connectionId: "conn-b"), context: context(clock: clock))
        let rows = await ledger.records()
        #expect(rows[0].cost == CostEstimate(amount: "0.00039", currency: "CNY", source: .estimated, pricingRevision: "price-2026-10"))
        #expect(rows[1].cost == nil)

        let all = UsageSummaryBuilder.summarize(rows, from: .distantPast, to: .distantFuture)
        #expect(all["costCoverage"]?.stringValue == "partial")
        #expect(all["knownCostSubtotal"]?["source"]?.stringValue == "estimated")
        #expect(all["knownCostSubtotal"]?["amount"]?.stringValue == "0.00039")
        try validates(all)

        let onlyB = UsageSummaryBuilder.summarize(rows, from: .distantPast, to: .distantFuture, connectionId: "conn-b")
        #expect(onlyB["inferenceAttempts"]?.intValue == 1)
        #expect(onlyB["reportedTokens"]?.isNull == true)
        #expect(onlyB["costCoverage"]?.stringValue == "unknown")
        try validates(onlyB)

        let early = UsageSummaryBuilder.summarize(rows, from: .distantPast, to: mid.addingTimeInterval(1))
        #expect(early["inferenceAttempts"]?.intValue == 1)
        let empty = UsageSummaryBuilder.summarize([], from: mid, to: mid.addingTimeInterval(1))
        #expect(empty["inferenceAttempts"]?.intValue == 0)
        try validates(empty)
    }

    @Test func decimalText() {
        #expect(DecimalText.format(Decimal(string: "0.000390000")!) == "0.00039")
        #expect(DecimalText.format(Decimal(12)) == "12")
        #expect(DecimalText.format(Decimal(string: "0.1234567890123456")!) == "0.123456789012")
    }
}
