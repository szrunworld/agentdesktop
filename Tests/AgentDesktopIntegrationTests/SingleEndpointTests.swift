import AgentDesktopAI
import AgentDesktopClient
@testable import AgentDesktopProtocol
import AgentDesktopService
import Foundation
import Testing
@testable import AgentDesktopRuntime

// A2 (PR2b): the AI service's ai.* methods on the Runtime's one endpoint,
// in the runtime/1 envelope with lowercase error codes; no second socket.

/// Blocking socket calls run on a plain thread, never on the Swift
/// cooperative pool the service's async handlers need (a test that blocked
/// pool threads would starve the very service it waits for).
func offPool<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try body() }) }.start()
    }
}

private func serving() async throws -> (RuntimeServer, SocketRuntimeClient, RuntimeService, String) {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    let path = dir + "/runtime.sock"
    let runtime = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_a2", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: path, buildSource: "unknown"),
                                 backend: Backend(), testSocketOwnerToken: "adt1_test-owner-credential"); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir + "/ai.sqlite", credentials: InMemoryCredentialStore()))
    let served = runtime.contract.methods.filter { $0.servedBy == "ai-service" }.map(\.method)
    runtime.registerExtensions(RuntimeBridge.handlers(service, methods: served))
    runtime.registerCapabilitySection("gui") { RuntimeBridge.guiCapabilities(service) }
    let server = RuntimeServer(path: path, service: runtime)
    try server.start()
    let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"),
                                      credential: ClientCredential(clientId: "local:\(getuid())", token: "adt1_test-owner-credential"))
    return (server, client, runtime, dir)
}

@Test func aiMethodsAnswerOnTheRuntimeEndpointInRuntimeTerms() async throws {
    let (server, client, _, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    try await offPool {

        let empty = try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.list", params: .obj([])))
        #expect(empty["items"]?.arrayValue?.isEmpty == true)

        // The requestId is the idempotency key: the same write twice is one write.
        let create = RuntimeRequest(requestId: "a2-conn-create-1", method: "ai.connections.create", params: .obj([
            ("name", .string("Local")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://example.invalid/v1")),
            ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-test-not-real"))]))]))
        let first = try client.call(create)
        let again = try client.call(create)
        #expect(first["connectionId"] == again["connectionId"])
        #expect(first.encoded().contains("sk-test") == false)
        #expect(try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.list",
                                               params: .obj([])))["items"]?.arrayValue?.count == 1)

        // ai/1 errors come back as runtime/1 codes, the original kept aside.
        do {
            _ = try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.get",
                                               params: .obj([("connectionId", .string("conn_missing"))])))
            Issue.record("a missing connection must be refused")
        } catch let e as RuntimeError {
            #expect(e.code == "not_found")
            #expect(e.details?["serviceCode"]?.stringValue == "NOT_FOUND")
        }
        do {
            _ = try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.list",
                                               params: .obj([("bogus", .bool(true))])))
            Issue.record("bad params must be refused")
        } catch let e as RuntimeError {
            #expect(e.code == "invalid_argument")
        }
    }
}

@Test func oneCapabilitiesAnswerListsTheAIMethodsAndTheGUISection() async throws {
    let (server, client, _, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    try await offPool {
        let caps = try client.call(RuntimeRequest(.capabilities))
        #expect(RuntimeContract.shared.validate(caps, "Capabilities").isEmpty)
        let names = Set((caps["interface"]?["methods"]?.arrayValue ?? []).compactMap { $0["method"]?.stringValue })
        #expect(names.contains("ai.connections.create"))
        #expect(names.contains("gui.runs.start"))
        #expect(names.contains("runtime.handshake"))
        #expect(caps["gui"] != nil)
    }
}

@Test func withoutTheAIServiceItsMethodsSaySoAndNeedAHandshake() throws {
    let runtime = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_a2b", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: "/tmp/x.sock", buildSource: "unknown"),
                                 backend: Backend()); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    let c = ConnectionState(peerUID: getuid())
    let line = Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"r1","method":"ai.connections.list","params":{}}"#.utf8)
    if case let .failure(e) = runtime.respond(to: line, on: c).result { #expect(e.code == "handshake_required") }
    else { Issue.record("a handshake comes first") }
    _ = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"h","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}}"#.utf8), on: c)
    if case let .failure(e) = runtime.respond(to: line, on: c).result { #expect(e.code == "capability_missing") }
    else { Issue.record("no AI service, no ai.* methods") }
}

// --idempotency-key is the runtime/1 requestId: one key, one request, per
// caller and across every method (runtime-api-v1-freeze §1).
private let connParams: JSONValue = .obj([
    ("name", .string("Idem")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://example.invalid/v1")),
    ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string("sk-idem-not-real"))]))])

