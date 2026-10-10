import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Helpers for the A6 unit.run workpack (docs/acp/12-unit-run.md). Prefix
// URTest. Layer of each test is stated in its suite name.

/// What ACP did with one unit.run scenario, from catalog to wire frames.
struct URTestTrace {
    var tasks: [ACPExposedTask] = []
    var receipt: ACPSubmissionReceipt = .unconfirmed
    var events: [ACPRuntimeEvent] = []
    var updates: [ACPSessionUpdate] = []
    /// The `session/update` JSON-RPC notifications an ACP v1 editor gets.
    var frames: [JSONValue] = []
    /// ACP v1 schema violations of those frames.
    var wireProblems: [String] = []

    var wireText: String { frames.map { $0.encoded() }.joined(separator: "\n") }

    var runId: String? {
        switch receipt {
        case let .accepted(s), let .duplicate(s): return s.runId
        default: return nil
        }
    }

    /// Tool call bodies (`update`) for action tool calls, in order.
    var actionUpdates: [JSONValue] {
        frames.compactMap { $0["params"]?["update"] }.filter {
            let tag = $0["sessionUpdate"]?.stringValue
            return (tag == "tool_call" || tag == "tool_call_update") && ($0["toolCallId"]?.stringValue ?? "").hasPrefix("act:")
        }
    }

    var actionLevels: [String] {
        actionUpdates.compactMap { $0["_meta"]?["agentdesktop"]?["actionLevel"]?.stringValue }
    }

    /// The `结果` entry of the last plan update.
    var planResult: String? {
        frames.compactMap { $0["params"]?["update"] }.last { $0["sessionUpdate"]?.stringValue == "plan" }?["entries"]?
            .arrayValue?.last?["content"]?.stringValue
    }
}

enum URTestFlow {
    static let sessionId = "acps_urtest"

    static func port(_ rt: URTestRuntime, timeout: Double = 5) throws -> ACPBridgeRuntimePort {
        var config = ACPBridgeConfiguration()
        config.callTimeout = timeout
        config.pollInterval = 0.01
        config.uid = rt.uid
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("urtest-\(UUID().uuidString)")
        return ACPBridgeRuntimePort(makeClient: rt.factory, log: try ACPSubmissionLog(path: dir.appendingPathComponent("submissions.json").path),
                                    config: config)
    }

    /// Render updates the way an ACP v1 editor receives them and check each
    /// frame against the vendored ACP v1 schema.
    static func render(_ updates: [ACPSessionUpdate], into t: inout URTestTrace) {
        let wire = ACPWireV1()
        for u in updates {
            guard let (method, params) = wire.encodeUpdate(sessionId: sessionId, u) else { continue }
            let frame = JSONValue.obj([("jsonrpc", .string("2.0")), ("method", .string(method)), ("params", params)])
            t.wireProblems += TTestSchema.check(frame).map { "\(frame.encoded().prefix(120)): \($0)" }
            t.frames.append(frame)
        }
    }

    /// catalog → submit → events → projector → wire, reacting to the
    /// scenario's trigger (cancel or disconnect after an event type).
    static func drive(_ rt: URTestRuntime, _ port: ACPBridgeRuntimePort, policy: ACPPrivacyPolicy = ACPPrivacyPolicy(),
                      input: JSONValue? = nil, key: String? = nil, taskType: String? = nil, extra: [JSONValue] = []) async throws -> URTestTrace {
        let s = rt.scenario
        var t = URTestTrace()
        t.tasks = try await port.tasks()
        let candidates = t.tasks.filter { $0.taskType == ACPTaskCatalog.unitRunMethod || $0.taskType.hasPrefix(ACPTaskCatalog.unitRunMethod + "/") }
        if taskType == nil && candidates.count > 1 { throw URTestError.ambiguousTask }
        guard let task = candidates.first(where: { taskType == nil || $0.taskType == taskType }) else {
            t.receipt = .refused(code: "capability_missing", message: "no unit.run task")
            return t
        }
        if !extra.isEmpty { rt.with { rt.scenario = URTestScenario(raw: s.raw.setting("runtime", s.runtime.setting("onAccept", .array(s.onAccept + extra)))) } }
        t.receipt = try await port.submit(ACPSubmission(submissionKey: key ?? "urtest-\(s.name)", acpSessionId: sessionId,
                                                        taskType: task.taskType, input: input ?? s.input, desktopId: s.desktopId))
        guard let runId = t.runId else { return t }
        var session = ACPProjectorSession()
        for try await e in port.events(runId: runId, after: nil) {
            t.events.append(e)
            let ups = session.project(e, policy: policy)
            t.updates += ups
            render(ups, into: &t)
            if e.type == s.cancelAfter {
                _ = try await port.cancel(runId: runId, requestId: "acp-cancel-\(sessionId)-\(runId)")
            }
            if e.type == s.disconnectAfter {
                await port.connectionLost()
            }
            if t.events.count > 200 { break }
        }
        return t
    }

