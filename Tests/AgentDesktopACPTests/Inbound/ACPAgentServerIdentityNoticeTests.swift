import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// The placeholder-identity notice describes the current connection: it is
/// never part of the stored conversation, and a load shows it exactly once.
@Suite struct ACPAgentServerIdentityNoticeTests {
    private func count(_ h: STestHarness, _ sid: String) -> Int {
        h.connection.updatesFor(sid).filter {
            if case let .agentMessage(t) = $0 { return t.hasPrefix(ACPAgentServer.identityNoticePrefix) }
            return false
        }.count
    }

    /// Lane Q's L2 finding: with a slow Runtime the editor's first prompt
    /// opens a turn before the notice after session/new goes out; the
    /// notice was then recorded and a load showed it twice.
    @Test func loadShowsTheNoticeExactlyOnce() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        rt.tasksDelay.with { $0 = .milliseconds(150) }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go") // before the notice after session/new is sent
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        #expect(await sEventually { count(h, sid) == 1 })
        rt.end("run-1")
        _ = await h.connection.waitReply(p)
        #expect(try !h.store.history(sessionId: sid).contains { $0.text.contains("身份说明") })
        h.connection.close()
        await h.runTask.value

        rt.tasksDelay.with { $0 = .zero }
        let h2 = STestHarness(runtime: rt, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not loaded"); return }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(count(h2, sid) == 1)
        // The conversation itself is still replayed.
        #expect(h2.connection.updatesFor(sid).contains(.userMessage(ACPAgentServer.userInputPlaceholder)))
    }

    /// A history written before this fix may hold the notice; a load
    /// still shows it once.
    @Test func anOldStoredNoticeIsNotReplayedAgain() async throws {
        let h = STestHarness()
        defer { h.cleanup() }
        let sid = await h.newSession()
        try h.store.appendHistory(sessionId: sid, [
            ACPSessionManagerHistoryEntry(kind: .user, text: "hi", at: "t"),
            ACPSessionManagerHistoryEntry(kind: .agent, text: ACPAgentServer.identityNoticePrefix + "old", at: "t"),
        ])
        h.connection.close()
        await h.runTask.value
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(1)
        #expect(h2.connection.updatesBeforeReply(1, sid).contains(.userMessage(ACPAgentServer.userInputPlaceholder)))
        let before = h2.connection.updatesBeforeReply(1, sid).filter {
            if case let .agentMessage(t) = $0 { return t.hasPrefix(ACPAgentServer.identityNoticePrefix) }
            return false
        }
        #expect(before.count == 1)
        #expect(!before.contains(.agentMessage(ACPAgentServer.identityNoticePrefix + "old")))
    }

    /// Verified callers (after PR2b) get no notice at all.
    @Test func verifiedCallerHasNoNoticeOnLoad() async throws {
        let rt = STestRuntime()
        rt.callerValue.with { $0 = ACPCaller(principalId: "alice", clientId: "e", connectionId: "c", verified: true) }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        h.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h.connection.waitReply(1)
        #expect(count(h, sid) == 0)
    }
}
