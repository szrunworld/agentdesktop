import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// Layer: Mock. `ACPAgentServer` against `CurTestPort` (a fake
/// `ACPRuntimePort`). These prove how ACP's session layer uses a cursor:
/// where a resumed session starts, that the live/history boundary at
/// `lastCursor` neither loses nor repeats an event, the fallback when the
/// Runtime does not send `lastCursor`, cursor errors, cross-session
/// isolation, and that a resume never submits, cancels or restarts a Run.
/// Passing proves nothing about the Runtime cursor (11-run-cursor.md §五).
@Suite struct CurServerResumeTests {
    private func counts(_ lines: [String]) -> [String: Int] {
        lines.reduce(into: [:]) { $0[$1, default: 0] += 1 }
    }

    // MARK: Resume position

    @Test("[Mock] session/resume without lastCursor continues after the stored cursor: missed events once, none repeated (CUR-M10)")
    func resumeContinuesAfterStoredCursor() async throws {
        let port = CurTestPort()
        port.addRun("dur", lifetime: "platform_durable")
        for c in 1...3 { port.emit("dur", cursor: c) }
        let h1 = CurTestHarness(port: port)
        defer { h1.cleanup() }
        try h1.seed("s1", runIds: ["dur"], lastCursor: ["dur": 1])
        h1.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h1.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(await sEventually { h1.eventLines("s1").count == 2 })
        #expect(h1.eventLines("s1") == ["[dur#2] dur-2", "[dur#3] dur-3"])
        port.emit("dur", cursor: 4)
        #expect(await sEventually { h1.eventLines("s1").count == 3 })
        await h1.disconnect()
        // The cursor the editor reached is stored on disconnect.
        #expect(try h1.store.load(sessionId: "s1")?.lastCursor["dur"] == 4)

        // Disconnected: the observed Durable Run goes on.
        port.emit("dur", cursor: 5)
        port.emit("dur", cursor: 6)
        let h2 = CurTestHarness(port: port, dir: h1.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(await sEventually { h2.eventLines("s1").count == 2 })
        #expect(h2.eventLines("s1") == ["[dur#5] dur-5", "[dur#6] dur-6"])
        #expect(port.eventsCalls.get().last.map { $0.0 == "dur" && $0.1 == 4 } == true)
        #expect(port.submissions.get().isEmpty && port.cancels.get().isEmpty)
    }

    @Test("[Mock] session/resume with lastCursor follows from the snapshot cursor: today's behaviour, see open question Q2 (CUR-M11)")
    func resumeWithLastCursorStartsAtSnapshot() async throws {
        let port = CurTestPort()
        port.exposeLastCursor.with { $0 = true }
        port.addRun("dur", lifetime: "platform_durable")
        for c in 1...6 { port.emit("dur", cursor: c) }
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["dur"], lastCursor: ["dur": 4])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        port.emit("dur", cursor: 7)
        #expect(await sEventually { h.eventLines("s1").count == 1 })
        // Pinned current behaviour: 5 and 6 (emitted while away) are not
        // shown on session/resume once lastCursor exists; Q2 asks whether
        // resume should start at the stored cursor (4) instead.
        #expect(h.eventLines("s1") == ["[dur#7] dur-7"])
        #expect(port.eventsCalls.get().contains { $0.0 == "dur" && $0.1 == 6 })
    }

    // MARK: Live / history boundary on session/load

