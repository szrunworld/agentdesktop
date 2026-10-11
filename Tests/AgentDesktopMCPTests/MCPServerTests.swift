import AgentDesktopClient
import AgentDesktopProtocol
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentDesktopMCP
@testable import AgentDesktopRuntime

final class MCPPlatform: DesktopPlatform, @unchecked Sendable {
    // G2 probes: an ordinary button of window 3, a QWERTY layout, an
    // empty menu bar.
    func clipboardHit(at point: (x: Double, y: Double), pid: Int32) -> PlatformHit? {
        PlatformHit(role: "AXButton", texts: [], windowId: 3)
    }
    func menuItems(pid: Int32) -> [PlatformMenuItem]? { [] }
    func focusedControl(pid: Int32) -> PlatformHit? { PlatformHit(role: "AXNone", texts: [], windowId: 3) }
    func menuOpen(pid: Int32) -> Bool? { false }
    func keyCharacter(_ key: String, modifiers: [String]) -> PlatformKeyCharacter { key.count == 1 ? .character(key) : .named }

    let lock = NSLock()
    var placed = false
    var performed: [PlatformAction] = []
    let window = PlatformWindow(windowId: 3, pid: 4, appName: "备忘录", title: "购物清单",
                                frame: AgentDesktopProtocol.Rect(x: 3000, y: 0, width: 1280, height: 800))
    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle {
        ScreenHandle(name: name, displayId: 5, frame: AgentDesktopProtocol.Rect(x: 3000, y: 0, width: 1280, height: 800), hiDPI: true)
    }
    func destroyScreen(name: String) throws {}
    func quit(pid: Int32) -> Bool { true }
    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws -> (pid: Int32, windows: [PlatformWindow]) {
        lock.withLock { placed = true }
        return (4, [window])
    }
    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] {
        lock.withLock { placed = true }
        return [window]
    }
    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? { lock.withLock { placed } ? window : nil }
    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) {
        let ctx = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return (2560, 1600)
    }
    /// Test double: the window alone, as the window's crop of this double's screen.
    func windowScreenshot(_ screen: ScreenHandle, pid: Int32, windowId: UInt32, to path: String) throws -> (width: Int, height: Int) {
        guard let w = window(on: screen, pid: pid, windowId: windowId) else { throw PlatformError(.notFound, "window \(windowId) is not on screen") }
        return try windowImage(screen, frame: w.frame, to: path)
    }

    func windowImage(_ screen: ScreenHandle, frame: AgentDesktopProtocol.Rect, to path: String) throws -> (width: Int, height: Int) {
        try screenshot(screen, to: path)
    }
    func stack(on screen: ScreenHandle) -> [PlatformWindow] { lock.withLock { placed ? [window] : [] } }
    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws -> ElementRead {
        ElementRead(window: window, elements: [PlatformElement(index: 2, role: "AXButton", label: "完成", value: nil, actions: ["AXPress"],
                                  frame: AgentDesktopProtocol.Rect(x: 3100, y: 50, width: 60, height: 24))])
    }
    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String {
        lock.withLock { performed.append(action) }
        return action.elementIndex != nil ? "ax.press" : "event.click"
    }
}

struct MCPBackend: RuntimeBackend {
    var platform: AgentDesktopProtocol.Platform { .init(os: "macos", osVersion: "15", arch: "arm64") }
    func permissions() -> BackendPermissions { .init(screenRecording: .granted, accessibility: .granted) }
    func features() -> [String] { [] }
    func applications(includeBackground: Bool) -> [AppSummary] {
        [AppSummary(process: ProcessIdentity(pid: 4, startedAt: "2026-10-08T01:00:00.000Z"), bundleId: "com.apple.Notes",
                    name: "Notes", active: false, hidden: false)]
    }
    /// The bound window is in its app's list, as on a real machine (#163
    /// refuses input when it is not: the list could not be read).
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [AgentDesktopProtocol.WindowSummary] {
        guard pid == nil || pid == 4 else { return [] }
        return [WindowSummary(windowId: 3, process: ProcessIdentity(pid: 4, startedAt: nil), appName: "备忘录",
                              bundleId: "com.apple.Notes", title: "购物清单",
                              frame: Rect(x: 3010, y: 10, width: 500, height: 400), onScreen: true)]
    }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z") }
    /// An executable in no app bundle: known not to be iPhone Mirroring (#139).
    func executablePath(_ pid: Int32) -> String? { "/test/bin/process" }
}

