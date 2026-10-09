import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopService

// #166: the bridge's test-only timeline. With a recorder the bridge answers
// exactly as without one; the timeline has every stage, in order, on the
// threads that ran them, and nothing of the request but its method.

private func service() async throws -> (AgentDesktopService, String) {
    let dir = NSTemporaryDirectory() + "adt-bdiag-\(UUID().uuidString.prefix(8))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let s = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir + "/ai.sqlite", credentials: InMemoryCredentialStore()))
    return (s, dir)
}

private let secretKey = "sk-bdiag-secret-not-real"
private let secretRequestId = "bdiag-request-id-0001"

private func call(_ method: String, _ params: JSONValue, requestId: String = RuntimeRequest.newId(),
                  deadline: Date? = nil) -> ExtensionCall {
    ExtensionCall(method: method, requestId: requestId, deadline: deadline, params: params, clientId: "local:\(getuid())", owner: true)
}

private let createParams: JSONValue = .obj([
    ("name", .string("Diag")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://example.invalid/v1")),
    ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string(secretKey))]))])

/// What a caller can see of an answer, without the ids that differ per service.
private func shape(_ r: Result<JSONValue, RuntimeError>) -> String {
    switch r {
    case let .success(v): return "ok " + (v.objectMembers?.map(\.0).sorted().joined(separator: ",") ?? v.encoded())
    case let .failure(e): return "error \(e.code) notSent=\(String(describing: e.notSent)) \(e.message)"
    }
}

/// Blocking: on a plain thread, never on the cooperative pool the service needs.
private func answer(_ c: ExtensionCall, _ s: AgentDesktopService, idempotent: Bool,
                    _ d: BridgeDiagnostics?) async -> Result<JSONValue, RuntimeError> {
    await withCheckedContinuation { k in
        Thread { k.resume(returning: RuntimeBridge.answer(c, service: s, idempotent: idempotent, diagnostics: d)) }.start()
    }
}

@Test func theBridgeAnswersTheSameWithAndWithoutTheTimeline() async throws {
    let (plain, d1) = try await service(), (traced, d2) = try await service()
    defer { try? FileManager.default.removeItem(atPath: d1); try? FileManager.default.removeItem(atPath: d2) }
    let recorder = BridgeDiagnostics()
    let calls: [(ExtensionCall, Bool)] = [
        (call("ai.connections.list", .obj([])), false),
        (call("ai.connections.create", createParams, requestId: secretRequestId), true),
        (call("ai.connections.list", .obj([])), false),
        (call("ai.connections.get", .obj([("connectionId", .string("conn_missing"))])), false),
    ]
    for (c, idempotent) in calls {
        let a = await answer(c, plain, idempotent: idempotent, nil)
        let b = await answer(c, traced, idempotent: idempotent, recorder)
        #expect(shape(a) == shape(b), "\(c.method)")
    }
    #expect(Set(recorder.events.map(\.call)).count == calls.count)
}

@Test func eachCallHasEveryStageInOrderOnItsThreads() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let recorder = BridgeDiagnostics()
    _ = await answer(call("ai.connections.list", .obj([])), s, idempotent: false, recorder)
    let e = Dictionary(recorder.events.map { ($0.stage, $0) }, uniquingKeysWith: { a, _ in a })
    try #require(Set(e.keys) == [.entered, .taskCreated, .waitStarted, .taskStarted, .resultReady, .answered],
                 "stages: \(e.keys.map(\.rawValue).sorted())")
    let at = { (s: BridgeDiagnostics.Stage) in e[s]?.uptimeNanos ?? 0 }
    #expect(at(.entered) <= at(.taskCreated) && at(.taskCreated) <= at(.waitStarted) && at(.waitStarted) <= at(.answered))
    #expect(at(.entered) <= at(.taskStarted) && at(.taskStarted) <= at(.resultReady) && at(.resultReady) <= at(.answered))
    #expect(e[.entered]?.sinceEnteredNanos == 0)
    // The connection thread notes its own stages; the task runs elsewhere.
    let caller = e[.entered]?.threadId ?? 0
    #expect(caller != 0 && [.taskCreated, .waitStarted, .answered].allSatisfy { e[$0]?.threadId == caller })
    #expect(e[.taskStarted]?.threadId ?? 0 != 0 && e[.taskStarted]?.taskPriority != nil)
    #expect(recorder.events.allSatisfy { $0.call == 1 && $0.method == "ai.connections.list" })
}

