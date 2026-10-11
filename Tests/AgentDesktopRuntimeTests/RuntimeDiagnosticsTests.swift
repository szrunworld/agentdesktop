import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// PR4: diagnostics.export (Hub v1 W08, HUB-T074). Read-only; least data;
// scoped to the caller; secrets redacted; preview writes nothing.

private func export(_ s: RuntimeService, _ c: ConnectionState, _ params: String = "{}") throws -> (JSONValue, JSONValue?) {
    let r = try #require(data(call(s, c, "diagnostics.export", params: params)), "\(call(s, c, "diagnostics.export", params: params).json.encoded())")
    #expect(contract.validate(r, "DiagnosticsExport").isEmpty, "\(r.encoded())")
    guard let id = r["artifact"]?["artifactId"]?.stringValue else { return (r, nil) }
    let chunk = try #require(data(call(s, c, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)))
    #expect(chunk["eof"] == .bool(true))
    let bytes = try #require(Data(base64Encoded: chunk["dataBase64"]?.stringValue ?? ""))
    return (r, try StrictJSON.parse(bytes))
}

@Test func hubT074_theExportHoldsMetadataAndNoSecretsTypedTextOrScreenshots() throws {
    let sc = try scene()
    _ = act(sc, clickContinue, id: "diag-click")
    _ = act(sc, #"{"kind":"type","text":"TYPED-CANARY-4711"}"#, id: "diag-type")
    let (app, appId, token) = try pairedClient(sc.s, capabilities: ["run"], name: "agent adt1_SECRETCANARYTOKEN0001")
    _ = app
    let shot = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)))
    let screenshotId = shot["image"]?["artifactId"]?.stringValue

    let (result, doc) = try export(sc.s, sc.c)
    let document = try #require(doc)
    #expect(result["manifest"]?["scope"]?["role"]?.stringValue == "owner")
    let text = document.encoded()
    for leak in [token, "SECRETCANARYTOKEN0001", "TYPED-CANARY-4711", "文件传输助手", "/tmp/t.sock", "callerFacts", "outcome\":{"] {
        #expect(!text.contains(leak), "\(leak) leaked")
    }
    if let screenshotId { #expect(!text.contains(screenshotId), "no screenshot reference") }
    let sections = try #require(document["sections"])
    for name in RuntimeService.diagnosticsSections { #expect(sections[name] != nil, "\(name)") }
    #expect(sections["clients"]?.arrayValue?.contains { $0["clientId"]?.stringValue == appId } == true)
    #expect(sections["clients"]?.arrayValue?.first { $0["clientId"]?.stringValue == appId }?["agentName"]?.stringValue == "agent [redacted]")
    #expect(sections["runs"]?["runs"]?.arrayValue?.isEmpty == false)
    #expect(sections["runs"]?["truncated"] == .bool(false))
    #expect(sections["runs"]?["runs"]?.arrayValue?.first?["stop"]?["quiescentAt"] != nil, "stop evidence")
    let requestRows = sections["requests"]?["byMethodAndState"]?.arrayValue ?? []
    #expect(requestRows.contains { $0["method"]?.stringValue == "act" })
    #expect(document["manifest"]?["excluded"]?.arrayValue?.isEmpty == false)
}

@Test func theExportChangesNothing() throws {
    let sc = try scene()
    _ = act(sc, clickContinue)
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe", "run"], desktops: [sc.desktop])
    func snapshot() -> String {
        let runs = sc.s.runs.list(RunStore.ListFilter(), after: nil, limit: 1000).runs.map(\.json).map { $0.encoded() }
        let grants = sc.s.hub.clients().map { "\($0.clientId):\($0.state):\(sc.s.hub.grant($0.clientId)?.revision ?? -1)" }
        let ledger = (try? sc.s.ledger.list(RequestLedger.Filter(), after: nil, limit: 1000).records.count) ?? -1
        return "\(runs)|\(grants)|\(sc.s.desktops.list().map(\.desktopId))|\(sc.s.openConnections.all.count)|\(ledger)|\(sc.s.execution.inputAdmission)"
    }
    let before = snapshot()
    _ = try export(sc.s, sc.c)
    _ = try export(sc.s, app)
    _ = try export(sc.s, sc.c, #"{"preview":true}"#)
    #expect(snapshot() == before, "no Run, grant, Desktop, connection, ledger record or admission change")
}

@Test func aPreviewSaysWhatWouldBeExportedAndWritesNothing() throws {
    let sc = try scene()
    let artifactsBefore = try FileManager.default.contentsOfDirectory(atPath: sc.s.artifacts.directory).count
    let (r, doc) = try export(sc.s, sc.c, #"{"preview":true,"sections":["runtime","runs"]}"#)
    #expect(doc == nil && r["artifact"] == nil && r["preview"] == .bool(true))
    #expect(r["manifest"]?["sections"]?.arrayValue?.compactMap { $0["name"]?.stringValue } == ["runtime", "runs"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: sc.s.artifacts.directory).count == artifactsBefore)
}

@Test func aPairedClientExportsOnlyItsOwnScope() throws {
    let sc = try scene()
    _ = act(sc, clickContinue, id: "owner-act")
    let (app, appId) = try pairedConnection(sc.s, capabilities: ["observe", "run"], name: "app-a")
    let (_, otherId) = try pairedConnection(sc.s, capabilities: ["run"], name: "app-b")
    _ = call(sc.s, app, "hub.clients.list")  // a refusal of its own
    let (r, doc) = try export(sc.s, app)
    #expect(r["manifest"]?["scope"]?["role"]?.stringValue == "paired")
    let sections = try #require(doc?["sections"])
    #expect(sections["clients"]?.arrayValue?.compactMap { $0["clientId"]?.stringValue } == [appId])
    #expect(sections["connections"]?.arrayValue?.allSatisfy { $0["clientId"]?.stringValue == appId } == true)
    #expect(sections["runs"]?["runs"]?.arrayValue?.isEmpty == true, "the owner's Runs are not its")
    #expect(sections["desktops"]?.arrayValue?.isEmpty == true, "no Desktop in its grant")
    #expect(sections["requests"]?["byMethodAndState"]?.arrayValue?.isEmpty == true)
    let text = doc?.encoded() ?? ""
    #expect(!text.contains(otherId))
    // The owner's export reaches no further for it: not readable by the client.
    let (owned, _) = try export(sc.s, sc.c)
    let id = try #require(owned["artifact"]?["artifactId"]?.stringValue)
    #expect(code(call(sc.s, app, "artifact.read", params: #"{"artifactId":"\#(id)"}"#)) == "not_found")
    // Without observe: refused. With observe alone: no Runs.
    let (runner, _) = try pairedConnection(sc.s, capabilities: ["run"], name: "runner")
    #expect(code(call(sc.s, runner, "diagnostics.export")) == "grant_missing")
    let (observer, _) = try pairedConnection(sc.s, capabilities: ["observe"], name: "observer")
    #expect(try export(sc.s, observer).1?["sections"]?["runs"]?["runs"]?.arrayValue?.isEmpty == true)
}

@Test func diagnosticsWorkWithoutADesktopPlatform() throws {
    let s = makeService()
    let c = handshaken(s)
    let r = try #require(data(call(s, c, "diagnostics.export", params: #"{"preview":true}"#)))
    #expect(contract.validate(r, "DiagnosticsExport").isEmpty)
}

@Test func redactionDropsSecretKeysAndCredentialShapes() {
    let v = JSONValue.obj([("token", .string("x")), ("nested", .obj([("apiKey", .string("y")),
                           ("note", .string("use adt1_abcdefghijkl and sk-abcdefghijklmnopqrstu and Bearer abc.def.ghi"))]))])
    let out = RuntimeService.redacted(v).encoded()
    #expect(!out.contains("\"token\"") && !out.contains("apiKey"))
    #expect(!out.contains("adt1_abcdefghijkl") && !out.contains("sk-abc") && !out.contains("abc.def.ghi"))
}

@Test func anotherClientsLeaseIsNotNamedAndUnitRunIsOnlyListedWithAnExecutor() throws {
    let sc = try scene()
    let started = try #require(data(call(sc.s, sc.c, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    let (app, _) = try pairedConnection(sc.s, capabilities: ["observe"], desktops: [sc.desktop])
    let theirs = try #require(try export(sc.s, app).1?["sections"]?["desktops"]?.arrayValue?.first)
    #expect(theirs["leaseHeld"] == .bool(true) && theirs["leaseRunId"] == .null)
    #expect(!(try export(sc.s, app).1?.encoded().contains(started) ?? true))
    let owners = try #require(try export(sc.s, sc.c).1?["sections"]?["desktops"]?.arrayValue?.first { $0["desktopId"]?.stringValue == sc.desktop })
    #expect(owners["leaseRunId"]?.stringValue == started)
    // No GUI executor registered here: unit.run is not offered, as in runtime.capabilities.
    let methods = try export(sc.s, sc.c).1?["sections"]?["capabilities"]?["methods"]?.arrayValue?.compactMap(\.stringValue) ?? []
    #expect(!methods.contains("unit.run") && methods.contains("act"))
}

@Test func theRunsSectionSaysWhenItIsCutShortAndFindsLateStopEvidence() throws {
    let sc = try scene()
    let at = Timestamp.string(Date())
    for i in 0..<(RuntimeService.diagnosticsRunLimit + 3) {
        sc.s.runs.create(RunRecord(runId: "run_bulk\(i)", kind: "act", origin: .agentHub, ownership: .externalClient,
                                   lifetime: .connectionScoped, clientId: "app:x", connectionId: nil, sessionId: "ses_x", desktopId: "d_x",
                                   phase: .ended, outcome: .success, quiescence: .confirmed, closingReason: "completed", revision: 2,
                                   createdAt: at, endedAt: at, receipts: [], unknownActions: 0))
    }
    for _ in 0..<150 { sc.s.runs.appendEvent("run_bulk0", "action.accepted", .obj([("requestId", .string("r")), ("kind", .string("click"))])) }
    sc.s.runs.appendEvent("run_bulk0", "run.quiescent", .obj([("revision", .int(3))]))
    let (r, doc) = try export(sc.s, sc.c, #"{"sections":["runs"]}"#)
    #expect(doc?["sections"]?["runs"]?["truncated"] == .bool(true))
    #expect(r["manifest"]?["sections"]?.arrayValue?.first?["truncated"] == .bool(true))
    #expect(sc.s.runs.events("run_bulk0", types: ["run.quiescent"]).count == 1)
}
