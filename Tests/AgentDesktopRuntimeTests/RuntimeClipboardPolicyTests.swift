import AgentDesktopClient
@testable import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

// G2 (Kevin, 2026-10-08/09): an agent's input never goes through the
// user's clipboard. The Runtime judges what is actually about to be sent,
// right before sending, whatever the caller says, and refuses what it
// cannot judge. Every entry is held to it: a one-action Run, an exec Run,
// the socket every outside client uses, and the GUI explorer's ports.

private func key(_ k: String, _ mods: [String]) -> String {
    let m = mods.map { #""\#($0)""# }.joined(separator: ",")
    return #"{"kind":"key","key":"\#(k)","modifiers":[\#(m)]}"#
}

private func clickAt(_ x: Int, _ y: Int) -> String { #"{"kind":"click","target":{"imagePoint":{"x":\#(x),"y":\#(y)}}}"# }

private func expectRefusal(_ r: RuntimeResponse, path: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(code(r) == "permission_denied", sourceLocation: sourceLocation)
    let f = failure(r)
    #expect(f?.notSent == true, sourceLocation: sourceLocation)
    #expect(f?.details?["reason"]?.stringValue == "clipboard_path_refused", sourceLocation: sourceLocation)
    #expect(f?.details?["path"]?.stringValue == path, sourceLocation: sourceLocation)
}

private func sent(_ r: RuntimeResponse, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(data(r)?["delivery"]?.stringValue == "dispatched", "\(r)", sourceLocation: sourceLocation)
}

private func hit(_ role: String, _ texts: [String], shortcut: String? = nil, window: UInt32? = 11, inMenu: Bool = false)
    -> ((x: Double, y: Double), Int32) -> PlatformHit? {
    { _, _ in PlatformHit(role: role, texts: texts, shortcut: shortcut, windowId: window, inMenu: inMenu) }
}

// MARK: Keys

@Test(arguments: [
    ("v", ["cmd"]), ("V", ["cmd"]), ("v", ["cmd", "shift"]), ("v", ["cmd", "option", "shift"]),
    ("c", ["cmd"]), ("x", ["cmd"]), ("c", ["shift", "cmd"]),
    // Virtual machines and remote desktops share the Mac's clipboard on ctrl.
    ("v", ["ctrl"]), ("c", ["ctrl"]), ("x", ["ctrl"]),
])
func clipboardKeysAreRefusedBeforeAnythingIsSent(_ k: String, _ mods: [String]) throws {
    let sc = try scene()
    expectRefusal(act(sc, key(k, mods)), path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
}

@Test(arguments: ["f2", "f3", "f4"])
func officesCutCopyPasteKeysAreRefused(_ k: String) throws {
    let sc = try scene()
    expectRefusal(act(sc, key(k, [])), path: "function_key")
    #expect(sc.platform.performed.isEmpty)
}

@Test func theLayoutDecidesWhatAKeySends() throws {
    // Dvorak: the key code the engine sends for "." types v, for "i" c, for "b" x.
    let platform = FakePlatform()
    platform.layout = [".": "v", "i": "c", "b": "x", "v": "k"]
    let sc = try scene(platform)
    expectRefusal(act(sc, key(".", ["cmd"])), path: "shortcut")
    expectRefusal(act(sc, key("i", ["cmd"])), path: "shortcut")
    expectRefusal(act(sc, key("b", ["cmd"])), path: "shortcut")
    #expect(platform.performed.isEmpty)
}

@Test func anUnreadableLayoutOrMenuBarRefusesShortcutsButNotPlainKeys() throws {
    let platform = FakePlatform()
    platform.layoutKnown = false
    let sc = try scene(platform)
    expectRefusal(act(sc, key("a", ["cmd"])), path: "layout_unknown")
    sent(act(sc, key("return", [])))
    sent(act(sc, key("a", [])))
    platform.layoutKnown = true
    platform.menu = nil
    expectRefusal(act(sc, key("a", ["cmd"])), path: "menu_unverified")
    #expect(platform.performed.count == 2)
}

@Test func aShortcutTheUserMovedPasteToIsRefused() throws {
    let platform = FakePlatform()
    platform.menu = [PlatformMenuItem(texts: ["Paste"], shortcut: "cmd+shift+P"),
                     PlatformMenuItem(texts: ["Einsetzen und Stil anpassen"], shortcut: "cmd+option+E"),
                     PlatformMenuItem(texts: ["Bold"], shortcut: "cmd+B")]
    let sc = try scene(platform)
    expectRefusal(act(sc, key("p", ["shift", "cmd"])), path: "menu_shortcut")
    expectRefusal(act(sc, key("e", ["cmd", "option"])), path: "menu_shortcut")
    sent(act(sc, key("b", ["cmd"])))
    #expect(platform.performed.count == 1)
}

@Test func keysThatDoNotUseTheClipboardStillWork() throws {
    let sc = try scene()
    for action in [key("a", ["cmd"]), key("z", ["cmd"]), key("v", []), key("v", ["shift"]), key("f5", []),
                   key("return", ["cmd"]), #"{"kind":"type","text":"粘贴 paste ⌘V"}"#] {
        sent(act(sc, action))
    }
    #expect(sc.platform.performed.count == 7)
}

// MARK: Clicks

@Test func aClickOnAContextMenusPasteIsRefusedWhereverItWasAimed() throws {
    // b9's probe: right-click, then click "Paste" in the menu by image point.
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = hit("AXMenuItem", ["Paste"], window: nil, inMenu: true)
    expectRefusal(act(sc, clickAt(100, 100)), path: "menu_item")
    // Even when the item says nothing but its key.
    platform.hitAt = hit("AXMenuItem", [], shortcut: "cmd+V", window: nil, inMenu: true)
    expectRefusal(act(sc, clickAt(100, 100)), path: "menu_item")
    // An item that says nothing at all cannot be judged.
    platform.hitAt = hit("AXMenuItem", [], window: nil, inMenu: true)
    expectRefusal(act(sc, clickAt(100, 100)), path: "menu_item_unverified")
    // A menu item that is read and is not paste, copy or cut is fine.
    platform.hitAt = hit("AXMenuItem", ["Look Up “word”"], window: nil, inMenu: true)
    sent(act(sc, clickAt(100, 100)))
    #expect(platform.performed.count == 1)
}

@Test(arguments: [
    ("AXMenuItem", "Coller"), ("AXMenuItem", "Einfügen"), ("AXMenuItem", "Pegar"), ("AXMenuItem", "貼上"),
    ("AXMenuItem", "貼り付け"), ("AXMenuItem", "Paste Item"), ("AXMenuItem", "Paste as Plain Text"),
    ("AXMenuItem", "Copy Link"), ("AXMenuItem", "Paste ⌘V"), ("AXButton/AXToggle", "Paste"),
    ("AXLink", "Copy link"), ("AXCell", "Kopieren"), ("AXPopUpButton", "粘贴"), ("AXButton", "拷贝"),
    ("AXImage", "Cut…"),
])
func aControlWhoseNameSaysPasteCopyOrCutIsRefusedInAnyLanguage(_ role: String, _ text: String) throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let inMenu = role == "AXMenuItem"
    platform.hitAt = hit(role, ["", text], window: inMenu ? nil : 11, inMenu: inMenu)
    let r = act(sc, clickAt(100, 100))
    #expect(code(r) == "permission_denied")
    #expect(failure(r)?.details?["path"]?.stringValue == (inMenu ? "menu_item" : "control"))
    #expect(platform.performed.isEmpty)
}

@Test func anIconButtonDescribedAsPasteIsRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    // The title is a glyph; the description names it.
    platform.hitAt = hit("AXButton", ["⎘", "Paste"])
    expectRefusal(act(sc, clickAt(100, 100)), path: "control")
}

@Test func whatAccessibilityCannotReadOrWhatLiesOutsideTheWindowIsRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = { _, _ in nil }
    expectRefusal(act(sc, clickAt(100, 100)), path: "hit_unavailable")
    // A popover, sheet or another app's window over the bound one.
    platform.hitAt = hit("AXButton", ["OK"], window: 99)
    expectRefusal(act(sc, clickAt(100, 100)), path: "outside_bound_window")
    platform.hitAt = hit("AXButton", ["OK"], window: nil)
    expectRefusal(act(sc, clickAt(100, 100)), path: "outside_bound_window")
    #expect(platform.performed.isEmpty)
}

