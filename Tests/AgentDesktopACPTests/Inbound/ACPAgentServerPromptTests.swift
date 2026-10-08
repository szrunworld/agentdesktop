import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// Prompt, submission, cancel, approvals and questions on fakes.
@Suite struct ACPAgentServerPromptTests {
    private func harness(_ tasks: [ACPExposedTask], version: ACPVersion = .v1,
                         holdTime: Duration = .seconds(5)) -> STestHarness {
        let rt = STestRuntime()
        rt.taskList.with { $0 = tasks }
        return STestHarness(version: version, runtime: rt, holdTime: holdTime)
    }

    private func stop(_ r: ACPReply?) -> ACPStopReason? {
        if case let .promptFinished(s)? = r { return s }
        return nil
    }

    @Test func commandRunsToEndAndStreams() async throws {
        let h = harness([STestHarness.task("inspect.window")])
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "/inspect-window main")
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        let sub = try #require(h.runtime.submissions.get().first)
        #expect(sub.taskType == "inspect.window")
        #expect(sub.input == .obj([("text", .string("main"))]))
        #expect(sub.acpSessionId == sid)
        #expect(sub.submissionKey.hasPrefix("acp1-"))
        rt(h).emit("run-1", cursor: 1, text: "working")
        #expect(await sEventually { h.connection.allText(sid).contains("[run-1#1] working") })
        #expect(h.connection.replyFor(p) == nil) // turn still open while running
        rt(h).end("run-1")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(try h.store.load(sessionId: sid)?.runIds == ["run-1"])
        #expect(try h.store.load(sessionId: sid)?.lastCursor["run-1"] == 1)
    }

    private func rt(_ h: STestHarness) -> STestRuntime { h.runtime }

    @Test func v2AnswersAtAcceptanceAndEndsWithAnUpdate() async {
        let h = harness([STestHarness.task("work", freeText: true)], version: .v2)
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        #expect(!h.connection.updatesFor(sid).contains(.turnEnded(.endTurn)))
        h.runtime.end("run-1")
        #expect(await sEventually { h.connection.updatesFor(sid).contains(.turnEnded(.endTurn)) })
    }

    @Test func freeTextWithoutAllowingTaskCreatesNothing() async {
        let h = harness([STestHarness.task("work", freeText: false)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "please do the thing")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.runtime.submitCount == 0)
        #expect(h.connection.allText(sid).contains("/work"))
    }

    @Test func ambiguousFreeTextCreatesNothing() async {
        let h = harness([STestHarness.task("a", freeText: true), STestHarness.task("b", freeText: true)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "do it")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.runtime.submitCount == 0)
    }

    @Test func invalidInputIsNotSubmitted() async {
        let schema: JSONValue = .obj([
            ("type", .string("object")),
            ("properties", .obj([("count", .obj([("type", .string("integer")), ("maximum", .int(5))]))])),
            ("required", .array([.string("count")])),
            ("additionalProperties", .bool(false)),
        ])
        let h = harness([STestHarness.task("batch", schema: schema)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        for (n, text) in ["/batch {\"count\": 9}", "/batch {}", "/batch {\"count\":1,\"x\":2}", "/batch nope", "/unknown"]
            .enumerated() {
            let p = h.prompt(sid, text)
            #expect(stop(await h.connection.waitReply(p)) == .endTurn, "case \(n)")
        }
        #expect(h.runtime.submitCount == 0)
        let p = h.prompt(sid, "/batch {\"count\": 3}")
        #expect(await sEventually { h.runtime.submitCount == 1 })
        h.runtime.end("run-1")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
    }

    @Test func turnInProgressIsRefused() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.submitCount == 1 })
        let p2 = h.prompt(sid, "again")
        guard case let .error(e)? = await h.connection.waitReply(p2) else { Issue.record("not refused"); return }
        #expect(e.reason == "turn_in_progress")
        #expect(h.runtime.submitCount == 1)
    }

    /// An editor retry of the same prompt while the Run is still open maps
    /// to the same Run (same submission key → duplicate).
    @Test func retryAfterHoldTimeMapsToSameRun() async {
        let h = harness([STestHarness.task("work", freeText: true)], holdTime: .milliseconds(50))
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p1 = h.prompt(sid, "go")
        #expect(stop(await h.connection.waitReply(p1)) == .endTurn)
        #expect(h.connection.allText(sid).contains("后续更新会继续"))
        // Updates keep coming outside the turn.
        h.runtime.emit("run-1", cursor: 1, text: "later")
        #expect(await sEventually { h.connection.allText(sid).contains("[run-1#1] later") })

        let p2 = h.prompt(sid, "go")
        _ = await h.connection.waitReply(p2)
        let subs = h.runtime.submissions.get()
        #expect(subs.count == 2)
        #expect(subs[0].submissionKey == subs[1].submissionKey)
        #expect(h.runtime.runs.get().count == 1)
        #expect(h.connection.allText(sid).contains("重试"))
        #expect(try! h.store.load(sessionId: sid)?.runIds == ["run-1"])

        // After the run ended, the same text is a new request.
        h.runtime.end("run-1")
        let p3 = h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.submitCount == 3 })
        #expect(h.runtime.submissions.get()[2].submissionKey != subs[0].submissionKey)
        h.runtime.end("run-2")
        _ = await h.connection.waitReply(p3)
    }

    @Test func unconfirmedIsNeverResentAndRetryKeepsTheKey() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        h.runtime.submitOverride.with { $0 = { _ in .unconfirmed } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.runtime.submitCount == 1)
        #expect(h.connection.allText(sid).contains("待核实"))
        #expect(try! h.store.load(sessionId: sid)?.runIds == [])

        let p2 = h.prompt(sid, "go")
        _ = await h.connection.waitReply(p2)
        let subs = h.runtime.submissions.get()
        #expect(subs.count == 2)
        #expect(subs[0].submissionKey == subs[1].submissionKey)
    }

    @Test func refusedEndsWithRefusalAndCreatesNoBinding() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        h.runtime.submitOverride.with { $0 = { _ in .refused(code: "not_authorized", message: "secret reason") } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(stop(await h.connection.waitReply(p)) == .refusal)
        #expect(!h.connection.allText(sid).contains("secret"))
        #expect(try! h.store.load(sessionId: sid)?.runIds == [])
    }

    // MARK: Cancel

    @Test func cancelEndsOnlyAfterQuiescenceConfirmed() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        h.connection.notify(.cancel(sessionId: sid))
        #expect(await sEventually { h.runtime.cancels.get().count == 1 })
        #expect(h.runtime.cancels.get()[0] == ("run-1", "acp-cancel-\(sid)-run-1"))
        #expect(await sEventually { h.connection.allText(sid).contains("正在停止") })
        try? await Task.sleep(for: .milliseconds(60))
        #expect(h.connection.replyFor(p) == nil) // stopping, quiescence pending
        h.runtime.setPhase("run-1", "stopping", quiescence: "confirmed")
        #expect(stop(await h.connection.waitReply(p)) == .cancelled)
    }

    @Test func cancelBeforeAcceptanceCancelsTheRunOnceKnown() async {
        let h = harness([STestHarness.task("work", freeText: true, approval: true)])
        defer { h.cleanup() }
        // The pre-submit confirmation is pending while cancel arrives.
        let gate = STestLocked(false)
        h.connection.permissionAnswer.with { $0 = { _ in
            while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
            return .selected(.allowOnce)
        } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { h.connection.permissionRequests.get().count == 1 })
        h.connection.notify(.cancel(sessionId: sid))
        try? await Task.sleep(for: .milliseconds(20))
        gate.with { $0 = true }
        #expect(stop(await h.connection.waitReply(p)) == .cancelled)
        #expect(h.runtime.submitCount == 0)
    }

    // MARK: Approvals

    private func approvalRun(_ answer: @escaping @Sendable (ACPPermissionRequest) async -> ACPPermissionOutcome,
                             mode: String = "ask") async -> (STestHarness, String, Int) {
        let h = harness([STestHarness.task("work", freeText: true)])
        h.connection.permissionAnswer.with { $0 = answer }
        let sid = await h.newSession()
        if mode != "ask" {
            h.connection.request(50, .setConfigOption(sessionId: sid, optionId: "mode", value: mode))
            _ = await h.connection.waitReply(50)
        }
        let p = h.prompt(sid, "go")
        _ = await sEventually { h.runtime.runs.get()["run-1"] != nil }
        let call = ACPToolCall(toolCallId: "a1", title: "Send to secret@x", kind: .execute, status: .pending)
        h.runtime.pendingByRun.with { $0["run-1"] = [.approval(id: "ap-1", runId: "run-1", toolCall: call, summary: ["secret summary"])] }
        h.runtime.setPhase("run-1", "waiting_approval")
        return (h, sid, p)
    }

    @Test func approvalAllowOnce() async {
        let (h, _, p) = await approvalRun { _ in .selected(.allowOnce) }
        defer { h.cleanup() }
        #expect(await sEventually { h.runtime.decisions.get().count == 1 })
        #expect(h.runtime.decisions.get()[0] == ("ap-1", true))
        let req = h.connection.permissionRequests.get()[0]
        #expect(req.options == [.allowOnce, .rejectOnce])
        #expect(!req.toolCall.title.contains("secret"))
        #expect(!req.summary.joined().contains("secret"))
        h.runtime.end("run-1")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
    }

    @Test func approvalRejectAndUnavailableAndCancelledDeny() async {
        for outcome in [ACPPermissionOutcome.selected(.rejectOnce), .unavailable, .cancelled] {
            let (h, _, _) = await approvalRun { _ in outcome }
            #expect(await sEventually { h.runtime.decisions.get().count == 1 }, "\(outcome)")
            #expect(h.runtime.decisions.get().first?.1 == false, "\(outcome)")
            h.cleanup()
        }
    }

    @Test func autoModeNeverPromptsNorApproves() async {
        let (h, sid, p) = await approvalRun({ _ in .selected(.allowOnce) }, mode: "auto")
        defer { h.cleanup() }
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.connection.permissionRequests.get().isEmpty)
        #expect(h.runtime.decisions.get().isEmpty)
        #expect(h.connection.allText(sid).contains("主窗口"))
    }

    /// README §2.5: capability_missing on the Runtime side is "no approvals
    /// available", never an allow.
    @Test func approvalChannelMissingIsNeverAnAllow() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        h.connection.permissionAnswer.with { $0 = { _ in .selected(.allowOnce) } }
        h.runtime.pendingFails.with { $0 = true }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        h.runtime.setPhase("run-1", "waiting_approval")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.runtime.decisions.get().isEmpty)
        #expect(h.connection.permissionRequests.get().isEmpty)
        #expect(h.connection.allText(sid).contains("不会当作批准"))
    }

    @Test func cancelDeniesAnOpenPermissionRequest() async {
        let gate = STestLocked(false)
        let (h, sid, p) = await approvalRun { _ in
            while !gate.get() { try? await Task.sleep(for: .milliseconds(5)) }
            return .selected(.allowOnce) // the editor answers allow after the cancel
        }
        defer { h.cleanup() }
        #expect(await sEventually { h.connection.permissionRequests.get().count == 1 })
        h.connection.notify(.cancel(sessionId: sid))
        #expect(await sEventually { h.runtime.decisions.get().count == 1 })
        gate.with { $0 = true }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(h.runtime.decisions.get().map(\.1) == [false])
        h.runtime.end("run-1", outcome: "cancelled")
        #expect(stop(await h.connection.waitReply(p)) == .cancelled)
    }

    @Test func requiresApprovalTaskAsksBeforeSubmitInAskMode() async {
        let h = harness([STestHarness.task("work", freeText: true, approval: true)])
        defer { h.cleanup() }
        h.connection.permissionAnswer.with { $0 = { _ in .selected(.rejectOnce) } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.runtime.submitCount == 0)

        h.connection.request(60, .setConfigOption(sessionId: sid, optionId: "mode", value: "auto"))
        _ = await h.connection.waitReply(60)
        h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.submitCount == 1 })
        #expect(h.connection.permissionRequests.get().count == 1)
    }

    // MARK: Questions

    @Test func questionAnsweredInEditor() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        h.connection.askAnswer.with { $0 = { _ in .answered("blue") } }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        h.runtime.pendingByRun.with { $0["run-1"] = [.question(id: "q1", runId: "run-1", message: "which secret colour?", choices: [])] }
        h.runtime.setPhase("run-1", "waiting_input")
        #expect(await sEventually { h.runtime.answers.get().count == 1 })
        #expect(h.runtime.answers.get()[0] == ("q1", "blue"))
        #expect(h.connection.questions.get()[0].message == "which ••• colour?")
        h.runtime.end("run-1")
        _ = await h.connection.waitReply(p)
    }

    @Test func questionFallsBackToNextPrompt() async {
        let h = harness([STestHarness.task("work", freeText: true)])
        defer { h.cleanup() }
        let sid = await h.newSession()
        let p = h.prompt(sid, "go")
        #expect(await sEventually { h.runtime.runs.get()["run-1"] != nil })
        h.runtime.pendingByRun.with { $0["run-1"] = [.question(id: "q1", runId: "run-1", message: "which colour?", choices: [])] }
        h.runtime.setPhase("run-1", "waiting_input")
        #expect(stop(await h.connection.waitReply(p)) == .endTurn)
        #expect(h.connection.allText(sid).contains("下一条 prompt"))
        h.runtime.pendingByRun.with { $0["run-1"] = [] }
        h.runtime.setPhase("run-1", "running")
        let p2 = h.prompt(sid, "green")
        #expect(await sEventually { h.runtime.answers.get().count == 1 })
        #expect(h.runtime.answers.get()[0] == ("q1", "green"))
        #expect(h.runtime.submitCount == 1) // the answer did not start a task
        h.runtime.end("run-1")
        #expect(stop(await h.connection.waitReply(p2)) == .endTurn)
    }

    // MARK: Fixed commands

    @Test func statusRunsAndCancelCommands() async {
        let h = harness([STestHarness.task("work", freeText: true)], holdTime: .milliseconds(30))
        defer { h.cleanup() }
        let sid = await h.newSession()
        _ = await h.connection.waitReply(h.prompt(sid, "go"))
        _ = await h.connection.waitReply(h.prompt(sid, "/status"))
        #expect(h.connection.allText(sid).contains("run-1：阶段 running"))
        _ = await h.connection.waitReply(h.prompt(sid, "/status run-999"))
        #expect(h.connection.allText(sid).contains("本会话没有这个任务"))
        _ = await h.connection.waitReply(h.prompt(sid, "/cancel"))
        #expect(h.runtime.cancels.get().map(\.0) == ["run-1"])
        h.runtime.end("run-1", outcome: "unknown")
        _ = await h.connection.waitReply(h.prompt(sid, "/runs"))
        #expect(h.connection.allText(sid).contains("结果未知 · 需要核实"))
        #expect(h.runtime.submitCount == 1)
    }
}