/// A live Runtime on a temporary socket and an MCP server talking to it.
final class MCPHarness {
    let dir: String
    let server: RuntimeServer
    let service: RuntimeService
    let platform = MCPPlatform()
    let mcp: MCPServer
    let path: String
    let credential: ClientCredential
    var nextId = 0

    init(desktopScope: String? = nil) throws {
        var template = Array("/tmp/adt-XXXXXX".utf8CString)
        dir = String(cString: mkdtemp(&template)!)
        path = dir + "/runtime.sock"
        service = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_mcp", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                               endpoint: path, buildSource: "unknown"),
                                     backend: MCPBackend(), platform: platform)
        service.bindsOnlyLaunchedProcesses = false
        service.refusesScreenCaptureWithoutBinding = false
        server = RuntimeServer(path: path, service: service)
        try server.start()
        // An MCP host is an external agent: a paired app, never the owner (A4).
        let pairing = try service.hub.startPairing(connectionId: "conn_test", agentName: "mcp-test", publisher: nil,
                                                   requested: .obj([]), callerFacts: .obj([]))
        let (client, _) = try service.hub.approve(pairing, grant: HubStore.Grant(
            clientId: "", capabilities: ["observe", "act", "desktop.manage", "run"], desktops: ["created"],
            apps: ["com.apple.Notes"], expiresAt: Timestamp.string(Date().addingTimeInterval(3600)), revision: 0, state: "active"))
        let credential = ClientCredential(clientId: client.clientId, token: service.hub.collect(pairing.pairingId) ?? "")
        self.credential = credential
        let path = self.path
        mcp = MCPServer(desktopScope: desktopScope, makeClient: {
            SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "mcp-test", version: "1"),
                                credential: credential)
        })
    }

    /// Another MCP server of the same paired app on the same Runtime.
    func server(desktopScope: String?) -> MCPServer {
        let path = self.path, credential = self.credential
        return MCPServer(desktopScope: desktopScope, makeClient: {
            SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "mcp-test", version: "1"),
                                credential: credential)
        })
    }

    /// A direct runtime/1 connection as the same paired app.
    func client() -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "mcp-test", version: "1"),
                            credential: credential)
    }

    deinit {
        server.stop()
        try? FileManager.default.removeItem(atPath: dir)
    }

    func send(_ method: String, _ params: JSONValue = .obj([])) -> JSONValue? {
        nextId += 1
        let msg = JSONValue.obj([("jsonrpc", .string("2.0")), ("id", .int(nextId)), ("method", .string(method)), ("params", params)])
        return mcp.handle(line: msg.encoded())
    }

    /// The tool's JSON text content, and whether it is an error.
    func tool(_ name: String, _ args: [(String, JSONValue)] = []) -> (JSONValue?, Bool, [JSONValue]) {
        let r = send("tools/call", .obj([("name", .string(name)), ("arguments", .obj(args))]))
        let content = r?["result"]?["content"]?.arrayValue ?? []
        let text = content.first?["text"]?.stringValue ?? ""
        return (try? StrictJSON.parse(text), r?["result"]?["isError"]?.boolValue ?? true, content)
    }
}

