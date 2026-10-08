import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Lane Q, layer L1 (docs/acp/tests/README.md §一): Kevin's second ruling
// P1 and P2 checked through the whole shipped ACP stack exactly as
// agentdesktop-acp-dev wires it — ACPStdioFileTransport over real pipes,
// ACPStdioConnection, ACPAgentServer, ACPProjector, ACPWireV1,
// ACPFileSessionStore on disk — with only the Runtime replaced by a
// scripted ACPRuntimePort. Assertions are on the bytes the editor would
// receive and the files the server writes. Not end-to-end: the Runtime is
// scripted (A6 not merged).

/// A scripted Runtime with one free-text task. Each submitted Run replays
/// `script` and then reports `final` as its snapshot.
final class QTestScriptedPort: ACPRuntimePort, @unchecked Sendable {
    let script: [ACPRuntimeEvent]
    let final: ACPRunSnapshot
    /// Events are released one by one; `holdAfter` stops the stream after
    /// that many events until `release()` (to disconnect mid-run).
    let holdAfter: Int?
    private let lock = NSLock()
    private var released = false
    private var submits = 0
    private var cancels = 0
    private var decisions = 0
    private var lost = 0
    private var runStarted = false

    init(script: [ACPRuntimeEvent], final: ACPRunSnapshot, holdAfter: Int? = nil) {
        self.script = script; self.final = final; self.holdAfter = holdAfter
    }

    var counts: (submits: Int, cancels: Int, decisions: Int, lost: Int) {
        lock.withLock { (submits, cancels, decisions, lost) }
    }
    func release() { lock.withLock { released = true } }

    func caller() async throws -> ACPCaller { ACPCaller(principalId: "qtest-owner", clientId: "qtest", connectionId: "c1") }

    func tasks() async throws -> [ACPExposedTask] {
        [ACPExposedTask(taskType: "qtest.sample", displayName: "中立样本", description: "Q 的脚本化任务",
                        inputSchema: .obj([("type", .string("object")),
                                           ("properties", .obj([("text", .obj([("type", .string("string"))]))]))]),
                        allowFreeText: true, requiresApproval: false, dataClassification: "public")]
    }

    func submit(_ s: ACPSubmission) async throws -> ACPSubmissionReceipt {
        lock.withLock { submits += 1; runStarted = true }
        return .accepted(ACPRunSnapshot(runId: final.runId, phase: "running", outcome: nil, quiescence: "not_confirmed",
                                        lifetime: "connection_scoped"))
    }

