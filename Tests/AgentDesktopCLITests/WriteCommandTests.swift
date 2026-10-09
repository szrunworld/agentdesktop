import CryptoKit
import AgentDesktopClient
import AgentDesktopProtocol
@testable import AgentDesktopRuntime
import Foundation
import Testing
@testable import AgentDesktopCLI

@Test func writeCommandsMapToTheirMethodsAndParams() {
    let cases: [([String], String, JSONValue, RequestContext)] = [
        (["desktop", "create", "--name", "w", "--size", "1280x800"], "desktop.create",
         .obj([("name", .string("w")), ("width", .int(1280)), ("height", .int(800))]), .init()),
        (["desktop", "destroy", "d_1"], "desktop.destroy", .obj([("desktopId", .string("d_1"))]), .init()),
        (["app", "launch", "--desktop", "d_1", "--bundle-id", "com.apple.Notes", "--new-instance"], "app.launch",
         .obj([("desktopId", .string("d_1")), ("bundleId", .string("com.apple.Notes")), ("newInstance", .bool(true))]), .init()),
        (["window", "bind", "--desktop", "d_1", "--pid", "42", "--window", "7"], "window.bind",
         .obj([("desktopId", .string("d_1")), ("pid", .int(42)), ("windowId", .int(7))]), .init()),
        (["window", "unbind", "--desktop", "d_1"], "window.unbind", .obj([("desktopId", .string("d_1"))]), .init()),
        (["session", "open", "--desktop", "d_1"], "session.open", .obj([("desktopId", .string("d_1"))]), .init()),
        (["session", "show", "s_1"], "session.show", .obj([("sessionId", .string("s_1"))]), .init()),
        (["session", "close", "s_1"], "session.close", .obj([("sessionId", .string("s_1"))]), .init()),
        (["observe", "--session", "s_1", "--query", "继续", "--no-elements"], "observe",
         .obj([("query", .string("继续")), ("elements", .bool(false))]), RequestContext(sessionId: "s_1")),
        (["observe", "--desktop", "d_1"], "observe", .obj([]), RequestContext(desktopId: "d_1")),
        (["request", "show", "r-1"], "request.show", .obj([("requestId", .string("r-1"))]), .init()),
    ]
    for (args, method, params, context) in cases {
        let h = Harness()
        h.answer = { _ in .obj([]) }
        _ = h.cli.run(args + ["--format", "json"])
        #expect(h.requests == [method], "\(args)")
        #expect(h.clients.first?.calls.first?.params == params, "\(args)")
        #expect(h.clients.first?.calls.first?.context == context, "\(args)")
    }
}

@Test func badWriteArgumentsNeverConnect() {
    let cases: [[String]] = [
        ["desktop", "create", "--size", "big"], ["app", "launch", "--desktop", "d"],
        ["app", "launch", "--desktop", "d", "--bundle-id", "a", "--path", "/b"], ["window", "bind", "--desktop", "d"],
        ["window", "bind", "--desktop", "d", "--pid", "0"], ["observe"], ["observe", "--session", "s", "--desktop", "d"],
        ["observe", "--desktop", "d", "--no-screenshot", "--image-output", "/tmp/x.png"],
        ["desktop", "destroy", "d", "--request-id", "has space"], ["session", "show", "s", "--request-id", "x"],
    ]
    for args in cases {
        let h = Harness()
        #expect(h.cli.run(args) == 2, "\(args)")
        #expect(h.clients.isEmpty, "\(args)")
    }
}

@Test func aWriteIsRecordedBeforeItIsSentAndKeepsItsRequestId() throws {
    let h = Harness()
    var log: [(String, String, String)] = []
    var cli = h.cli
    cli.recordRequest = { id, m, e in
        #expect(h.clients.first?.calls.isEmpty ?? true, "recorded before sending")
        log.append((id, m, e))
    }
    #expect(cli.run(["desktop", "create", "--request-id", "mine-1", "--format", "json"]) == 0)
    #expect(log.count == 1)
    #expect(log.first?.0 == "mine-1" && log.first?.1 == "desktop.create")
    #expect(h.clients.first?.calls.first?.requestId == "mine-1")
    #expect(try h.json()["requestId"]?.stringValue == "mine-1")

    // Reads are not logged.
    log = []
    _ = cli.run(["desktop", "list"])
    #expect(log.isEmpty)
}

