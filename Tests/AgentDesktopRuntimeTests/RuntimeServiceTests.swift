import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

let contract = RuntimeContract.shared

/// Answer one line on `conn` and check the reply against the Response schema.
func answer(_ service: RuntimeService, _ line: String, _ conn: ConnectionState) -> RuntimeResponse {
    let r = service.respond(to: Data(line.utf8), on: conn)
    #expect(contract.validate(r.json, "Response").isEmpty, "reply breaks the schema: \(r.json.encoded())")
    return r
}

func code(_ r: RuntimeResponse) -> String? {
    if case let .failure(e) = r.result { return e.code }
    return nil
}

func data(_ r: RuntimeResponse) -> JSONValue? {
    if case let .success(d) = r.result { return d }
    return nil
}

func handshaken(_ s: RuntimeService) -> ConnectionState {
    let c = ConnectionState(peerUID: getuid())
    _ = answer(s, handshakeLine, c)
    return c
}

@Test func malformedMessagesAreRefusedWithoutARequestId() {
    let s = makeService()
    let c = ConnectionState(peerUID: getuid())
    for line in ["not json", "[1]", #"{"requestId":"a","requestId":"b"}"#] {
        let r = answer(s, line, c)
        #expect(code(r) == "schema_invalid", "\(line)")
    }
    #expect(answer(s, "not json", c).requestId == nil)
}

@Test func anotherApiVersionIsAVersionMismatch() {
    let r = answer(makeService(), #"{"apiVersion":"agentdesktop.ai/1","requestId":"r1","method":"runtime.status","params":{}}"#,
                   ConnectionState(peerUID: getuid()))
    #expect(code(r) == "version_mismatch")
    #expect(r.requestId == "r1")
}

@Test func selfDeclaredIdentityFieldsAreRefused() {
    let s = makeService()
    let r = answer(s, #"{"apiVersion":"agentdesktop.runtime/1","requestId":"r1","method":"runtime.status","callerId":"root","params":{}}"#,
                   handshaken(s))
    #expect(code(r) == "schema_invalid")
}

@Test func everyMethodButHandshakeNeedsAHandshakeFirst() {
    let s = makeService()
    let c = ConnectionState(peerUID: getuid())
    #expect(code(answer(s, requestLine("runtime.status"), c)) == "handshake_required")
    #expect(data(answer(s, handshakeLine, c))?["product"]?.stringValue == "AgentDesktop")
    #expect(data(answer(s, requestLine("runtime.status"), c)) != nil)
}