// A deadline already past: the wait may run out at once, or the task may
// answer first. Either way the timeline says how the wait ended, and the
// answer is the one the bridge gives without a timeline. (Which of the two
// happens is the scheduler's choice, so neither is required here; the
// timed-out order is pinned step by step in the test below.)
@Test(.timeLimit(.minutes(1))) func aWaitThatRunsOutIsTimedOutAndAnswersAsBefore() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let recorder = BridgeDiagnostics()
    for _ in 0..<20 {
        let c = call("ai.connections.list", .obj([]), deadline: Date().addingTimeInterval(-1))
        let r = await answer(c, s, idempotent: false, recorder)
        let thisCall = recorder.events.last { $0.stage == .entered }?.call
        let ended = recorder.events.first { $0.call == thisCall && ($0.stage == .answered || $0.stage == .timedOut) }
        if case let .failure(e) = r, e.code == "deadline_exceeded", e.message.contains("did not answer in time") {
            #expect(ended?.stage == .timedOut)
        } else {
            #expect(ended?.stage == .answered)
        }
    }
    // Codex on d700f37: every task the timed-out waits left behind finishes
    // before the service's directory goes (the time limit, not a clock here,
    // ends a wait that never would).
    while recorder.events.filter({ $0.stage == .resultReady }).count < 20 { try await Task.sleep(nanoseconds: 10_000_000) }
}

@Test func theTimelineHoldsNoParamsCredentialOrRequestId() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Lines: @unchecked Sendable { let lock = NSLock(); var all: [String] = [] }
    let printed = Lines()
    let recorder = BridgeDiagnostics(onEvent: { e in printed.lock.withLock { printed.all.append(e.description) } })
    _ = await answer(call("ai.connections.create", createParams, requestId: secretRequestId), s, idempotent: true, recorder)
    recorder.waitForReports()
    let text = printed.lock.withLock { printed.all }.joined(separator: "\n") + recorder.events.map(\.description).joined()
    #expect(!text.isEmpty)
    for secret in [secretKey, secretRequestId, "example.invalid", "Diag"] { #expect(!text.contains(secret), "\(secret)") }
}

// b9 and Codex on 062f5db, 53dc980, 42108c5 and d700f37: the hook runs on
// the recorder's report queue (so on neither the connection thread nor the
// task), and only for a call whose own wait has ended, even with calls in
// flight together. On that queue the hook is held until every call has
// answered, so no answer waits for it; called anywhere else it only notes
// and never blocks, so a wrong recorder fails the test instead of hanging
// it. No timeout decides anything.
@Test func theHookRunsOffTheBridgeAndOnlyForCallsWhoseWaitEnded() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // The hook touches nothing of the recorder: it notes what it got, where
    // and when (monotonic), and the checks come after.
    final class Seen: @unchecked Sendable {
        let lock = NSLock(); var got: [(event: BridgeDiagnostics.Event, at: UInt64, onQueue: Bool)] = []
    }
    let seen = Seen()
    let allAnswered = DispatchSemaphore(value: 0)
    let recorder = BridgeDiagnostics(onEvent: { e in
        let onQueue = BridgeDiagnostics.onReportQueue
        seen.lock.withLock { seen.got.append((e, DispatchTime.now().uptimeNanoseconds, onQueue)) }
        guard onQueue else { return }
        allAnswered.wait()
        allAnswered.signal()
    })
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { _ = await answer(call("ai.connections.list", .obj([])), s, idempotent: false, recorder) } }
    }
    allAnswered.signal()
    recorder.waitForReports()
    let got = seen.lock.withLock { seen.got }
    #expect(got.allSatisfy { $0.onQueue })
    #expect(got.count == 8 * 6)
    let noted = recorder.events
    for c in Set(noted.map(\.call)) {
        let ended = noted.first { $0.call == c && ($0.stage == .answered || $0.stage == .timedOut) }?.uptimeNanos ?? .max
        let mine = got.filter { $0.event.call == c }
        // Handed on only once the call's own wait had ended...
        #expect(mine.allSatisfy { $0.at >= ended }, "call \(c)")
        // ...and in the order they were noted.
        #expect(mine.map(\.event.stage) == noted.filter { $0.call == c }.map(\.stage))
    }
}

// Codex on a756034, b9 on d700f37: a call's stages are held until its own
// wait ends, and those that come later (a timed-out call's task) reach the
// hook after `timedOut`, in the order they were noted. Driven step by step:
// no scheduling decides it.
@Test func stagesAreHeldUntilTheWaitEndsAndLateOnesFollowIt() {
    final class Got: @unchecked Sendable { let lock = NSLock(); var stages: [BridgeDiagnostics.Stage] = [] }
    let got = Got()
    let recorder = BridgeDiagnostics(onEvent: { e in got.lock.withLock { got.stages.append(e.stage) } })
    let trace = recorder.begin(method: "ai.connections.list")
    trace.note(.taskCreated)
    trace.note(.waitStarted)
    recorder.waitForReports()
    #expect(got.lock.withLock { got.stages }.isEmpty)
    trace.note(.timedOut)
    trace.noteInTask(.taskStarted, taskPriority: 21)
    trace.noteInTask(.resultReady)
    recorder.waitForReports()
    #expect(got.lock.withLock { got.stages } == [.entered, .taskCreated, .waitStarted, .timedOut, .taskStarted, .resultReady])
}
