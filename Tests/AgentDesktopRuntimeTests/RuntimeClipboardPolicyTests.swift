import AgentDesktopClient
@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// G2 (Kevin, 2026-10-08): input never goes through the user's clipboard.
// The Runtime refuses it whatever the caller says about its text, before
// anything is sent, on every entry: a one-action Run, an exec Run, the
// socket every outside client uses, and the GUI explorer's ports.

private func key(_ k: String, _ mods: [String]) -> String {
    let m = mods.map { #""\#($0)""# }.joined(separator: ",")
    return #"{"kind":"key","key":"\#(k)","modifiers":[\#(m)]}"#
}

private func expectClipboardRefusal(_ r: RuntimeResponse, path: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(code(r) == "permission_denied", sourceLocation: sourceLocation)
    let f = failure(r)
    #expect(f?.notSent == true, sourceLocation: sourceLocation)
    #expect(f?.details?["reason"]?.stringValue == "clipboard_path_refused", sourceLocation: sourceLocation)
    #expect(f?.details?["path"]?.stringValue == path, sourceLocation: sourceLocation)
}

@Test(arguments: [
    ("v", ["cmd"]), ("V", ["cmd"]), ("v", ["cmd", "shift"]), ("v", ["cmd", "option", "shift"]),
    ("c", ["cmd"]), ("x", ["cmd"]), ("c", ["shift", "cmd"]),
])
func clipboardShortcutsAreRefusedBeforeAnythingIsSent(_ k: String, _ mods: [String]) throws {
    let sc = try scene()
    let r = act(sc, key(k, mods))
    expectClipboardRefusal(r, path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
}

@Test func aRefusedPasteEndsItsRunAsFailedWithTheReasonInItsHistory() throws {
    let sc = try scene()
    let r = act(sc, key("v", ["cmd"]), id: "paste-1")
    expectClipboardRefusal(r, path: "shortcut")
    let runs = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue)
    let run = try #require(runs.first)
    #expect(run["outcome"]?.stringValue == "failed")
    let runId = try #require(run["runId"]?.stringValue)
    let events = try #require(data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(runId)"}"#))?["events"]?.arrayValue)
    let refused = try #require(events.first { $0["type"]?.stringValue == "action.refused" })
    #expect(refused["data"]?["reason"]?["code"]?.stringValue == "permission_denied")
    #expect(!events.contains { $0["type"]?.stringValue == "action.dispatched" })
    // The same requestId again: the same refusal, still nothing sent.
    expectClipboardRefusal(act(sc, key("v", ["cmd"]), id: "paste-1"), path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
}

@Test func keysThatDoNotUseTheClipboardStillWork() throws {
    let sc = try scene()
    for action in [key("a", ["cmd"]), key("v", ["ctrl"]), key("v", []), key("z", ["cmd"]),
                   #"{"kind":"type","text":"粘贴 paste ⌘V"}"#] {
        #expect(data(act(sc, action)) != nil, "\(action)")
    }
    #expect(sc.platform.performed.count == 5)
}

@Test(arguments: [("AXMenuItem", "Paste"), ("AXMenuItem", "Paste and Match Style"), ("AXMenuItem", "粘贴"),
                  ("AXMenuItem", "拷贝"), ("AXButton", "Copy"), ("AXMenuItem", " Cut… ")])
func pressingAClipboardControlIsRefused(_ role: String, _ label: String) throws {
    let platform = FakePlatform()
    platform.elements = [PlatformElement(index: 0, role: role, label: label, value: nil, actions: ["AXPress"],
                                         frame: Rect(x: 2100, y: 100, width: 80, height: 30))]
    let sc = try scene(platform)
    expectClipboardRefusal(act(sc, clickContinue), path: "control")
    #expect(platform.performed.isEmpty)
}

@Test func controlsThatOnlyMentionTheClipboardAreNotRefused() throws {
    let platform = FakePlatform()
    platform.elements = [
        PlatformElement(index: 0, role: "AXStaticText", label: "Paste", value: nil, actions: [], frame: Rect(x: 2100, y: 100, width: 80, height: 30)),
        PlatformElement(index: 1, role: "AXButton", label: "Copy link to clipboard settings", value: nil, actions: ["AXPress"],
                        frame: Rect(x: 2100, y: 150, width: 80, height: 30)),
    ]
    let sc = try scene(platform)
    #expect(data(act(sc, clickContinue)) != nil)
    let snap = try #require(data(call(sc.s, sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#))?["snapshotId"]?.stringValue)
    #expect(data(act(sc, #"{"kind":"click","target":{"elementRef":"el_1"}}"#, snapshot: snap)) != nil)
    #expect(platform.performed.count == 2)
}

@Test func anExecRunIsHeldToTheSameRule() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let runId = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    expectClipboardRefusal(act(sc, key("v", ["cmd"]), runId: runId, on: owner), path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
    // The Run goes on: the refusal sent nothing, so later input is allowed.
    #expect(data(act(sc, clickContinue, runId: runId, on: owner))?["delivery"]?.stringValue == "dispatched")
}

@Test func aClientOverTheSocketCannotPasteEither() throws {
    let sc = try scene()
    let dir = try socketDirectory()
    let path = dir + "/runtime.sock"
    let server = RuntimeServer(path: path, service: sc.s)
    try server.start()
    defer { server.stop(); try? FileManager.default.removeItem(atPath: dir) }
    let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "acp", version: "1"), timeout: 5)
    defer { client.close() }
    let params = try StrictJSON.parse(Data(#"{"snapshotId":"\#(sc.snapshot)","action":\#(key("v", ["cmd"]))}"#.utf8))
    do {
        _ = try client.call(RuntimeRequest(requestId: "sock-paste", method: "act", context: RequestContext(sessionId: sc.session), params: params))
        Issue.record("a paste over the socket was accepted")
    } catch let e as RuntimeError {
        #expect(e.code == "permission_denied")
        #expect(e.details?["reason"]?.stringValue == "clipboard_path_refused")
    }
    #expect(sc.platform.performed.isEmpty)
}

@Test func theGuiExplorersKeysGoThroughTheSameRule() async throws {
    let (platform, _, ports, d) = try guiScene()
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    let bundle = try await ports.observe(runId: "r1", expectedGeneration: 1)
    let shot = bundle.observation.screenshots[0].screenshotId
    let paste = proposal(.action(.key(keys: ["Meta", "V"])), run: "r1", stamp: bundle.observation.stamp, shot: shot)
    let r = try await ports.execute(paste, actionId: "act-paste")
    #expect(r.deliveryState == .rejected)
    #expect(platform.performed.isEmpty)
}

// Structure: every entry reaches the platform through act alone, and the
// macOS typing routes never touch the pasteboard. A new input path or a
// clipboard-based typing route fails here until G2 is reconsidered for it.
@Test func inputReachesThePlatformOnlyThroughActAndTypingNeverUsesThePasteboard() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sources = root.appendingPathComponent("Sources")
    var performSites: [String] = []
    let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)?
        .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
    for f in files {
        let text = try String(contentsOf: f, encoding: .utf8)
        if text.contains("platform.perform(") { performSites.append(f.lastPathComponent) }
    }
    #expect(performSites == ["RuntimeService+Act.swift"], "\(performSites)")
    let typing = ["engine/Sources/SecondScreenCore/InputEngine.swift", "engine/Sources/SecondScreenCore/BackgroundInput.swift",
                  "engine/Sources/SecondScreenCore/Accessibility.swift", "Sources/AgentDesktopRuntime/Platform/EnginePlatform.swift"]
    for rel in typing {
        let text = try String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8)
        #expect(!text.contains("NSPasteboard") && !text.contains("PasteboardSnapshot") && !text.contains("ClipboardLease"), "\(rel)")
    }
}
