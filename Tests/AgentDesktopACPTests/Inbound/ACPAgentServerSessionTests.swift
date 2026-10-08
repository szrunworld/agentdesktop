import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// T06–T08 and connection loss on fakes of lanes T, R and E.
@Suite struct ACPAgentServerSessionTests {
    @Test func initializeClaimsOnlyWhatIsImplemented() async {
        let h = STestHarness()
        defer { h.cleanup() }
        h.connection.request(1, .initialize(client: nil, capabilities: ACPClientCapabilities(), requested: "1"))
        guard case let .initialized(version, _, caps)? = await h.connection.waitReply(1) else {
            Issue.record("no initialize answer"); return
        }
        #expect(version == .v1)
        #expect(caps.resumeSessions && caps.listSessions && caps.closeSessions)
        #expect(!caps.promptImages && !caps.promptEmbeddedContext)
    }

    /// T06: create, list, resume.
    @Test func createListResume() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("inspect.window")] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }

        let sid = await h.newSession()
        #expect(sid.hasPrefix("acps_"))
        let stored = try #require(try h.store.load(sessionId: sid))
        #expect(stored.principalId == "alice")
        #expect(stored.clientId == "editor-1")
        #expect(stored.options == ACPSessionManagerOptions.defaults)
        // available_commands: one per task plus the fixed ones.
        #expect(await sEventually {
            h.connection.updatesFor(sid).contains {
                if case let .availableCommands(c) = $0 { return c.map(\.name) == ["inspect-window", "help", "status", "runs", "cancel"] }
                return false
            }
        })

        h.connection.request(2, .listSessions(cwd: nil))
        guard case let .sessions(list)? = await h.connection.waitReply(2) else { Issue.record("no list"); return }
        #expect(list.map(\.sessionId) == [sid])

        // A finished run in the stored binding is replayed on resume.
        rt.addRun("run-old")
        rt.emit("run-old", cursor: 1, text: "first")
        rt.emit("run-old", cursor: 2, text: "second")
        rt.end("run-old")
        var b = stored
        b.runIds = ["run-old"]; b.revision += 1
        try h.store.save(b)

        let h2 = STestHarness(runtime: rt, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(3, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h2.connection.waitReply(3) else { Issue.record("not resumed"); return }
        let text = h2.connection.allText(sid)
        #expect(text.contains("[run-old#1] first"))
        #expect(text.contains("[run-old#2] second"))
        // Resuming never submits or restarts anything.
        #expect(rt.submitCount == 0)
        #expect(rt.cancels.get().isEmpty)
    }

    /// T07: the principal comes from the Runtime, never from the editor;
    /// another principal's session is refused like an unknown one.
    @Test func crossPrincipalResumeIsRefused() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        let before = try h.store.load(sessionId: sid)

        let bob = STestRuntime()
        bob.callerValue.with { $0 = ACPCaller(principalId: "bob", clientId: "editor-2", connectionId: "c2") }
        let h2 = STestHarness(runtime: bob, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case let .error(e)? = await h2.connection.waitReply(1) else { Issue.record("not refused"); return }
        #expect(e.reason == "session_not_found")
        h2.connection.request(2, .resumeSession(sessionId: "acps_does-not-exist", cwd: nil, replay: true))
        guard case let .error(e2)? = await h2.connection.waitReply(2) else { Issue.record("not refused"); return }
        #expect(e2 == e)
        h2.connection.request(3, .listSessions(cwd: nil))
        guard case let .sessions(list)? = await h2.connection.waitReply(3) else { Issue.record("no list"); return }
        #expect(list.isEmpty)
        // Bob cannot prompt into it either.
        h2.connection.request(4, .prompt(sessionId: sid, content: [.text("hi")]))
        guard case let .error(e4)? = await h2.connection.waitReply(4) else { Issue.record("prompt allowed"); return }
        #expect(e4.reason == "session_not_open")
        #expect(try h.store.load(sessionId: sid) == before)
    }

    @Test func callerFailureCreatesNothing() async throws {
        let rt = STestRuntime()
        rt.callerValue.with { $0 = nil }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        h.connection.request(1, .newSession(cwd: "/x"))
        guard case let .error(e)? = await h.connection.waitReply(1) else { Issue.record("created"); return }
        #expect(e.reason == "caller_unavailable")
        #expect(try h.store.list(principalId: "alice").isEmpty)
    }

    /// T08: concurrent sessions do not cross-stream.
    @Test func concurrentSessionsDoNotCrossStream() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let a = await h.newSession()
        let b = await h.newSession()
        h.prompt(a, "job a")
        h.prompt(b, "job b")
        #expect(await sEventually {
            (try? h.store.load(sessionId: a)?.runIds.count) == 1 && (try? h.store.load(sessionId: b)?.runIds.count) == 1
        })
        let runA = try #require(try h.store.load(sessionId: a)?.runIds.first)
        let runB = try #require(try h.store.load(sessionId: b)?.runIds.first)
        #expect(runA != runB)
        rt.emit(runA, cursor: 1, text: "for-a")
        rt.emit(runB, cursor: 1, text: "for-b")
        // An event naming run B delivered on run A's stream is dropped.
        rt.injectForeign(into: runA, event: ACPRuntimeEvent(runId: runB, cursor: 9, type: "text",
                                                            payload: .obj([("text", .string("stray"))])))
        #expect(await sEventually { h.connection.allText(a).contains("for-a") && h.connection.allText(b).contains("for-b") })
        rt.end(runA); rt.end(runB)
        #expect(await sEventually { h.connection.replies.get().count >= 4 })
        #expect(!h.connection.allText(a).contains("for-b"))
        #expect(!h.connection.allText(b).contains("for-a"))
        #expect(!h.connection.allText(a).contains("stray"))
        #expect(!h.connection.allText(b).contains("stray"))
    }

    /// Resume replays each event once even when cursors repeat.
    @Test func resumeDeduplicatesByCursor() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        rt.addRun("r1")
        rt.emit("r1", cursor: 1, text: "one")
        rt.emit("r1", cursor: 1, text: "one-again")
        rt.emit("r1", cursor: 2, text: "two")
        rt.end("r1")
        var b = try #require(try h.store.load(sessionId: sid))
        b.runIds = ["r1"]; b.revision += 1
        try h.store.save(b)
        h.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h.connection.waitReply(1)
        let msgs = h.connection.messages(sid).filter { $0.hasPrefix("[r1#") }
        #expect(msgs == ["[r1#1] one", "[r1#2] two"])
        #expect(await sEventually { (try? h.store.load(sessionId: sid)?.lastCursor["r1"]) == 2 })
    }

    /// An active connection-scoped run seen on resume is followed, not restarted.
    @Test func resumeFollowsActiveRunWithoutRestart() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        rt.addRun("live")
        var b = try #require(try h.store.load(sessionId: sid))
        b.runIds = ["live"]; b.revision += 1
        try h.store.save(b)
        h.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        rt.emit("live", cursor: 5, text: "progress")
        #expect(await sEventually { h.connection.allText(sid).contains("[live#5] progress") })
        #expect(rt.submitCount == 0)
    }

    /// Connection loss: the Runtime is told once; nothing resumes on reconnect.
    @Test func connectionLossIsReportedOnceAndNothingResumes() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        let sid = await h.newSession()
        h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get().count == 1 })
        h.connection.close("stdin closed")
        h.connection.close("again")
        await h.runTask.value
        #expect(rt.connectionLostCount.get() == 1)
        #expect(rt.submitCount == 1)

        // Reconnect and resume: still one submission, the old run is only observed.
        let h2 = STestHarness(runtime: rt, dir: h.dir)
        defer { h2.cleanup() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(rt.submitCount == 1)
    }

    @Test func closeSessionStopsItsConnectionScopedRuns() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        rt.addRun("durable", lifetime: "platform_durable")
        h.prompt(sid, "go")
        #expect(await sEventually { (try? h.store.load(sessionId: sid)?.runIds.isEmpty) == false })
        let scoped = try #require(try h.store.load(sessionId: sid)?.runIds.first)
        try await h.server.persistForTest(sid) { $0.runIds.append("durable") }
        h.connection.request(9, .closeSession(sessionId: sid))
        guard case .closed? = await h.connection.waitReply(9) else { Issue.record("not closed"); return }
        #expect(rt.cancels.get().map(\.0) == [scoped])
    }

    @Test func configOptionsValidateAndFeedPolicy() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        h.connection.request(1, .setConfigOption(sessionId: sid, optionId: "screenshots", value: "everything"))
        guard case let .error(e)? = await h.connection.waitReply(1) else { Issue.record("accepted"); return }
        #expect(e.reason == "invalid_params")
        h.connection.request(2, .setConfigOption(sessionId: sid, optionId: "nope", value: "x"))
        guard case .error? = await h.connection.waitReply(2) else { Issue.record("accepted"); return }
        h.connection.request(3, .setConfigOption(sessionId: sid, optionId: "screenshots", value: "submit"))
        guard case let .configSet(opts)? = await h.connection.waitReply(3) else { Issue.record("not set"); return }
        #expect(opts.first(where: { $0.id == "screenshots" })?.value == "submit")
        h.connection.request(4, .setConfigOption(sessionId: sid, optionId: "pageText", value: "on"))
        _ = await h.connection.waitReply(4)
        #expect(try h.store.load(sessionId: sid)?.options.first(where: { $0.id == "pageText" })?.value == "on")

        h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get().count == 1 })
        rt.emit("run-1", cursor: 1, text: "x")
        #expect(await sEventually { !h.projector.policies.get().isEmpty })
        let p = h.projector.policies.get().last!
        #expect(p.screenshots == .onSubmit)
        #expect(p.pageText)
    }

    @Test func titleIsStoredRedacted() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        let i = h.prompt(sid, "my secret plan")
        _ = await h.connection.waitReply(i)
        let raw = try String(contentsOf: h.dir.appendingPathComponent("\(sid).json"), encoding: .utf8)
        #expect(!raw.contains("secret"))
        #expect(try h.store.load(sessionId: sid)?.title == "my ••• plan")
    }
}

extension ACPAgentServer {
    /// Test hook: mutate a live binding through the normal save path.
    func persistForTest(_ sid: String, _ mutate: (inout ACPSessionBinding) -> Void) throws {
        try persist(sid, mutate)
    }
}
