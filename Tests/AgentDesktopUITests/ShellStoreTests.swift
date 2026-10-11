import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopUI

struct FastClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 2_000_000) }
}

/// A clock that never fires: the poll loop stays idle, so a test sees only
/// the calls it makes.
struct StillClock: PollClock {
    func pause(milliseconds: Int) async throws { try await Task.sleep(nanoseconds: 3_600_000_000_000) }
}

/// Holds chosen methods until the test releases them, in any order.
final class GatedRuntime: RuntimePort, @unchecked Sendable {
    let inner: MockRuntime
    let gated: Set<String>
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    var isSample: Bool { inner.isSample }

    init(_ inner: MockRuntime, gated: Set<String>) {
        self.inner = inner
        self.gated = gated
    }

    var waitingCount: Int { lock.withLock { waiting.count } }

    /// Let the i-th waiting call (in arrival order) go on.
    func release(_ i: Int) {
        let c = lock.withLock { waiting.remove(at: i) }
        c.resume()
    }

    func call(_ method: String, _ params: JSONValue, context: RequestContext) async throws -> JSONValue {
        // Read before waiting: the answer reflects the moment of the call.
        let answer: Result<JSONValue, Error>
        do { answer = .success(try await inner.call(method, params, context: context)) } catch { answer = .failure(error) }
        if gated.contains(method) {
            await withCheckedContinuation { c in lock.withLock { waiting.append(c) } }
        }
        return try answer.get()
    }

    func subscribe(after: Int?) async throws -> AsyncThrowingStream<JSONValue, Error> {
        try await inner.subscribe(after: after)
    }
}

