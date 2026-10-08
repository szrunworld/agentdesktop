import AgentDesktopAI
import AgentDesktopClient
import AgentDesktopContracts
import AgentDesktopService
import Foundation
import Testing
@testable import AgentDesktopProtocol
@testable import AgentDesktopRuntime

// A2 (PR2b): the AI service's ai.* methods on the Runtime's one endpoint,
// in the runtime/1 envelope with lowercase error codes; no second socket.

private func serving() async throws -> (RuntimeServer, SocketRuntimeClient, RuntimeService, String) {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    let path = dir + "/runtime.sock"
    let runtime = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_a2", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: path, buildSource: "unknown"),
                                 backend: Backend())
    let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir + "/ai.sqlite", credentials: InMemoryCredentialStore()))
    let served = runtime.contract.methods.filter { $0.servedBy == "ai-service" }.map(\.method)
    runtime.registerExtensions(RuntimeBridge.handlers(service, methods: served))
    runtime.registerCapabilitySection("gui") { RuntimeBridge.guiCapabilities(service) }
    let server = RuntimeServer(path: path, service: runtime)
    try server.start()
    let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "t", version: "1"))
    return (server, client, runtime, dir)
}

@Test func aiMethodsAnswerOnTheRuntimeEndpointInRuntimeTerms() async throws {
    let (server, client, _, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }

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
        #expect(e.details?["aiCode"]?.stringValue == "NOT_FOUND")
    }
    do {
        _ = try client.call(RuntimeRequest(requestId: RuntimeRequest.newId(), method: "ai.connections.list",
                                           params: .obj([("bogus", .bool(true))])))
        Issue.record("bad params must be refused")
    } catch let e as RuntimeError {
        #expect(e.code == "invalid_argument")
    }
}

@Test func oneCapabilitiesAnswerListsTheAIMethodsAndTheGUISection() async throws {
    let (server, client, _, dir) = try await serving()
    defer { client.close(); server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let caps = try client.call(RuntimeRequest(.capabilities))
    #expect(RuntimeContract.shared.validate(caps, "Capabilities").isEmpty)
    let names = Set((caps["interface"]?["methods"]?.arrayValue ?? []).compactMap { $0["method"]?.stringValue })
    #expect(names.contains("ai.connections.create"))
    #expect(names.contains("gui.runs.start"))
    #expect(names.contains("runtime.handshake"))
    #expect(caps["gui"] != nil)
}

@Test func withoutTheAIServiceItsMethodsSaySoAndNeedAHandshake() throws {
    let runtime = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_a2b", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: "/tmp/x.sock", buildSource: "unknown"),
                                 backend: Backend())
    let c = ConnectionState(peerUID: getuid())
    let line = Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"r1","method":"ai.connections.list","params":{}}"#.utf8)
    if case let .failure(e) = runtime.respond(to: line, on: c).result { #expect(e.code == "handshake_required") }
    else { Issue.record("a handshake comes first") }
    _ = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"h","method":"runtime.handshake","params":{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}}"#.utf8), on: c)
    if case let .failure(e) = runtime.respond(to: line, on: c).result { #expect(e.code == "capability_missing") }
    else { Issue.record("no AI service, no ai.* methods") }
}