@Test func handshakeWithoutACommonVersionFails() {
    let s = makeService()
    let c = ConnectionState(peerUID: getuid())
    let r = answer(s, requestLine("runtime.handshake",
                                  params: #"{"apiVersions":["agentdesktop.runtime/9"],"client":{"name":"t","version":"1"}}"#), c)
    #expect(code(r) == "version_mismatch")
    #expect(code(answer(s, requestLine("runtime.status"), c)) == "handshake_required", "a failed handshake grants nothing")
}

@Test func unknownMethodsAreMissingCapabilities() {
    let s = makeService()
    let c = handshaken(s)
    #expect(code(answer(s, requestLine("act"), c)) == "capability_missing")
    #expect(code(answer(s, requestLine("desktop.create"), c)) == "capability_missing")
}

@Test func paramsAreCheckedAgainstTheirSchema() {
    let s = makeService()
    let c = handshaken(s)
    #expect(code(answer(s, requestLine("runtime.status", params: #"{"x":1}"#), c)) == "schema_invalid")
    #expect(code(answer(s, requestLine("window.list", params: #"{"pid":1,"bundleId":"a"}"#), c)) == "schema_invalid")
    #expect(code(answer(s, requestLine("desktop.show", params: "{}"), c)) == "schema_invalid")
}

@Test func statusCountsWhatTheRuntimeHolds() throws {
    let desktops = DesktopRegistry()
    let s = makeService(desktops: desktops)
    s.connectionCount = { 3 }
    let c = handshaken(s)
    var d = try #require(data(answer(s, requestLine("runtime.status"), c)))
    #expect(contract.validate(d, "RuntimeStatus").isEmpty)
    #expect(d["connections"]?.intValue == 3)
    #expect(d["desktops"]?.intValue == 0)
    desktops.add(Desktop(desktopId: "d_001", name: "w", state: "ready", createdAt: Timestamp.string(Date())))
    d = try #require(data(answer(s, requestLine("runtime.status"), c)))
    #expect(d["desktops"]?.intValue == 1)
}

@Test func capabilitiesReportInterfaceAndBackendApart() throws {
    var backend = FixedBackend()
    backend.perms = BackendPermissions(screenRecording: .denied, accessibility: .granted)
    let s = makeService(backend: backend)
    let d = try #require(data(answer(s, requestLine("runtime.capabilities"), handshaken(s))))
    #expect(contract.validate(d, "Capabilities").isEmpty)
    let methods = d["interface"]?["methods"]?.arrayValue?.compactMap { $0["method"]?.stringValue } ?? []
    #expect(Set(methods) == Set(RuntimeMethod.allCases.map(\.rawValue)))
    #expect(d["backend"]?["permissions"]?["screenRecording"]?.stringValue == "denied")
}

@Test func desktopShowFindsOrReportsNotFound() throws {
    let desktops = DesktopRegistry()
    desktops.add(Desktop(desktopId: "d_001", name: "w", state: "ready", createdAt: Timestamp.string(Date())))
    let s = makeService(desktops: desktops)
    let c = handshaken(s)
    #expect(data(answer(s, requestLine("desktop.show", params: #"{"desktopId":"d_001"}"#), c))?["name"]?.stringValue == "w")
    let missing = answer(s, requestLine("desktop.show", id: "r9", params: #"{"desktopId":"d_404"}"#), c)
    #expect(code(missing) == "not_found")
    #expect(missing.requestId == "r9")
    let list = try #require(data(answer(s, requestLine("desktop.list"), c)))
    #expect(contract.validate(list, "DesktopList").isEmpty)
}

@Test func windowListFiltersByProcessOrApp() throws {
    let s = makeService()
    let c = handshaken(s)
    let all = try #require(data(answer(s, requestLine("window.list"), c)))
    #expect(contract.validate(all, "WindowList").isEmpty)
    #expect(all["windows"]?.arrayValue?.count == 2)
    let byPid = try #require(data(answer(s, requestLine("window.list", params: #"{"pid":202}"#), c)))
    #expect(byPid["windows"]?.arrayValue?.first?["title"]?.stringValue == "文件传输助手 \"草稿\"\n第二行")
    let byApp = try #require(data(answer(s, requestLine("window.list", params: #"{"bundleId":"com.apple.calculator"}"#), c)))
    #expect(byApp["windows"]?.arrayValue?.count == 1)
    let withHidden = try #require(data(answer(s, requestLine("window.list", params: #"{"pid":202,"includeOffscreen":true}"#), c)))
    #expect(withHidden["windows"]?.arrayValue?.count == 2)
    let apps = try #require(data(answer(s, requestLine("app.list"), c)))
    #expect(contract.validate(apps, "AppList").isEmpty)
}

@Test func theMacBackendAnswersWithSchemaShapes() {
    // Read-only and permission-independent: listing needs no grant.
    let s = makeService(backend: MacBackend())
    let c = handshaken(s)
    for (method, def) in [("app.list", "AppList"), ("window.list", "WindowList"), ("runtime.capabilities", "Capabilities")] {
        let d = data(answer(s, requestLine(method), c))
        #expect(d.map { contract.validate($0, def) } == [], "\(method)")
    }
    #expect(MacBackend.identity(getpid()).startedAt != nil)
}
