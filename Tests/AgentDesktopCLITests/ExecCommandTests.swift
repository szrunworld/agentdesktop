import AgentDesktopClient
import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktopCLI

@Test func actAndRunCommandsMapToTheirRequests() {
    let cases: [([String], String, JSONValue)] = [
        (["act", "click", "--session", "s", "--snapshot", "o", "--element", "el_1"], "act",
         .obj([("snapshotId", .string("o")), ("action", .obj([("kind", .string("click")), ("target", .obj([("elementRef", .string("el_1"))]))]))])),
        (["act", "click", "--session", "s", "--snapshot", "o", "--image-point", "392,210", "--right"], "act",
         .obj([("snapshotId", .string("o")), ("action", .obj([("kind", .string("click")),
              ("target", .obj([("imagePoint", .obj([("x", .int(392)), ("y", .int(210))]))])), ("button", .string("right"))]))])),
        (["act", "type", "--session", "s", "--snapshot", "o", "--element", "el_2", "--text", "你好\n第二行"], "act",
         .obj([("snapshotId", .string("o")), ("action", .obj([("kind", .string("type")), ("target", .obj([("elementRef", .string("el_2"))])),
              ("text", .string("你好\n第二行"))]))])),
        (["act", "key", "--session", "s", "--snapshot", "o", "--key", "v", "--modifiers", "cmd,shift"], "act",
         .obj([("snapshotId", .string("o")), ("action", .obj([("kind", .string("key")), ("key", .string("v")),
              ("modifiers", .array([.string("cmd"), .string("shift")]))]))])),
        (["wait", "--session", "s", "--element-present", "--label", "完成", "--wait-timeout", "2s"], "wait",
         .obj([("condition", .obj([("kind", .string("elementPresent")), ("label", .string("完成"))])), ("timeoutMs", .int(2000))])),
        (["run", "show", "run_1"], "run.show", .obj([("runId", .string("run_1"))])),
        (["run", "list", "--origin", "gui_explorer", "--active", "--limit", "500"], "run.list",
         .obj([("origin", .string("gui_explorer")), ("active", .bool(true)), ("limit", .int(200))])),
        (["runtime", "stop-all", "--request-id", "stop-1"], "runtime.stopAll", .obj([("scope", .string("all_platform_runs"))])),
        (["runtime", "enable-input"], "runtime.enableInput", .obj([])),
    ]
    for (args, method, params) in cases {
        let h = Harness()
        _ = h.cli.run(args + ["--format", "json"])
        #expect(h.requests == [method], "\(args)")
        #expect(h.clients.first?.calls.first?.params == params, "\(args)")
        let sent = h.clients.first?.calls.first?.json ?? .null
        let violations = RuntimeContract.shared.validate(sent, "Request")
        #expect(violations.isEmpty, "\(args): \(violations)")
    }
}

@Test func badActArgumentsNeverConnect() {
    for args: [String] in [
        ["act", "click", "--session", "s", "--snapshot", "o"],
        ["act", "click", "--session", "s", "--snapshot", "o", "--element", "e", "--image-point", "1,2"],
        ["act", "click", "--session", "s", "--snapshot", "o", "--image-point", "-1,2"],
        ["act", "type", "--session", "s", "--snapshot", "o"],
        ["act", "type", "--session", "s", "--snapshot", "o", "--text", "a", "--text-file", "f"],
        ["act", "click", "--session", "s", "--element", "e"],
        ["act", "click", "--snapshot", "o", "--element", "e"],   // no session and no context
        ["wait", "--session", "s", "--label", "x"],
        ["run", "cancel", "r", "--wait-timeout", "5s"],
        ["run", "events", "r", "--after", "-1"],
        ["events", "watch", "--after", "x"],
        ["events", "watch", "--format", "json"],
        ["session", "exec", "--desktop", "d", "ls"],
        ["session", "exec", "--desktop", "d", "--session", "s", "--", "ls"],
        ["session", "exec", "--", "ls"],
        ["session", "exec", "--desktop", "d", "--"],
    ] {
        let h = Harness()
        #expect(h.cli.run(args) == 2, "\(args)")
        #expect(h.clients.isEmpty, "\(args)")
    }
}

@Test func textFromAFileIsReadJustBeforeSending() throws {
    let h = Harness()
    var cli = h.cli
    cli.readFile = { _ in Data("草稿 \"引号\"\n".utf8) }
    #expect(cli.run(["act", "type", "--session", "s", "--snapshot", "o", "--text-file", "draft.txt", "--format", "json"]) == 0)
    #expect(h.clients.first?.calls.first?.params["action"]?["text"]?.stringValue == "草稿 \"引号\"\n")
    let missing = Harness()
    var cli2 = missing.cli
    cli2.readFile = { _ in throw CocoaError(.fileNoSuchFile) }
    #expect(cli2.run(["act", "type", "--session", "s", "--snapshot", "o", "--text-file", "nope"]) == 2)
    #expect(missing.clients.isEmpty)
}

