import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopProtocol

// contracts/runtime/v1 is the single source for enums, error codes and
// shapes; Swift, C# and the SDKs are checked against the same fixtures.

let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
let contract = RuntimeContract.shared

@Test func embeddedContractEqualsTheRepositoryCopy() throws {
    let embedded = RuntimeContract.embedded
    for (name, text) in [("runtime.schema", embedded.schema), ("methods", embedded.methods), ("errors", embedded.errors)] {
        let repo = try String(contentsOf: repoRoot.appendingPathComponent("contracts/runtime/v1/\(name).json"), encoding: .utf8)
        // The generator writes the file followed by the closing delimiter's line.
        #expect(repo == text + "\n" || repo == text,
                "\(name).json differs from RuntimeContractData.swift; run scripts/generate-runtime-contract.sh")
    }
}

@Test func everyFixtureMatchesItsVerdict() throws {
    let dir = repoRoot.appendingPathComponent("contracts/fixtures/runtime/v1")
    let files = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".json") }.sorted()
    #expect(files.count >= 15)
    for f in files {
        let doc = try StrictJSON.parse(Data(contentsOf: dir.appendingPathComponent(f)))
        let def = try #require(doc["def"]?.stringValue, "\(f) names no def")
        let instance = try #require(doc["instance"], "\(f) has no instance")
        let violations = contract.validate(instance, def)
        if f.hasSuffix(".valid.json") {
            #expect(violations.isEmpty, "\(f): \(violations)")
        } else {
            #expect(f.hasSuffix(".invalid.json"), "\(f) must end in .valid.json or .invalid.json")
            let holds = !(violations.isEmpty)
            #expect(holds, "\(f) should be refused")
        }
    }
}

@Test func methodCatalogMatchesTheImplementedMethods() {
    #expect(Set(contract.methods.map(\.method)) == Set(RuntimeMethod.allCases.map(\.rawValue)))
    for m in contract.methods {
        let holds = !(contract.validate(.obj([]), m.params).contains { $0.contains("$ref") })
        #expect(holds, "\(m.params) missing")
        #expect(m.mutation == false, "PR1 exposes reads only: \(m.method)")
    }
}

@Test func errorTableGivesThePlanExitClasses() throws {
    let expected: [String: Int32] = [
        "invalid_argument": 2, "schema_invalid": 2, "runtime_offline": 3, "permission_denied": 4,
        "approval_required": 4, "control_busy": 5, "stale_observation": 5, "idempotency_conflict": 5,
        "version_mismatch": 6, "capability_missing": 6, "model_unavailable": 6, "execution_failed": 7,
        "wait_timeout": 8, "request_acceptance_unknown": 9, "action_delivery_unknown": 9,
        "cancel_acceptance_unknown": 9,
    ]
    for (code, exit) in expected {
        #expect(try #require(contract.error(code)).exitCode == exit, "\(code)")
    }
    #expect(Set(contract.errors.map(\.code)).count == contract.errors.count)
}

@Test func swiftModelsWriteTheSchemaShapes() {
    let identity = RuntimeIdentity(instanceId: "rt_1", pid: 42, startedAt: Timestamp.string(Date()),
                                   endpoint: "/tmp/r.sock", buildSource: "unknown")
    #expect(contract.validate(identity.json, "RuntimeIdentity").isEmpty)
    #expect(RuntimeIdentity(json: identity.json) == identity)
    let status = RuntimeStatus(instanceId: "rt_1", state: "running", startedAt: identity.startedAt,
                               uptimeSeconds: 1.23456, connections: 1, desktops: 0, sessions: 0, runs: 0)
    #expect(contract.validate(status.json, "RuntimeStatus").isEmpty)
    let window = WindowSummary(windowId: 7, process: ProcessIdentity(pid: 3, startedAt: nil), appName: "微信",
                               bundleId: nil, title: "a\n\"b\"", frame: Rect(x: -1.5, y: 0, width: 10, height: 20),
                               onScreen: true)
    #expect(contract.validate(window.json, "Window").isEmpty)
    let app = AppSummary(process: ProcessIdentity(pid: 3, startedAt: Timestamp.string(Date())), bundleId: "x.y",
                         name: "Y", active: false, hidden: true)
    #expect(contract.validate(app.json, "App").isEmpty)
    let desktop = Desktop(desktopId: "d_001", name: "workspace-demo", state: "ready", createdAt: Timestamp.string(Date()))
    #expect(contract.validate(desktop.json, "Desktop").isEmpty)
}

@Test func requestAndResponseRoundTrip() throws {
    var r = RuntimeRequest(.desktopShow, params: .obj([("desktopId", .string("d_1"))]))
    r.context = RequestContext(sessionId: "s_1")
    #expect(contract.validate(r.json, "Request").isEmpty)
    #expect(RuntimeRequest(validated: try StrictJSON.parse(r.json.encodedData())) == r)

    let ok = RuntimeResponse.success(r.requestId, .obj([("x", .int(1))]))
    let failed = RuntimeResponse.failure(nil, RuntimeError("frame_too_large", "big", phase: .request))
    for resp in [ok, failed] {
        #expect(contract.validate(resp.json, "Response").isEmpty)
        #expect(RuntimeResponse(validated: resp.json) == resp)
        let holds = !(resp.json.encoded().contains("\n"))
        #expect(holds, "one response is one line")
    }
}

@Test func newRequestIdsAreValidAndDistinct() {
    let ids = (0..<100).map { _ in RuntimeRequest.newId() }
    #expect(Set(ids).count == 100)
    #expect(ids.allSatisfy { contract.validate(.string($0), "Id").isEmpty })
}

@Test func lineChannelKeepsBytesAfterALineAndRefusesOversizedMessages() throws {
    var fds: [Int32] = [0, 0]
    #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    defer { close(fds[0]); close(fds[1]) }
    let reader = LineChannel(fd: fds[0], limit: 16)
    _ = "ab\ncd\n".withCString { write(fds[1], $0, 6) }
    #expect(reader.readLine() == .line(Data("ab".utf8)))
    #expect(reader.readLine() == .line(Data("cd".utf8)))
    _ = String(repeating: "x", count: 20).withCString { write(fds[1], $0, 20) }
    #expect(reader.readLine() == .tooLarge)
}

