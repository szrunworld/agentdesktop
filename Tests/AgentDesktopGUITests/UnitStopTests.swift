import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopGUI

// Codex on 8bcb18c: a stop the Runtime accepted, or a record it could not
// write, must keep the next model call from starting — at once, not when
// the lifecycle actor hears of it.

/// The Runtime's side for these tests: records, can refuse one event type.
final class StopTestSink: UnitRunSink, @unchecked Sendable {
    private let lock = NSLock()
    private var ended: UnitRunEnding?
    private var recorded: [JSONValue] = []
    let refuse: String?
    init(refuse: String? = nil) { self.refuse = refuse }
    func record(_ type: String, _ data: JSONValue) -> Bool {
        guard type != refuse else { return false }
        lock.withLock { recorded.append(.obj([("type", .string(type)), ("data", data)])) }
        return true
    }
    var events: [JSONValue] { lock.withLock { recorded } }
    func verified(status: String, observationId: String?, checkedAt: Date) {}
    func finished(_ ending: UnitRunEnding) { lock.withLock { ended = ending } }
    var ending: UnitRunEnding? { lock.withLock { ended } }
}

/// The spy observation, with a hook that runs inside each observe.
struct HookedObservation: GuiObservationPort {
    let inner: SpyObservation
    let hook: @Sendable () -> Void
    func observe(runId: String, expectedGeneration: UInt64) async throws -> ObservationBundle {
        let b = try await inner.observe(runId: runId, expectedGeneration: expectedGeneration)
        hook()
        return b
    }
}

final class StopBox: @unchecked Sendable {
    let handle = UnitRunStopHandle()
    func fire() { handle.stop() }
}

func unitParams() -> JSONValue {
    .obj([
        ("desktopId", .string("desk-a")), ("mode", .string("explore")), ("goal", .obj([("description", .string(GuiHarness.goal))])),
        ("verification", .obj([("all", .array([.obj([("kind", .string("element_text_equals")), ("role", .string("static_text")),
                                                     ("text", .string(GuiHarness.expected))])]))])),
        ("allowedActions", .array([.string("click"), .string("type")])),
    ])
}

func stopTestService(_ h: GuiHarness, observation: GuiObservationPort) -> UnitRunService {
    let codecs = GuiCodecRegistry()
    return UnitRunService(resolver: ConfigBindingResolver(store: h.store, codecs: codecs), evidence: h.evidence,
                          ports: GuiExplorerPorts(observation: observation, execution: h.executor, audit: h.audit),
                          features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]),
                          aiService: h.ai, codecs: codecs, clock: h.clock)
}

@discardableResult
func startUnit(_ units: UnitRunService, _ sink: StopTestSink, runId: String,
               stop: UnitRunStopHandle = UnitRunStopHandle()) async throws -> UnitRunStopHandle {
    let plan = try await units.admit(params: unitParams(), callerScope: "owner").get()
    units.start(plan, context: UnitRunContext(runId: runId, sessionId: "sess-a", desktopId: "desk-a", bindingEpoch: 1,
                                              callerScope: "owner", params: unitParams()), sink: sink, stop: stop)
    return stop
}

@Suite("unit Run stops and record failures")
struct UnitStopTests {
    // Codex on 25f29ff: a stop the Runtime accepted before the executor
    // started reaches it as it arms: nothing of the Run runs.
    @Test func aStopAcceptedBeforeStartRunsNothing() async throws {
        let h = try GuiHarness([click(200, 100)])
        try await h.setUpProfile()
        let units = stopTestService(h, observation: h.observation)
        let handle = UnitRunStopHandle()
        handle.stop()
        let sink = StopTestSink()
        try await startUnit(units, sink, runId: "run-early-1", stop: handle)
        await units.task(for: "run-early-1")?.value
        #expect(h.ai.callCount == 0)
        #expect(await h.observation.count == 0)
        #expect(sink.ending == .cancelled)
    }

