import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// Lane T test helpers (prefix TTest, docs/acp/03-lanes.md §2).

enum TTestFixtures {
    static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures/acp-schema")
}

/// The vendored ACP v1 schema, loaded into the contract's JSON Schema
/// validator. Keywords that carry no assertion there (OpenAPI
/// `discriminator`, the generator's `x-*` hints, `unevaluatedProperties:
/// true`) are dropped first; anything else unknown makes loading fail.
enum TTestSchema {
    static let id = "https://agentclientprotocol.com/schema/v1/schema.json"

    static let registry: SchemaRegistry = {
        let data = try! Data(contentsOf: TTestFixtures.root.appendingPathComponent("v1/schema.json"))
        let raw = try! StrictJSON.parse(data, maxDepth: 256)
        let doc = strip(raw).setting("$id", .string(id))
        let r = SchemaRegistry()
        try! r.add(doc)
        return r
    }()

    static func strip(_ v: JSONValue, inMap: Bool = false) -> JSONValue {
        switch v {
        case let .object(members):
            var out: [(key: String, value: JSONValue)] = []
            for m in members {
                if inMap { out.append((m.key, strip(m.value))); continue }
                if m.key == "discriminator" || m.key.hasPrefix("x-") { continue }
                if m.key == "unevaluatedProperties", m.value == .bool(true) { continue }
                if m.key == "default" || m.key == "const" || m.key == "enum" || m.key == "examples" {
                    out.append(m); continue
                }
                let isMap = m.key == "properties" || m.key == "$defs"
                out.append((m.key, strip(m.value, inMap: isMap)))
            }
            return .object(out)
        case let .array(items):
            return .array(items.map { strip($0) })
        default:
            return v
        }
    }

    static func violations(_ instance: JSONValue, def: String) -> [SchemaViolation] {
        try! registry.validate(instance, documentId: id, pointer: "/$defs/\(def)")
    }

    static func rootViolations(_ instance: JSONValue) -> [SchemaViolation] {
        try! registry.validate(instance, documentId: id, pointer: "")
    }

    static let resultDef: [String: String] = [
        "initialize": "InitializeResponse",
        "session/new": "NewSessionResponse",
        "session/load": "LoadSessionResponse",
        "session/resume": "ResumeSessionResponse",
        "session/list": "ListSessionsResponse",
        "session/close": "CloseSessionResponse",
        "session/prompt": "PromptResponse",
        "session/set_config_option": "SetSessionConfigOptionResponse",
    ]
    static let paramsDef: [String: String] = [
        "session/update": "SessionNotification",
        "session/request_permission": "RequestPermissionRequest",
        "elicitation/create": "CreateElicitationRequest",
    ]

    /// Validate one frame the agent emitted: the whole message against the
    /// schema root, plus its params/result/error against the exact type.
    /// `answering` is the method of the request a response answers.
    static func check(_ frame: JSONValue, answering: String? = nil) -> [String] {
        var out = rootViolations(frame).map { "root: \($0)" }
        if let method = frame["method"]?.stringValue {
            guard let def = paramsDef[method] else { return out + ["unexpected method \(method)"] }
            out += violations(frame["params"] ?? .null, def: def).map { "\(def): \($0)" }
        } else if let error = frame["error"] {
            out += violations(error, def: "Error").map { "Error: \($0)" }
        } else if let result = frame["result"] {
            guard let m = answering, let def = resultDef[m] else { return out + ["no result type for \(answering ?? "?")"] }
            out += violations(result, def: def).map { "\(def): \($0)" }
        } else {
            out.append("neither method, result nor error")
        }
        return out
    }
}

/// Collects values from an async source. `next()` waits for the next value
/// or the end of the source, never for a wall-clock window: tests prove
/// "nothing else arrived" with an ordering probe instead (TTestEditor.probe*).
/// The long deadline is only a hang guard.
actor TTestInbox<T: Sendable> {
    private var items: [T] = []
    private(set) var finished = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func put(_ x: T) { items.append(x); wake() }
    func finish() { finished = true; wake() }

    private func wake() {
        let w = waiters
        waiters = []
        for c in w { c.resume() }
    }

    func next(hangGuard: Double = 60) async -> T? {
        let deadline = Date().addingTimeInterval(hangGuard)
        while items.isEmpty && !finished {
            if Date() > deadline { return nil }
            // Re-check at least every 50 ms in case of a missed wake-up.
            let guardTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 50_000_000)
                await self?.wakeForGuard()
            }
            await withCheckedContinuation { waiters.append($0) }
            guardTask.cancel()
        }
        return items.isEmpty ? nil : items.removeFirst()
    }

    private func wakeForGuard() { wake() }

    var pending: Int { items.count }
}

