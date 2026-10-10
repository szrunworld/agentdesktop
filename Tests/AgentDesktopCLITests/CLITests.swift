import AgentDesktopClient
import AgentDesktopProtocol
import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktopCLI

// Layer 1 of CLI plan §11: commands and output against an injected client.

/// Records every client the CLI makes and every request it sends.
final class RecordingClient: RuntimeClient {
    let endpoint: Endpoint
    var handshakes = 0
    var calls: [RuntimeRequest] = []
    var closed = false
    var identityResult: Result<RuntimeIdentity, RuntimeError>
    var answer: (RuntimeRequest) throws -> JSONValue

    init(endpoint: Endpoint, identity: Result<RuntimeIdentity, RuntimeError>,
         answer: @escaping (RuntimeRequest) throws -> JSONValue) {
        self.endpoint = endpoint
        self.identityResult = identity
        self.answer = answer
    }

    func handshake() throws -> RuntimeIdentity {
        handshakes += 1
        return try identityResult.get()
    }

    func call(_ request: RuntimeRequest) throws -> JSONValue {
        _ = try handshake()
        calls.append(request)
        return try answer(request)
    }

    func close() { closed = true }
}

let testIdentity = RuntimeIdentity(instanceId: "rt_test", pid: 77, startedAt: "2026-10-08T03:00:00Z",
                                   endpoint: "/tmp/r.sock", buildSource: "abc1234")

final class Harness {
    var out: [String] = []
    var err: [String] = []
    var clients: [RecordingClient] = []
    var launches: [String?] = []
    var identity: Result<RuntimeIdentity, RuntimeError> = .success(testIdentity)
    var answer: (RuntimeRequest) throws -> JSONValue = { _ in .obj([]) }
    var environment = ["HOME": "/Users/test"]
    var executable = "/Applications/Agent Desktop.app/Contents/Resources/bin/agentdesktop"
    var launch: (String?) -> String? = { _ in nil }

    var cli: CLI {
        var c = CLI()
        c.credentials = MemoryCredentialStore()
        c.stdout = { [unowned self] in out.append($0) }
        c.stderr = { [unowned self] in err.append($0) }
        c.environment = environment
        c.executablePath = executable
        c.makeClient = { [unowned self] e in
            let client = RecordingClient(endpoint: e, identity: identity, answer: answer)
            clients.append(client)
            return client
        }
        c.launchProduct = { [unowned self] p in launches.append(p); return launch(p) }
        c.sleep = { _ in }
        return c
    }

    func run(_ args: String...) -> Int32 { cli.run(args) }
    var requests: [String] { clients.flatMap { $0.calls.map(\.method) } }
    func json() throws -> JSONValue {
        #expect(out.count == 1, "exactly one stdout object: \(out)")
        return try StrictJSON.parse(out.joined())
    }
}

@Test func helpNeverConnects() {
    for args in [["help"], ["--help"], ["runtime", "--help"], ["window", "list", "-h"], ["help", "desktop"]] {
        let h = Harness()
        #expect(h.cli.run(args) == 0, "\(args)")
        #expect(h.clients.isEmpty, "\(args) made a client")
        #expect(h.out.joined().contains("usage: agentdesktop"))
    }
    let bare = Harness()
    #expect(bare.cli.run([]) == 2)
    #expect(bare.clients.isEmpty)
}

@Test func badArgumentsAreRefusedBeforeAnyConnection() {
    let cases: [[String]] = [
        ["frobnicate"], ["runtime"], ["runtime", "status", "extra"], ["desktop", "show"],
        ["window", "list", "--pid", "1", "--bundle-id", "a"], ["window", "list", "--pid", "x"],
        ["runtime", "status", "--format", "text", "--format", "text"], ["runtime", "status", "--formatt", "json"],
        ["runtime", "status", "--format", "yaml"], ["runtime", "status", "--format", "jsonl"],
        ["runtime", "start", "--wait-timeout", "soon"], ["app", "list", "--all=yes"], ["desktop", "list", "--endpoint"],
        ["version", "--", "x"],
    ]
    for args in cases {
        let h = Harness()
        #expect(h.cli.run(args) == 2, "\(args)")
        #expect(h.clients.isEmpty, "\(args) connected")
        #expect(h.out.isEmpty, "\(args) wrote stdout in text mode")
        #expect(h.err.first?.hasPrefix("agentdesktop: invalid_argument:") == true, "\(args): \(h.err)")
    }
}

