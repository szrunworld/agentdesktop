import Combine
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

/// Waits until `check` holds, re-checking after every change the Store
/// publishes (checked first in the waiting task itself, so a change between
/// the two checks is not missed). No sleeping: the only timer is the
/// failsafe that ends a hung test.
@MainActor
func until(_ what: String, _ store: ShellStore, timeout: UInt64 = 60, _ check: @escaping @MainActor () -> Bool) async {
    if check() { return }
    // Every published change, buffered (Combine's own `.values` traps when
    // a change arrives between two reads).
    let (changes, sink) = AsyncStream<Void>.makeStream()
    let subscription = store.objectWillChange.sink { _ in sink.yield() }
    defer { subscription.cancel(); sink.finish() }
    let ok = await withTaskGroup(of: Bool.self) { group in
        group.addTask { @MainActor in
            if check() { return true }
            for await _ in changes {
                // objectWillChange fires before the change; let it land.
                await Task.yield()
                if check() { return true }
            }
            return false
        }
        group.addTask {
            try? await Task.sleep(nanoseconds: timeout * 1_000_000_000)
            return false
        }
        let first = await group.next() ?? false
        group.cancelAll()
        sink.finish()
        return first
    }
    if !ok { Issue.record("timed out waiting for \(what)") }
}

/// A port over the mock that records each subscription's `after` and can
/// replace what `subscribe` does.
final class PushPort: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    private let lock = NSLock()
    private var _afters: [Int?] = []
    /// When set, `subscribe` throws it (once per entry, then the mock).
    private var _subscribeFailures: [RuntimeError] = []
    var isSample: Bool { true }

    init(_ inner: MockRuntime) { self.inner = inner }

    var afters: [Int?] { lock.withLock { _afters } }
    func failSubscribe(_ e: RuntimeError, times: Int = 1) {
        lock.withLock { _subscribeFailures += Array(repeating: e, count: times) }
    }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        try await inner.call(method, params, context: context)
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        let failure: RuntimeError? = lock.withLock {
            _afters.append(after)
            return _subscribeFailures.isEmpty ? nil : _subscribeFailures.removeFirst()
        }
        if let failure { throw failure }
        return try await inner.subscribe(after: after)
    }
}

/// Ends its first stream normally after one frame, then serves the mock.
final class EndingPort: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    private let lock = NSLock()
    private var opened = 0
    var isSample: Bool { true }
    init(_ inner: MockRuntime) { self.inner = inner }
    var subscriptions: Int { lock.withLock { opened } }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        try await inner.call(method, params, context: context)
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        let n = lock.withLock { opened += 1; return opened }
        guard n == 1 else { return try await inner.subscribe(after: after) }
        let latest = inner.latestCursor
        let frame: JSONValue = .obj([("apiVersion", .string(RuntimeAPI.version)),
                                     ("event", .obj([("runId", .string("run_001")), ("sequence", .int(99)), ("at", .string("2026-10-11T00:00:00Z")),
                                                     ("type", .string("run.progress")), ("data", .obj([]))])),
                                     ("cursor", .int(latest))])
        return AsyncThrowingStream { c in
            c.yield(frame)
            c.finish()
        }
    }
}

@MainActor
@Suite("Store push (U1b-2)", .serialized)
struct StorePushTests {
    func runIds(_ store: ShellStore) -> Set<String> { Set(store.runs.compactMap { $0["runId"]?.stringValue }) }
    func run(_ store: ShellStore, _ id: String) -> JSONValue? { store.runs.first { $0["runId"]?.stringValue == id } }