    func snapshot(runId: String) async throws -> ACPRunSnapshot {
        let done = lock.withLock { holdAfter == nil || released }
        if done { return final }
        return ACPRunSnapshot(runId: runId, phase: "running", outcome: nil, quiescence: "not_confirmed",
                              lifetime: "connection_scoped", lastCursor: holdAfter)
    }

    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        lock.withLock { cancels += 1 }
        return final
    }

    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        let script = script, hold = holdAfter
        return AsyncThrowingStream { cont in
            let task = Task {
                for (i, e) in script.enumerated() where e.cursor > (cursor ?? 0) {
                    if let hold, i >= hold {
                        while !(self.lock.withLock { self.released }) {
                            if Task.isCancelled { cont.finish(); return }
                            try? await Task.sleep(for: .milliseconds(20))
                        }
                    }
                    try? await Task.sleep(for: .milliseconds(10))
                    cont.yield(e)
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func pending(runId: String) async throws -> [ACPPendingDecision] { [] }
    func decide(approvalId: String, allow: Bool) async throws { lock.withLock { decisions += 1 } }
    func answer(questionId: String, text: String) async throws {}
    func connectionLost() async { lock.withLock { lost += 1 } }
}

/// One editor connection to a server over real pipes.
final class QTestPipeEditor: @unchecked Sendable {
    let toAgent = Pipe()
    let fromAgent = Pipe()
    let server: ACPAgentServer
    private let lock = NSLock()
    private var bytes = Data()
    private var served: Task<Void, Never>?
    private var nextId = 0

    init(port: any ACPRuntimePort, storeDir: URL) {
        let transport = ACPStdioFileTransport(input: toAgent.fileHandleForReading, output: fromAgent.fileHandleForWriting)
        let connection = ACPStdioConnection(transport: transport)
        var config = ACPAgentServerConfig()
        config.pollInterval = .milliseconds(50)
        config.drainTimeout = .milliseconds(500)
        config.holdTime = .seconds(20)
        server = ACPAgentServer(connection: connection, runtime: port, projector: ACPProjector(),
                                store: ACPFileSessionStore(directory: storeDir), config: config)
        let reader = fromAgent.fileHandleForReading
        Thread.detachNewThread { [weak self] in
            while true {
                let d = reader.availableData
                if d.isEmpty { return }
                self?.lock.withLock { self?.bytes.append(d) }
            }
        }
        connection.start()
        let s = server
        served = Task { await s.run() }
    }

    /// Everything the agent wrote so far, byte for byte.
    var output: Data { lock.withLock { bytes } }
    var frames: [JSONValue] {
        output.split(separator: 0x0a).compactMap { try? StrictJSON.parse(Data($0)) }
    }

    func send(_ method: String, _ params: JSONValue) -> Int {
        nextId += 1
        let v = JSONValue.obj([("jsonrpc", .string("2.0")), ("id", .int(nextId)), ("method", .string(method)), ("params", params)])
        toAgent.fileHandleForWriting.write(Data((v.encoded() + "\n").utf8))
        return nextId
    }

    /// Send and wait for the response with that id.
    @discardableResult
    func call(_ method: String, _ params: JSONValue, timeout: Double = 15) async throws -> JSONValue {
        let id = send(method, params)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let r = frames.first(where: { $0["id"]?.intValue == id && $0["method"] == nil }) { return r }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw QTestStackError.timeout(method)
    }

    /// Close stdin (the editor went away) and wait for the server to return.
    func disconnect() async {
        try? toAgent.fileHandleForWriting.close()
        await served?.value
    }
}

enum QTestStackError: Error { case timeout(String) }

enum QTestStack {
    static func event(_ type: String, _ data: [(String, JSONValue)], cursor: Int, run: String = "run_0a1b2c3d4e5f") -> ACPRuntimeEvent {
        ACPRuntimeEvent(runId: run, cursor: cursor, type: type, payload: .obj(data))
    }

    static func receipt(delivery: String, execution: String, target: JSONValue) -> JSONValue {
        .obj([("receiptId", .string("rcpt_00aa11bb22cc")), ("requestId", .string("req_0001aaaabbbb")),
              ("runId", .string("run_0a1b2c3d4e5f")), ("desktopId", .string("desk_000000aaaaaa")),
              ("sessionId", .string("sess_000000bbbbbb")), ("snapshotId", .string("snap_000000cccccc")),
              ("delivery", .string(delivery)), ("execution", .string(execution)),
              ("verification", .string("not_requested")), ("businessResult", .string("not_evaluated")),
              ("route", .string("ax")), ("target", target)])
    }

    /// With QTEST_STACK_EVIDENCE=<dir>, keep the raw agent output of a test
    /// (docs/acp/tests/evidence) — byte-exact, as the editor received it.
    static func keep(_ name: String, _ data: Data) {
        guard let dir = ProcessInfo.processInfo.environment["QTEST_STACK_EVIDENCE"], !dir.isEmpty else { return }
        let u = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        try? data.write(to: u.appendingPathComponent(name))
    }

    static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("qtest-stack-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    /// Every file under `dir`, as text.
    static func filesText(_ dir: URL) -> [(String, String)] {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return [] }
        return e.compactMap { $0 as? URL }.compactMap { u in
            (try? Data(contentsOf: u)).map { (u.lastPathComponent, String(decoding: $0, as: UTF8.self)) }
        }
    }

    static func initialize(_ ed: QTestPipeEditor) async throws {
        try await ed.call("initialize", .obj([("protocolVersion", .int(1)),
                                               ("clientCapabilities", .obj([("fs", .obj([("readTextFile", .bool(false)),
                                                                                          ("writeTextFile", .bool(false))]))]))]))
    }

    static func newSession(_ ed: QTestPipeEditor, cwd: URL) async throws -> String {
        let r = try await ed.call("session/new", .obj([("cwd", .string(cwd.path)), ("mcpServers", .array([]))]))
        return try #require(r["result"]?["sessionId"]?.stringValue)
    }

    static func updates(_ ed: QTestPipeEditor, _ sid: String) -> [JSONValue] {
        ed.frames.filter { $0["method"]?.stringValue == "session/update" && $0["params"]?["sessionId"]?.stringValue == sid }
            .compactMap { $0["params"]?["update"] }
    }

    /// The tool call updates for one id, in order.
    static func toolStates(_ ups: [JSONValue], id: String) -> [JSONValue] {
        ups.filter { $0["toolCallId"]?.stringValue == id }
    }
}

@Suite("Q · L1 stack: Kevin's ruling P1 (window titles and identity)", .serialized)
struct QTestStackP1Tests {
    static let name = "王小明"
    static let title = "候选人 王小明 的简历 – Preview"

    static var script: [ACPRuntimeEvent] {
        let target = JSONValue.obj([("windowId", .int(813)), ("elementRef", .string("el_7")), ("title", .string(title)),
                                    ("windowTitle", .string(title)), ("appName", .string("Preview \(name)")),
                                    ("label", .string("下载简历"))])
        return [
            QTestStack.event("run.started", [("kind", .string("act")), ("title", .string(title))], cursor: 1),
            QTestStack.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("click")),
                                                 ("title", .string("Click download on \(title)")), ("target", target)], cursor: 2),
            QTestStack.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb")), ("windowTitle", .string(title))], cursor: 3),
            QTestStack.event("action.completed", [("receipt", QTestStack.receipt(delivery: "dispatched", execution: "completed", target: target)),
                                                  ("target", target), ("summary", .string("Opened \(name)'s resume")),
                                                  ("windowTitle", .string(title)), ("name", .string(name))], cursor: 4),
            QTestStack.event("run.ended", [("outcome", .string("success")), ("windowTitle", .string(title)),
                                           ("error", .obj([("code", .string("x")), ("message", .string("window \(title) closed"))]))], cursor: 5),
        ]
    }

    /// ACP-RULE-P1-01/02: with screenshots=all and pageText=on, the name and
    /// the bound window's title appear in no frame, no replayed frame and no
    /// stored file; the page label (body text under pageText) does.
    @Test func widenedPolicyStillHidesTheBoundWindowTitle() async throws {
        let store = QTestStack.tempDir("p1-store"), cwd = QTestStack.tempDir("p1-cwd")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: cwd) }
        let port = QTestScriptedPort(script: Self.script,
                                     final: ACPRunSnapshot(runId: "run_0a1b2c3d4e5f", phase: "ended", outcome: "success",
                                                           quiescence: "confirmed", lifetime: "connection_scoped", lastCursor: 5))
        let ed = QTestPipeEditor(port: port, storeDir: store)
        try await QTestStack.initialize(ed)
        let sid = try await QTestStack.newSession(ed, cwd: cwd)
        for (k, v) in [("screenshots", "all"), ("pageText", "on")] {
            let r = try await ed.call("session/set_config_option", .obj([("sessionId", .string(sid)), ("configId", .string(k)),
                                                                          ("value", .string(v))]))
            #expect(r["error"] == nil, "widening \(k) refused: \(r.encoded())")
        }
        let p = try await ed.call("session/prompt", .obj([("sessionId", .string(sid)),
                                                          ("prompt", .array([.obj([("type", .string("text")), ("text", .string("打开简历"))])]))]),
                                  timeout: 20)
        #expect(p["result"]?["stopReason"] != nil)
        await ed.disconnect()

        // Reconnect and load: the replay must be clean too.
        let ed2 = QTestPipeEditor(port: port, storeDir: store)
        try await QTestStack.initialize(ed2)
        try await ed2.call("session/load", .obj([("sessionId", .string(sid)), ("cwd", .string(cwd.path)), ("mcpServers", .array([]))]),
                           timeout: 20)
        await ed2.disconnect()

        QTestStack.keep("p1-live.ndjson", ed.output)
        QTestStack.keep("p1-replay.ndjson", ed2.output)
        var surfaces: [(String, String)] = [("live frames", String(decoding: ed.output, as: UTF8.self)),
                                            ("replay frames", String(decoding: ed2.output, as: UTF8.self))]
        surfaces += QTestStack.filesText(store).map { ("store \($0.0)", $0.1) }
        #expect(surfaces.count >= 3, "the session store wrote nothing")
        for (where_, text) in surfaces {
            #expect(!text.contains(Self.name), "name in \(where_)")
            #expect(!text.contains("候选人"), "window title in \(where_)")
            #expect(!text.contains("Preview"), "window title / app name in \(where_)")
        }
        // The run really was projected (not an empty pass).
        let ups = QTestStack.updates(ed, sid)
        #expect(ups.contains { $0["sessionUpdate"]?.stringValue == "tool_call" })
        #expect(String(decoding: ed.output, as: UTF8.self).contains("下载简历"), "page label under pageText=on should show")
        #expect(port.counts.submits == 1)
    }
}