@Test func aRefusedCommandLineStillAnswersInJSONWhenAsked() throws {
    let h = Harness()
    #expect(h.run("desktop", "show", "--format", "json") == 2)
    let v = try h.json()
    #expect(v["ok"] == .bool(false))
    #expect(v["error"]?["code"]?.stringValue == "invalid_argument")
    #expect(v["error"]?["notSent"] == .bool(true))
    #expect(RuntimeContract.shared.validate(v, "Response").isEmpty)
}

@Test func versionIsLocal() throws {
    let h = Harness()
    #expect(h.run("version", "--format", "json") == 0)
    #expect(h.clients.isEmpty)
    let v = try h.json()
    #expect(v["data"]?["apiVersions"] == .array([.string(RuntimeAPI.version)]))
    #expect(v["requestId"] == .null)
}

@Test func eachQuerySendsExactlyItsMethod() {
    let cases: [([String], String, JSONValue)] = [
        (["runtime", "status"], "runtime.status", .obj([])),
        (["runtime", "capabilities"], "runtime.capabilities", .obj([])),
        (["desktop", "list"], "desktop.list", .obj([])),
        (["desktop", "show", "d_001"], "desktop.show", .obj([("desktopId", .string("d_001"))])),
        (["app", "list"], "app.list", .obj([])),
        (["app", "list", "--all"], "app.list", .obj([("includeBackground", .bool(true))])),
        (["window", "list", "--pid", "42"], "window.list", .obj([("pid", .int(42))])),
        (["window", "list", "--bundle-id=com.apple.calculator"], "window.list", .obj([("bundleId", .string("com.apple.calculator"))])),
        (["window", "list", "--all"], "window.list", .obj([("includeOffscreen", .bool(true))])),
    ]
    for (args, method, params) in cases {
        let h = Harness()
        _ = h.cli.run(args + ["--format", "json"])
        #expect(h.clients.count == 1, "\(args)")
        #expect(h.requests == [method], "\(args)")
        #expect(h.clients.first?.calls.first?.params == params, "\(args)")
        #expect(h.clients.first?.closed == true)
        #expect(RuntimeContract.shared.validate(h.clients[0].calls[0].json, "Request").isEmpty)
    }
}

@Test func jsonOutputIsOneParseableLineWithCJKQuotesAndNewlines() throws {
    let h = Harness()
    let title = "文件传输助手 \"草稿\"\n第二行"
    h.answer = { _ in .obj([("windows", .array([WindowSummary(
        windowId: 9, process: ProcessIdentity(pid: 5, startedAt: nil), appName: "微信", bundleId: nil, title: title,
        frame: Rect(x: 0, y: 0, width: 1, height: 1), onScreen: true).json]))]) }
    #expect(h.run("window", "list", "--format", "json") == 0)
    let holds = !(h.out[0].contains("\n"))
    #expect(holds)
    #expect(h.err.isEmpty, "stderr stays clean")
    let v = try h.json()
    #expect(v["data"]?["windows"]?.arrayValue?.first?["title"]?.stringValue == title)
    #expect(RuntimeContract.shared.validate(v, "Response").isEmpty)
}

@Test func runtimeErrorsKeepTheirCodeAndExitClass() throws {
    let cases: [(RuntimeError, Int32)] = [
        (.runtimeOffline("x", endpoint: "/e"), 3),
        (RuntimeError("permission_denied", "x", phase: .connect), 4),
        (RuntimeError("version_mismatch", "x", phase: .handshake), 6),
        (.connectionLost("x"), 9),
        (RuntimeError("something_new", "x", phase: .handler), 1),
    ]
    for (error, exit) in cases {
        let h = Harness()
        h.identity = .failure(error)
        #expect(h.run("desktop", "list", "--format", "json") == exit, "\(error.code)")
        #expect(try h.json()["error"]?["code"]?.stringValue == error.code)
    }
    let notFound = Harness()
    notFound.answer = { _ in throw RuntimeError.notFound("no desktop d_9") }
    #expect(notFound.run("desktop", "show", "d_9") == 2)
    #expect(notFound.out.isEmpty)
    #expect(notFound.err.joined().contains("not_found: no desktop d_9"))
}

