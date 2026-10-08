import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopClient

/// A transport that answers from a script and records what was sent.
final class ScriptedTransport: RuntimeTransport {
    var sent: [JSONValue] = []
    var replies: [(JSONValue) throws -> Data]
    var closed = false

    init(_ replies: [(JSONValue) throws -> Data]) { self.replies = replies }

    func exchange(_ message: Data) throws -> Data {
        let v = try StrictJSON.parse(message)
        sent.append(v)
        guard !replies.isEmpty else { throw RuntimeError.connectionLost("script ended") }
        return try replies.removeFirst()(v)
    }

    func close() { closed = true }
}

func identity(product: String = RuntimeAPI.product, api: String = RuntimeAPI.version) -> RuntimeIdentity {
    RuntimeIdentity(product: product, apiVersion: api, instanceId: "rt_test", pid: 99,
                    startedAt: "2026-10-08T03:00:00Z", endpoint: "/tmp/x.sock", buildSource: "unknown")
}

func reply(_ data: JSONValue) -> (JSONValue) throws -> Data {
    { req in RuntimeResponse.success(req["requestId"]!.stringValue!, data).json.encodedData() }
}

func client(_ t: ScriptedTransport) -> SocketRuntimeClient {
    SocketRuntimeClient(endpoint: Endpoint(path: "/tmp/x.sock", source: .option),
                        info: ClientInfo(name: "test", version: "1"), connect: { _, _ in t })
}

@Test func endpointPrecedenceIsOptionThenEnvironmentThenProduct() {
    let env = ["HOME": "/Users/u", EndpointResolver.environmentKey: "~/side.sock"]
    #expect(EndpointResolver.resolve(option: "/a.sock", environment: env) == Endpoint(path: "/a.sock", source: .option))
    #expect(EndpointResolver.resolve(option: nil, environment: env).source == .environment)
    let holds = !(EndpointResolver.resolve(option: nil, environment: env).path.hasPrefix("~"))
    #expect(holds)
    #expect(EndpointResolver.resolve(option: nil, environment: ["HOME": "/Users/u"])
        == Endpoint(path: "/Users/u/Library/Application Support/AgentDesktop/runtime.sock", source: .product))
}

@Test func inspectRefusesMissingPathsAndNonSockets() throws {
    let missing = EndpointResolver.inspect("/nonexistent/agentdesktop/runtime.sock")
    #expect(missing?.code == "runtime_offline")
    #expect(missing?.notSent == true)
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("adt-notsock-\(getpid())")
    try Data().write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    #expect(EndpointResolver.inspect(file.path)?.code == "runtime_offline")
}

@Test func connectingToNothingIsOfflineAndNotSent() {
    let c = SocketRuntimeClient(endpoint: Endpoint(path: "/nonexistent/r.sock", source: .option),
                                info: ClientInfo(name: "t", version: "1"))
    #expect(throws: RuntimeError.self) { try c.handshake() }
    do { _ = try c.handshake() } catch let e as RuntimeError {
        #expect(e.code == "runtime_offline")
        #expect(e.phase == .connect)
    } catch {}
}

@Test func handshakeOffersVersionsAndKeepsTheIdentity() throws {
    let t = ScriptedTransport([reply(identity().json), reply(.obj([("desktops", .array([]))]))])
    let c = client(t)
    #expect(try c.handshake() == identity())
    _ = try c.call(RuntimeRequest(.desktopList))
    #expect(t.sent.count == 2, "one handshake per connection")
    #expect(t.sent[0]["method"]?.stringValue == "runtime.handshake")
    #expect(t.sent[0]["params"]?["apiVersions"] == .array([.string(RuntimeAPI.version)]))
    #expect(t.sent[1]["method"]?.stringValue == "desktop.list")
}

@Test func anotherProductOrVersionIsRefused() throws {
    let other = ScriptedTransport([reply(identity(product: "2ndscreen").json)])
    #expect { try client(other).handshake() } throws: { ($0 as? RuntimeError)?.code == "instance_mismatch" }
    #expect(other.closed)

    let notJSON = ScriptedTransport([{ _ in Data("ok".utf8) }])
    #expect { try client(notJSON).handshake() } throws: { ($0 as? RuntimeError)?.code == "instance_mismatch" }

    let oldAPI = ScriptedTransport([{ _ in Data(#"{"schemaVersion":"agentdesktop.ai/1","ok":true}"#.utf8) }])
    #expect { try client(oldAPI).handshake() } throws: { ($0 as? RuntimeError)?.code == "version_mismatch" }
}

@Test func aReplyForAnotherRequestIsRefused() throws {
    let t = ScriptedTransport([reply(identity().json),
                               { _ in RuntimeResponse.success("req_other", .obj([])).json.encodedData() }])
    let c = client(t)
    #expect { try c.call(RuntimeRequest(.status)) } throws: { ($0 as? RuntimeError)?.code == "instance_mismatch" }
}

@Test func runtimeErrorsArriveIntact() throws {
    let t = ScriptedTransport([reply(identity().json), { req in
        RuntimeResponse.failure(req["requestId"]!.stringValue!, .notFound("no desktop d_9")).json.encodedData()
    }])
    let c = client(t)
    #expect { try c.call(RuntimeRequest(.desktopShow, params: .obj([("desktopId", .string("d_9"))]))) } throws: {
        let e = $0 as? RuntimeError
        return e?.code == "not_found" && e?.phase == .handler && e?.message == "no desktop d_9"
    }
}

@Test func aLostConnectionClosesTheClient() throws {
    let t = ScriptedTransport([reply(identity().json)])
    let c = client(t)
    #expect { try c.call(RuntimeRequest(.status)) } throws: { ($0 as? RuntimeError)?.code == "connection_lost" }
    #expect(t.closed)
}