    // Runs follow pushed events; run.list is not polled while pushing.
    @Test func runsArePushedNotPolled() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: FastClock(), pollMs: 1)
        await store.start()
        await until("push live", store) { store.pushLive }
        #expect(store.runUpdates == .subscription)
        let listed = m.callLog.filter { $0 == "run.list" }.count
        let desk = store.desktops[2]["desktopId"]!.stringValue!
        let id = m.addRun(desktopId: desk)
        await until("pushed run", store) { self.run(store, id) != nil }
        _ = try await m.call("run.cancel", .obj([("runId", .string(id))]))
        await until("stopping", store) { self.run(store, id)?["phase"]?.stringValue == "stopping" }
        #expect(RunsText.phase(run(store, id)!).text == "停止中")
        m.confirmQuiescence(id)
        await until("ended", store) { self.run(store, id)?["phase"]?.stringValue == "ended" }
        // Desktops and status keep polling meanwhile; Runs never do.
        let polls = m.callLog.filter { $0 == "desktop.list" }.count
        await until("a few poll rounds", store) { m.callLog.filter { $0 == "desktop.list" }.count > polls + 3 }
        #expect(m.callLog.filter { $0 == "run.list" }.count == listed)
        #expect(store.eventCursor == m.latestCursor)
        store.stop()
        #expect(m.subscriberCount == 0, "stopping the Store ends the stream")
    }

    // The stream is lost while connected: it is opened again after the last
    // applied cursor, and what happened in between arrives.
    @Test func resumesAfterTheLastCursor() async {
        let m = MockRuntime.sample()
        let port = PushPort(m)
        let store = ShellStore(runtime: port, clock: FastClock(), pollMs: 1)
        await store.start()
        await until("push live", store) { store.pushLive }
        let desk = store.desktops[0]["desktopId"]!.stringValue!
        let first = m.addRun(desktopId: desk)
        await until("first run", store) { self.run(store, first) != nil }
        let cursor = store.eventCursor
        #expect(cursor != nil)
        m.dropSubscriptions()
        let missed = m.addRun(desktopId: desk)
        await until("missed run arrives after resume", store) { self.run(store, missed) != nil }
        #expect(port.afters.first! == nil)
        #expect(port.afters.contains(cursor), "resubscribed after the last applied cursor")
        #expect(store.runUpdates == .subscription)
        store.stop()
    }

    // Past the stored events: follow from now and take a snapshot after
    // the subscription, so nothing falls between.
    @Test func expiredCursorTakesASnapshot() async {
        let m = MockRuntime.sample()
        let port = PushPort(m)
        port.failSubscribe(RuntimeError("events_cursor_expired", "expired", phase: .handler))
        let store = ShellStore(runtime: port, clock: StillClock())
        await store.apply(frame: .obj([("cursor", .int(1)), ("event", .obj([]))]))
        await store.start()
        await until("push live", store) { store.pushLive }
        #expect(port.afters == [1, nil])
        #expect(store.eventCursor == nil)
        let log = m.callLog
        #expect(log.lastIndex(of: "run.list")! > log.firstIndex(of: "runtime.capabilities")!)
        // The snapshot after subscribing saw a Run made before it.
        #expect(store.runs.count == 3)
        store.stop()
    }

    // A Runtime that lists events.subscribe but cannot push here: Runs are
    // polled instead, and the page sees the same data.
    @Test func fallsBackToPolling() async {
        let m = MockRuntime.sample()
        let port = PushPort(m)
        port.failSubscribe(.capabilityMissing("no push here"))
        let store = ShellStore(runtime: port, clock: FastClock(), pollMs: 1)
        await store.start()
        await until("fell back", store) { store.runUpdates == .polling }
        #expect(store.pushFallback?.code == "capability_missing")
        #expect(!store.pushLive)
        let desk = store.desktops[0]["desktopId"]!.stringValue!
        let id = m.addRun(desktopId: desk)
        await until("polled run", store) { self.run(store, id) != nil }
        #expect(store.loopCount == 1, "only the poll loop is left")
        store.stop()
    }

    // The Runtime is gone when subscribing: Disconnected; when it answers
    // again the poll loop reconnects and the push resumes from the cursor.
    @Test func reconnectsAndResumes() async {
        let m = MockRuntime.sample()
        let port = PushPort(m)
        let store = ShellStore(runtime: port, clock: FastClock(), pollMs: 1)
        await store.start()
        await until("push live", store) { store.pushLive }
        let desk = store.desktops[0]["desktopId"]!.stringValue!
        let a = m.addRun(desktopId: desk)
        await until("run a", store) { self.run(store, a) != nil }
        let cursor = store.eventCursor
        m.offline = true
        m.dropSubscriptions()
        await until("disconnected", store) { if case .disconnected = store.connection { return true }; return false }
        let b = m.addRun(desktopId: desk)
        m.offline = false
        await until("reconnected and b arrived", store) { self.run(store, b) != nil }
        if case .connected = store.connection {} else { Issue.record("not connected") }
        #expect(port.afters.contains(cursor))
        #expect(store.runUpdates == .subscription)
        store.stop()
    }

    // A pushed Run that cannot be read for a transient reason is read again
    // after resubscribing from the cursor: the final state is not lost.
    @Test func aFailedReadIsRetriedFromTheCursor() async {
        let m = MockRuntime.sample()
        let port = PushPort(m)
        let store = ShellStore(runtime: port, clock: FastClock(), pollMs: 1)
        await store.start()
        await until("push live", store) { store.pushLive }
        m.failNext("run.show", code: "internal_error")
        m.confirmQuiescence("run_002")
        await until("ended after the retry", store) {
            store.runs.first { $0["runId"]?.stringValue == "run_002" }?["phase"]?.stringValue == "ended"
        }
        #expect(port.afters.count >= 2, "resubscribed after the failed read")
        #expect(store.runUpdates == .subscription)
        store.stop()
    }

    // The Runtime closed the stream on its own: it is opened again.
    @Test func reopensAStreamTheRuntimeEnded() async {
        let m = MockRuntime.sample()
        let port = EndingPort(m)
        let store = ShellStore(runtime: port, clock: StillClock())
        await store.start()
        await until("second stream", store) { port.subscriptions == 2 && store.pushLive }
        let desk = store.desktops[0]["desktopId"]!.stringValue!
        let id = m.addRun(desktopId: desk)
        await until("run on the new stream", store) { self.run(store, id) != nil }
        store.stop()
    }

    // A pushed Run read from an old source is dropped (generations), and
    // a snapshot never moves a Run back to an older revision.
    @Test func lateAnswersAreDropped() async {
        let old = MockRuntime.sample()
        let gated = GatedRuntime(old, gated: ["run.show"])
        let store = ShellStore(runtime: gated, clock: StillClock())
        let pending = Task { await store.apply(frame: .obj([("cursor", .int(50)), ("event", .obj([("runId", .string("run_002"))]))])) }
        while gated.waitingCount == 0 { await Task.yield() }
        await store.switchRuntime(MockRuntime())
        gated.release(0)
        await pending.value
        #expect(store.runs.isEmpty, "the old source's Run must not appear")
        #expect(store.eventCursor == nil, "nor its cursor")
        store.stop()

        let newer = JSONValue.obj([("runId", .string("r")), ("revision", .int(3)), ("phase", .string("stopping"))])
        let older = JSONValue.obj([("runId", .string("r")), ("revision", .int(2)), ("phase", .string("running"))])
        let other = JSONValue.obj([("runId", .string("s")), ("revision", .int(1))])
        let merged = ShellStore.merge(snapshot: [older, other], over: [newer])
        #expect(merged == [newer, other])
        #expect(ShellStore.merge(snapshot: [other], over: [newer]) == [other], "the snapshot decides what is listed")
        let id = try #require(newer["runId"]?.stringValue)
        #expect(ShellStore.merge(snapshot: [other], over: [newer], preserving: [id]) == [newer, other],
                "a Run pushed while the list was in flight survives the old snapshot")
    }

    // A frame whose Run cannot be read because the Runtime went away keeps
    // the cursor where it was, so the frame comes again.
    @Test func cursorMovesOnlyAfterTheRunIsRead() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.apply(frame: .obj([("cursor", .int(4)), ("event", .obj([("runId", .string("run_001"))]))]))
        #expect(store.eventCursor == 4)
        m.offline = true
        await store.apply(frame: .obj([("cursor", .int(5)), ("event", .obj([("runId", .string("run_001"))]))]))
        #expect(store.eventCursor == 4)
        m.offline = false
        // Any other failed read keeps the cursor too (the frame comes again).
        m.failNext("run.show", code: "internal_error")
        await store.apply(frame: .obj([("cursor", .int(5)), ("event", .obj([("runId", .string("run_001"))]))]))
        #expect(store.eventCursor == 4)
        // A Run that is gone is skipped and the cursor moves on.
        await store.apply(frame: .obj([("cursor", .int(6)), ("event", .obj([("runId", .string("run_gone"))]))]))
        #expect(store.eventCursor == 6)
    }
}

