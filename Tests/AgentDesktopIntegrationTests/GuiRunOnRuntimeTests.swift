import AgentDesktopAI
import AgentDesktopContracts
import AgentDesktopGUI
import AgentDesktopProtocol
import AgentDesktopService
import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import AgentDesktopRuntime

// A GUI run of the AI service executed by the Runtime: the explorer asks
// the Runtime's ports to observe and act; every input goes through the
// Runtime's act (checks, lease, ledger) to the platform.

let integrationGoal = "点击保存按钮，把表单保存"
let saved = "已保存"
let integrationKey = "sk-canary-runtime-integration"

/// A form window on a 2x screen at x=2000: a 保存 button and a status text.
final class FormPlatform: DesktopPlatform, @unchecked Sendable {
    let lock = NSLock()
    var status = "未保存"
    var inputs: [PlatformAction] = []
    var placed = false
    let windowFrame = AgentDesktopProtocol.Rect(x: 2100, y: 100, width: 400, height: 300)
    let button = AgentDesktopProtocol.Rect(x: 2300, y: 300, width: 100, height: 40)

    func createScreen(name: String, width: Int?, height: Int?) throws -> ScreenHandle {
        ScreenHandle(name: name, displayId: 9, frame: AgentDesktopProtocol.Rect(x: 2000, y: 0, width: 1280, height: 800), hiDPI: true)
    }
    func destroyScreen(name: String) throws {}
    func quit(pid: Int32) -> Bool { true }
    func launch(on screen: ScreenHandle, bundleId: String?, path: String?, newInstance: Bool) throws -> (pid: Int32, windows: [PlatformWindow]) {
        throw PlatformError(.refused, "not in this test")
    }
    var window: PlatformWindow { PlatformWindow(windowId: 11, pid: 101, appName: "Form", title: "表单", frame: windowFrame) }
    func moveWindows(to screen: ScreenHandle, pid: Int32, windowId: UInt32?) throws -> [PlatformWindow] {
        lock.withLock { placed = true }
        return [window]
    }
    func window(on screen: ScreenHandle, pid: Int32, windowId: UInt32) -> PlatformWindow? {
        lock.withLock { placed } && windowId == 11 ? window : nil
    }
    func stack(on screen: ScreenHandle) -> [PlatformWindow] { lock.withLock { placed } ? [window] : [] }
    func screenshot(_ screen: ScreenHandle, cropTo frame: AgentDesktopProtocol.Rect, to path: String) throws -> (width: Int, height: Int) {
        let w = Int(frame.width) * 2, h = Int(frame.height) * 2
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return (w, h)
    }
    func screenshot(_ screen: ScreenHandle, to path: String) throws -> (width: Int, height: Int) {
        let ctx = CGContext(data: nil, width: 2560, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 2560, height: 1600))
        let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
        CGImageDestinationFinalize(dest)
        return (2560, 1600)
    }
    func elements(on screen: ScreenHandle, pid: Int32, windowId: UInt32, query: String?, deadline: Date) throws -> ElementRead {
        let st = lock.withLock { status }
        return ElementRead(window: window, elements: [
            PlatformElement(index: 0, role: "AXButton", label: "保存", value: nil, actions: ["AXPress"], frame: button),
            PlatformElement(index: 1, role: "AXStaticText", label: nil, value: st, actions: [], frame: nil),
        ])
    }
    func perform(_ action: PlatformAction, on screen: ScreenHandle, pid: Int32, windowId: UInt32) throws -> String {
        lock.withLock {
            inputs.append(action)
            if action.kind == .click, let p = action.point,
               p.x >= button.x, p.x < button.x + button.width, p.y >= button.y, p.y < button.y + button.height {
                status = saved
            }
        }
        return "event.click"
    }
}

struct Backend: RuntimeBackend {
    var platform: AgentDesktopProtocol.Platform { .init(os: "macos", osVersion: "15", arch: "arm64") }
    func permissions() -> BackendPermissions { .init(screenRecording: .granted, accessibility: .granted) }
    func features() -> [String] { [] }
    func applications(includeBackground: Bool) -> [AppSummary] { [] }
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [AgentDesktopProtocol.WindowSummary] { [] }
    func processIdentity(_ pid: Int32) -> ProcessIdentity { ProcessIdentity(pid: pid, startedAt: "2026-10-08T01:00:00.000Z") }
}