private func count(_ client: SocketRuntimeClient) throws -> Int {
    try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.list", params: .obj([])))["items"]?.arrayValue?.count ?? -1
}

@Test func aKeyReusedForOtherParamsOrAnotherMethodIsRefusedAndRunsNothing() async throws {
    let (server, client, runtime, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    try await offPool {
        let first = try client.call(RuntimeRequest(requestId: "idem-key-0001", method: "ai.connections.create", params: connParams))
        #expect(try count(client) == 1)

        // Same key, other params.
        var other = connParams.setting("name", .string("Other"))
        do {
            _ = try client.call(RuntimeRequest(requestId: "idem-key-0001", method: "ai.connections.create", params: other))
            Issue.record("same key, other params must be refused")
        } catch let e as RuntimeError { #expect(e.code == "idempotency_conflict") }
        // Same key, another AI method.
        other = .obj([("name", .string("M")), ("connectionId", first["connectionId"]!), ("connectionRevision", first["revision"]!),
                      ("modelId", .string("m")), ("requestOptions", .obj([])), ("maxOutputTokens", .int(256))])
        do {
            _ = try client.call(RuntimeRequest(requestId: "idem-key-0001", method: "ai.modelProfiles.create", params: other))
            Issue.record("same key, another method must be refused")
        } catch let e as RuntimeError { #expect(e.code == "idempotency_conflict") }
        // Same key, one of the Runtime's own writes: one namespace.
        do {
            _ = try client.call(RuntimeRequest(requestId: "idem-key-0001", method: "runtime.enableInput", params: .obj([])))
            Issue.record("same key, a Runtime write must be refused")
        } catch let e as RuntimeError { #expect(e.code == "idempotency_conflict") }
        #expect(try count(client) == 1)
        #expect(try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.modelProfiles.list",
                                               params: .obj([])))["items"]?.arrayValue?.isEmpty == true)
        // The original request still replays its own answer.
        let replay = try client.call(RuntimeRequest(requestId: "idem-key-0001", method: "ai.connections.create", params: connParams))
        #expect(replay["connectionId"] == first["connectionId"])
        #expect(try runtime.ledger.record(caller: "local:\(getuid())", requestId: "idem-key-0001")?.state == .completed)
    }
}

@Test func aWriteThatFailedCanBeRetriedWithItsKey() async throws {
    let (server, client, runtime, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    try await offPool {
        let params: JSONValue = .obj([("connectionId", .string("conn_missing")), ("expectedRevision", .int(1))])
        for _ in 0..<2 {
            do {
                _ = try client.call(RuntimeRequest(requestId: "idem-fail-0001", method: "ai.connections.disable", params: params))
                Issue.record("a missing connection cannot be disabled")
            } catch let e as RuntimeError { #expect(e.code == "not_found") }
            // Nothing happened, so nothing holds the key.
            #expect(try runtime.ledger.record(caller: "local:\(getuid())", requestId: "idem-fail-0001") == nil)
        }
    }
}

@Test func concurrentDuplicatesMakeOneWrite() async throws {
    let (server, client, _, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let ids = try await withThrowingTaskGroup(of: String.self) { group in
        for _ in 0..<6 {
            group.addTask { try await offPool {
                let c = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"),
                                      credential: ClientCredential(clientId: "local:\(getuid())", token: "adt1_test-owner-credential"))
                defer { c.close() }
                return try c.call(RuntimeRequest(requestId: "idem-race-0001", method: "ai.connections.create",
                                                 params: connParams))["connectionId"]?.stringValue ?? ""
            } }
        }
        return try await group.reduce(into: Set<String>()) { $0.insert($1) }
    }
    #expect(ids.count == 1)
    #expect(try await offPool { try count(client) } == 1)
}

@Test func anUnknownOutcomeStaysUnknownAndIsNeverRunAgain() throws {
    let runtime = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_unk", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: "/tmp/x.sock", buildSource: "unknown"),
                                 backend: Backend()); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    final class Calls: @unchecked Sendable { var n = 0 }
    let calls = Calls()
    runtime.registerExtensions(["ai.connections.create": { _ in
        calls.n += 1
        return .failure(RuntimeError("request_acceptance_unknown", "the AI service did not answer in time", phase: .handler))
    }])
    let c = ConnectionState(peerUID: getuid())
    _ = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"h","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}}"#.utf8), on: c)
    let line = RuntimeRequest(requestId: "idem-unknown-1", method: "ai.connections.create", params: connParams).json.encodedData()
    for _ in 0..<2 {
        if case let .failure(e) = runtime.respond(to: line, on: c).result { #expect(e.code == "request_acceptance_unknown") }
        else { Issue.record("an unknown outcome is not a success") }
    }
    #expect(calls.n == 1, "the retry is answered from the ledger, not run again")
}