    @Test("[Mock] session/load with lastCursor: history up to it before the answer, the boundary event exactly once (CUR-M12)")
    func loadBoundaryWithLastCursor() async throws {
        let port = CurTestPort()
        port.exposeLastCursor.with { $0 = true }
        port.addRun("open", lifetime: "platform_durable")
        for c in 1...3 { port.emit("open", cursor: c) }
        // An event lands right after the snapshot was taken: on the boundary.
        let fired = STestLocked(false)
        port.afterSnapshot.with { $0 = { runId in
            guard runId == "open", fired.with({ let was = $0; $0 = true; return !was }) else { return }
            port.emit("open", cursor: 4)
        } }
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["open"])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        let before = h.eventLinesBeforeReply(1, "s1")
        #expect(Array(before.prefix(3)) == ["[open#1] open-1", "[open#2] open-2", "[open#3] open-3"])
        port.emit("open", cursor: 5)
        #expect(await sEventually { h.eventLines("s1").count == 5 })
        let lines = h.eventLines("s1")
        #expect(counts(lines).values.allSatisfy { $0 == 1 })
        #expect(lines == (1...5).map { "[open#\($0)] open-\($0)" })
        #expect(port.submissions.get().isEmpty && port.cancels.get().isEmpty)
    }

    @Test("[Mock] session/load without lastCursor (today's Runtime): every event exactly once, an answer, nothing submitted (CUR-M13)")
    func loadFallbackWithoutLastCursor() async throws {
        let port = CurTestPort()
        port.addRun("open", lifetime: "platform_durable")
        port.addRun("done")
        for c in 1...3 { port.emit("open", cursor: c); port.emit("done", cursor: c) }
        port.end("done", outcome: "success")
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["done", "open"], lastCursor: ["done": 3, "open": 2])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        // load replays from the start for an empty editor, whatever was stored.
        #expect(port.eventsCalls.get().allSatisfy { $0.1 == nil })
        port.emit("open", cursor: 4)
        #expect(await sEventually { h.eventLines("s1").count == 7 })
        let lines = h.eventLines("s1")
        #expect(counts(lines).values.allSatisfy { $0 == 1 })
        #expect(lines.filter { $0.hasPrefix("[done#") } == (1...3).map { "[done#\($0)] done-\($0)" })
        #expect(lines.filter { $0.hasPrefix("[open#") } == (1...4).map { "[open#\($0)] open-\($0)" })
        // The ended Run is replayed in full before the answer.
        #expect(h.eventLinesBeforeReply(1, "s1").filter { $0.hasPrefix("[done#") }.count == 3)
        #expect(port.submissions.get().isEmpty && port.cancels.get().isEmpty)
    }

    @Test("[Mock] a source that repeats events and ignores the cursor still shows each event once (CUR-M14)")
    func sessionDedupsSloppySource() async throws {
        let port = CurTestPort()
        port.sloppyStreams.with { $0 = true }
        port.addRun("dur", lifetime: "platform_durable")
        for c in 1...4 { port.emit("dur", cursor: c) }
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["dur"], lastCursor: ["dur": 2])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(await sEventually { h.eventLines("s1").count >= 2 })
        try await Task.sleep(for: .milliseconds(50))
        #expect(h.eventLines("s1") == ["[dur#3] dur-3", "[dur#4] dur-4"])
    }

    // MARK: Isolation

    @Test("[Mock] another principal's session is not found and none of its Runs is read (CUR-M15)")
    func foreignSessionIsNotRead() async throws {
        let port = CurTestPort()
        port.addRun("bobs", lifetime: "platform_durable")
        port.emit("bobs", cursor: 1, text: "bob-secret-1")
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("bob-session", principal: "bob", runIds: ["bobs"], lastCursor: ["bobs": 0])
        for (i, replay) in [(1, true), (2, false)] {
            h.connection.request(i, .resumeSession(sessionId: "bob-session", cwd: nil, replay: replay))
            guard case let .error(e)? = await h.connection.waitReply(i) else { Issue.record("foreign session opened"); return }
            #expect(e.reason == "session_not_found")
        }
        #expect(port.eventsCalls.get().isEmpty)
        #expect(port.snapshotCalls.get().isEmpty)
        #expect(!h.connection.allText("bob-session").contains("bob-secret"))
    }

    @Test("[Mock] an event naming another Run on this Run's stream is dropped (CUR-M16)")
    func foreignRunEventDropped() async throws {
        let port = CurTestPort()
        port.addRun("mine", lifetime: "platform_durable")
        port.emit("mine", cursor: 1)
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["mine"], lastCursor: ["mine": 0])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        port.inject(into: "mine", ACPRuntimeEvent(runId: "theirs", cursor: 2, type: "text",
                                                  payload: .obj([("text", .string("leak"))])))
        port.emit("mine", cursor: 2)
        #expect(await sEventually { h.eventLines("s1").count == 2 })
        #expect(h.eventLines("s1") == ["[mine#1] mine-1", "[mine#2] mine-2"])
        #expect(try h.store.load(sessionId: "s1")?.lastCursor["theirs"] == nil)
    }

    // MARK: Cursor errors

    @Test("[Mock] events_cursor_expired: load still answers, shows the snapshot, never resubmits, keeps serving (CUR-M17, ACP-30-03 ACP side)")
    func cursorExpiredDegradesToSnapshot() async throws {
        let port = CurTestPort()
        port.addRun("open", lifetime: "platform_durable")
        port.addRun("old")
        port.end("old", outcome: "success")
        let expired = ACPError(code: -32000, reason: "events_cursor_expired", message: "cursor before the retained range")
        port.streamError.with { $0 = ["open": expired, "old": expired] }
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["old", "open"], lastCursor: ["old": 5, "open": 5])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("load failed on an expired cursor"); return }
        #expect(h.connection.allText("s1").contains("任务 open："))
        #expect(port.submissions.get().isEmpty && port.cancels.get().isEmpty)
        // The connection is still served.
        h.connection.request(2, .listSessions(cwd: nil))
        guard case let .sessions(list)? = await h.connection.waitReply(2) else { Issue.record("server stopped serving"); return }
        #expect(list.map(\.sessionId) == ["s1"])
        // The stored cursor is not rewound or invented.
        #expect(try h.store.load(sessionId: "s1")?.lastCursor == ["old": 5, "open": 5])
    }

    @Test("[Mock · not run] events_cursor_expired on an ended Run tells the editor its history is incomplete (CUR-M18, target)",
          .disabled("waiting for Run.lastEventSequence / cursor contract: per-Run events_cursor_expired semantics (11-run-cursor §四 P3) and the ACP notice wording (§六 Q5)"))
    func cursorExpiredOnEndedRunIsSaid() async throws {
        let port = CurTestPort()
        port.addRun("old")
        port.end("old", outcome: "success")
        port.streamError.with { $0 = ["old": ACPError(code: -32000, reason: "events_cursor_expired", message: "expired")] }
        let h = CurTestHarness(port: port)
        defer { h.cleanup() }
        try h.seed("s1", runIds: ["old"])
        h.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(h.connection.allText("s1").contains("任务 old："))
        #expect(h.connection.allText("s1").contains("历史"))
    }

    // MARK: Delegated Runs are not resumed (ADR v2.2, K1)

    @Test("[Mock] disconnect ends the Delegated Run; reconnect (load and resume) never submits, cancels or restarts it (CUR-M19, ACP-30 ACP side)")
    func delegatedRunNotResumed() async throws {
        let port = CurTestPort()
        port.addRun("deleg", owned: true)
        port.emit("deleg", cursor: 1)
        let h1 = CurTestHarness(port: port)
        defer { h1.cleanup() }
        try h1.seed("s1", runIds: ["deleg"], lastCursor: ["deleg": 0])
        h1.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h1.connection.waitReply(1) else { Issue.record("not resumed"); return }
        #expect(await sEventually { h1.eventLines("s1").count == 1 })
        await h1.disconnect()
        #expect(port.connectionLostCount.get() == 1)
        #expect(port.runs.get()["deleg"]?.snapshot.phase == "ended")

        // Reconnect with session/resume: the ended Run is not followed.
        let h2 = CurTestHarness(port: port, dir: h1.dir)
        h2.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: false))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        try await Task.sleep(for: .milliseconds(50))
        #expect(!port.eventsCalls.get().dropFirst().contains { $0.0 == "deleg" })
        await h2.disconnect()

        // Reconnect with session/load: history is replayed, nothing more.
        let h3 = CurTestHarness(port: port, dir: h1.dir)
        defer { h3.connection.close() }
        h3.connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await h3.connection.waitReply(1) else { Issue.record("not loaded"); return }
        #expect(h3.eventLines("s1") == ["[deleg#1] deleg-1"])
        #expect(port.submissions.get().isEmpty)
        #expect(port.cancels.get().isEmpty)
        #expect(port.runs.get()["deleg"]?.snapshot.phase == "ended")
        #expect(port.runs.get().count == 1)
        #expect(try h3.store.load(sessionId: "s1")?.runIds == ["deleg"])
    }
}
