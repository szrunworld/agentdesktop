import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// Round 2: replay flag, cwd filters, restart-safe submission keys,
/// decline, caller honesty, ACPRedactor and the per-session projector.
@Suite struct ACPAgentServerResumeTests {
    private func stop(_ r: ACPReply?) -> ACPStopReason? {
        if case let .promptFinished(s)? = r { return s }
        return nil
    }

    /// A stored session with one ended Run (events 1, 2) and one open Run
    /// (events 1, 2 so far).
    private func seeded() async throws -> (STestHarness, String) {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        let sid = await h.newSession()
        rt.addRun("old")
        rt.emit("old", cursor: 1, text: "old-1")
        rt.emit("old", cursor: 2, text: "old-2")
        rt.end("old")
        rt.addRun("open")
        rt.emit("open", cursor: 1, text: "open-1")
        rt.emit("open", cursor: 2, text: "open-2")
        var b = try #require(try h.store.load(sessionId: sid))
        b.runIds = ["old", "open"]; b.revision += 1
        try h.store.save(b)
        h.connection.close()
        await h.runTask.value
        return (h, sid)
    }

    @Test func replayTrueStreamsHistoryBeforeTheAnswerAndLiveAfter() async throws {
        let (h, sid) = try await seeded()
        defer { h.cleanup() }
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        let before = h2.connection.updatesBeforeReply(1, sid).compactMap { u -> String? in
            if case let .agentMessage(t) = u, t.hasPrefix("[") { return t }; return nil
        }
        // History of both Runs, up to the open Run's lastCursor, came first.
        #expect(before == ["[old#1] old-1", "[old#2] old-2", "[open#1] open-1", "[open#2] open-2"])
        h.runtime.emit("open", cursor: 3, text: "open-3")
        #expect(await sEventually { h2.connection.allText(sid).contains("[open#3] open-3") })
        #expect(h2.connection.messages(sid).filter { $0.hasPrefix("[open#2]") }.count == 1)
        #expect(h.runtime.submitCount == 0)
    }