/// Ark as the capability tests and this run expect it. The button centre
/// (2350,320) is source pixel (700,640), model canvas (500,440) of the
/// 800x600 window crop, normalized (625,733).
final class Upstream: HTTPTransport, @unchecked Sendable {
    let lock = NSLock()
    var runCalls = 0
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> HTTPResult {
        let body = String(decoding: request.httpBody ?? Data(), as: UTF8.self)
        if request.url?.path.hasSuffix("/models") == true {
            return HTTPResult(status: 200, body: Data(#"{"object":"list","data":[{"id":"doubao-seed-2-1-lite-260915","object":"model"}]}"#.utf8))
        }
        let reply: String
        if body.contains(SyntheticGuiFixture.authPrompt) { reply = "OK" }
        else if body.contains(SyntheticGuiFixture.colorQuestion) { reply = SyntheticGuiFixture.colorAnswer }
        else if body.contains(SyntheticGuiFixture.guiTask) { reply = "Thought: the blue button.\nAction: click(start_box='(750,780)')" }
        else if body.contains("保存按钮") {
            lock.withLock { runCalls += 1 }
            reply = "Thought: 保存。\nAction: click(start_box='(625,733)')"
        } else {
            return HTTPResult(status: 400, body: Data(#"{"error":{"message":"unexpected prompt"}}"#.utf8))
        }
        let response = JSONValue.obj([
            ("id", .string("up-1")), ("model", .string("doubao-seed-2-1-lite-260915")),
            ("choices", .array([.obj([("index", .int(0)), ("message", .obj([("role", .string("assistant")), ("content", .string(reply))])),
                                      ("finish_reason", .string("stop"))])])),
            ("usage", .obj([("prompt_tokens", .int(900)), ("completion_tokens", .int(20)), ("total_tokens", .int(920))])),
        ])
        return HTTPResult(status: 200, headers: ["Content-Type": "application/json"], body: response.encodedData())
    }
}

@Test func aGuiRunOfTheServiceIsExecutedByTheRuntime() async throws {
    let platform = FormPlatform()
    let runtime = RuntimeService(identity: RuntimeIdentity(instanceId: "rt_int", pid: getpid(), startedAt: Timestamp.string(Date()),
                                                           endpoint: "/tmp/int.sock", buildSource: "unknown"),
                                 backend: Backend(), platform: platform)
    let c = ConnectionState(peerUID: getuid())
    func rt(_ method: String, _ params: String = "{}") -> JSONValue? {
        let r = runtime.respond(to: Data(#"{"apiVersion":"agentdesktop.runtime/1","requestId":"\#(RuntimeRequest.newId())","method":"\#(method)","params":\#(params)}"#.utf8), on: c)
        if case let .success(d) = r.result { return d }
        return nil
    }
    _ = rt("runtime.handshake", #"{"apiVersions":["agentdesktop.runtime/1"],"client":{"name":"t","version":"1"}}"#)
    let desktop = try #require(rt("desktop.create")?["desktopId"]?.stringValue)
    #expect(rt("window.bind", #"{"desktopId":"\#(desktop)","pid":101}"#) != nil)

    let ports = RuntimeGuiPorts(service: runtime)
    struct NoAudit: GuiAuditPort {
        func reserveInference(runId: String, stepIndex: Int, snapshotId: String) {}
        func recordInference(_ receipt: GuiInferenceReceipt) {}
        func reserveAction(_ proposal: GuiProposal) -> String { "act-" + UUID().uuidString.prefix(8).lowercased() }
        func recordAction(_ receipt: GuiActionReceipt) {}
    }
    let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("adt-int-\(UUID().uuidString.prefix(8))")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let upstream = Upstream()
    let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir.appendingPathComponent("config.sqlite").path, credentials: InMemoryCredentialStore(), http: upstream,
        executionBackend: GuiExecutionBackend(
            ports: GuiExplorerPorts(observation: ports, execution: ports, audit: NoAudit()), sessions: ports,
            features: GuiBackendFeatures(actions: GuiActionKind.allCases, verificationPredicates: ["element_text_equals"]))))
    let router = service.router(callerScope: "owner", trustedOwner: true)
    func ai(_ command: String, _ params: JSONValue = .obj([]), key: String? = nil) async throws -> JSONValue {
        var m: [(String, JSONValue)] = [("schemaVersion", .string("agentdesktop.ai/1")), ("requestId", .string(UUID().uuidString.lowercased())),
                                        ("command", .string(command)), ("params", params)]
        if let key { m.append(("context", .obj([("idempotencyKey", .string(key))]))) }
        var out = await router.respond(toBody: JSONValue.obj(m).encodedData())
        out.removeLast()
        let r = try StrictJSON.parse(out)
        guard r["ok"]?.boolValue == true, let result = r["result"] else { throw ContractError(.internalError, "\(command): \(r.encoded())") }
        return result
    }
    func until(_ check: () async throws -> Bool) async throws {
        for _ in 0..<500 { if try await check() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw ContractError(.deadlineExceeded, "condition not reached")
    }

    // Model configuration as an owner would do it.
    let conn = try await ai("ai.connections.create", .obj([
        ("name", .string("Ark")), ("protocol", .string("openai_chat")), ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")),
        ("timeoutMs", .int(30000)), ("credential", .obj([("apiKey", .string(integrationKey))]))]), key: "integration-c1")
    let refresh = try await ai("ai.models.refresh", .obj([("connectionId", conn["connectionId"]!), ("expectedRevision", conn["revision"]!)]), key: "integration-r1")
    try await until { ["succeeded", "failed"].contains(try await ai("ai.operations.get", .obj([("operationId", refresh["operationId"]!)]))["state"]?.stringValue ?? "") }
    let model = try await ai("ai.modelProfiles.create", .obj([
        ("name", .string("Seed lite")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
        ("modelId", .string("doubao-seed-2-1-lite-260915")), ("requestOptions", .obj([("temperature", .int(0))])), ("maxOutputTokens", .int(1024))]), key: "integration-m1")
    let gui = try await ai("ai.profiles.create", .obj([
        ("name", .string("UI-TARS")), ("modelProfileId", model["modelProfileId"]!), ("modelProfileRevision", model["revision"]!),
        ("adapterId", .string("uitars_v1")), ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("uitars-prompt-1")),
        ("parserVersion", .string("uitars-parser-1")), ("coordinateProtocol", .string("normalized_1000")), ("limits", GuiLimits.ceiling.json),
        ("allowedFallbackProfileRefs", .array([]))]), key: "integration-g1")
    let test = try await ai("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedRevision", gui["revision"]!),
                                                    ("fixtureId", .string("synthetic_gui_v1"))]), key: "integration-t1")
    try await until { ["succeeded", "failed", "cancelled"].contains(try await ai("ai.operations.get", .obj([("operationId", test["operationId"]!)]))["state"]?.stringValue ?? "") }
    #expect(platform.inputs.isEmpty, "capability tests never touch the desktop")
    let def = try await ai("ai.profiles.default.get")
    _ = try await ai("ai.profiles.setDefault", .obj([("guiProfileId", gui["guiProfileId"]!), ("expectedDefaultRevision", def["default"]!["revision"]!),
                                                    ("expectedProfileRevision", gui["revision"]!)]), key: "integration-d1")

    // The run, against the Runtime's Desktop.
    let start = try await ai("gui.runs.start", .obj([
        ("desktopId", .string(desktop)), ("goal", .string(integrationGoal)),
        ("verification", .obj([("kind", .string("element_text_equals")), ("role", .string("static_text")), ("text", .string(saved))])),
        ("allowedActions", .array([.string("click")]))]), key: "integration-run-1")
    let runId = try #require(start["runId"]?.stringValue)
    var run: JSONValue = .null
    try await until {
        run = try await ai("gui.runs.get", .obj([("runId", .string(runId))]))
        return ["succeeded", "failed", "cancelled", "waiting_user"].contains(run["state"]?.stringValue ?? "")
    }
    #expect(run["state"]?.stringValue == "succeeded", "\(run.encoded())")
    #expect(run["goalVerification"]?["status"]?.stringValue == "passed")
    #expect(platform.status == saved)
    #expect(platform.inputs.count == 1)
    // normalized_1000 rounds: within half a source pixel of the button centre.
    let hit = try #require(platform.inputs.first?.point)
    #expect(abs(hit.x - 2350) < 0.5 && abs(hit.y - 320) < 0.5, "\(hit)")
    #expect(upstream.runCalls == 1)
}