    // Codex on 70f4a4e: model calls that failed with no receipt still show
    // on the Run, with how many went out.
    @Test func failedModelCallsAreCountedOnTheRun() async throws {
        let transient = StubAiService.Reply.error(ContractError(.upstreamUnavailable, "503"))
        let h = try GuiHarness([transient, transient])
        try await h.setUpProfile()
        let units = stopTestService(h, observation: h.observation)
        let sink = StopTestSink()
        try await startUnit(units, sink, runId: "run-503-1")
        await units.task(for: "run-503-1")?.value
        #expect(h.ai.callCount == 2)
        let attempts = sink.events.filter { $0["type"]?.stringValue == "unit.inference.attempt" }
        #expect(attempts.compactMap { $0["data"]?["attempts"]?.intValue }.reduce(0, +) == 2)
        #expect(attempts.last?["data"]?["state"]?.stringValue == "failed")
        #expect(sink.ending == .failed(reason: "upstream_unavailable"))
        for e in attempts {
            let full = e.setting("runId", .string("run-503-1")).setting("sequence", .int(1)).setting("at", .string("2026-10-10T00:00:00Z"))
            #expect(RuntimeContract.shared.validate(full, "UnitRunEvent").isEmpty, "\(e.encoded())")
        }
    }

    // Codex on 25f29ff: the profile is resolved before the action,
    // predicate and mode checks (F40-06 order).
    @Test func theProfileIsCheckedFirst() async throws {
        let h = try GuiHarness([])
        let units = stopTestService(h, observation: h.observation)
        let both = unitParams().setting("allowedActions", .array([.string("click")])).setting("mode", .string("replay_only"))
        guard case let .failure(e) = await units.admit(params: both, callerScope: "owner") else { Issue.record("must refuse"); return }
        #expect(e.code == "not_found" && e.details?["reason"]?.stringValue == "no_default_gui_profile")
    }

    // A stop accepted while the explorer observes: no model call follows,
    // and the Run reports cancelled.
    @Test func aStopAcceptedDuringObservationStartsNoModelCall() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let box = StopBox()
        let units = stopTestService(h, observation: HookedObservation(inner: h.observation, hook: { box.fire() }))
        let sink = StopTestSink()
        try await startUnit(units, sink, runId: "run-stop-1", stop: box.handle)
        await units.task(for: "run-stop-1")?.value
        #expect(h.ai.callCount == 0, "the stop was accepted before the first model call")
        #expect(await h.executor.executed.isEmpty)
        #expect(sink.ending == .cancelled)
    }

    // A unit.progress the Runtime could not write stops the step before its
    // model call (the record is incomplete).
    @Test func aProgressEventThatWasNotWrittenStopsBeforeTheModelCall() async throws {
        let h = try GuiHarness([click(200, 100)])
        try await h.setUpProfile()
        let units = stopTestService(h, observation: h.observation)
        let sink = StopTestSink(refuse: "unit.progress")
        _ = try await startUnit(units, sink, runId: "run-progress-1")
        await units.task(for: "run-progress-1")?.value
        #expect(h.ai.callCount == 0)
        #expect(sink.ending == .failed(reason: "audit_unavailable"))
    }

    // A stop while an input is out lets it finish (its receipt is awaited)
    // and starts nothing after it.
    @Test func aStopDuringInputWaitsForItAndStartsNothingAfter() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada")])
        try await h.setUpProfile()
        await h.executor.set(mode: .hang)
        let units = stopTestService(h, observation: h.observation)
        let sink = StopTestSink()
        let stop = try await startUnit(units, sink, runId: "run-input-1")
        await eventually("the input") { await h.executor.isHanging }
        stop.stop()
        await h.executor.release()
        await units.task(for: "run-input-1")?.value
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
        #expect(sink.ending == .cancelled)
    }
}

// Codex on 073b96f: a Run that ends at once (stopped before it started)
// leaves no task behind in the long-lived service.
@Test func aRunThatEndsAtOnceLeavesNoTask() async throws {
    let h = try GuiHarness([])
    try await h.setUpProfile()
    let units = stopTestService(h, observation: h.observation)
    for i in 0..<20 {
        let handle = UnitRunStopHandle()
        handle.stop()
        try await startUnit(units, StopTestSink(), runId: "run-fast-\(i)", stop: handle)
    }
    await eventually("every task cleaned up") { (0..<20).allSatisfy { units.task(for: "run-fast-\($0)") == nil } }
}