@MainActor
func waitFor(_ what: String, _ check: () -> Bool) async {
    for _ in 0..<400 {
        if check() { return }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    Issue.record("timed out waiting for \(what)")
}

@MainActor
@Suite("Shell store", .serialized)
struct ShellStoreTests {
    @Test func startsWithOneUpdateSourcePerKind() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        #expect(store.connection == .connected(instanceId: "rt_mock", productVersion: RuntimeAPI.productVersion))
        #expect(store.desktops.count == 3)
        #expect(store.desktopsState == .loaded)
        #expect(store.runsState == .loaded)
        #expect(store.activeRuns.count == 2)
        #expect(store.runUpdates == .subscription)
        #expect(store.desktopUpdates == .polling)
        #expect(store.isSample)
        store.stop()

        let p = MockRuntime.sample()
        p.subscriptionEnabled = false
        let polled = ShellStore(runtime: p, clock: StillClock())
        await polled.start()
        #expect(polled.runUpdates == .polling)
        #expect(!p.callLog.contains("events.subscribe"))
        polled.stop()
    }

    // An answer from a replaced Runtime source is discarded.
    @Test func dropsAnswersFromAnOldGeneration() async {
        let old = MockRuntime.sample()
        let gated = GatedRuntime(old, gated: ["desktop.list"])
        let store = ShellStore(runtime: gated, clock: StillClock())
        let pending = Task { await store.refreshDesktops() }
        await waitFor("old desktop.list in flight") { gated.waitingCount == 1 }
        let fresh = MockRuntime()
        await store.switchRuntime(fresh)
        #expect(store.generation == 1)
        #expect(store.desktopsState == .empty)
        gated.release(0)
        await pending.value
        #expect(store.desktops.isEmpty, "old source's three Desktops must not appear")
        #expect(store.desktopsState == .empty)
        store.stop()
    }

    // Within one source, the latest request wins even if it answers first.
    @Test func lastRequestWins() async {
        let m = MockRuntime()
        m.addDesktop(name: "A")
        let gated = GatedRuntime(m, gated: ["desktop.list"])
        let store = ShellStore(runtime: gated, clock: StillClock())
        let first = Task { await store.refreshDesktops() }
        await waitFor("first in flight") { gated.waitingCount == 1 }
        m.addDesktop(name: "B")
        let second = Task { await store.refreshDesktops() }
        await waitFor("second in flight") { gated.waitingCount == 2 }
        gated.release(1)
        await second.value
        #expect(store.desktops.count == 2)
        gated.release(0)
        await first.value
        #expect(store.desktops.count == 2, "the older answer (one Desktop) is dropped")
    }

    // A failed refresh keeps the last good data and its time; a lost
    // Runtime shows Disconnected, never sample data in its place.
    @Test func failuresKeepLastGoodData() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        store.stop()
        let synced = store.desktopsSyncedAt
        m.failNext("desktop.list", code: "internal_error")
        await store.refreshDesktops()
        #expect(store.desktops.count == 3)
        #expect(store.desktopsSyncedAt == synced)
        if case .failed(let p) = store.desktopsState { #expect(p.code == "internal_error") } else { Issue.record("not failed") }
        m.offline = true
        await store.refreshDesktops()
        if case .disconnected(let p) = store.desktopsState { #expect(p.code == "runtime_offline") } else { Issue.record("not disconnected") }
        #expect(store.desktops.count == 3)
    }

    @Test func offlineAtStart() async {
        let m = MockRuntime()
        m.offline = true
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        guard case .disconnected(let p) = store.connection else { Issue.record("connected"); return }
        #expect(p.code == "runtime_offline")
        #expect(store.desktopsState == .disconnected(p))
        #expect(store.runUpdates == .none)
    }

    // Run events update the list from run.show; stopping the Store ends the
    // stream and changes no Run.
    @Test func followsEventsAndStopsCleanly() async throws {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.start()
        await waitFor("subscribed") { m.subscriberCount == 1 }
        let desk = store.desktops[2]["desktopId"]!.stringValue!
        let id = m.addRun(desktopId: desk)
        await waitFor("new run arrives") { store.runs.contains { $0["runId"]?.stringValue == id } }
        let active = store.activeRuns.first { $0["runId"]?.stringValue == id }!
        _ = try await m.call("run.cancel", .obj([("runId", .string(id))]))
        await waitFor("stopping shown") {
            store.runs.first { $0["runId"]?.stringValue == id }?["phase"]?.stringValue == "stopping"
        }
        #expect(RunStatusPresentation.make(run: store.runs.first { $0["runId"]?.stringValue == id }!).text == "停止中")
        m.confirmQuiescence(id)
        await waitFor("ended shown") {
            store.runs.first { $0["runId"]?.stringValue == id }?["phase"]?.stringValue == "ended"
        }
        #expect(active["phase"]?.stringValue == "running")

        let before = try await m.call("run.list", .obj([("active", .bool(true))]))
        store.stop()
        await waitFor("unsubscribed") { m.subscriberCount == 0 }
        let after = try await m.call("run.list", .obj([("active", .bool(true))]))
        #expect(before == after, "closing the view changes no Run (ADR-02)")
    }

    // Past the stored events: read run.list, then follow from now.
    @Test func expiredCursorFallsBackToSnapshot() async {
        let m = MockRuntime.sample()
        let store = ShellStore(runtime: m, clock: StillClock())
        await store.apply(frame: .obj([("cursor", .int(1)), ("event", .obj([]))]))
        #expect(store.eventCursor == 1)
        m.trimEvents(through: m.latestCursor)
        await store.start()
        await waitFor("resubscribed and refreshed snapshot") {
            let log = m.callLog
            guard m.subscriberCount == 1,
                  let subscription = log.firstIndex(of: "events.subscribe"),
                  let snapshot = log.lastIndex(of: "run.list") else { return false }
            return snapshot > subscription
        }
        #expect(store.eventCursor == nil)
        let log = m.callLog
        #expect(log.filter { $0 == "events.subscribe" }.count == 2)
        #expect(log.lastIndex(of: "run.list")! > log.firstIndex(of: "events.subscribe")!)
        store.stop()
    }

    @Test func pollingRefreshesDesktops() async {
        let m = MockRuntime()
        let store = ShellStore(runtime: m, clock: FastClock(), pollMs: 1)
        await store.start()
        #expect(store.desktopsState == .empty)
        m.addDesktop(name: "新")
        await waitFor("poll picks up the Desktop") { store.desktops.count == 1 }
        #expect(store.desktopsState == .loaded)
        store.stop()
    }
}