@Test func aLostReplyToAWriteIsAnUnknownOutcomeNotAnOfflineRuntime() throws {
    let h = Harness()
    h.answer = { _ in throw RuntimeError.connectionLost("the Runtime closed the connection before replying") }
    #expect(h.run("desktop", "destroy", "d_1", "--request-id", "kill-1", "--format", "json") == 9)
    let e = try h.json()["error"]
    #expect(e?["code"]?.stringValue == "request_acceptance_unknown")
    #expect(e?["message"]?.stringValue?.contains("request show kill-1") == true)
}

@Test func observeSavesTheScreenshotByIdNotByPath() throws {
    let h = Harness()
    let png = Data((0..<700_000).map { UInt8($0 % 251) })
    let sha = SHA256.hash(data: png).map { String(format: "%02x", $0) }.joined()
    h.answer = { r in
        switch r.method {
        case "observe":
            return .obj([("snapshotId", .string("obs_1")), ("image", .obj([("artifactId", .string("art_1"))])),
                         ("elements", .array([]))])
        case "artifact.show":
            return .obj([("artifactId", .string("art_1")), ("byteSize", .int(png.count)), ("sha256", .string(sha))])
        default:
            // Two chunks, the way the Runtime caps one read.
            let offset = r.params["offset"]?.intValue ?? 0
            let part = png.subdata(in: offset..<min(png.count, offset + 524_288))
            return .obj([("artifactId", .string("art_1")), ("offset", .int(offset)), ("length", .int(part.count)),
                         ("eof", .bool(offset + part.count >= png.count)), ("dataBase64", .string(part.base64EncodedString()))])
        }
    }
    var written: (Data, String)?
    var cli = h.cli
    cli.writeFile = { written = ($0, $1) }
    #expect(cli.run(["observe", "--desktop", "d_1", "--image-output", "/tmp/out.png", "--format", "json"]) == 0)
    #expect(written?.0 == png)
    #expect(written?.1 == "/tmp/out.png")
    #expect(h.clients[0].calls.map(\.method) == ["observe", "artifact.show", "artifact.read", "artifact.read"])
    #expect(try h.json()["data"]?["savedTo"]?.stringValue == "/tmp/out.png")
}

@Test func aChangedArtifactIsNotSaved() throws {
    let h = Harness()
    h.answer = { r in
        r.method == "artifact.show"
            ? .obj([("artifactId", .string("art_1")), ("sha256", .string(String(repeating: "0", count: 64)))])
            : .obj([("artifactId", .string("art_1")), ("offset", .int(0)), ("length", .int(3)), ("eof", .bool(true)),
                    ("dataBase64", .string("AAAA"))])
    }
    var cli = h.cli
    var wrote = false
    cli.writeFile = { _, _ in wrote = true }
    #expect(cli.run(["artifact", "get", "art_1", "--out", "/tmp/x.png", "--format", "json"]) == 7)
    #expect(wrote == false)
}

/// A minimal platform for the end-to-end flow over a real socket.
final class TinyPlatform: DesktopPlatform, @unchecked Sendable {
    // G2 probes: an ordinary button of window 3, a QWERTY layout, an
    // empty menu bar.
    func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit? {
        PlatformHit(role: "AXButton", texts: [], windowId: 3)
    }
    func menuItems(pid: Int32) -> [PlatformMenuItem]? { [] }
    func focusedControl(pid: Int32) -> PlatformHit? { PlatformHit(role: "AXNone", texts: [], windowId: nil) }
    func menuOpen(pid: Int32) -> Bool? { false }
    func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter { key.count == 1 ? .character(key) : .named }

