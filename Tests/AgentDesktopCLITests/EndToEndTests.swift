import AgentDesktopClient
import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktopCLI

// Layer 2 of CLI plan §11: the real CLI code, real client and a real
// RuntimeServer over a Unix socket. Only the platform backend is fixed.

struct StubBackend: RuntimeBackend {
    var perms = BackendPermissions(screenRecording: .granted, accessibility: .granted)
    var platform: Platform { Platform(os: "macos", osVersion: "15.1.0", arch: "arm64") }
    func permissions() -> BackendPermissions { perms }
    func features() -> [String] { ["apps.list", "windows.list"] }
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z") }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        [WindowSummary(windowId: 3, process: ProcessIdentity(pid: 4, startedAt: nil), appName: "备忘录",
                       bundleId: "com.apple.Notes", title: "购物清单", frame: Rect(x: 0, y: 0, width: 500, height: 400),
                       onScreen: true)]
    }
}

final class LiveRuntime {
    let dir: String
    let path: String
    let server: RuntimeServer

    init(backend: RuntimeBackend = StubBackend()) throws {
        var template = Array("/tmp/adt-XXXXXX".utf8CString)
        dir = String(cString: mkdtemp(&template)!)
        path = dir + "/runtime.sock"
        let identity = RuntimeIdentity(instanceId: "rt_live", pid: getpid(), startedAt: Timestamp.string(Date()),
                                       endpoint: path, buildSource: "unknown")
        let service = { let s = RuntimeService(identity: identity, backend: backend, testSocketOwnerToken: cliTestOwner.token); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
        try writeOwnerCredential(service, endpoint: path)
        server = RuntimeServer(path: path, service: service)
        try server.start()
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func run(_ args: [String]) -> (Int32, [String], [String]) {
        var out: [String] = []
        var err: [String] = []
        var cli = CLI()
        cli.credentials = cliTestCredentials
        cli.stdout = { out.append($0) }
        cli.stderr = { err.append($0) }
        cli.environment = ["HOME": "/nonexistent", EndpointResolver.environmentKey: path]
        cli.launchProduct = { _ in Issue.record("launched"); return "no" }
        return (cli.run(args), out, err)
    }
}

@Test func statusOverTheRealSocket() throws {
    let rt = try LiveRuntime()
    let (code, out, err) = rt.run(["runtime", "status", "--format", "json"])
    #expect(code == 0, "\(err)")
    let v = try StrictJSON.parse(out.joined())
    #expect(RuntimeContract.shared.validate(v, "Response").isEmpty)
    #expect(RuntimeContract.shared.validate(v["data"]!["identity"]!, "RuntimeIdentity").isEmpty)
    #expect(RuntimeContract.shared.validate(v["data"]!["status"]!, "RuntimeStatus").isEmpty)
    #expect(v["data"]?["identity"]?["instanceId"]?.stringValue == "rt_live")
    #expect(v["data"]?["status"]?["connections"]?.intValue == 1)

    let (textCode, text, _) = rt.run(["runtime", "status"])
    #expect(textCode == 0)
    #expect(text.joined().contains("endpoint     \(rt.path)"))
}

@Test func windowListTextAndJSONOverTheRealSocket() throws {
    let rt = try LiveRuntime()
    let (code, out, _) = rt.run(["window", "list"])
    #expect(code == 0)
    #expect(out.joined().contains("备忘录"))
    #expect(out.joined().contains("购物清单"))
    let (_, json, _) = rt.run(["window", "list", "--format", "json"])
    #expect(try StrictJSON.parse(json.joined())["data"]?["windows"]?.arrayValue?.first?["title"]?.stringValue == "购物清单")
}

@Test func desktopShowOfAnUnknownIdIsNotFound() throws {
    let rt = try LiveRuntime()
    let (code, out, err) = rt.run(["desktop", "show", "d_404", "--format", "json"])
    #expect(code == 2)
    #expect(err.isEmpty)
    let v = try StrictJSON.parse(out.joined())
    #expect(v["error"]?["code"]?.stringValue == "not_found")
    #expect(v["error"]?["phase"]?.stringValue == "handler")
    #expect(v["requestId"]?.stringValue?.hasPrefix("req_") == true)
}

@Test func doctorPassesAgainstAHealthyRuntimeAndNamesMissingPermissions() throws {
    let healthy = try LiveRuntime()
    let (ok, out, _) = healthy.run(["doctor", "--format", "json"])
    #expect(ok == 0)
    #expect(try StrictJSON.parse(out.joined())["data"]?["healthy"] == .bool(true))

    var backend = StubBackend()
    backend.perms = BackendPermissions(screenRecording: .denied, accessibility: .granted)
    let denied = try LiveRuntime(backend: backend)
    let (code, text, _) = denied.run(["doctor"])
    #expect(code == 4)
    #expect(text.joined().contains("FAIL  permission.screenRecording"))
}

@Test func doctorAndQueriesAgainstNothingAreOffline() {
    var out: [String] = []
    var err: [String] = []
    var cli = CLI()
    cli.credentials = cliTestCredentials
    cli.stdout = { out.append($0) }
    cli.stderr = { err.append($0) }
    cli.environment = ["HOME": "/nonexistent"]
    #expect(cli.run(["doctor"]) == 3)
    #expect(out.joined().contains("FAIL  endpoint"))
    out = []
    #expect(cli.run(["runtime", "status"]) == 3)
    #expect(out.isEmpty)
    #expect(err.joined().contains("runtime_offline"))
    #expect(err.joined().contains("agentdesktop runtime start"))
}

/// The CLI under test speaks to its test Runtime as the owner. That is a
/// test seam (`testSocketOwnerToken`): the product has no socket owner (A4
/// S1). The credential sits in memory, never in a file or the keychain.
let cliTestOwner = ClientCredential(clientId: "local:\(getuid())", token: "adt1_cli-test-owner")
let cliTestCredentials = MemoryCredentialStore()

func writeOwnerCredential(_ s: RuntimeService, endpoint: String) throws {
    try cliTestCredentials.save(cliTestOwner, endpoint: endpoint, profile: "cli")
}

/// The user's window, scripted: approves (A4-SEC-03 CLI test).
final class WindowSaysYes: TrustedConfirmer, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var actions: [String] { lock.withLock { asked } }
    func confirm(_ request: ConfirmationRequest) -> ConfirmationDecision {
        lock.withLock { asked.append(request.action) }
        return .approved(digest: request.digest)
    }
}

/// The CLI is a client like any other (A4 S1/S3): it pairs through the
/// window, keeps its credential in its store (the keychain; here memory),
/// and every owner call it makes is confirmed in the window.
@Test func theCLIPairsThroughTheWindowAndKeepsItsCredentialInItsStore() throws {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let service = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_pair", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: path, buildSource: "unknown"),
                                 backend: StubBackend(), platform: TinyPlatform())
    let window = WindowSaysYes()
    service.confirmer = window
    let server = RuntimeServer(path: path, service: service)
    try server.start()
    defer { server.stop() }
    let store = MemoryCredentialStore()
    func run(_ args: [String]) -> (Int32, JSONValue?) {
        var out: [String] = []
        var cli = CLI()
        cli.credentials = store
        cli.stdout = { out.append($0) }
        cli.stderr = { _ in }
        cli.environment = ["HOME": "/nonexistent", EndpointResolver.environmentKey: path]
        cli.recordRequest = { _, _, _ in }
        let code = cli.run(args + ["--format", "json"])
        return (code, try? StrictJSON.parse(out.joined()))
    }
    // Not paired: refused, and nothing is the owner.
    #expect(run(["desktop", "list"]).0 == 4)
    let (code, paired) = run(["agents", "pair", "--name", "my cli", "--capabilities", "observe,desktop.manage", "--desktops", "created"])
    #expect(code == 0, "\(paired?.encoded() ?? "")")
    let clientId = try #require(paired?["data"]?["clientId"]?.stringValue)
    #expect(try store.load(endpoint: path, profile: "cli")?.clientId == clientId)
    #expect(paired?.encoded().contains("adt1_") == false, "the token is not printed")
    #expect(window.actions == ["hub.pairing.start"])
    #expect(run(["desktop", "list"]).0 == 0)
    // This CLI's code is not verified (no Developer ID yet, A4 R1): sensitive
    // owner calls are refused without asking.
    let (lc, listed) = run(["agents", "list"])
    #expect(lc == 4)
    #expect(listed?["error"]?["details"]?["reason"]?.stringValue == "unverified_identity")
    #expect(window.actions == ["hub.pairing.start"])
    // Its own grant: refused without asking.
    #expect(run(["agents", "grant", clientId, "--capabilities", "observe,act"]).0 == 4)
    // Another app's access: not even to take it away (R1); its own: asked, then done.
    let pairing = try service.hub.startPairing(connectionId: "conn_x", agentName: "other", publisher: nil, requested: .obj([]), callerFacts: .obj([]))
    let (other, _) = try service.hub.approve(pairing, grant: HubStore.Grant(clientId: "", capabilities: ["observe"], desktops: [], apps: [],
                                                                            expiresAt: Timestamp.string(Date().addingTimeInterval(600)),
                                                                            revision: 0, state: "active"))
    #expect(run(["agents", "revoke", other.clientId]).0 == 4)
    #expect(window.actions == ["hub.pairing.start"])
    #expect(service.hub.client(other.clientId)?.state == "active")
    _ = run(["agents", "revoke", clientId])     // its own: the reply may not arrive (its connection is cut)
    #expect(window.actions == ["hub.pairing.start", "hub.clients.revoke"])
    #expect(service.hub.client(clientId)?.state == "revoked")
}
