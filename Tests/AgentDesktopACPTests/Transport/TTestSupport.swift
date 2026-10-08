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

/// Collects values from an async source so tests can wait with a timeout.
actor TTestInbox<T: Sendable> {
    private var items: [T] = []
    private(set) var finished = false

    func put(_ x: T) { items.append(x) }
    func finish() { finished = true }

    func next(timeout: Double = 2.0) async -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if !items.isEmpty { return items.removeFirst() }
            if finished || Date() > deadline { return nil }
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

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
    private(set) var schemaProblems: [String] = []

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
        lock.withLock { schemaProblems += problems.map { "\(v.encoded().prefix(160)): \($0)" } }
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

    func nextFrame(timeout: Double = 2.0) async -> JSONValue? { await frames.next(timeout: timeout) }
    func nextEvent(timeout: Double = 2.0) async -> ACPConnectionEvent? { await events.next(timeout: timeout) }

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