@Test func initializeListAndProtocolErrors() throws {
    let h = try MCPHarness()
    let initResult = try #require(h.send("initialize", .obj([("protocolVersion", .string("2024-11-05")),
                                                             ("capabilities", .obj([])), ("clientInfo", .obj([("name", .string("t"))]))]))?["result"])
    #expect(initResult["protocolVersion"]?.stringValue == "2024-11-05")
    #expect(initResult["capabilities"]?["tools"] != nil)
    #expect(h.mcp.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
    let tools = h.send("tools/list")?["result"]?["tools"]?.arrayValue ?? []
    #expect(tools.count == MCPTools.all.count)
    #expect(tools.allSatisfy { $0["inputSchema"]?["type"]?.stringValue == "object" && !($0["description"]?.stringValue ?? "").isEmpty })
    #expect(h.send("nope")?["error"]?["code"]?.intValue == -32601)
    #expect(h.mcp.handle(line: "{not json")?["error"]?["code"]?.intValue == -32700)
    #expect(h.send("tools/call", .obj([("name", .string("rm_rf"))]))?["error"]?["code"]?.intValue == -32602)
}

@Test func aWholeFlowThroughMCPTools() throws {
    let h = try MCPHarness()
    let (d, e1, _) = h.tool("desktop_create", [("name", .string("mcp"))])
    #expect(!e1)
    let desktop = try #require(d?["desktopId"]?.stringValue)
    #expect(d?["requestId"]?.stringValue?.hasPrefix("mcp_") == true)
    #expect(!h.tool("app_launch", [("desktopId", .string(desktop)), ("bundleId", .string("com.apple.Notes"))]).1)
    #expect(!h.tool("window_bind", [("desktopId", .string(desktop)), ("pid", .int(4))]).1)
    let session = try #require(h.tool("session_open", [("desktopId", .string(desktop))]).0?["sessionId"]?.stringValue)

    let (o, oe, content) = h.tool("observe", [("sessionId", .string(session))])
    #expect(!oe)
    let snap = try #require(o?["snapshotId"]?.stringValue)
    #expect(o?["elements"]?.arrayValue?.first?["label"]?.stringValue == "完成")
    // 2560x1600 comes back at 1280x800; act x,y are in that image.
    #expect(o?["imageForYou"]?["scaleToSnapshot"]?.doubleValue == 2)
    let image = try #require(content.first { $0["type"]?.stringValue == "image" })
    #expect(image["mimeType"]?.stringValue == "image/png")
    #expect((Data(base64Encoded: image["data"]?.stringValue ?? "")?.count ?? 0) > 100)

    let (c1, ce1, _) = h.tool("act_click", [("sessionId", .string(session)), ("snapshotId", .string(snap)), ("elementRef", .string("el_2"))])
    #expect(!ce1)
    #expect(c1?["delivery"]?.stringValue == "dispatched")
    // (100, 30) in the returned image is (200, 60) px, (3100, 30) in points.
    let (c2, ce2, _) = h.tool("act_click", [("sessionId", .string(session)), ("snapshotId", .string(snap)), ("x", .int(100)), ("y", .int(30))])
    #expect(!ce2, "\(String(describing: c2))")
    #expect(h.platform.performed.last?.point?.x == 3100 && h.platform.performed.last?.point?.y == 30)

    // A refused act is a tool error that says no input was sent.
    let r = h.send("tools/call", .obj([("name", .string("act_click")), ("arguments", .obj([
        ("sessionId", .string(session)), ("snapshotId", .string("obs_gone")), ("elementRef", .string("el_2"))]))]))
    #expect(r?["result"]?["isError"]?.boolValue == true)
    #expect(r?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("stale_observation") == true)
    #expect(r?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.contains("no input was sent") == true)

    // A retried write with its requestId returns the original outcome.
    let rid = try #require(c1?["requestId"]?.stringValue)
    #expect(h.tool("request_show", [("requestId", .string(rid))]).0?["state"]?.stringValue == "completed")
    let again = h.tool("act_click", [("sessionId", .string(session)), ("snapshotId", .string(snap)), ("elementRef", .string("el_2")),
                                     ("requestId", .string(rid))])
    #expect(again.0?["receiptId"] == c1?["receiptId"])
    #expect(h.platform.performed.count == 2)
    #expect(!h.tool("session_close", [("sessionId", .string(session))]).1)
    #expect(!h.tool("desktop_destroy", [("desktopId", .string(desktop))]).1)
}