    /// The scenario's own expectations, shared with lane Q's real runs.
    static func checkExpectations(_ t: URTestTrace, _ rt: URTestRuntime, sourceLocation: SourceLocation = #_sourceLocation) {
        let x = rt.scenario.expect
        let name = rt.scenario.name
        if x["submit"]?.stringValue == "accepted" {
            #expect(t.runId != nil, "\(name): not accepted: \(t.receipt)", sourceLocation: sourceLocation)
        }
        if let levels = x["actionLevels"]?.arrayValue?.compactMap(\.stringValue) {
            #expect(t.actionLevels == levels, "\(name): action levels", sourceLocation: sourceLocation)
        }
        if let st = x["finalToolStatus"]?.stringValue {
            #expect(t.actionUpdates.last?["status"]?.stringValue == st, "\(name): final tool status", sourceLocation: sourceLocation)
        }
        if let raw = x["finalRawOutput"] {
            #expect(t.actionUpdates.last?["rawOutput"] == raw, "\(name): rawOutput", sourceLocation: sourceLocation)
        }
        if let plan = x["planResult"]?.stringValue {
            #expect(t.planResult == plan, "\(name): plan result \(t.planResult ?? "nil")", sourceLocation: sourceLocation)
        }
        for s in x["textContains"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            #expect(t.wireText.contains(s), "\(name): wire lacks \(s)", sourceLocation: sourceLocation)
        }
        for s in x["textExcludes"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
            #expect(!t.wireText.contains(s), "\(name): wire shows \(s)", sourceLocation: sourceLocation)
        }
        if let f = x["runtimeFinal"], let run = rt.onlyRun {
            #expect(run.outcome == f["outcome"]?.stringValue, "\(name): Run outcome", sourceLocation: sourceLocation)
            #expect(run.closingReason == f["closingReason"]?.stringValue, "\(name): closingReason", sourceLocation: sourceLocation)
        }
        if let n = x["unitRunCalls"]?.intValue {
            #expect(rt.count("unit.run") == n, "\(name): unit.run calls", sourceLocation: sourceLocation)
        }
        if let n = x["cancelCalls"]?.intValue {
            #expect(rt.count("run.cancel") == n, "\(name): run.cancel calls", sourceLocation: sourceLocation)
        }
        #expect(t.wireProblems.isEmpty, "\(name): \(t.wireProblems)", sourceLocation: sourceLocation)
        #expect(rt.allViolations.isEmpty, "\(name): \(rt.allViolations)", sourceLocation: sourceLocation)
    }
}

/// One editor speaking ACP v1 over real pipes to the shipped server stack
/// (ACPStdioConnection, ACPAgentServer, ACPProjector, ACPWireV1,
/// ACPFileSessionStore) with a given runtime port. Every frame the agent
/// writes is checked against the ACP v1 schema.
final class URTestPipeEditor: @unchecked Sendable {
    let toAgent = Pipe()
    let fromAgent = Pipe()
    let server: ACPAgentServer
    private let lock = NSLock()
    private var bytes = Data()
    private var sent: [Int: String] = [:]
    private var served: Task<Void, Never>?
    private var nextId = 0