@Test func statusAndCapabilitiesNeverStartTheRuntime() {
    for cmd in [["runtime", "status"], ["runtime", "capabilities"], ["doctor"], ["desktop", "list"]] {
        let h = Harness()
        h.identity = .failure(.runtimeOffline("down", endpoint: "/e"))
        _ = h.cli.run(cmd)
        #expect(h.launches.isEmpty, "\(cmd) launched the product")
    }
}

@Test func runtimeStartLeavesARunningRuntimeAlone() throws {
    let h = Harness()
    #expect(h.run("runtime", "start", "--format", "json") == 0)
    #expect(h.launches.isEmpty)
    #expect(try h.json()["data"]?["started"] == .bool(false))
}

@Test func runtimeStartLaunchesTheBundleItShipsInAndWaitsForTheHandshake() throws {
    let h = Harness()
    var attempts = 0
    h.identity = .failure(.runtimeOffline("down", endpoint: "/e"))
    // The product answers on the third probe after the launch.
    h.launch = { [unowned h] _ in
        h.identity = .failure(.runtimeOffline("starting", endpoint: "/e"))
        return nil
    }
    var cli = h.cli
    let inner = cli.makeClient!
    cli.makeClient = { e in
        attempts += 1
        if attempts >= 4 { h.identity = .success(testIdentity) }
        return inner(e)
    }
    #expect(cli.run(["runtime", "start", "--format", "json"]) == 0)
    #expect(h.launches == ["/Applications/Agent Desktop.app"])
    #expect(try h.json()["data"]?["started"] == .bool(true))
}

@Test func runtimeStartTimesOutWithoutChangingAnything() throws {
    let h = Harness()
    h.identity = .failure(.runtimeOffline("down", endpoint: "/e"))
    var clock = Date(timeIntervalSince1970: 0)
    var cli = h.cli
    cli.sleep = { clock = clock.addingTimeInterval($0) }
    cli.now = { clock }
    #expect(cli.run(["runtime", "start", "--wait-timeout", "1s", "--format", "json"]) == 8)
    #expect(try h.json()["error"]?["code"]?.stringValue == "wait_timeout")
    #expect(h.launches.count == 1)
}

@Test func runtimeStartDoesNotLaunchForAnotherEndpoint() {
    let h = Harness()
    h.identity = .failure(.runtimeOffline("down", endpoint: "/e"))
    #expect(h.run("runtime", "start", "--endpoint", "/tmp/side.sock") == 2)
    #expect(h.launches.isEmpty)
    h.environment[EndpointResolver.environmentKey] = "/tmp/side.sock"
    #expect(h.run("runtime", "start") == 2)
    #expect(h.launches.isEmpty)
}

@Test func outsideABundleTheProductIsFoundByBundleID() {
    let h = Harness()
    h.executable = "/Users/test/src/.build/debug/agentdesktop"
    h.identity = .failure(.runtimeOffline("down", endpoint: "/e"))
    h.launch = { _ in "LSOpenURLsWithRole() failed" }
    #expect(h.run("runtime", "start") == 3)
    #expect(h.launches == [nil])
    #expect(h.err.joined().contains("cannot start com.agentdesktop.app"))
}

@Test func textTablesAlignWideCharacters() {
    let t = TextTable.render(["PID", "NAME", "X"], [["1", "BOSS直聘", "a"], ["22", "Finder", "b"]])
    let lines = t.split(separator: "\n").map(String.init)
    let col = lines.map { l in TextTable.width(String(l[..<l.lastIndex(of: " ")!])) }
    #expect(Set(col).count == 1, "last column starts at one display column: \(t)")
}

@Test func contractGroupsGoToTheContractCLIUnchanged() {
    for args in [["ai", "connections", "list"], ["--json", "gui", "status", "--run-id", "r"],
                 ["--socket", "/tmp/s", "rpc", "--request-file", "f"], ["ai", "capabilities"]] {
        let h = Harness()
        var seen: [String]?
        var cli = h.cli
        cli.runContract = { seen = $0; return 0 }
        #expect(cli.run(args) == 0)
        let expected = args.contains("--socket") ? args
            : ["--socket", "/Users/test/Library/Application Support/AgentDesktop/runtime.sock"] + args
        #expect(seen == expected, "\(args)")
        #expect(h.clients.isEmpty)
    }
    let h = Harness()
    var delegated = false
    var cli = h.cli
    cli.runContract = { _ in delegated = true; return 0 }
    _ = cli.run(["runtime", "capabilities"])
    let holds = !(delegated)
    #expect(holds, "runtime capabilities is agentdesktop.runtime/1")
    #expect(h.requests == ["runtime.capabilities"])
}

