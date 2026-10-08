import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Lane Q, layer L1: capability claims through the whole stack (real pipes,
// ACPStdioConnection, ACPAgentServer, ACPWireV1), Runtime scripted.
// ACP-T05-05: the initialize answer claims exactly what the server
// implements, and nothing it does not. ACP-T05-04: an editor without
// elicitation gets no elicitation/create; the Runtime's question stays
// unanswered and the Run is not moved on.

/// A Run that waits for input with one question, until the test ends it.
final class QTestQuestionPort: ACPRuntimePort, @unchecked Sendable {
    private let lock = NSLock()
    private var submits = 0, answers = 0, declines = 0, decisions = 0
    var counts: (submits: Int, answers: Int, declines: Int, decisions: Int) {
        lock.withLock { (submits, answers, declines, decisions) }
    }

    func caller() async throws -> ACPCaller { ACPCaller(principalId: "qtest-owner", clientId: "qtest", connectionId: "c1") }
    func tasks() async throws -> [ACPExposedTask] {
        [ACPExposedTask(taskType: "qtest.sample", displayName: "中立样本", description: "Q 的脚本化任务",
                        inputSchema: .obj([("type", .string("object"))]), allowFreeText: true, requiresApproval: false,
                        dataClassification: "public")]
    }
    func submit(_ s: ACPSubmission) async throws -> ACPSubmissionReceipt {
        lock.withLock { submits += 1 }
        return .accepted(snap())
    }
    private func snap() -> ACPRunSnapshot {
        ACPRunSnapshot(runId: "run_0a1b2c3d4e5f", phase: "waiting_input", outcome: nil, quiescence: "not_confirmed",
                       lifetime: "connection_scoped", lastCursor: 1)
    }
    func snapshot(runId: String) async throws -> ACPRunSnapshot { snap() }
    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot { snap() }
    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        AsyncThrowingStream { cont in
            if (cursor ?? 0) < 1 {
                cont.yield(QTestStack.event("run.started", [("kind", .string("unit")), ("lifetime", .string("connection_scoped"))], cursor: 1))
            }
            cont.finish()
        }
    }
    func pending(runId: String) async throws -> [ACPPendingDecision] {
        [.question(id: "q_0001", runId: runId, message: "选哪一个？", choices: ["甲", "乙"])]
    }
    func decide(approvalId: String, allow: Bool) async throws { lock.withLock { decisions += 1 } }
    func answer(questionId: String, text: String) async throws { lock.withLock { answers += 1 } }
    func decline(questionId: String) async throws { lock.withLock { declines += 1 } }
    func connectionLost() async {}
}