    @Test func replayFalseSendsNoHistoryButFollowsLiveEvents() async throws {
        let (h, sid) = try await seeded()
        defer { h.cleanup() }
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: false))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        // Rebound to this connection.
        #expect(try h.store.load(sessionId: sid)?.clientId == "editor-1")
        h.runtime.emit("open", cursor: 3, text: "open-3")
        #expect(await sEventually { h2.connection.allText(sid).contains("[open#3] open-3") })
        let text = h2.connection.allText(sid)
        #expect(!text.contains("old-1") && !text.contains("old-2"))
        #expect(!text.contains("open-1") && !text.contains("open-2"))
        // The follower asked only for events after the current cursor.
        #expect(h.runtime.eventsCalls.get().contains { $0.0 == "open" && $0.1 == 2 })
        // An ended Run is not read at all without replay.
        #expect(!h.runtime.eventsCalls.get().contains { $0.0 == "old" })
        #expect(h.runtime.submitCount == 0)
    }

    @Test func listAndResumeFilterByCwd() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        h.connection.request(1, .newSession(cwd: "/work/a"))
        guard case let .sessionCreated(a, _)? = await h.connection.waitReply(1) else { Issue.record("no a"); return }
        h.connection.request(2, .newSession(cwd: "/work/b"))
        guard case let .sessionCreated(b, _)? = await h.connection.waitReply(2) else { Issue.record("no b"); return }
        h.connection.request(3, .listSessions(cwd: "/work/a"))
        guard case let .sessions(onlyA)? = await h.connection.waitReply(3) else { Issue.record("no list"); return }
        #expect(onlyA.map(\.sessionId) == [a])
        #expect(onlyA.first?.cwd == "/work/a")
        h.connection.request(4, .listSessions(cwd: nil))
        guard case let .sessions(all)? = await h.connection.waitReply(4) else { Issue.record("no list"); return }
        #expect(Set(all.map(\.sessionId)) == [a, b])
        h.connection.request(5, .resumeSession(sessionId: b, cwd: "/work/a", replay: false))
        guard case let .error(e)? = await h.connection.waitReply(5) else { Issue.record("resumed in wrong cwd"); return }
        #expect(e.reason == "session_not_found")
        h.connection.request(6, .resumeSession(sessionId: b, cwd: "/work/b", replay: false))
        guard case .resumed? = await h.connection.waitReply(6) else { Issue.record("not resumed"); return }
    }

    // MARK: Submission keys

    @Test func unconfirmedKeyIsWrittenAheadAndReusedAfterRestart() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        rt.submitOverride.with { $0 = { _ in .unconfirmed } }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        #expect(stop(await h.connection.waitReply(h.prompt(sid, "go"))) == .endTurn)
        let key = try #require(rt.submissions.get().first?.submissionKey)
        #expect(try h.store.load(sessionId: sid)?.pendingSubmissionKey == key)
        h.connection.close()
        await h.runTask.value

        // A new process: nothing in memory, only the stored binding.
        rt.submitOverride.with { $0 = nil }
        let h2 = STestHarness(runtime: rt, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(1)
        #expect(h2.connection.allText(sid).contains("待核实"))
        let p = h2.prompt(sid, "go")
        #expect(await sEventually { rt.submitCount == 2 })
        #expect(rt.submissions.get()[1].submissionKey == key)
        #expect(await sEventually { (try? h.store.load(sessionId: sid)?.runIds) == ["run-1"] })
        #expect(try h.store.load(sessionId: sid)?.pendingSubmissionKey == nil)
        rt.end("run-1")
        _ = await h2.connection.waitReply(p)
    }

    @Test func submitErrorsFollowThePortErrorRule() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        // Definite: capability_missing (no unit.run before A6) → refusal, key cleared.
        rt.submitError.with { $0 = ACPError(code: -32000, reason: "capability_missing", message: "unit.run missing") }
        #expect(stop(await h.connection.waitReply(h.prompt(sid, "go"))) == .refusal)
        #expect(try h.store.load(sessionId: sid)?.pendingSubmissionKey == nil)
        // Unknown: timeout → unconfirmed, key kept, nothing resent.
        rt.submitError.with { $0 = ACPError(code: -32000, reason: "timeout", message: "slow") }
        #expect(stop(await h.connection.waitReply(h.prompt(sid, "go"))) == .endTurn)
        #expect(try h.store.load(sessionId: sid)?.pendingSubmissionKey != nil)
        #expect(h.connection.allText(sid).contains("待核实"))
        // A non-ACPError counts as timeout too.
        rt.submitError.with { $0 = STestError() }
        #expect(stop(await h.connection.waitReply(h.prompt(sid, "go"))) == .endTurn)
        #expect(rt.submitCount == 3)
    }

    @Test func pendingTimeoutKeepsWaitingInsteadOfEnding() async {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let now = ContinuousClock().now
        let h = STestHarness(runtime: rt, monotonicNow: { now })
        defer { h.cleanup() }
        rt.pendingError.with { $0 = ACPError(code: -32000, reason: "timeout", message: "slow") }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        rt.setPhase("run-1", "waiting_approval")
        #expect(await sEventually { h.connection.allText(sid).contains("继续查询") })
        let reads = rt.snapshotReads.get()
        #expect(await sEventually { rt.snapshotReads.get() >= reads + 2 })
        #expect(h.connection.replyFor(p) == nil)
        rt.end("run-1")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(rt.decisions.get().isEmpty)
    }

    // MARK: Questions

    @Test func declineIsRecordedWhenTheRuntimeSupportsIt() async {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        rt.declineSupported.with { $0 = true }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        h.connection.askAnswer.with { $0 = { _ in .declined } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        rt.pendingByRun.with { $0["run-1"] = [.question(id: "q1", runId: "run-1", message: "which?", choices: [])] }
        rt.setPhase("run-1", "waiting_input")
        #expect(await sEventually { rt.declines.get() == ["q1"] })
        #expect(h.connection.replyFor(p) == nil) // the turn goes on
        rt.end("run-1")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(!h.connection.allText(sid).contains("下一条 prompt"))
    }

    @Test func declineWithoutRuntimeSupportFallsBackToNextPrompt() async {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        h.connection.askAnswer.with { $0 = { _ in .declined } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        rt.pendingByRun.with { $0["run-1"] = [.question(id: "q1", runId: "run-1", message: "which?", choices: [])] }
        rt.setPhase("run-1", "waiting_input")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(rt.declines.get().isEmpty)
        #expect(h.connection.allText(sid).contains("下一条 prompt"))
    }

    // MARK: Caller honesty

    @Test func placeholderCallerIsSaidPlainly() async {
        let h = STestHarness()
        defer { h.cleanup() }
        let sid = await h.newSession()
        #expect(await sEventually { h.connection.allText(sid).contains("尚未认证调用方身份") })

        let rt = STestRuntime()
        rt.callerValue.with { $0 = ACPCaller(principalId: "alice", clientId: "e", connectionId: "c", verified: true) }
        let h2 = STestHarness(runtime: rt)
        defer { h2.cleanup() }
        let sid2 = await h2.newSession()
        _ = await sEventually(.milliseconds(100)) { false }
        #expect(!h2.connection.allText(sid2).contains("尚未认证"))
    }

    // MARK: Privacy

    @Test func approvalAndQuestionTextGoThroughTheRedactor() async {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        h.connection.permissionAnswer.with { $0 = { _ in .selected(.rejectOnce) } }
        h.connection.askAnswer.with { $0 = { _ in .answered("ok") } }
        let sid = await h.newSession()
        h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        let call = ACPToolCall(toolCallId: "a1", title: "Mail bob@example.com", kind: .execute, status: .pending,
                               detail: ["call 13800138000"])
        rt.pendingByRun.with {
            $0["run-1"] = [.approval(id: "ap", runId: "run-1", toolCall: call, summary: ["to bob@example.com"]),
                           .question(id: "q", runId: "run-1", message: "phone 13800138000?", choices: ["bob@example.com"])]
        }
        rt.setPhase("run-1", "waiting_approval")
        #expect(await sEventually { !h.connection.questions.get().isEmpty })
        let req = h.connection.permissionRequests.get()[0]
        let shown = ([req.toolCall.title] + req.toolCall.detail + req.summary).joined(separator: " ")
        #expect(!shown.contains("bob@example.com") && !shown.contains("13800138000"))
        #expect(shown.contains(ACPRedactMask.email))
        let q = h.connection.questions.get()[0]
        #expect(!q.message.contains("13800138000"))
        #expect(!q.choices.joined().contains("bob@example.com"))
    }

    @Test func titleGoesThroughTheRedactorBeforeTheStore() async throws {
        let h = STestHarness()
        defer { h.cleanup() }
        let sid = await h.newSession()
        _ = await h.connection.waitReply(h.prompt(sid, "write to bob@example.com"))
        let raw = try String(contentsOf: h.dir.appendingPathComponent("\(sid).json"), encoding: .utf8)
        #expect(!raw.contains("bob@example.com") && !raw.contains("write to"))
        #expect(try h.store.load(sessionId: sid)?.title == "对话")
    }

    /// With lane E's projector the server holds one ACPProjectorSession per
    /// ACP session: what the editor sees equals feeding one in order.
    @Test func realProjectorIsFedPerSessionInOrder() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt, realProjector: ACPProjector())
        defer { h.cleanup() }
        let sid = await h.newSession()
        let events = [
            ACPRuntimeEvent(runId: "run_0a1b2c3d4e5f", cursor: 1, type: "run.started", payload: .obj([("kind", .string("unit"))])),
            ACPRuntimeEvent(runId: "run_0a1b2c3d4e5f", cursor: 2, type: "run.ended", payload: .obj([("outcome", .string("success"))])),
        ]
        rt.addRun("run_0a1b2c3d4e5f")
        rt.runs.with { $0["run_0a1b2c3d4e5f"]?.events = events }
        rt.end("run_0a1b2c3d4e5f")
        var b = try #require(try h.store.load(sessionId: sid))
        b.runIds = ["run_0a1b2c3d4e5f"]; b.revision += 1
        try h.store.save(b)
        h.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h.connection.waitReply(1)
        var expected = ACPProjectorSession()
        let want = events.flatMap { expected.project($0, policy: ACPPrivacyPolicy()) }
        // Before the answer: newSession's own updates, then the replay.
        let before = h.connection.updatesBeforeReply(1, sid)
        #expect(Array(before.suffix(want.count)) == want)
        // The stateless projection would differ: context matters here.
        #expect(want != events.flatMap { ACPProjector().project($0, policy: ACPPrivacyPolicy()) })
    }
}
