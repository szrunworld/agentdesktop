import AgentDesktopClient
@testable import AgentDesktopCLI
import AgentDesktopProtocol
import AgentDesktopRuntime
import Foundation
import Testing

// Endpoint diagnosis (doctor): read only, and an answer on the socket is not
// trusted for that alone.

private func doctor(_ path: String, env extra: [String: String] = [:],
                    signer: @escaping (Data) -> EndpointInspector.Signer = { _ in .same }) -> (Int32, JSONValue?, String) {
    var out: [String] = []
    var cli = CLI()
    // Test binaries are unsigned; the signature check is exercised on its own below.
    cli.peerSigner = signer
    cli.stdout = { out.append($0) }
    cli.stderr = { _ in }
    cli.environment = ["HOME": "/nonexistent", EndpointResolver.environmentKey: path].merging(extra) { $1 }
    cli.launchProduct = { _ in Issue.record("launched"); return "no" }
    let code = cli.run(["doctor", "--format", "json"])
    let text = out.joined()
    return (code, try? StrictJSON.parse(Data(text.utf8)), text)
}

private func diagnosis(_ v: JSONValue?) -> JSONValue? { v?["data"]?["diagnosis"] }

/// Every file in the directory with its size, mode and modification time.
private func snapshot(_ dir: String) -> [String: String] {
    var out: [String: String] = [:]
    for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] {
        var st = stat()
        lstat(dir + "/" + name, &st)
        out[name] = "\(st.st_size) \(st.st_mode) \(st.st_mtimespec.tv_sec).\(st.st_mtimespec.tv_nsec) \(st.st_ino)"
    }
    return out
}

@Test func aHealthyRuntimeIsVerifiedAndNothingIsChanged() throws {
    let rt = try LiveRuntime()
    let before = snapshot(rt.dir)
    let auditBefore = rt.server.service.hub.auditEvents()
    let runsBefore = try StrictJSON.parse(Data(rt.run(["run", "list", "--format", "json"]).1.joined().utf8))["data"]?["runs"]?.arrayValue?.count
    let (code, v, _) = doctor(rt.path)
    #expect(code == 0)
    let d = try #require(diagnosis(v))
    #expect(d["identity"]?.stringValue == "verified", "\(d.encoded())")
    #expect(d["holder"]?.stringValue == "alive" && d["socket"]?.stringValue == "ok")
    #expect(d["peerPid"]?.intValue == Int(getpid()))
    // This test Runtime has no desktop platform, so it offers no Runs;
    // asking cost nothing.
    #expect(d["runsAvailable"] == nil, "protected Run probe is skipped")
    // Read only: no file changed, nothing created, no Run made.
    #expect(snapshot(rt.dir) == before)
    #expect(rt.server.service.hub.auditEvents() == auditBefore, "diagnosis creates no authorization audit entries")
    let runsAfter = try StrictJSON.parse(Data(rt.run(["run", "list", "--format", "json"]).1.joined().utf8))["data"]?["runs"]?.arrayValue?.count
    #expect(runsAfter == runsBefore)
}

@Test func aRuntimeThatClaimsAnotherIdentityIsAMismatch() throws {
    // It answers the handshake, but names a pid that is not the socket's
    // peer and not the lock file's owner.
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let fake = RuntimeIdentity(instanceId: "rt_fake", pid: 99_999, startedAt: Timestamp.string(Date()), endpoint: path,
                               buildSource: "unknown")
    let server = RuntimeServer(path: path, service: RuntimeService(identity: fake, backend: StubBackend()))
    try server.start()
    defer { server.stop() }
    let (code, v, _) = doctor(path)
    let d = try #require(diagnosis(v))
    #expect(d["identity"]?.stringValue == "mismatch", "\(d.encoded())")
    #expect(code != 0)
}