@Test func windowsCommandsSendTheirMethods() throws {
    let cases: [([String], String, JSONValue)] = [
        (["windows", "request", "--desktop", "d_1", "--app", "com.tencent.xinWeChat", "--allow", "observe,act", "--duration", "1h"],
         "hub.windows.request", .obj([("desktopId", .string("d_1")), ("bundleId", .string("com.tencent.xinWeChat")),
                                      ("permissions", .array([.string("observe"), .string("act")])), ("durationSeconds", .int(3600))])),
        (["windows", "request", "--desktop", "d_1", "--app", "com.tencent.xinWeChat", "--window", "12", "--allow", "observe"],
         "hub.windows.request", .obj([("desktopId", .string("d_1")), ("bundleId", .string("com.tencent.xinWeChat")), ("windowId", .int(12)),
                                      ("permissions", .array([.string("observe")]))])),
        (["windows", "list"], "hub.windows.list", .obj([])),
        (["windows", "list", "--all"], "hub.windows.list", .obj([("includeEnded", .bool(true))])),
        (["windows", "revoke", "wg_1"], "hub.windows.revoke", .obj([("windowGrantId", .string("wg_1"))])),
    ]
    for (args, method, params) in cases {
        let h = Harness()
        _ = h.cli.run(args + ["--format", "json"])
        #expect(h.requests == [method], "\(args)")
        #expect(h.clients.first?.calls.first?.params == params, "\(args)")
        #expect(RuntimeContract.shared.validate(h.clients[0].calls[0].json, "Request").isEmpty, "\(args)")
    }
    // --allow is required, refused before any connection.
    let h = Harness()
    #expect(h.cli.run(["windows", "request", "--desktop", "d_1", "--app", "com.x"]) == 2)
    #expect(h.clients.isEmpty)
    // Durations that do not fit are argument errors, never a crash.
    for d in ["1e309s", "1e300d", "8d", "0.1s"] {
        let h = Harness()
        #expect(h.cli.run(["windows", "request", "--desktop", "d_1", "--app", "com.x", "--allow", "observe", "--duration", d]) == 2, "\(d)")
        #expect(h.clients.isEmpty)
    }
}

@Test func displaysCommandsSendTheirMethods() throws {
    // Owner-only in the Runtime; the CLI only maps them (a paired CLI is told owner_only).
    let cases: [([String], String, JSONValue)] = [
        (["displays", "list"], "hub.displays.list", .obj([])),
        (["displays", "attach", "--display", "1", "--client", "app:wx", "--name", "主显示器"],
         "hub.displays.attach", .obj([("displayId", .int(1)), ("clientId", .string("app:wx")), ("name", .string("主显示器"))])),
        (["displays", "attach", "--display", "2", "--client", "app:wx"],
         "hub.displays.attach", .obj([("displayId", .int(2)), ("clientId", .string("app:wx"))])),
        (["displays", "detach", "d_1"], "hub.displays.detach", .obj([("desktopId", .string("d_1"))])),
        (["displays", "detach", "d_1", "--client", "app:wx"], "hub.displays.detach", .obj([("desktopId", .string("d_1")), ("clientId", .string("app:wx"))])),
    ]
    for (args, method, params) in cases {
        let h = Harness()
        _ = h.cli.run(args + ["--format", "json"])
        #expect(h.requests == [method], "\(args)")
        #expect(h.clients.first?.calls.first?.params == params, "\(args)")
        #expect(RuntimeContract.shared.validate(h.clients[0].calls[0].json, "Request").isEmpty, "\(args)")
    }
    // Refused locally, before any connection.
    for args in [["displays", "attach", "--client", "app:wx"], ["displays", "attach", "--display", "1"],
                 ["displays", "attach", "--display", "0", "--client", "app:wx"], ["displays", "detach"]] {
        let h = Harness()
        #expect(h.cli.run(args) == 2, "\(args)")
        #expect(h.clients.isEmpty, "\(args)")
    }
}
