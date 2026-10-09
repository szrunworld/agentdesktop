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
    case let .failure(e): return "error \(e.code) notSent=\(e.notSent) \(e.message)"
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

// A deadline already past: the wait ends at once. The timeline says how it
// ended, and the answer is the one the bridge gives without a timeline.
@Test func aWaitThatRunsOutIsTimedOutAndAnswersAsBefore() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    var timedOut = 0
    for _ in 0..<20 {
        let recorder = BridgeDiagnostics()
        let c = call("ai.connections.list", .obj([]), deadline: Date().addingTimeInterval(-1))
        let r = await answer(c, s, idempotent: false, recorder)
        let ended = recorder.events.first { $0.stage == .answered || $0.stage == .timedOut }
        if case let .failure(e) = r, e.code == "deadline_exceeded", e.message.contains("did not answer in time") {
            #expect(ended?.stage == .timedOut)
            timedOut += 1
        } else {
            #expect(ended?.stage == .answered)
        }
    }
    #expect(timedOut > 0, "a wait with no time left never ran out")
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

// b9 and Codex on 062f5db, 53dc980 and 42108c5: the hook runs on neither
// the connection thread nor the task, and only for a call whose own wait
// has ended, even with calls in flight together. Here the hook blocks until
// every call has answered: were it on the reply path, no call could answer
// and the hook's wait would run out.
@Test func theHookRunsOffTheBridgeAndOnlyForCallsWhoseWaitEnded() async throws {
    let (s, dir) = try await service()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    final class Seen: @unchecked Sendable {
        let lock = NSLock(); var threads: Set<UInt64> = []; var events: [BridgeDiagnostics.Event] = []
        var beforeTheWaitEnded = 0; var hookWaitRanOut = 0; weak var recorder: BridgeDiagnostics?
    }
    let seen = Seen()
    let allAnswered = DispatchSemaphore(value: 0)
    let recorder = BridgeDiagnostics(onEvent: { e in
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        let ended = seen.recorder?.events.contains { $0.call == e.call && ($0.stage == .answered || $0.stage == .timedOut) } ?? false
        seen.lock.withLock { seen.threads.insert(tid); seen.events.append(e); if !ended { seen.beforeTheWaitEnded += 1 } }
        if allAnswered.wait(timeout: .now() + 3) == .timedOut { seen.lock.withLock { seen.hookWaitRanOut += 1 } }
        allAnswered.signal()
    })
    seen.recorder = recorder
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 { group.addTask { _ = await answer(call("ai.connections.list", .obj([])), s, idempotent: false, recorder) } }
    }
    allAnswered.signal()
    recorder.waitForReports()
    let bridgeThreads = Set(recorder.events.map(\.threadId))
    let got = seen.lock.withLock { (seen.threads, seen.events, seen.beforeTheWaitEnded, seen.hookWaitRanOut) }
    #expect(got.3 == 0, "the hook held up an answer")
    #expect(got.0.isDisjoint(with: bridgeThreads))
    #expect(got.2 == 0)
    #expect(got.1.count == 8 * 6)
    // Each call's stages are handed on in the order they were noted.
    for c in Set(got.1.map(\.call)) {
        let mine = got.1.filter { $0.call == c }.map(\.stage)
        #expect(mine == recorder.events.filter { $0.call == c }.map(\.stage))
    }
}