@Test func anAnswerWithoutAnOwnershipRecordIsUnverified() throws {
    let rt = try LiveRuntime()
    // As an older Runtime would have left it: a pid only.
    try Data("\(getpid())\n".utf8).write(to: URL(fileURLWithPath: rt.path + ".lock"))
    let (code, v, _) = doctor(rt.path)
    let d = try #require(diagnosis(v))
    #expect(d["identity"]?.stringValue == "unverified")
    #expect(d["holder"]?.stringValue == "legacy")
    #expect(code == 0, "unverified is a warning, not a failure")
}

@Test func aCrashedOwnersLeftoversAreReportedAndLeftAlone() throws {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = SocketOptions.address(path)!
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
    close(fd)
    chmod(path, 0o600)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
    try p.run()
    p.waitUntilExit()
    let ghost = EndpointRecord(product: "AgentDesktop", productVersion: "0.0.1", pid: p.processIdentifier, instanceId: "rt_ghost",
                               endpoint: path, listening: true, since: "2026-10-01T00:00:00.000Z")
    try Data(ghost.line.utf8).write(to: URL(fileURLWithPath: path + ".lock"))
    let before = snapshot(dir)
    let (code, v, text) = doctor(path)
    let d = try #require(diagnosis(v))
    #expect(d["holder"]?.stringValue == "gone")
    #expect(d["failures"]?.arrayValue?.contains(.string("connect")) == true)
    #expect(code == 3)
    #expect(text.contains("nothing changed here"))
    #expect(snapshot(dir) == before, "diagnosis repairs and removes nothing")
}

@Test func aPidNowOwnedByALaterProcessIsReportedAsReused() throws {
    let rt = try LiveRuntime()
    // A record older than the process now holding that pid.
    var r = try #require((try? String(contentsOfFile: rt.path + ".lock", encoding: .utf8)).flatMap { EndpointRecord.parse($0).record })
    r.since = "2000-01-01T00:00:00.000Z"
    try Data(r.line.utf8).write(to: URL(fileURLWithPath: rt.path + ".lock"))
    let (_, v, _) = doctor(rt.path)
    let d = try #require(diagnosis(v))
    #expect(d["holder"]?.stringValue == "pid_reused")
    #expect(d["identity"]?.stringValue == "unverified")
}

@Test func aSocketOpenToOthersIsNotConnectedTo() throws {
    let rt = try LiveRuntime()
    chmod(rt.path, 0o666)
    let (code, v, _) = doctor(rt.path)
    #expect(diagnosis(v)?["socket"]?.stringValue == "too_open")
    #expect(diagnosis(v)?["peerPid"] == nil, "no connection was made")
    #expect(code == 4)
}