/// A scripted editor on the other end of an in-memory pipe, plus the
/// connection under test. Every frame the agent emits is schema-checked.
final class TTestEditor: @unchecked Sendable {
    let agentSide: ACPStdioMemoryTransport
    let editorSide: ACPStdioMemoryTransport
    let connection: ACPStdioConnection
    let frames = TTestInbox<JSONValue>()
    let rawFrames = TTestInbox<Data>()
    let events = TTestInbox<ACPConnectionEvent>()
    /// Requests we sent, by id, so responses can be checked against the right type.
    private let lock = NSLock()
    private var sentMethods: [String: String] = [:]
    private var problems: [String] = []
    /// Schema violations of every frame received so far. A frame is checked
    /// before `nextFrame()` can return it, so this is complete for all
    /// frames a test has already read.
    var schemaProblems: [String] { lock.withLock { problems } }

    init(options: ACPStdioConnectionOptions = .init()) {
        (agentSide, editorSide) = ACPStdioMemoryTransport.pair()
        connection = ACPStdioConnection(transport: agentSide, options: options)
        let frames = frames, rawFrames = rawFrames, events = events, editorSide = editorSide
        let maxBytes = options.maxFrameBytes * 4
        Task {
            var splitter = ACPFrameSplitter(maxFrameBytes: maxBytes)
            for await chunk in editorSide.chunks {
                for unit in splitter.feed(chunk) {
                    guard case let .frame(d) = unit else { continue }
                    await rawFrames.put(d)
                    if let v = try? StrictJSON.parse(d) {
                        self.schemaCheck(v)
                        await frames.put(v)
                    }
                }
            }
            await frames.finish()
            await rawFrames.finish()
        }
        let conn = connection
        Task {
            for await e in conn.events { await events.put(e) }
            await events.finish()
        }
        connection.start()
    }

    private func schemaCheck(_ v: JSONValue) {
        let key = v["id"].map { $0.encoded() } ?? ""
        let answering = lock.withLock { sentMethods[key] }
        let problems = TTestSchema.check(v, answering: v["method"] == nil ? answering : nil)
        lock.withLock { self.problems += problems.map { "\(v.encoded().prefix(160)): \($0)" } }
    }

    func sendRaw(_ text: String) async {
        try? await editorSide.write(Data(text.utf8))
    }

    func send(_ v: JSONValue) async {
        if let m = v["method"]?.stringValue, let id = v["id"] {
            lock.withLock { sentMethods[id.encoded()] = m }
        }
        await sendRaw(v.encoded() + "\n")
    }

    func request(_ id: Int, _ method: String, _ params: JSONValue) async {
        await send(.obj([("jsonrpc", .string("2.0")), ("id", .int(id)), ("method", .string(method)),
                         ("params", params)]))
    }

    func notify(_ method: String, _ params: JSONValue) async {
        await send(.obj([("jsonrpc", .string("2.0")), ("method", .string(method)), ("params", params)]))
    }

    func respond(_ id: JSONValue, _ result: JSONValue) async {
        await send(.obj([("jsonrpc", .string("2.0")), ("id", id), ("result", result)]))
    }

    func nextFrame() async -> JSONValue? { await frames.next() }
    func nextEvent() async -> ACPConnectionEvent? { await events.next() }

    private var probeCounter = 0

    /// True when nothing else came out before the answer to a fresh probe
    /// request: frames are written in order, so this proves "no frame".
    func probeFrameIsNext() async -> Bool {
        let id = lock.withLock { probeCounter += 1; return "probe-\(probeCounter)" }
        await send(.obj([("jsonrpc", .string("2.0")), ("id", .string(id)), ("method", .string("probe/ping")),
                         ("params", .obj([]))]))
        let f = await nextFrame()
        return f?["id"] == .string(id) && f?["error"] != nil
    }

    /// True when the next event the server sees is a probe `session/new`
    /// sent now: proves no other event was delivered before it. Needs an
    /// initialized connection; the probe's frame-level answer is not awaited.
    func probeEventIsNext() async -> Bool {
        let cwd = lock.withLock { probeCounter += 1; return "/probe-\(probeCounter)" }
        await send(.obj([("jsonrpc", .string("2.0")), ("id", .string("e" + cwd)), ("method", .string("session/new")),
                         ("params", .obj([("cwd", .string(cwd)), ("mcpServers", .array([]))]))]))
        guard case let .request(_, .newSession(got))? = await nextEvent() else { return false }
        return got == cwd
    }

    static let defaultCaps: ACPAgentCapabilities = {
        var c = ACPAgentCapabilities()
        c.listSessions = true
        return c
    }()

    /// Run `initialize` through a fake server answer; returns the result.
    @discardableResult
    func initialize(protocolVersion: Int = 1, clientCapabilities: JSONValue = .obj([]),
                    agentCaps: ACPAgentCapabilities = TTestEditor.defaultCaps) async -> JSONValue? {
        await request(0, "initialize", .obj([("protocolVersion", .int(protocolVersion)),
                                             ("clientCapabilities", clientCapabilities),
                                             ("clientInfo", .obj([("name", .string("ttest")),
                                                                  ("version", .string("0"))]))]))
        guard case let .request(id, .initialize)? = await nextEvent() else { return nil }
        await connection.reply(to: id, .initialized(version: .v1, agent: .init(name: "agentdesktop", version: "0.0.0"),
                                                    capabilities: agentCaps))
        return await nextFrame()?["result"]
    }

    func close() { editorSide.close() }
}
