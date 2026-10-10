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
    let refuse: String?
    init(refuse: String? = nil) { self.refuse = refuse }
    func record(_ type: String, _ data: JSONValue) -> Bool { type != refuse }
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
    let lock = NSLock()
    var stop: (@Sendable () -> Void)?
    var fired = false
    func fire() {
        let s: (@Sendable () -> Void)? = lock.withLock { guard !fired else { return nil }; fired = true; return stop }
        s?()
    }
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
    return UnitRunService(resolver: ConfigBindingResolver(store: h.store, codecs: codecs),
                          ports: GuiExplorerPorts(observation: observation, execution: h.executor, audit: h.audit),
                          features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]),
                          aiService: h.ai, codecs: codecs, clock: h.clock)
}

func startUnit(_ units: UnitRunService, _ sink: StopTestSink, runId: String) async throws -> @Sendable () -> Void {
    let plan = try await units.admit(params: unitParams(), callerScope: "owner").get()
    return units.start(plan, context: UnitRunContext(runId: runId, sessionId: "sess-a", desktopId: "desk-a", bindingEpoch: 1,
                                                     callerScope: "owner", params: unitParams()), sink: sink)
}

@Suite("unit Run stops and record failures")
struct UnitStopTests {
    // A stop accepted while the explorer observes: no model call follows,
    // and the Run reports cancelled.
    @Test func aStopAcceptedDuringObservationStartsNoModelCall() async throws {
        let h = try GuiHarness([click(200, 100), typeText("Ada"), click(200, 300)])
        try await h.setUpProfile()
        let box = StopBox()
        let units = stopTestService(h, observation: HookedObservation(inner: h.observation, hook: { box.fire() }))
        let sink = StopTestSink()
        let stop = try await startUnit(units, sink, runId: "run-stop-1")
        box.lock.withLock { box.stop = stop }
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
        stop()
        await h.executor.release()
        await units.task(for: "run-input-1")?.value
        #expect(await h.executor.executed.count == 1)
        #expect(h.ai.callCount == 1)
        #expect(sink.ending == .cancelled)
    }
}