@Test func runCancelWaitsForTheCurrentStateNotTheCachedAccept() throws {
    let h = Harness()
    var waits = 0
    h.answer = { r in
        switch r.method {
        case "run.cancel":
            return .obj([("cancelRequest", .obj([("accepted", .bool(true)), ("scope", .obj([("kind", .string("run")), ("id", .string("run_1"))]))])),
                         ("execution", .obj([("phase", .string("stopping")), ("quiescence", .string("pending")), ("outcome", .null), ("revision", .int(2))]))])
        case "run.wait":
            waits += 1
            if waits < 3 { throw RuntimeError("wait_timeout", "still cancelling", phase: .handler) }
            return .obj([("runId", .string("run_1")), ("phase", .string("ended")), ("outcome", .string("cancelled")),
                         ("quiescence", .string("confirmed")), ("revision", .int(4))])
        default: return .obj([])
        }
    }
    #expect(h.run("run", "cancel", "run_1", "--wait", "--request-id", "c-1", "--format", "json") == 0)
    let v = try h.json()
    #expect(v["data"]?["execution"]?["outcome"]?.stringValue == "cancelled")
    #expect(v["data"]?["execution"]?["quiescence"]?.stringValue == "confirmed")
    #expect(h.requests.filter { $0 == "run.cancel" }.count == 1, "never cancels twice")
}

@Test func runWaitTimeoutLeavesTheRunAlone() throws {
    let h = Harness()
    h.answer = { _ in throw RuntimeError("wait_timeout", "run run_1 is still running", phase: .handler,
                                         details: .obj([("state", .string("running")), ("quiescent", .bool(false))])) }
    var clock = Date(timeIntervalSince1970: 0)
    var cli = h.cli
    cli.now = { clock }
    cli.sleep = { clock = clock.addingTimeInterval($0) }
    var calls = 0
    let inner = cli.makeClient
    cli.makeClient = { e in
        let c = inner(e) as! RecordingClient
        let answer = c.answer
        c.answer = { r in calls += 1; clock = clock.addingTimeInterval(5); return try answer(r) }
        return c
    }
    #expect(cli.run(["run", "wait", "run_1", "--wait-timeout", "12s", "--format", "json"]) == 8)
    #expect(!h.requests.contains("run.cancel"))
    #expect(try h.json()["error"]?["message"]?.stringValue?.contains("the run continues") == true)
}

@Test func insideSessionExecTheContextSuppliesTargetAndRun() throws {
    let dir = NSTemporaryDirectory() + "adt-ctx-\(getpid())-\(UUID().uuidString.prefix(6))"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let ctx = ExecContext(endpoint: "/tmp/ctx.sock", desktopId: "d_1", sessionId: "s_ctx", runId: "run_ctx",
                          token: String(repeating: "ab", count: 32))
    let file = try ctx.write(directory: dir)
    var st = stat()
    #expect(stat(file, &st) == 0 && st.st_mode & 0o777 == 0o600)

    let h = Harness()
    h.environment[ExecContext.environmentKey] = file
    #expect(h.run("act", "click", "--snapshot", "o", "--element", "el_1", "--format", "json") == 0)
    let client = try #require(h.clients.first)
    #expect(client.endpoint.path == "/tmp/ctx.sock")
    #expect(client.calls.map(\.method) == ["run.attach", "act"])
    #expect(client.calls[0].params["token"]?.stringValue == ctx.token)
    #expect(client.calls[1].context == RequestContext(sessionId: "s_ctx", runId: "run_ctx"))

    // A context file others can read is refused.
    chmod(file, 0o644)
    let open = Harness()
    open.environment[ExecContext.environmentKey] = file
    #expect(open.run("observe") == 4)
    #expect(open.clients.isEmpty)
}

@Test func sessionExecOwnsARunAroundTheChild() throws {
    let h = Harness()
    h.answer = { r in
        switch r.method {
        case "session.open": return .obj([("sessionId", .string("s_new")), ("desktopId", .string("d_1")), ("state", .string("open"))])
        case "run.start":
            return .obj([("run", .obj([("runId", .string("run_9")), ("desktopId", .string("d_1")), ("state", .string("running"))])),
                         ("attachToken", .string(String(repeating: "cd", count: 32)))])
        case "run.finish": return .obj([("runId", .string("run_9")), ("state", .string("completed")), ("quiescent", .bool(true))])
        default: return .obj([])
        }
    }
    var seenEnv: [String: String] = [:]
    var fileDuringChild: String?
    var cli = h.cli
    cli.spawnChild = { argv, env in
        #expect(argv == ["/bin/zsh", "./agent-flow.sh", "--flag"])
        seenEnv = env
        let path = env[ExecContext.environmentKey]!
        fileDuringChild = try? String(contentsOfFile: path, encoding: .utf8)
        return 3
    }
    #expect(cli.run(["session", "exec", "--desktop", "d_1", "--format", "json", "--", "/bin/zsh", "./agent-flow.sh", "--flag"]) == 3)
    #expect(h.requests == ["session.open", "run.start", "run.finish", "session.close"])
    #expect(h.clients.count == 1, "one owner connection for the whole exec")
    #expect(h.clients[0].calls[1].context == RequestContext(sessionId: "s_new"))
    #expect(h.clients[0].calls[2].params["exitCode"]?.intValue == 3)
    #expect(fileDuringChild?.contains("run_9") == true)
    #expect(!FileManager.default.fileExists(atPath: seenEnv[ExecContext.environmentKey] ?? "/"), "the context file is removed")
    #expect(!(h.out.joined() + h.err.joined()).contains(String(repeating: "cd", count: 32)), "the token is never printed")
}