@Test func missingArgumentsAreToolErrorsWithoutAConnection() throws {
    var made = 0
    let mcp = MCPServer(makeClient: {
        made += 1
        return SocketRuntimeClient(endpoint: Endpoint(path: "/nonexistent/r.sock", source: .option), info: ClientInfo(name: "t", version: "1"))
    })
    let r = mcp.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"act_click","arguments":{"sessionId":"s"}}}"#)
    #expect(r?["result"]?["isError"]?.boolValue == true)
    #expect(made == 0)
    let offline = mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"desktop_list","arguments":{}}}"#)
    #expect(offline?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue?.hasPrefix("runtime_offline") == true)
}

/// One tool call on `server`: its JSON text, whether it is an error, and the raw text.
func call(_ server: MCPServer, _ name: String, _ args: [(String, JSONValue)] = [], id: Int = 1) -> (JSONValue?, Bool, String) {
    let msg = JSONValue.obj([("jsonrpc", .string("2.0")), ("id", .int(id)), ("method", .string("tools/call")),
                             ("params", .obj([("name", .string(name)), ("arguments", .obj(args))]))])
    let r = server.handle(line: msg.encoded())
    let text = r?["result"]?["content"]?.arrayValue?.first?["text"]?.stringValue ?? ""
    return (try? StrictJSON.parse(text), r?["result"]?["isError"]?.boolValue ?? true, text)
}

/// SDK-06 / A7: `agentdesktop mcp --desktop-id A` reaches only Desktop A,
/// even though its paired app's grant covers Desktop B as well.
@Test func aServerLimitedToOneDesktopRefusesEveryOther() async throws {
    // Blocking socket calls stay off the cooperative pool (strict-pool CI).
    try await onPlainThread { try serverLimitedToOneDesktop() }
}