@Test func theCheckReadsTheControlAgainJustBeforeSending() throws {
    // The snapshot saw "继续"; by the time of the click the control says "Paste".
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = hit("AXButton", ["Paste"])
    expectRefusal(act(sc, clickContinue), path: "control")
    #expect(platform.performed.isEmpty)
}

@Test func ordinaryControlsAndTextThatOnlyMentionsTheClipboardAreClickable() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    for texts in [["继续"], ["Copyright 2026"], ["Clipboard settings"],
                  ["Copy the code below into the field, then press Continue to go on."]] {
        platform.hitAt = hit("AXStaticText", texts)
        sent(act(sc, clickAt(100, 100)))
    }
    platform.hitAt = nil
    sent(act(sc, clickContinue))
    #expect(platform.performed.count == 5)
}

// MARK: Every entry

@Test func aRefusalEndsAOneActionRunAsFailedWithTheReasonInItsHistory() throws {
    let sc = try scene()
    expectRefusal(act(sc, key("v", ["cmd"]), id: "paste-1"), path: "shortcut")
    let run = try #require(data(call(sc.s, sc.c, "run.list"))?["runs"]?.arrayValue?.first)
    #expect(run["outcome"]?.stringValue == "failed")
    let runId = try #require(run["runId"]?.stringValue)
    let events = try #require(data(call(sc.s, sc.c, "run.events", params: #"{"runId":"\#(runId)"}"#))?["events"]?.arrayValue)
    #expect(events.first { $0["type"]?.stringValue == "action.refused" }?["data"]?["reason"]?["code"]?.stringValue == "permission_denied")
    #expect(!events.contains { $0["type"]?.stringValue == "action.dispatched" })
    expectRefusal(act(sc, key("v", ["cmd"]), id: "paste-1"), path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
}

@Test func anExecRunIsHeldToTheSameRule() throws {
    let sc = try scene()
    let owner = handshaken(sc.s)
    let runId = try #require(data(call(sc.s, owner, "run.start", context: #"{"sessionId":"\#(sc.session)"}"#))?["run"]?["runId"]?.stringValue)
    expectRefusal(act(sc, key("v", ["cmd"]), runId: runId, on: owner), path: "shortcut")
    #expect(sc.platform.performed.isEmpty)
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

@Test func theGuiExplorersKeysAndPointClicksGoThroughTheSameRule() async throws {
    let (platform, _, ports, d) = try guiScene()
    _ = try await ports.authorize(sessionId: nil, desktopId: d, callerScope: "u", trustedOwner: true, runId: "r1")
    let bundle = try await ports.observe(runId: "r1", expectedGeneration: 1)
    let shot = bundle.observation.screenshots[0].screenshotId
    let paste = proposal(.action(.key(keys: ["Meta", "V"])), run: "r1", stamp: bundle.observation.stamp, shot: shot)
    #expect(try await ports.execute(paste, actionId: "act-paste").deliveryState == .rejected)
    // The explorer clicks by point only: a context menu's Paste under it is refused.
    platform.hitAt = hit("AXMenuItem", ["Paste"], window: nil, inMenu: true)
    let click = proposal(.action(.click(sourcePixel: Point(x: 100, y: 100))), run: "r1", stamp: bundle.observation.stamp, shot: shot)
    #expect(try await ports.execute(click, actionId: "act-menu").deliveryState == .rejected)
    #expect(platform.performed.isEmpty)
}

// MARK: Structure

// Every entry reaches the platform through act alone, and nothing the
// Runtime or the engine's input path links touches the pasteboard. A new
// input path or a clipboard-based route fails here until G2 is weighed for it.
@Test func inputReachesThePlatformOnlyThroughActAndNoInputPathTouchesThePasteboard() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    func swiftFiles(_ dir: String) -> [URL] {
        (FileManager.default.enumerator(at: root.appendingPathComponent(dir), includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }) ?? []
    }
    let product = swiftFiles("Sources")
    let engine = swiftFiles("engine/Sources")
    // One way to the platform's input: `.perform(` in the Runtime, only in act.
    var performSites: [String] = []
    for f in product where f.path.contains("/AgentDesktopRuntime/") {
        let text = try String(contentsOf: f, encoding: .utf8)
        if text.contains(".perform(") { performSites.append(f.lastPathComponent) }
    }
    #expect(performSites == ["RuntimeService+Act.swift"], "\(performSites)")
    // The pasteboard is touched only where a person asks for it (the main
    // window's copy button) or by the iPhone path, which is not linked into
    // the Runtime (G1) and is held to G2 when it is.
    let allowed: Set<String> = ["Forms.swift", "PasteboardSnapshot.swift", "ClipboardLease.swift", "HostFlag.swift",
                                "IPhonePaste.swift", "IPhoneCapabilities.swift"]
    for f in product + engine {
        let text = try String(contentsOf: f, encoding: .utf8)
        if text.contains("NSPasteboard") || text.contains("PasteboardSnapshot") || text.contains("ClipboardLease") {
            #expect(allowed.contains(f.lastPathComponent), "\(f.path) touches the pasteboard")
        }
    }
    // The Runtime and the host never import the iPhone agent code.
    for f in product where f.path.contains("/AgentDesktopRuntime/") || f.path.contains("/Sources/AgentDesktop/") {
        let text = try String(contentsOf: f, encoding: .utf8)
        #expect(!text.contains("import TarsAgent"), "\(f.path)")
    }
}