    init(port: any ACPRuntimePort, storeDir: URL) {
        let transport = ACPStdioFileTransport(input: toAgent.fileHandleForReading, output: fromAgent.fileHandleForWriting)
        let connection = ACPStdioConnection(transport: transport)
        var config = ACPAgentServerConfig()
        config.pollInterval = .milliseconds(20)
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

    var output: Data { lock.withLock { bytes } }
    var text: String { String(decoding: output, as: UTF8.self) }
    static func decodeFrames(_ output: Data) -> (frames: [JSONValue], problems: [String]) {
        var frames: [JSONValue] = []
        var problems: [String] = []
        var start = output.startIndex
        for end in output.indices where output[end] == 0x0a {
            do { frames.append(try StrictJSON.parse(Data(output[start..<end]))) }
            catch { problems.append("frame \(frames.count + problems.count + 1): invalid JSON: \(error)") }
            start = output.index(after: end)
        }
        // The reader may have received only part of the next frame.
        return (frames, problems)
    }

    var frames: [JSONValue] { Self.decodeFrames(output).frames }

    /// ACP v1 schema violations over every frame the agent wrote.
    var schemaProblems: [String] {
        let methods = lock.withLock { sent }
        let decoded = Self.decodeFrames(output)
        return decoded.problems + decoded.frames.flatMap { f -> [String] in
            let answering = f["method"] == nil ? f["id"]?.intValue.flatMap { methods[$0] } : nil
            return TTestSchema.check(f, answering: answering).map { "\(f.encoded().prefix(120)): \($0)" }
        }
    }

    private func write(_ v: JSONValue) {
        toAgent.fileHandleForWriting.write(Data((v.encoded() + "\n").utf8))
    }

    func send(_ method: String, _ params: JSONValue) -> Int {
        let id = lock.withLock { nextId += 1; sent[nextId] = method; return nextId }
        write(.obj([("jsonrpc", .string("2.0")), ("id", .int(id)), ("method", .string(method)), ("params", params)]))
        return id
    }

    func respond(_ id: JSONValue, _ result: JSONValue) {
        write(.obj([("jsonrpc", .string("2.0")), ("id", id), ("result", result)]))
    }

    func waitFrame(timeout: Double = 15, _ match: @escaping (JSONValue) -> Bool) async throws -> JSONValue {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let f = frames.first(where: match) { return f }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw URTestError.timeout
    }

    @discardableResult
    func call(_ method: String, _ params: JSONValue, timeout: Double = 15) async throws -> JSONValue {
        let id = send(method, params)
        return try await waitFrame(timeout: timeout) { $0["id"]?.intValue == id && $0["method"] == nil }
    }

    func initialize() async throws {
        try await call("initialize", .obj([("protocolVersion", .int(1)), ("clientCapabilities", .obj([]))]))
    }

    func newSession(cwd: URL) async throws -> String {
        let r = try await call("session/new", .obj([("cwd", .string(cwd.path)), ("mcpServers", .array([]))]))
        return try #require(r["result"]?["sessionId"]?.stringValue)
    }

    func prompt(_ sid: String, _ text: String) -> Int {
        send("session/prompt", .obj([("sessionId", .string(sid)),
                                     ("prompt", .array([.obj([("type", .string("text")), ("text", .string(text))])]))]))
    }

    /// Answer the next `session/request_permission` with one option id.
    func answerPermission(_ optionId: String) async throws {
        let req = try await waitFrame { $0["method"]?.stringValue == "session/request_permission" }
        respond(req["id"] ?? .null, .obj([("outcome", .obj([("outcome", .string("selected")), ("optionId", .string(optionId))]))]))
    }

    func disconnect() async {
        try? toAgent.fileHandleForWriting.close()
        await served?.value
    }

    static func tempDir(_ name: String) -> URL {
        let u = FileManager.default.temporaryDirectory.appendingPathComponent("urtest-\(name)-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

enum URTestError: Error { case timeout, ambiguousTask }

extension JSONValue {
    /// The input with one more member (escalation probes).
    func urAdding(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case let .object(m) = self else { return self }
        return .object(m + [(key: key, value: value)])
    }
}
