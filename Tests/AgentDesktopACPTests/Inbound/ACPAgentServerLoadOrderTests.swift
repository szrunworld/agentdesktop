import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// session/load (ACP v1 Loading Sessions): every replayed update first,
/// each send awaited, then the answer; the conversation itself is part of
/// the replay and is stored only after redaction.
@Suite struct ACPAgentServerLoadOrderTests {
    /// One prompt that starts a Run with two events and ends; then the
    /// process goes away. Returns the harness (closed) and the session id.
    private func conversation(_ prompt: String = "please go") async throws -> (STestHarness, String) {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        let sid = await h.newSession()
        let p = h.prompt(sid, prompt)
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        rt.emit("run-1", cursor: 1, text: "step one")
        rt.emit("run-1", cursor: 2, text: "step two")
        rt.end("run-1")
        _ = await h.connection.waitReply(p)
        let q = h.prompt(sid, "/nope")
        _ = await h.connection.waitReply(q)
        h.connection.close()
        await h.runTask.value
        return (h, sid)
    }

    private func text(_ u: ACPSessionUpdate) -> String? {
        switch u {
        case let .userMessage(t): return "› 你：" + t  // user lines tagged for these assertions
        case let .agentMessage(t), let .agentThought(t): return t
        default: return nil
        }
    }

    @Test func allReplayUpdatesComeBeforeTheLoadReply() async throws {
        let (h, sid) = try await conversation()
        defer { h.cleanup() }
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(7, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h2.connection.waitReply(7) else { Issue.record("not loaded"); return }
        // Give any late frame a chance to show up after the reply.
        try? await Task.sleep(for: .milliseconds(100))

        // Frame order: updates…, then the reply, and nothing for the
        // session after it (the Run ended, so there is nothing live).
        let order = h2.connection.order.get()
        let replyAt = try #require(order.firstIndex(of: "reply:7"))
        #expect(replyAt > 0)
        #expect(!order[(replyAt + 1)...].contains("update"), "\(order)")

        let lines = h2.connection.updatesFor(sid).compactMap(text)
        func at(_ needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }
        let user = try #require(at("› 你：please go"))
        let accepted = try #require(at("任务已受理：run-1"))
        let ev1 = try #require(at("[run-1#1] step one"))
        let ev2 = try #require(at("[run-1#2] step two"))
        let ended = try #require(at("任务 run-1 已结束"))
        let second = try #require(at("› 你：/nope"))
        let guidance = try #require(at("没有 /nope 这个命令"))
        #expect(user < accepted && accepted < ev1 && ev1 < ev2 && ev2 < ended && ended < second && second < guidance,
                "\(lines)")
        // Each event once.
        #expect(lines.filter { $0.contains("[run-1#1]") }.count == 1)
        #expect(h.runtime.submitCount == 1) // loading never resubmits
    }

    @Test func v2LoadAlsoRepliesLast() async throws {
        let (h, sid) = try await conversation()
        defer { h.cleanup() }
        let h2 = STestHarness(version: .v2, runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(3, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(3)
        let order = h2.connection.order.get()
        let replyAt = try #require(order.firstIndex(of: "reply:3"))
        #expect(order[..<replyAt].filter { $0 == "update" }.count > 3)
        #expect(!order[(replyAt + 1)...].contains("update"))
    }

    @Test func resumeWithoutReplaySendsNoConversation() async throws {
        let (h, sid) = try await conversation()
        defer { h.cleanup() }
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: false))
        guard case .resumed? = await h2.connection.waitReply(1) else { Issue.record("not resumed"); return }
        try? await Task.sleep(for: .milliseconds(100))
        let lines = h2.connection.updatesFor(sid).compactMap(text)
        #expect(!lines.contains { $0.contains("› 你") || $0.contains("[run-1#") || $0.contains("任务已受理") })
        #expect(h2.connection.updatesBeforeReply(1, sid).isEmpty)
    }

    @Test func conversationIsStoredRedactedAndOwnerOnly() async throws {
        let (h, sid) = try await conversation("mail bob@example.com about 13800138000")
        defer { h.cleanup() }
        let file = h.dir.appendingPathComponent("\(sid).history.json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("bob@example.com") && !raw.contains("13800138000"))
        #expect(raw.contains(ACPRedactMask.email))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // The replay shows the redacted line, never the raw one.
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(1)
        let all = h2.connection.updatesFor(sid).compactMap(text).joined(separator: "\n")
        #expect(all.contains("› 你：mail \(ACPRedactMask.email)"))
        #expect(!all.contains("bob@example.com"))
        // Closing forgets the conversation too.
        h2.connection.request(2, .closeSession(sessionId: sid))
        _ = await h2.connection.waitReply(2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct ACPFileSessionStoreHistoryTests {
    private func store() -> (ACPFileSessionStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("acp-s-hist-\(UUID().uuidString)")
        return (ACPFileSessionStore(directory: dir), dir)
    }

    private func binding(_ id: String) -> ACPSessionBinding {
        ACPSessionBinding(acpSessionId: id, principalId: "alice", clientId: "c", cwd: "/w", title: "t", runIds: [],
                          lastCursor: [:], options: ACPSessionManagerOptions.defaults, createdAt: "x", updatedAt: "x",
                          revision: 1)
    }

    @Test func appendNeedsABindingKeepsOrderAndIsBounded() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        let e = { (t: String) in ACPSessionManagerHistoryEntry(kind: .agent, text: t, at: "now") }
        #expect(throws: ACPFileSessionStoreError.self) { try s.appendHistory(sessionId: "s1", [e("x")]) }
        try s.save(binding("s1"))
        try s.appendHistory(sessionId: "s1", [ACPSessionManagerHistoryEntry(kind: .user, text: "hi", at: "t0")])
        try s.appendHistory(sessionId: "s1", [e("a"), e("b")])
        #expect(try s.history(sessionId: "s1").map(\.text) == ["hi", "a", "b"])
        #expect(try s.history(sessionId: "s1").first?.kind == .user)
        // The binding is untouched (its revision is not the history's).
        #expect(try s.load(sessionId: "s1")?.revision == 1)
        try s.appendHistory(sessionId: "s1", (0..<ACPFileSessionStore.historyLimit).map { e("n\($0)") })
        let all = try s.history(sessionId: "s1")
        #expect(all.count == ACPFileSessionStore.historyLimit)
        #expect(all.last?.text == "n\(ACPFileSessionStore.historyLimit - 1)")
        // History files are not sessions.
        #expect(try s.list(principalId: "alice").map(\.acpSessionId) == ["s1"])
    }

    @Test func theStoreRedactsWhateverItIsGiven() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try s.save(binding("s1"))
        try s.appendHistory(sessionId: "s1", [ACPSessionManagerHistoryEntry(kind: .user, text: "to a@b.com", at: "t")])
        #expect(try s.history(sessionId: "s1").first?.text == "to \(ACPRedactMask.email)")
    }

    /// T06-08: a long history loads quickly.
    @Test func thousandLinesLoadFast() async throws {
        let rt = STestRuntime()
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        try h.store.appendHistory(sessionId: sid, (0..<1000).map {
            ACPSessionManagerHistoryEntry(kind: $0 % 2 == 0 ? .user : .agent, text: "line \($0)", at: "t")
        })
        let clock = ContinuousClock()
        let start = clock.now
        h.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        guard case .resumed? = await h.connection.waitReply(1) else { Issue.record("not loaded"); return }
        #expect(clock.now - start < .seconds(15))
        #expect(h.connection.updatesBeforeReply(1, sid).count >= 1000)
    }
}