@Test func ctrlCDuringSessionExecCancelsTheRun() {
    let h = Harness()
    h.answer = { r in
        r.method == "run.start"
            ? .obj([("run", .obj([("runId", .string("run_9")), ("desktopId", .string("d_1"))])), ("attachToken", .string(String(repeating: "0", count: 64)))])
            : .obj([("runId", .string("run_9")), ("state", .string("cancelled")), ("quiescent", .bool(true))])
    }
    var cli = h.cli
    var interrupted = false
    cli.spawnChild = { _, _ in interrupted = true; return 130 }
    cli.interrupted = { interrupted }
    #expect(cli.run(["session", "exec", "--session", "s_1", "--", "sleep", "100"]) == 130)
    #expect(h.requests == ["run.start", "run.cancel", "run.wait"])
}

@Test func sessionExecEndToEndWithAChildThatObservesAndClicks() throws {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let platform = TinyPlatform()
    let service = { let s = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_exec", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: path, buildSource: "unknown"),
                                 backend: StubBackend(), platform: platform); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; s.socketLaunchRequiresGrant = false; s.socketDiscoveryRequiresGrant = false; s.socketGuiRunRequiresGrant = false; s.socketsSeeOnlyTheirOwn = false; s.socketExtensionsAreReadOnly = false; return s }()
    let server = RuntimeServer(path: path, service: service)
    try server.start()
    defer { server.stop() }

    func cli(_ env: [String: String], _ out: @escaping (String) -> Void) -> CLI {
        var c = CLI()
        c.stdout = out
        c.stderr = { _ in }
        c.environment = env
        c.recordRequest = { _, _, _ in }
        c.interrupted = { false }
        return c
    }
    var setupOut: [String] = []
    let base = ["HOME": "/nonexistent", EndpointResolver.environmentKey: path]
    _ = cli(base) { setupOut.append($0) }.run(["desktop", "create", "--format", "json"])
    let desktop = try #require(try StrictJSON.parse(setupOut.joined())["data"]?["desktopId"]?.stringValue)
    _ = cli(base) { _ in }.run(["window", "bind", "--desktop", desktop, "--pid", "4"])

    var childCodes: [Int32] = []
    var parent = cli(base) { _ in }
    parent.spawnChild = { _, env in
        // The child's own agentdesktop commands, with only the context.
        var childEnv = env
        childEnv.removeValue(forKey: EndpointResolver.environmentKey)
        var obs: [String] = []
        childCodes.append(cli(childEnv) { obs.append($0) }.run(["observe", "--format", "json"]))
        let snap = (try? StrictJSON.parse(obs.joined()))?["data"]?["snapshotId"]?.stringValue ?? ""
        childCodes.append(cli(childEnv) { _ in }.run(["act", "click", "--snapshot", snap, "--element", "el_2"]))
        // Meanwhile a one-shot act from outside is refused: the Desktop is held.
        var outside: [String] = []
        childCodes.append(cli(base) { outside.append($0) }.run(["act", "click", "--session", "s_none", "--snapshot", snap, "--element", "el_2"]))
        return 0
    }
    #expect(parent.run(["session", "exec", "--desktop", desktop, "--", "agent"]) == 0)
    #expect(childCodes[0] == 0 && childCodes[1] == 0)
    #expect(childCodes[2] == 2, "unknown session from outside")
    #expect(platform.performed.count == 1)
    #expect(platform.performed.first?.elementIndex == 2)
    #expect((try? StrictJSON.parse({ var o: [String] = []; _ = cli(base) { o.append($0) }.run(["runtime", "status", "--format", "json"]); return o.joined() }()))?["data"]?["status"]?["runs"]?.intValue == 0, "the Run ended with the exec")
    #expect(service.sessions.openCount == 0, "the exec's own session was closed")
}

@Test func eventsWatchRoutes() throws {
    #expect(try CommandRouter.parse(["events", "watch"]).command == .eventsWatch(runId: nil, after: nil))
    #expect(try CommandRouter.parse(["events", "watch", "--run", "run_1", "--after", "3"]).command
            == .eventsWatch(runId: "run_1", after: 3))
    #expect(try CommandRouter.parse(["events", "watch", "--format", "jsonl"]).format == .jsonl)
}