@Suite("Pulled event stream")
struct PulledEventStreamTests {
    final class Source: @unchecked Sendable {
        let lock = NSLock()
        var batches: [[JSONValue]?]
        var pulls = 0
        var closes = 0
        init(_ b: [[JSONValue]?]) { batches = b }
        func pull() -> [JSONValue]? {
            lock.withLock {
                pulls += 1
                return batches.isEmpty ? [] : batches.removeFirst()
            }
        }
        func close() { lock.withLock { closes += 1 } }
    }

    static func frame(_ c: Int) -> JSONValue { .obj([("cursor", .int(c))]) }

    @Test func handsOnFramesAndEndsWhenTheSubscriptionEnds() async throws {
        let s = Source([[Self.frame(1), Self.frame(2)], [], [Self.frame(3)], nil])
        let stream = PulledEventStream.make(intervalMs: 1, clock: FastClock(), pull: { s.pull() }, close: { s.close() })
        var got: [Int] = []
        for try await f in stream { got.append(f["cursor"]!.intValue!) }
        #expect(got == [1, 2, 3])
        #expect(s.closes == 1)
    }

    @Test func readerStoppingClosesOnce() async throws {
        let s = Source([[Self.frame(1)]])
        let (seen, seenCont) = AsyncStream<Void>.makeStream()
        // The Store reads in a Task and cancels it when it stops.
        let reader = Task {
            let stream = PulledEventStream.make(intervalMs: 1, clock: FastClock(), pull: { s.pull() }, close: { s.close() })
            for try await _ in stream { seenCont.yield() }
        }
        for await _ in seen { break }
        reader.cancel()
        _ = await reader.result
        #expect(s.closes == 1)
        let pulls = s.lock.withLock { s.pulls }
        try await FastClock().pause(milliseconds: 1)
        try await FastClock().pause(milliseconds: 1)
        #expect(s.lock.withLock { s.pulls } <= pulls + 1, "taking stops with the reader")
    }

    @Test func aFailedPullEndsTheStreamWithItsError() async {
        let stream = PulledEventStream.make(intervalMs: 1, clock: FastClock(),
                                            pull: { throw RuntimeError("connection_lost", "gone", phase: .transport) },
                                            close: {})
        do {
            for try await _ in stream {}
            Issue.record("no error")
        } catch let e as RuntimeError {
            #expect(e.code == "connection_lost")
        } catch { Issue.record("other error") }
    }
}