@Suite("Q · L1 stack: capability claims (T05)", .serialized)
struct QTestStackCapabilityTests {
    /// ACP-T05-05.
    @Test func initializeClaimsExactlyWhatIsImplemented() async throws {
        let store = QTestStack.tempDir("t05-store"), cwd = QTestStack.tempDir("t05-cwd")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: cwd) }
        let ed = QTestPipeEditor(port: QTestQuestionPort(), storeDir: store)
        let r = try await ed.call("initialize", .obj([("protocolVersion", .int(1)), ("clientCapabilities", .obj([]))]))
        let caps = try #require(r["result"]?["agentCapabilities"], "\(r.encoded())")
        QTestStack.keep("t05-initialize.json", Data(r.encoded().utf8))

        // Exactly these keys, nothing extra (an unknown claim is an overclaim).
        #expect(Set(caps.objectMembers?.map(\.0) ?? []) == ["loadSession", "promptCapabilities", "mcpCapabilities", "sessionCapabilities"])
        #expect(caps["loadSession"]?.boolValue == true)
        #expect(caps["promptCapabilities"] == .obj([("image", .bool(false)), ("audio", .bool(false)), ("embeddedContext", .bool(false))]))
        #expect(caps["mcpCapabilities"] == .obj([("http", .bool(false)), ("sse", .bool(false))]))
        #expect(Set(caps["sessionCapabilities"]?.objectMembers?.map(\.0) ?? []) == ["list", "close", "resume"])
        #expect(r["result"]?["authMethods"] == .array([]))

        // The same claims as the server's ACPAgentCapabilities, field by field.
        var expected = ACPAgentCapabilities()
        expected.resumeSessions = true; expected.listSessions = true; expected.closeSessions = true
        #expect(caps["loadSession"]?.boolValue == expected.resumeSessions)
        #expect(caps["promptCapabilities"]?["image"]?.boolValue == expected.promptImages)
        #expect(caps["promptCapabilities"]?["embeddedContext"]?.boolValue == expected.promptEmbeddedContext)
        #expect((caps["sessionCapabilities"]?["list"] != nil) == expected.listSessions)
        #expect((caps["sessionCapabilities"]?["close"] != nil) == expected.closeSessions)
        #expect((caps["sessionCapabilities"]?["resume"] != nil) == expected.resumeSessions)
        // Defaults are all false (nothing claimed by accident).
        let none = ACPAgentCapabilities()
        #expect(!none.resumeSessions && !none.listSessions && !none.closeSessions && !none.promptImages && !none.promptEmbeddedContext)

        // Claimed methods answer (not -32601); unclaimed ones are refused.
        let sid = try await QTestStack.newSession(ed, cwd: cwd)
        for (m, p) in [("session/list", JSONValue.obj([])),
                       ("session/load", .obj([("sessionId", .string("qtest-none")), ("cwd", .string(cwd.path)), ("mcpServers", .array([]))])),
                       ("session/resume", .obj([("sessionId", .string("qtest-none")), ("cwd", .string(cwd.path)), ("mcpServers", .array([]))])),
                       ("session/close", .obj([("sessionId", .string("qtest-none"))]))] {
            let a = try await ed.call(m, p)
            #expect(a["error"]?["code"]?.intValue != -32601, "\(m) is claimed but not found: \(a.encoded())")
        }
        for (m, p) in [("session/set_mode", JSONValue.obj([("sessionId", .string(sid)), ("modeId", .string("x"))])),
                       ("authenticate", .obj([("methodId", .string("x"))])),
                       ("session/fork", .obj([("sessionId", .string(sid))]))] {
            let a = try await ed.call(m, p)
            #expect(a["error"]?["code"]?.intValue == -32601, "\(m) is not claimed but answered: \(a.encoded())")
        }
        // Not claimed: an image prompt is refused, not run.
        let img = try await ed.call("session/prompt", .obj([("sessionId", .string(sid)),
                                                            ("prompt", .array([.obj([("type", .string("image")), ("mimeType", .string("image/png")),
                                                                                     ("data", .string("iVBORw0KGgo="))])]))]))
        #expect(img["error"] != nil || img["result"]?["stopReason"]?.stringValue == "refusal", "\(img.encoded())")
        await ed.disconnect()
    }

    /// ACP-T05-04.
    @Test func withoutElicitationAQuestionStaysOpen() async throws {
        let store = QTestStack.tempDir("t05q-store"), cwd = QTestStack.tempDir("t05q-cwd")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: cwd) }
        let port = QTestQuestionPort()
        let ed = QTestPipeEditor(port: port, storeDir: store)
        // fs and terminal declared false, no elicitation at all.
        try await QTestStack.initialize(ed)
        let sid = try await QTestStack.newSession(ed, cwd: cwd)
        let p = try await ed.call("session/prompt", .obj([("sessionId", .string(sid)),
                                                          ("prompt", .array([.obj([("type", .string("text")), ("text", .string("开始"))])]))]),
                                  timeout: 20)
        #expect(p["result"]?["stopReason"]?.stringValue == "end_turn", "\(p.encoded())")
        try await Task.sleep(for: .milliseconds(300))
        let frames = ed.frames
        QTestStack.keep("t05-question-live.ndjson", ed.output)
        // Never asked through a channel the editor did not declare.
        #expect(!frames.contains { $0["method"]?.stringValue == "elicitation/create" })
        #expect(!frames.contains { ($0["method"]?.stringValue ?? "").hasPrefix("fs/") || ($0["method"]?.stringValue ?? "").hasPrefix("terminal/") })
        // Unanswered: nothing was answered, declined or decided on the editor's behalf.
        let c = port.counts
        #expect(c.answers == 0 && c.declines == 0 && c.decisions == 0, "\(c)")
        #expect(c.submits == 1)
        // The user is told where to answer.
        let text = String(decoding: ed.output, as: UTF8.self)
        #expect(text.contains("下一条 prompt"), "no hint where to answer")
        await ed.disconnect()
        #expect(port.counts.answers == 0)
    }
}