@Test func theExecContextsTokenIsNeverShown() throws {
    let rt = try LiveRuntime()
    let file = rt.dir + "/ctx.json"
    try Data(#"{"endpoint":"\#(rt.path)","desktopId":"d","sessionId":"s","runId":"r","token":"tok-secret-123"}"#.utf8)
        .write(to: URL(fileURLWithPath: file))
    let (_, _, text) = doctor(rt.path, env: ["AGENTDESKTOP_CONTEXT": file])
    #expect(text.contains("exec.context"))
    #expect(!text.contains("tok-secret-123"))
}

@Test func theEnvironmentIsNamed() {
    #expect(EndpointInspector.environment(of: "/Users/u/Library/Application Support/AgentDesktop/runtime.sock", home: "/Users/u") == .product)
    #expect(EndpointInspector.environment(of: "/tmp/adt-x/side.runtime.sock", home: "/Users/u") == .sideInstance)
    #expect(EndpointInspector.environment(of: "/tmp/adt-x/runtime.sock", home: "/Users/u") == .custom)
}


// b9's review of #154.

@Test func aRuntimeNotSignedAsTheProductIsAMismatchAndIsAskedNothingMore() throws {
    let rt = try LiveRuntime()
    let (code, v, text) = doctor(rt.path, signer: { _ in .different })
    let d = try #require(diagnosis(v))
    #expect(d["identity"]?.stringValue == "mismatch")
    #expect(d["runsAvailable"] == nil, "no Run service question after a contradiction")
    #expect(text.contains("not asked: the Runtime's identity is contradicted"))
    #expect(code != 0)
}

@Test func anUncomparableSignatureLeavesTheIdentityUnverified() throws {
    let rt = try LiveRuntime()
    let (_, v, _) = doctor(rt.path, signer: { _ in .unknown })
    #expect(diagnosis(v)?["identity"]?.stringValue == "unverified")
}

@Test func aLockFileThatIsAFifoOrALinkIsNotRead() throws {
    for kind in ["fifo", "link"] {
        let rt = try LiveRuntime()
        let lock = rt.path + ".lock"
        try FileManager.default.removeItem(atPath: lock)
        if kind == "fifo" { #expect(mkfifo(lock, 0o600) == 0) } else { try FileManager.default.createSymbolicLink(atPath: lock, withDestinationPath: "/dev/zero") }
        let started = Date()
        let (_, v, _) = doctor(rt.path)
        #expect(Date().timeIntervalSince(started) < 5, "\(kind): doctor did not wait on the lock file")
        #expect(diagnosis(v)?["holder"]?.stringValue == "unknown", "\(kind)")
        #expect(diagnosis(v)?["identity"]?.stringValue != "verified")
    }
}

@Test func aDirectoryOthersMayWriteFailsTheCheck() throws {
    let rt = try LiveRuntime()
    chmod(rt.dir, 0o777)
    defer { chmod(rt.dir, 0o700) }
    let (code, v, text) = doctor(rt.path)
    #expect(text.contains("others may write the endpoint's directory"))
    #expect(diagnosis(v)?["identity"]?.stringValue != "verified")
    #expect(code == 4)
    // b9's review of 98134e1: nothing is sent to what listens there.
    #expect(diagnosis(v)?["peerPid"] == nil, "no connection was made")
    #expect(diagnosis(v)?["runsAvailable"] == nil && diagnosis(v)?["signer"]?.stringValue != "same", "nothing was asked")
}

// b9's review of 98134e1: the signature is checked on the audit token of the
// process that wrote the handshake reply, read after it, never on a pid.
@Test func theSignerIsAskedAboutTheProcessThatAnswered() throws {
    let rt = try LiveRuntime()
    final class Seen: @unchecked Sendable { var tokens: [Data] = [] }
    let seen = Seen()
    let (_, v, _) = doctor(rt.path, signer: { seen.tokens.append($0); return .same })
    #expect(seen.tokens.count == 1)
    #expect(seen.tokens.first.flatMap(EndpointInspector.auditTokenPID) == getpid())
    #expect(diagnosis(v)?["identity"]?.stringValue == "verified")
    // A token naming no live process (or one that exec'd since) is not compared.
    #expect(EndpointInspector.signer(auditToken: Data(count: 32)) == .unknown)
    #expect(EndpointInspector.signer(auditToken: Data(count: 3)) == .unknown)
}

/// A real connection whose audit token reads differently after the first
/// read: another process (or the same pid after an exec) answering later.
private final class SwappingTokenClient: RuntimeClient {
    let inner: SocketRuntimeClient
    var reads = 0
    init(_ inner: SocketRuntimeClient) { self.inner = inner }
    var endpoint: Endpoint { inner.endpoint }
    func handshake() throws -> RuntimeIdentity { try inner.handshake() }
    func call(_ request: RuntimeRequest) throws -> JSONValue { try inner.call(request) }
    func subscribe(runId: String?, after: Int?) throws -> JSONValue { try inner.subscribe(runId: runId, after: after) }
    func nextEvent() throws -> PushedEvent { try inner.nextEvent() }
    func close() { inner.close() }
    var peer: PeerCredentials? { inner.peer }
    func peerAuditToken() -> Data? {
        reads += 1
        guard var t = inner.peerAuditToken() else { return nil }
        if reads > 1 { t[t.count - 1] ^= 0xFF }
        return t
    }
}

// b9's review of 37c0080: the token is read again after the later calls;
// a different one is a mismatch and what was answered is dropped.
@Test func anotherProcessAnsweringAfterTheHandshakeIsAMismatch() throws {
    let rt = try LiveRuntime()
    let endpoint = Endpoint(path: rt.path, source: .option)
    let swapping = SwappingTokenClient(SocketRuntimeClient(endpoint: endpoint, info: CLI.clientInfo))
    let report = EndpointInspector.inspect(endpoint, home: "/nonexistent", makeClient: { _ in swapping }, signer: { _ in .same })
    #expect(report.identity == .mismatch)
    #expect(report.capabilities == nil && report.runsAvailable == nil)
    #expect(report.failures.contains(.identity))
    // The same connection, read twice without a swap, stays verified.
    let plain = EndpointInspector.inspect(endpoint, home: "/nonexistent",
                                          makeClient: { SocketRuntimeClient(endpoint: $0, info: CLI.clientInfo) }, signer: { _ in .same })
    #expect(plain.identity == .verified, "\(plain.identityNotes)")
}

private struct ForbiddenDoctorCredentialStore: CredentialStore {
    func load(endpoint: String, profile: String) throws -> ClientCredential? {
        Issue.record("doctor read a stored credential")
        return nil
    }
    func save(_ credential: ClientCredential, endpoint: String, profile: String) throws {
        Issue.record("doctor saved a credential")
    }
    func delete(endpoint: String, profile: String) throws {
        Issue.record("doctor deleted a credential")
    }
}

@Test func doctorReportsItsUnpairedIdentityWithoutReadingCredentialsOrAuditingARefusal() throws {
    let rt = try LiveRuntime()
    let before = rt.server.service.hub.auditEvents()
    var output: [String] = []
    var cli = CLI()
    cli.credentials = ForbiddenDoctorCredentialStore()
    cli.peerSigner = { _ in .same }
    cli.stdout = { output.append($0) }
    cli.stderr = { _ in }
    cli.environment = [EndpointResolver.environmentKey: rt.path]
    #expect(cli.run(["doctor", "--format", "json"]) == 0)
    let result = try StrictJSON.parse(output.joined())
    let checks = result["data"]?["checks"]?.arrayValue ?? []
    let auth = checks.first { $0["id"]?.stringValue == "authentication" }
    #expect(auth?["message"]?.stringValue?.contains("role unpaired") == true)
    #expect(diagnosis(result)?["runsAvailable"] == nil)
    #expect(rt.server.service.hub.auditEvents() == before)
}

private final class FailedCapabilitiesClient: RuntimeClient {
    let inner: SocketRuntimeClient
    init(_ inner: SocketRuntimeClient) { self.inner = inner }
    var endpoint: Endpoint { inner.endpoint }
    var peer: PeerCredentials? { inner.peer }
    var principal: JSONValue? { inner.principal }
    func handshake() throws -> RuntimeIdentity { try inner.handshake() }
    func peerAuditToken() -> Data? { inner.peerAuditToken() }
    func close() { inner.close() }
    func call(_ request: RuntimeRequest) throws -> JSONValue {
        #expect(request.method == RuntimeMethod.capabilities.rawValue)
        throw RuntimeError("internal_error", "capabilities probe failed", phase: .request)
    }
}

@Test func aFailedCapabilitiesProbeMakesDoctorUnhealthy() throws {
    let rt = try LiveRuntime()
    var output: [String] = []
    var cli = CLI()
    cli.peerSigner = { _ in .same }
    cli.makeClient = { FailedCapabilitiesClient(SocketRuntimeClient(endpoint: $0, info: CLI.clientInfo)) }
    cli.environment = [EndpointResolver.environmentKey: rt.path]
    cli.stdout = { output.append($0) }
    cli.stderr = { _ in }
    #expect(cli.run(["doctor", "--format", "json"]) != 0)
    let result = try StrictJSON.parse(output.joined())
    #expect(result["data"]?["healthy"] == .bool(false))
    #expect(output.joined().contains("capabilities probe failed"))
}
