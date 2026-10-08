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
        server = RuntimeServer(path: path, service: { let s = RuntimeService(identity: identity, backend: backend); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; s.socketLaunchRequiresGrant = false; s.socketDiscoveryRequiresGrant = false; s.socketGuiRunRequiresGrant = false; s.socketsSeeOnlyTheirOwn = false; return s }())
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