@Suite("Q · L1 stack: Kevin's ruling P2 (unknown is terminal)", .serialized)
struct QTestStackP2Tests {
    static let target = JSONValue.obj([("windowId", .int(813)), ("elementRef", .string("el_7"))])

    static func script(withUnknownEvent: Bool) -> [ACPRuntimeEvent] {
        var s = [
            QTestStack.event("run.started", [("kind", .string("act"))], cursor: 1),
            QTestStack.event("action.accepted", [("requestId", .string("req_0001aaaabbbb")), ("kind", .string("type")),
                                                 ("target", target)], cursor: 2),
            QTestStack.event("action.dispatched", [("requestId", .string("req_0001aaaabbbb"))], cursor: 3),
        ]
        if withUnknownEvent {
            s.append(QTestStack.event("action.unknown", [("receipt", QTestStack.receipt(delivery: "unknown", execution: "unknown", target: target))],
                                      cursor: 4))
        }
        s.append(QTestStack.event("run.ended", [("outcome", .string("unknown")), ("reason", .string("owner_lost")),
                                                ("unknownActions", .int(1))], cursor: withUnknownEvent ? 5 : 4))
        return s
    }

    static let ended = ACPRunSnapshot(runId: "run_0a1b2c3d4e5f", phase: "ended", outcome: "unknown",
                                      quiescence: "confirmed", lifetime: "connection_scoped", lastCursor: 5)