func serverLimitedToOneDesktop() throws {
    let h = try MCPHarness()
    // Two Desktops of the same paired app, made without a limit.
    let a = try #require(h.tool("desktop_create", [("name", .string("a"))]).0?["desktopId"]?.stringValue)
    let b = try #require(h.tool("desktop_create", [("name", .string("b"))]).0?["desktopId"]?.stringValue)
    #expect(!h.tool("app_launch", [("desktopId", .string(a)), ("bundleId", .string("com.apple.Notes"))]).1)
    #expect(!h.tool("window_bind", [("desktopId", .string(a)), ("pid", .int(4))]).1)
    let sessionB = try #require(h.tool("session_open", [("desktopId", .string(b))]).0?["sessionId"]?.stringValue)
    // A Run on B, started directly.
    let direct = h.client()
    defer { direct.close() }
    _ = try direct.handshake()
    var start = RuntimeRequest(.runStart)
    start.context = RequestContext(sessionId: sessionB)
    let started = try direct.call(start)
    let runB = try #require(started["run"]?["runId"]?.stringValue ?? started["runId"]?.stringValue, "\(started.encoded())")

    let scoped = h.server(desktopScope: a)
    // tools/list: no desktop_create; desktopId is optional.
    let list = scoped.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"]?.arrayValue ?? []
    #expect(!list.contains { $0["name"]?.stringValue == "desktop_create" })
    #expect(list.count == MCPTools.all.count - 1)
    for t in list {
        #expect(!(t["inputSchema"]?["required"]?.arrayValue ?? []).contains(.string("desktopId")), "\(t["name"]?.stringValue ?? "")")
    }
    let instructions = scoped.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}"#)?["result"]?["instructions"]?.stringValue
    #expect(instructions?.contains(a) == true)

    func refused(_ r: (JSONValue?, Bool, String)) -> Bool {
        r.1 && r.2.hasPrefix("permission_denied") && r.2.contains("desktop_out_of_scope") && r.2.contains("no input was sent")
    }
    let launchesBefore = h.platform.lock.withLock { h.platform.performed.count }

    // Reads show only A.
    let desktops = call(scoped, "desktop_list").0?["desktops"]?.arrayValue ?? []
    #expect(desktops.compactMap { $0["desktopId"]?.stringValue } == [a])
    // Any other desktopId is refused, before anything is sent.
    #expect(refused(call(scoped, "desktop_create", [("name", .string("c"))])))
    #expect(refused(call(scoped, "app_launch", [("desktopId", .string(b)), ("bundleId", .string("com.apple.Notes"))])))
    #expect(refused(call(scoped, "window_bind", [("desktopId", .string(b)), ("pid", .int(4))])))
    #expect(refused(call(scoped, "session_open", [("desktopId", .string(b))])))
    #expect(refused(call(scoped, "desktop_destroy", [("desktopId", .string(b))])))
    #expect(refused(call(scoped, "observe", [("sessionId", .string(sessionB)), ("desktopId", .string(b))])))
    // A session, Run or request of B is refused too.
    #expect(refused(call(scoped, "observe", [("sessionId", .string(sessionB))])))
    #expect(refused(call(scoped, "act_click", [("sessionId", .string(sessionB)), ("snapshotId", .string("obs_x")), ("elementRef", .string("el_2"))])))
    #expect(refused(call(scoped, "wait_for_element", [("sessionId", .string(sessionB)), ("present", .bool(true)), ("timeoutMs", .int(100))])))
    #expect(refused(call(scoped, "session_close", [("sessionId", .string(sessionB))])))
    #expect(refused(call(scoped, "run_show", [("runId", .string(runB))])))
    #expect(refused(call(scoped, "run_cancel", [("runId", .string(runB))])))
    _ = try direct.call(RuntimeRequest(.windowUnbind, requestId: "unbind-b", params: .obj([("desktopId", .string(b))])))
    #expect(refused(call(scoped, "request_show", [("requestId", .string("unbind-b"))])))
    // A record tied to no Desktop (desktop.create) is refused too.
    _ = try direct.call(RuntimeRequest(.desktopCreate, requestId: "create-c", params: .obj([("name", .string("c"))])))
    #expect(refused(call(scoped, "request_show", [("requestId", .string("create-c"))])))
    // B's session is still open: nothing reached it.
    #expect(try direct.call(RuntimeRequest(.sessionShow, params: .obj([("sessionId", .string(sessionB))])))["state"]?.stringValue == "open")
    #expect(h.platform.lock.withLock { h.platform.performed.count } == launchesBefore)

    // On A everything works, with desktopId omitted.
    let session = try #require(call(scoped, "session_open").0?["sessionId"]?.stringValue)
    let (o, oe, _) = call(scoped, "observe", [("sessionId", .string(session))])
    #expect(!oe)
    let snap = try #require(o?["snapshotId"]?.stringValue)
    let (click, ce, text) = call(scoped, "act_click", [("sessionId", .string(session)), ("snapshotId", .string(snap)), ("elementRef", .string("el_2"))])
    #expect(!ce, "\(text)")
    #expect(click?["delivery"]?.stringValue == "dispatched")
    // observe and wait name the Desktop alone.
    #expect(!call(scoped, "observe", [("includeImage", .bool(false))]).1)
    #expect(!call(scoped, "wait_for_element", [("present", .bool(true)), ("label", .string("完成")), ("timeoutMs", .int(500))]).1)
    let rid = try #require(click?["requestId"]?.stringValue)
    #expect(call(scoped, "request_show", [("requestId", .string(rid))]).0?["state"]?.stringValue == "completed")
    #expect(!call(scoped, "session_close", [("sessionId", .string(session))]).1)
}

/// Without --desktop-id nothing changes: every tool, desktopId required.
@Test func anUnlimitedServerKeepsTheFullToolList() throws {
    let server = MCPServer(makeClient: { fatalError("no connection for tools/list") })
    let list = server.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"]?["tools"]?.arrayValue ?? []
    #expect(list.count == MCPTools.all.count)
    let launch = list.first { $0["name"]?.stringValue == "app_launch" }
    #expect(launch?["inputSchema"]?["required"]?.arrayValue?.contains(.string("desktopId")) == true)
    let observe = list.first { $0["name"]?.stringValue == "observe" }
    #expect(observe?["inputSchema"]?["required"]?.arrayValue == [.string("sessionId")])
}
