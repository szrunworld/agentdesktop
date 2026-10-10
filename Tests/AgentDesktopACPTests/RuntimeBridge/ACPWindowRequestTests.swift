import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// [Mock] `agentdesktop-acp-dev request-window` (#246, option A): the bridge
/// asks for observe and act on one window through hub.windows.request, then
/// checks the grant is for the window bound on the Desktop. Never retried.
@Suite("[Mock] ACP bridge window request")
struct ACPWindowRequestTests {
    static let process = JSONValue.obj([("pid", .int(42)), ("startedAt", .string("2026-10-11T00:00:00Z"))])
    static let grant = JSONValue.obj([("windowGrantId", .string("wg_1")), ("clientId", .string("app:acp")),
                                      ("desktopId", .string("desk_A")), ("expiresAt", .string("2026-10-11T08:00:00Z")),
                                      ("window", .obj([("windowId", .int(7)), ("process", process), ("bundleId", .string("com.example.app"))]))])

    final class WindowClient: RuntimeClient, @unchecked Sendable {
        var binding: JSONValue
        var requestError: RuntimeError?
        var requests: [RuntimeRequest] = []
        init(binding: JSONValue, requestError: RuntimeError? = nil) {
            self.binding = binding
            self.requestError = requestError
        }
        var endpoint: Endpoint { Endpoint(path: "/tmp/adt-x/side.runtime.sock", source: .option) }
        func handshake() throws -> RuntimeIdentity {
            RuntimeIdentity(instanceId: "i", pid: 1, startedAt: "2026-10-11T00:00:00Z", endpoint: endpoint.path, buildSource: "t")
        }
        func call(_ request: RuntimeRequest) throws -> JSONValue {
            requests.append(request)
            switch request.method {
            case RuntimeMethod.windowsRequest.rawValue:
                if let requestError { throw requestError }
                return ACPWindowRequestTests.grant
            case RuntimeMethod.desktopShow.rawValue:
                return .obj([("desktopId", .string("desk_A")), ("binding", binding)])
            default:
                Issue.record("request-window sent \(request.method)")
                return .obj([])
            }
        }
        func close() {}
        var methods: [String] { requests.map(\.method) }
    }

    func run(_ c: WindowClient, windowId: Int? = nil, duration: Int? = nil) throws -> ACPWindowRequest.Outcome {
        try ACPWindowRequest.request(client: c, desktopId: "desk_A", bundleId: "com.example.app", windowId: windowId,
                                     durationSeconds: duration) { _ in }
    }

    @Test("[Mock] it asks for exactly observe and act on the named app's window on that Desktop")
    func requestIsMinimal() throws {
        let c = WindowClient(binding: .obj([("windowId", .int(7)), ("process", Self.process)]))
        _ = try run(c, windowId: 7, duration: 28800)
        let p = c.requests[0].params
        #expect(c.requests[0].method == "hub.windows.request")
        #expect(p["desktopId"]?.stringValue == "desk_A")
        #expect(p["bundleId"]?.stringValue == "com.example.app")
        #expect(p["windowId"]?.intValue == 7)
        #expect(p["permissions"]?.arrayValue?.compactMap(\.stringValue) == ["observe", "act"])
        #expect(p["durationSeconds"]?.intValue == 28800)
        #expect(ACPWindowRequest.params(desktopId: "d", bundleId: "b", windowId: nil, durationSeconds: nil)["windowId"] == nil)
    }

    @Test("[Mock] a grant for the bound window is reported as granted")
    func boundWindowIsGranted() throws {
        let c = WindowClient(binding: .obj([("windowId", .int(7)), ("process", Self.process), ("generation", .int(2))]))
        #expect(try run(c) == .granted(windowGrantId: "wg_1", expiresAt: "2026-10-11T08:00:00Z"))
        #expect(c.methods == ["hub.windows.request", "desktop.show"])
    }

    @Test("[Mock] a grant for another window, another launch, or no binding is reported, not retried or revoked",
          arguments: [
              JSONValue.obj([("windowId", .int(8)), ("process", process)]),
              JSONValue.obj([("windowId", .int(7)), ("process", .obj([("pid", .int(42)), ("startedAt", .string("2026-10-11T01:00:00Z"))]))]),
              JSONValue.null,
          ])
    func otherWindowIsReported(binding: JSONValue) throws {
        let c = WindowClient(binding: binding)
        #expect(try run(c) == .notTheBoundWindow(windowGrantId: "wg_1"))
        #expect(c.methods == ["hub.windows.request", "desktop.show"])
    }

    @Test("[Mock] a refusal (denied, not grantable, not paired) is thrown once, never retried",
          arguments: ["permission_denied", "grant_missing", "pairing_required", "client_revoked", "not_found"])
    func refusalIsNotRetried(code: String) throws {
        let c = WindowClient(binding: .null, requestError: RuntimeError(code, "refused", phase: .request, notSent: true))
        do {
            _ = try run(c)
            Issue.record("expected \(code)")
        } catch let e as RuntimeError {
            #expect(e.code == code)
        }
        #expect(c.methods == ["hub.windows.request"])
    }
}
