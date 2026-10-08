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
    func focusedControl(pid: Int32) -> PlatformHit? { PlatformHit(role: "AXNone", texts: [], windowId: nil) }
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
        return try screenshot(screen, cropTo: w.frame, to: path)
    }

    func screenshot(_ screen: ScreenHandle, cropTo frame: AgentDesktopProtocol.Rect, to path: String) throws -> (width: Int, height: Int) {
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
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [AgentDesktopProtocol.WindowSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z") }
}

/// A live Runtime on a temporary socket and an MCP server talking to it.
final class MCPHarness {
    let dir: String
    let server: RuntimeServer
    let platform = MCPPlatform()
    let mcp: MCPServer
    var nextId = 0

    init() throws {
        var template = Array("/tmp/adt-XXXXXX".utf8CString)
        dir = String(cString: mkdtemp(&template)!)
        let path = dir + "/runtime.sock"
        let service = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_mcp", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                               endpoint: path, buildSource: "unknown"),
                                     backend: MCPBackend(), platform: platform)
        service.bindsOnlyLaunchedProcesses = false
        service.refusesScreenCaptureWithoutBinding = false
        server = RuntimeServer(path: path, service: service)
        try server.start()
        mcp = MCPServer(makeClient: { SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "mcp-test", version: "1")) })
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