    static func checkTerminalUnknown(_ ups: [JSONValue], where_: String) throws {
        let ids = Set(ups.compactMap { $0["sessionUpdate"]?.stringValue == "tool_call" ? $0["toolCallId"]?.stringValue : nil })
        let id = try #require(ids.first, "no tool call in \(where_)")
        let states = QTestStack.toolStates(ups, id: id)
        // Never completed, at any point.
        #expect(!states.contains { $0["status"]?.stringValue == "completed" }, "completed in \(where_)")
        let last = try #require(states.last)
        #expect(last["status"]?.stringValue == "failed", "last status in \(where_): \(last.encoded())")
        #expect(last["rawOutput"]?["execution"]?.stringValue == "terminated", "rawOutput in \(where_): \(last.encoded())")
        #expect(last["rawOutput"]?["outcome"]?.stringValue == "unknown", "rawOutput in \(where_)")
        #expect(last["title"]?.stringValue?.contains("结果未知 · 需要核实") == true, "title in \(where_): \(last.encoded())")
    }

    /// ACP-RULE-P2-01: the Run ends unknown while the editor watches.
    @Test func unknownActionEndsTerminalAndIsNeverRetried() async throws {
        let store = QTestStack.tempDir("p2a-store"), cwd = QTestStack.tempDir("p2a-cwd")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: cwd) }
        let port = QTestScriptedPort(script: Self.script(withUnknownEvent: true), final: Self.ended)
        let ed = QTestPipeEditor(port: port, storeDir: store)
        try await QTestStack.initialize(ed)
        let sid = try await QTestStack.newSession(ed, cwd: cwd)
        let p = try await ed.call("session/prompt", .obj([("sessionId", .string(sid)),
                                                          ("prompt", .array([.obj([("type", .string("text")), ("text", .string("输入"))])]))]),
                                  timeout: 20)
        #expect(p["result"]?["stopReason"]?.stringValue != nil)
        try await Task.sleep(for: .milliseconds(600))
        let ups = QTestStack.updates(ed, sid)
        QTestStack.keep("p2-unknown-live.ndjson", ed.output)
        try Self.checkTerminalUnknown(ups, where_: "live")
        #expect(String(decoding: ed.output, as: UTF8.self).contains("任务结束：结果未知 · 需要核实"))
        await ed.disconnect()
        #expect(port.counts.submits == 1, "retried: \(port.counts.submits) submits")
        #expect(port.counts.cancels == 0 && port.counts.decisions == 0)
    }

    /// ACP-RULE-P2-02: the editor leaves mid-run (dispatched, no result);
    /// the Runtime ends the Run unknown. On reconnect the replay shows the
    /// action terminal-unknown, nothing is resubmitted and it never turns
    /// completed.
    @Test func disconnectMidRunThenLoadShowsTerminalUnknownWithoutRetry() async throws {
        let store = QTestStack.tempDir("p2b-store"), cwd = QTestStack.tempDir("p2b-cwd")
        defer { try? FileManager.default.removeItem(at: store); try? FileManager.default.removeItem(at: cwd) }
        let port = QTestScriptedPort(script: Self.script(withUnknownEvent: false), final: Self.ended, holdAfter: 3)
        let ed = QTestPipeEditor(port: port, storeDir: store)
        try await QTestStack.initialize(ed)
        let sid = try await QTestStack.newSession(ed, cwd: cwd)
        _ = ed.send("session/prompt", .obj([("sessionId", .string(sid)),
                                            ("prompt", .array([.obj([("type", .string("text")), ("text", .string("输入"))])]))]))
        // Wait until the dispatched action is on the wire, then leave.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !QTestStack.updates(ed, sid).contains(where: { $0["sessionUpdate"]?.stringValue == "tool_call" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let liveBefore = QTestStack.updates(ed, sid)
        #expect(!liveBefore.contains { $0["status"]?.stringValue == "completed" })
        await ed.disconnect()
        #expect(port.counts.lost >= 1, "connectionLost not called")
        port.release() // the Runtime ends the Run (owner_lost, unknown)

        let ed2 = QTestPipeEditor(port: port, storeDir: store)
        try await QTestStack.initialize(ed2)
        try await ed2.call("session/load", .obj([("sessionId", .string(sid)), ("cwd", .string(cwd.path)), ("mcpServers", .array([]))]),
                           timeout: 20)
        try await Task.sleep(for: .milliseconds(800))
        let replay = QTestStack.updates(ed2, sid)
        QTestStack.keep("p2-disconnect-live.ndjson", ed.output)
        QTestStack.keep("p2-disconnect-replay.ndjson", ed2.output)
        try Self.checkTerminalUnknown(replay, where_: "replay after reconnect")
        await ed2.disconnect()
        #expect(port.counts.submits == 1, "resubmitted after reconnect: \(port.counts.submits)")
        #expect(port.counts.cancels == 0 && port.counts.decisions == 0)
    }
}
