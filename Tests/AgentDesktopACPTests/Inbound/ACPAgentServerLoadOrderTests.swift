import AgentDesktopProtocol
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
        // User input is never stored, so the replay shows the placeholder.
        let user = try #require(at("› 你：" + ACPAgentServer.userInputPlaceholder))
        let accepted = try #require(at("任务已受理：run-1"))
        let ev1 = try #require(at("[run-1#1] step one"))
        let ev2 = try #require(at("[run-1#2] step two"))
        let ended = try #require(at("任务 run-1 已结束"))
        let second = try #require(lines.lastIndex { $0.contains("› 你：" + ACPAgentServer.userInputPlaceholder) })
        #expect(!lines.contains { $0.contains("please go") || $0.contains("› 你：/nope") })
        // The live line named the command; the stored one does not echo it.
        let guidance = try #require(at("没有这个命令。"))
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

    /// b9 on #141: the title is a recognised command's canonical name or
    /// "对话"; an unknown "/word" never reaches <sid>.json or session/list.
    @Test(arguments: [("/hunter2secret", "对话"), ("/张三13800138000", "对话"), ("hunter2 free text", "对话"),
                      ("/help", "/help"), ("/status run-x", "/status")])
    func theTitleIsNeverUserText(_ prompt: String, _ title: String) async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: false)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        _ = await h.connection.waitReply(h.prompt(sid, prompt))
        #expect(try h.store.load(sessionId: sid)?.title == title)
        let raw = try String(contentsOf: h.dir.appendingPathComponent("\(sid).json"), encoding: .utf8)
        #expect(!raw.contains("hunter2") && !raw.contains("13800138000") && !raw.contains("张三"))
        h.connection.request(90, .listSessions(cwd: nil))
        guard case let .sessions(list)? = await h.connection.waitReply(90) else { Issue.record("no list"); return }
        #expect(list.first { $0.sessionId == sid }?.title == title)
    }

    /// Kevin's S4 ruling: a reopened session says plainly that the user's
    /// words were not kept; the notice itself is never stored.
    @Test func aReopenedSessionSaysTheInputWasNotSaved() async throws {
        let (h, sid) = try await conversation()
        defer { h.cleanup() }
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(1)
        let lines = h2.connection.updatesBeforeReply(1, sid).compactMap(text)
        #expect(lines.filter { $0 == ACPAgentServer.notSavedNotice }.count == 1)
        #expect(lines.contains { $0.contains("任务已受理：run-1") }) // useful history is kept
        let raw = try String(contentsOf: h.dir.appendingPathComponent("\(sid).history.json"), encoding: .utf8)
        #expect(!raw.contains("为保护隐私"))
    }

    /// #141 independent review: agent lines that echo the user's input or a
    /// Runtime question are shown live but stored without the echo.
    @Test func echoesNeverReachTheHistoryFile() async throws {
        let rt = STestRuntime()
        rt.taskList.with { $0 = [STestHarness.task("work", freeText: true)] }
        let h = STestHarness(runtime: rt)
        defer { h.cleanup() }
        let sid = await h.newSession()
        for line in ["/Users/me/secret-hunter2.txt", "/runs hunter2-runs", "/status hunter2-status",
                     "/hunter2abcdefghijklmnopqrstuvwxyzabcdefghij"] { // long all-letter token (Codex)
            _ = await h.connection.waitReply(h.prompt(sid, line))
        }
        let p = h.prompt(sid, "go")
        #expect(await sEventually { rt.runs.get()["run-1"] != nil })
        rt.pendingByRun.with { $0["run-1"] = [.question(id: "q1", runId: "run-1", message: "hunter2-question?", choices: [])] }
        rt.setPhase("run-1", "waiting_input")
        _ = await h.connection.waitReply(p)
        let live = h.connection.updatesFor(sid).compactMap(text).joined(separator: "\n")
        #expect(live.contains("hunter2-question"))           // shown to the user live
        #expect(!live.contains("hunter2-runs") && !live.contains("hunter2-status")) // /runs never echoes
        let raw = try String(contentsOf: h.dir.appendingPathComponent("\(sid).history.json"), encoding: .utf8)
        #expect(!raw.contains("hunter2"), "\(raw)")
        #expect(raw.contains("没有这个命令") && raw.contains("问题内容不保存"))
        rt.end("run-1")
    }

    @Test func conversationIsStoredRedactedAndOwnerOnly() async throws {
        let (h, sid) = try await conversation("mail bob@example.com about 13800138000")
        defer { h.cleanup() }
        let file = h.dir.appendingPathComponent("\(sid).history.json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("bob@example.com") && !raw.contains("13800138000") && !raw.contains("mail "))
        #expect(raw.contains(ACPAgentServer.userInputPlaceholder))
        let mode = (try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // The replay shows the redacted line, never the raw one.
        let h2 = STestHarness(runtime: h.runtime, dir: h.dir)
        defer { h2.connection.close() }
        h2.connection.request(1, .resumeSession(sessionId: sid, cwd: nil, replay: true))
        _ = await h2.connection.waitReply(1)
        let all = h2.connection.updatesFor(sid).compactMap(text).joined(separator: "\n")
        #expect(all.contains("› 你：" + ACPAgentServer.userInputPlaceholder))
        #expect(!all.contains("bob@example.com"))
        // Closing forgets the conversation too.
        h2.connection.request(2, .closeSession(sessionId: sid))
        _ = await h2.connection.waitReply(2)
        #expect(!FileManager.default.fileExists(atPath: file.path))
    }
}

@Suite struct ACPFileSessionStoreHistoryTests {
    private func store() -> (ACPFileSessionStore, URL) {
        let dir = ACPTestScratch.dir("acp-s-hist")
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
        #expect(try s.history(sessionId: "s1").map(\.text) == [ACPSessionManagerHistoryEntry.userInputPlaceholder, "a", "b"])
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
        try s.appendHistory(sessionId: "s1", [ACPSessionManagerHistoryEntry(kind: .user, text: "to a@b.com", at: "t"),
                                              ACPSessionManagerHistoryEntry(kind: .agent, text: "to a@b.com", at: "t")])
        // User text is never stored, whatever the caller passed; agent text is redacted.
        #expect(try s.history(sessionId: "s1").map(\.text)
            == [ACPSessionManagerHistoryEntry.userInputPlaceholder, "to \(ACPRedactMask.email)"])
        let raw = try String(contentsOf: dir.appendingPathComponent("s1.history.json"), encoding: .utf8)
        #expect(!raw.contains("a@b.com"))
    }

    /// #141 review + Kevin's S4 ruling: files written before format 2 are
    /// cleaned on disk the first time the store is used. User lines become
    /// the placeholder, echoes are removed, useful agent lines (accepted,
    /// status, results) stay, and a log records counts but no text.
    @Test func aLegacyHistoryAndTitleAreScrubbedOnDisk() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        var bound = binding("s1")
        bound.runIds = ["run-1"]
        try s.save(bound)
        let bindingURL = dir.appendingPathComponent("s1.json")
        var b = try String(contentsOf: bindingURL, encoding: .utf8)
        b = b.replacingOccurrences(of: "\"format\" : 2", with: "\"format\" : 1")
        b = b.replacingOccurrences(of: "\"title\" : \"", with: "\"title\" : \"secret plan hunter2 ")
        try b.write(to: bindingURL, atomically: true, encoding: .utf8)
        let legacy = #"{"format":1,"acpSessionId":"s1","revision":3,"entries":["#
            + #"{"kind":"user","text":"passphrase hunter2","at":"t"},"#
            + #"{"kind":"agent","text":"任务已受理：run-1（工作）。","runId":"run-1","at":"t"},"#
            + #"{"kind":"agent","text":"没有 /hunter2 这个命令。\n可用命令：","at":"t"},"#
            + #"{"kind":"agent","text":"任务 run-1 需要你的回答：hunter2 是什么？\n请在下一条 prompt 里直接回答。","at":"t"},"#
            + #"{"kind":"agent","text":"/work 的输入不符合要求，未创建任务：\n$：不接受字段 hunter2","at":"t"},"#
            + #"{"kind":"agent","text":"run-1：阶段 ended，结果 success\nhunter2-arg：状态待核实（不会自动重试）","at":"t"},"#
            + #"{"kind":"agent","text":"任务 run-1 已结束：阶段 ended，结果 success","runId":"run-1","at":"t"}]}"#
        try legacy.write(to: dir.appendingPathComponent("s1.history.json"), atomically: true, encoding: .utf8)

        let fresh = ACPFileSessionStore(directory: dir)
        let h = try fresh.history(sessionId: "s1")
        #expect(h.map(\.text) == [
            ACPSessionManagerHistoryEntry.userInputPlaceholder,
            "任务已受理：run-1（工作）。",
            "没有这个命令。",
            "任务 run-1 需要你的回答（问题内容不保存）。",
            "/work 的输入不符合要求，未创建任务。",
            ACPRedactor.redact("run-1：阶段 ended，结果 success\n（不属于本会话的任务，已清除）"),
            "任务 run-1 已结束：阶段 ended，结果 success",
        ])
        #expect(h[1].runId == "run-1")
        #expect(try fresh.load(sessionId: "s1")?.title == "对话")
        #expect(try fresh.load(sessionId: "s1")?.revision == 1)
        for name in ["s1.json", "s1.history.json", ACPFileSessionStore.migrationLogName] {
            let raw = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            #expect(!raw.contains("hunter2") && !raw.contains("secret plan"), "\(name)")
        }
        let log = try String(contentsOf: dir.appendingPathComponent(ACPFileSessionStore.migrationLogName), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(ACPFileSessionStore.MigrationLogEntry.self, from: Data($0.utf8)) }
        // Each file: an `intent` before the rewrite, a `done` after it.
        #expect(log.map { "\($0.file):\($0.status)" } == ["history:intent", "history:done", "binding:intent", "binding:done"]
                || log.map { "\($0.file):\($0.status)" } == ["binding:intent", "binding:done", "history:intent", "history:done"])
        let hist = try #require(log.first { $0.file == "history" })
        #expect(hist.entries == 7 && hist.userScrubbed == 1 && hist.agentChanged == 4 && hist.agentKept == 2 && hist.error == nil)
        #expect(log.contains { $0.file == "binding" && $0.titleReset && $0.error == nil })
        let mode = (try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent(ACPFileSessionStore.migrationLogName).path)[.posixPermissions] as? NSNumber)?.intValue
        #expect(mode == 0o600)
        // Migrated once: a second store finds nothing to do and logs nothing.
        _ = try ACPFileSessionStore(directory: dir).history(sessionId: "s1")
        #expect(try String(contentsOf: dir.appendingPathComponent(ACPFileSessionStore.migrationLogName), encoding: .utf8)
            .split(separator: "\n").count == log.count)
    }

    /// A session with format-1 files on disk: a title and history with a
    /// secret, a known Run's status line and an echoed /runs argument.
    private func legacySession(_ s: ACPFileSessionStore, _ dir: URL) throws {
        var bound = binding("s1")
        bound.runIds = ["run-1"]
        try s.save(bound)
        let bindingURL = dir.appendingPathComponent("s1.json")
        var b = try String(contentsOf: bindingURL, encoding: .utf8)
        b = b.replacingOccurrences(of: "\"format\" : 2", with: "\"format\" : 1")
        b = b.replacingOccurrences(of: "\"title\" : \"", with: "\"title\" : \"hunter2 ")
        try b.write(to: bindingURL, atomically: true, encoding: .utf8)
        let legacy = #"{"format":1,"acpSessionId":"s1","revision":1,"entries":["#
            + #"{"kind":"user","text":"hunter2","at":"t"},"#
            + #"{"kind":"agent","text":"run-1：阶段 ended，结果 success","at":"t"},"#
            + #"{"kind":"agent","text":"hunter2-arg：状态待核实（不会自动重试）","at":"t"}]}"#
        try legacy.write(to: dir.appendingPathComponent("s1.history.json"), atomically: true, encoding: .utf8)
    }

    private func raw(_ dir: URL, _ name: String) -> String {
        (try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)) ?? ""
    }

    /// Codex on #141: no log line, no rewrite; the migration stays pending
    /// and reads are still scrubbed in memory.
    @Test func whenTheMigrationLogCannotBeWrittenNothingIsRewritten() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try legacySession(s, dir)
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(ACPFileSessionStore.migrationLogName),
                                                withIntermediateDirectories: false) // a directory: open(O_WRONLY) fails
        let fresh = ACPFileSessionStore(directory: dir)
        let h = try fresh.history(sessionId: "s1")
        #expect(!h.contains { $0.text.contains("hunter2") })            // served scrubbed
        #expect(try fresh.load(sessionId: "s1")?.title == "对话")
        #expect(raw(dir, "s1.history.json").contains("\"format\":1"))   // not rewritten without a log line
        // Normal writes do not slip past the missing log line either.
        #expect(throws: ACPFileSessionStoreError.self) {
            try fresh.appendHistory(sessionId: "s1", [ACPSessionManagerHistoryEntry(kind: .agent, text: "x", at: "t")])
        }
        var b1 = try #require(try fresh.load(sessionId: "s1"))
        b1.revision += 1
        #expect(throws: ACPFileSessionStoreError.self) { try fresh.save(b1) }
        #expect(raw(dir, "s1.history.json").contains("\"format\":1") && raw(dir, "s1.json").contains("\"format\" : 1"))
        // Once the log can be written, the same store finishes the job.
        try FileManager.default.removeItem(at: dir.appendingPathComponent(ACPFileSessionStore.migrationLogName))
        _ = try fresh.history(sessionId: "s1")
        #expect(!raw(dir, "s1.history.json").contains("hunter2") && !raw(dir, "s1.json").contains("hunter2"))
        #expect(raw(dir, ACPFileSessionStore.migrationLogName).contains("\"file\":\"history\""))
    }

    /// Codex on #141 (355036e): when the rewrite fails, the log says so;
    /// a pre-write entry alone never reads as a completed migration.
    @Test func aFailedRewriteIsLoggedAsFailedNotDone() throws {
        let (s, dir) = store()
        defer { chmod(dir.path, 0o700); try? FileManager.default.removeItem(at: dir) }
        try legacySession(s, dir)
        let log = dir.appendingPathComponent(ACPFileSessionStore.migrationLogName)
        FileManager.default.createFile(atPath: log.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        chmod(dir.path, 0o500)  // existing files stay writable; no new temp file can be made
        let fresh = ACPFileSessionStore(directory: dir)
        _ = try? fresh.history(sessionId: "s1")
        chmod(dir.path, 0o700)
        let lines = try String(contentsOf: log, encoding: .utf8).split(separator: "\n")
            .map { try JSONDecoder().decode(ACPFileSessionStore.MigrationLogEntry.self, from: Data($0.utf8)) }
        #expect(!lines.isEmpty)
        #expect(!lines.contains { $0.status == "done" })
        #expect(lines.contains { $0.status == "failed" && $0.error != nil })
        #expect(raw(dir, "s1.history.json").contains("\"format\":1"))
    }

    /// Codex on #141 (1a6d9c2): a log that ends in half a line (a crash
    /// mid-write, or a rollback that did not stick) is never appended to;
    /// the migration stays pending and nothing is rewritten.
    @Test func aMigrationLogEndingInAHalfLineIsNeverAppendedTo() throws {
        let (s, dir) = store()
        defer { try? FileManager.default.removeItem(at: dir) }
        try legacySession(s, dir)
        let log = dir.appendingPathComponent(ACPFileSessionStore.migrationLogName)
        try Data(#"{"at":"x","entries":3,"fi"#.utf8).write(to: log)
        let fresh = ACPFileSessionStore(directory: dir)
        _ = try fresh.history(sessionId: "s1")
        #expect(raw(dir, ACPFileSessionStore.migrationLogName) == #"{"at":"x","entries":3,"fi"#)  // untouched
        #expect(raw(dir, "s1.history.json").contains("\"format\":1"))                         // not rewritten
        #expect(!(try fresh.history(sessionId: "s1")).contains { $0.text.contains("hunter2") })  // still served scrubbed
    }

    /// Codex on #141: an unreadable binding must not turn every status line
    /// into "another session's Run" for good.
    @Test func anUnreadableBindingLeavesTheHistoryForALaterRetry() throws {
        let (s, dir) = store()
        defer {
            chmod(dir.appendingPathComponent("s1.json").path, 0o600)
            try? FileManager.default.removeItem(at: dir)
        }
        try legacySession(s, dir)
        chmod(dir.appendingPathComponent("s1.json").path, 0)
        let fresh = ACPFileSessionStore(directory: dir)
        _ = try? fresh.list(principalId: "alice")
        #expect(raw(dir, "s1.history.json").contains("\"format\":1"))
        chmod(dir.appendingPathComponent("s1.json").path, 0o600)
        let h = try fresh.history(sessionId: "s1")
        #expect(h.map(\.text).contains("run-1：阶段 ended，结果 success"))   // the known Run's line survived
        #expect(!raw(dir, "s1.history.json").contains("hunter2"))
    }

    /// Codex on #141: a legacy file that cannot be opened keeps the
    /// migration pending instead of being skipped for good.
    @Test func anUnreadableLegacyFileIsRetried() throws {
        let (s, dir) = store()
        let history = dir.appendingPathComponent("s1.history.json").path
        defer { chmod(history, 0o600); try? FileManager.default.removeItem(at: dir) }
        try legacySession(s, dir)
        chmod(history, 0)
        let fresh = ACPFileSessionStore(directory: dir)
        _ = try? fresh.list(principalId: "alice")
        chmod(history, 0o600)
        _ = try fresh.history(sessionId: "s1")
        #expect(!raw(dir, "s1.history.json").contains("hunter2"))
        #expect(raw(dir, "s1.history.json").contains("\"format\":2"))
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