    var placed: Set<UInt32> = []
    var performed: [PlatformAction] = []
    func quit(pid: Int32) -> Bool { true }
    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String {
        performed.append(action)
        return "ax.press"
    }
    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle {
        ScreenHandle(name: name, displayId: 5, frame: Rect(x: 3000, y: 0, width: 1000, height: 700), hiDPI: false)
    }
    func destroyScreen(name: String) throws {}
    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws -> (pid: Int32, windows: [PlatformWindow]) {
        placed.insert(3)
        return (4, [PlatformWindow(windowId: 3, pid: 4, appName: "备忘录", title: "购物清单", frame: Rect(x: 3010, y: 10, width: 500, height: 400))])
    }
    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] {
        placed.insert(3)
        return [PlatformWindow(windowId: 3, pid: 4, appName: "备忘录", title: "购物清单", frame: Rect(x: 3010, y: 10, width: 500, height: 400))]
    }
    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? {
        placed.contains(windowId) ? PlatformWindow(windowId: 3, pid: 4, appName: "备忘录", title: "购物清单",
                                                   frame: Rect(x: 3010, y: 10, width: 500, height: 400)) : nil
    }
    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) {
        try Data("png".utf8).write(to: URL(fileURLWithPath: path))
        return (1000, 700)
    }
    /// Test double: the window alone, as the window's crop of this double's screen.
    func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int) {
        guard let w = window(on: screen, pid: pid, windowId: windowId) else { throw PlatformError(.notFound, "window \(windowId) is not on screen") }
        return try windowImage(screen, frame: w.frame, to: path)
    }

    func windowImage(_ screen: ScreenHandle, frame: AgentDesktopProtocol.Rect, to path: String) throws -> (width: Int, height: Int) {
        try Data("png".utf8).write(to: URL(fileURLWithPath: path))
        return (Int(frame.width), Int(frame.height))
    }
    func stack(on screen: ScreenHandle) -> [PlatformWindow] {
        placed.contains(3) ? [PlatformWindow(windowId: 3, pid: 4, appName: "备忘录", title: "购物清单",
                                             frame: Rect(x: 3010, y: 10, width: 500, height: 400))] : []
    }
    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws -> ElementRead {
        ElementRead(window: window(on: screen, pid: pid, windowId: windowId)!,
                    elements: [PlatformElement(index: 2, role: "AXButton", label: "完成", value: nil, actions: ["AXPress"],
                                               frame: Rect(x: 3100, y: 50, width: 60, height: 24))])
    }
}

@Test func theWholeReadWriteFlowOverTheRealSocket() throws {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let path = dir + "/runtime.sock"
    let identity = RuntimeIdentity(instanceId: "rt_e2e", pid: getpid(), startedAt: Timestamp.string(Date()),
                                   endpoint: path, buildSource: "unknown")
    let service = try { let s = RuntimeService(identity: identity, backend: StubBackend(), platform: TinyPlatform(),
                                 ledger: try RequestLedger(path: dir + "/requests.sqlite"),
                                 artifacts: try ArtifactStore(directory: dir + "/artifacts"), testSocketOwnerToken: cliTestOwner.token); s.bindsOnlyLaunchedProcesses = false; s.refusesScreenCaptureWithoutBinding = false; return s }()
    try writeOwnerCredential(service, endpoint: path)
    let server = RuntimeServer(path: path, service: service)
    try server.start()
    defer { server.stop() }

    func run(_ args: [String]) -> (Int32, JSONValue?) {
        var out: [String] = []
        var cli = CLI()
        cli.credentials = cliTestCredentials
        cli.stdout = { out.append($0) }
        cli.stderr = { _ in }
        cli.environment = ["HOME": "/nonexistent", EndpointResolver.environmentKey: path]
        cli.recordRequest = { _, _, _ in }
        let code = cli.run(args + ["--format", "json"])
        return (code, try? StrictJSON.parse(out.joined()))
    }
    let (c1, created) = run(["desktop", "create", "--name", "e2e", "--request-id", "e2e-create"])
    #expect(c1 == 0)
    let desktop = try #require(created?["data"]?["desktopId"]?.stringValue)
    #expect(run(["desktop", "create", "--name", "e2e", "--request-id", "e2e-create"]).1?["data"]?["desktopId"]?.stringValue == desktop)
    #expect(run(["app", "launch", "--desktop", desktop, "--bundle-id", "com.apple.Notes"]).0 == 0)
    #expect(run(["window", "bind", "--desktop", desktop, "--pid", "4"]).0 == 0)
    let (c2, session) = run(["session", "open", "--desktop", desktop])
    #expect(c2 == 0)
    let sid = try #require(session?["data"]?["sessionId"]?.stringValue)
    let png = dir + "/shot.png"
    let (c3, observed) = run(["observe", "--session", sid, "--image-output", png])
    #expect(c3 == 0)
    let observation = try #require(observed?["data"])
    // savedTo is the CLI's own addition; the rest is the Runtime's Observation.
    var members = observation.objectMembers ?? []
    members.removeAll { $0.key == "savedTo" }
    #expect(RuntimeContract.shared.validate(.object(members), "Observation").isEmpty)
    #expect(observed?["data"]?["elements"]?.arrayValue?.first?["label"]?.stringValue == "完成")
    #expect(FileManager.default.fileExists(atPath: png))
    #expect(run(["desktop", "destroy", desktop]).0 == 5, "an open session blocks destroy")
    #expect(run(["session", "close", sid]).0 == 0)
    #expect(run(["desktop", "destroy", desktop]).0 == 0)
    #expect(run(["request", "show", "e2e-create"]).1?["data"]?["state"]?.stringValue == "completed")
}
