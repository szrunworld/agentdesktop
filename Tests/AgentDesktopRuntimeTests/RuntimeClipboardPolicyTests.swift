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
    // The scene's session is the owner's; over the socket that is the
    // test-only owner token (A4: no socket client is the owner in the product).
    let client = SocketRuntimeClient(endpoint: Endpoint(path: path, source: .option), info: ClientInfo(name: "acp", version: "1"), timeout: 5,
                                     credential: testOwner)
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

// MARK: Round three (b9's second review)

@Test func typingIntoSomethingThatIsNotATextFieldIsRefused() throws {
    // The engine clicks a web field without focus before typing: typing at
    // a button would press it.
    let sc = try scene()
    expectRefusal(act(sc, #"{"kind":"type","text":"x","target":{"elementRef":"el_0"}}"#), path: "type_target_not_text")
    #expect(sc.platform.performed.isEmpty)
    sent(act(sc, #"{"kind":"type","text":"Ada","target":{"elementRef":"el_1"}}"#))
    sent(act(sc, #"{"kind":"type","text":"no target: the focused field"}"#))
}

@Test func pasteMovedToANamedOrUnmodifiedKeyIsRefused() throws {
    let platform = FakePlatform()
    platform.menu = [PlatformMenuItem(texts: ["Paste"], shortcut: "F6"),
                     PlatformMenuItem(texts: ["Copy"], shortcut: "option+P"),
                     PlatformMenuItem(texts: ["Einsetzen"], shortcut: "cmd+F5")]
    let sc = try scene(platform)
    expectRefusal(act(sc, key("f6", [])), path: "menu_shortcut")
    expectRefusal(act(sc, key("p", ["option"])), path: "menu_shortcut")
    expectRefusal(act(sc, key("f5", ["cmd"])), path: "menu_shortcut")
    sent(act(sc, key("f7", [])))
    #expect(platform.performed.count == 1)
}

@Test func shiftDeleteIsCutInAWindowsGuest() throws {
    let sc = try scene()
    expectRefusal(act(sc, key("forwarddelete", ["shift"])), path: "shortcut")
    sent(act(sc, key("forwarddelete", [])))
}

@Test func anIconInsideACopyButtonIsJudgedByTheButton() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = { _, _ in PlatformHit(role: "AXImage", texts: [], windowId: 11, ancestorTexts: ["", "Copy"]) }
    expectRefusal(act(sc, clickAt(100, 100)), path: "control")
}

@Test func aNamedKeyNeedsAReadableMenuBar() throws {
    let platform = FakePlatform()
    platform.menu = nil
    let sc = try scene(platform)
    expectRefusal(act(sc, key("f6", [])), path: "menu_unverified")
    sent(act(sc, key("a", [])))
}

// MARK: Round four (b9's third review)

@Test func typingIsAllowedOnlyIntoTextAndNeverIntoAClipboardControl() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    // A page's contenteditable chat box: editable text.
    platform.hitAt = { _, _ in PlatformHit(role: "AXGroup", texts: [], windowId: 11, editable: true) }
    sent(act(sc, #"{"kind":"type","text":"你好","target":{"elementRef":"el_0"}}"#))
    // b9's bypass: focus moved to a "Copy code" button with Tab, then typing
    // aimed at its container, which the engine would click: refused.
    platform.hitAt = { _, _ in PlatformHit(role: "AXGroup", texts: [], windowId: 11, focused: true) }
    expectRefusal(act(sc, #"{"kind":"type","text":"x","target":{"elementRef":"el_0"}}"#), path: "type_target_not_text")
    // A field's own words (a placeholder, a label around it) do not matter:
    // typing into a field is not a paste (b9's seventh review ②).
    platform.hitAt = { _, _ in PlatformHit(role: "AXTextField", texts: ["Paste your API key here"], windowId: 11,
                                           ancestorTexts: ["Copy link"], editable: true) }
    sent(act(sc, #"{"kind":"type","text":"x","target":{"elementRef":"el_0"}}"#))
    #expect(platform.performed.count == 2)
}

@Test func returnOrSpaceOnAFocusedCopyButtonIsRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.focusedHit = PlatformHit(role: "AXButton", texts: ["Copy code"], windowId: 11, focused: true)
    expectRefusal(act(sc, key("return", [])), path: "focused_control")
    expectRefusal(act(sc, key("space", [])), path: "focused_control")
    platform.focusedHit = nil
    expectRefusal(act(sc, key("return", [])), path: "focused_unverified")
    // A focused text field takes Return as a newline.
    platform.focusedHit = PlatformHit(role: "AXTextArea", texts: ["Copy"], windowId: 11, focused: true, editable: true)
    sent(act(sc, key("return", [])))
    platform.focusedHit = PlatformHit(role: "AXButton", texts: ["Send"], windowId: 11, focused: true)
    sent(act(sc, key("space", [])))
}

@Test func keyAliasesNameTheSameKey() throws {
    let platform = FakePlatform()
    platform.menu = [PlatformMenuItem(texts: ["Paste"], shortcut: "cmd+RETURN")]
    let sc = try scene(platform)
    expectRefusal(act(sc, key("enter", ["cmd"])), path: "menu_shortcut")
    expectRefusal(act(sc, key("return", ["cmd"])), path: "menu_shortcut")
}

@Test func plainMovementKeysDoNotNeedTheMenuBar() throws {
    let platform = FakePlatform()
    platform.menu = nil
    let sc = try scene(platform)
    for k in ["return", "tab", "down", "escape", "delete"] { sent(act(sc, key(k, []))) }
    expectRefusal(act(sc, key("f6", [])), path: "menu_unverified")
}

@Test(arguments: ["YAPIŞTIR", "วางลิงก์", "贴上", "สำเนาลิงก์"])
func moreLocalesAreRecognised(_ text: String) throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = { _, _ in PlatformHit(role: "AXMenuItem", texts: [text], windowId: nil, inMenu: true) }
    expectRefusal(act(sc, clickAt(100, 100)), path: "menu_item")
}

// b9's sixth review (a45e29c): typing goes to the focused element, so text
// without a target (or aimed at a point) typed into a focused "Copy code"
// button presses it; and a key given as " " or "\n" is Space or Return.
@Test func typingWithoutATargetChecksTheFocusedControl() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.focusedHit = PlatformHit(role: "AXButton", texts: ["Copy code"], windowId: 11, focused: true)
    expectRefusal(act(sc, #"{"kind":"type","text":" "}"#), path: "focused_control")
    expectRefusal(act(sc, #"{"kind":"type","text":"hello"}"#), path: "focused_control")
    // A target named fine does not help while focus is on the button.
    platform.hitAt = { _, _ in PlatformHit(role: "AXTextField", texts: [], windowId: 11, editable: true) }
    expectRefusal(act(sc, #"{"kind":"type","text":"x","target":{"elementRef":"el_0"}}"#), path: "focused_control")
    platform.focusedHit = nil
    expectRefusal(act(sc, #"{"kind":"type","text":"x"}"#), path: "focused_unverified")
    // Focus in a text field: typing goes there.
    platform.focusedHit = PlatformHit(role: "AXTextArea", texts: [], windowId: 11, focused: true, editable: true)
    sent(act(sc, #"{"kind":"type","text":"x\n"}"#))
    #expect(platform.performed.count == 1)
}

@Test func typingAtAPointIsJudgedByWhatIsThere() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.hitAt = { _, _ in PlatformHit(role: "AXButton", texts: ["Copy"], windowId: 11) }
    expectRefusal(act(sc, #"{"kind":"type","text":"x","target":{"imagePoint":{"x":60,"y":60}}}"#), path: "type_target_not_text")
    platform.hitAt = { _, _ in PlatformHit(role: "AXTextField", texts: [], windowId: 11) }
    sent(act(sc, #"{"kind":"type","text":"x","target":{"imagePoint":{"x":60,"y":60}}}"#))
}

@Test(arguments: [" ", "\n", "\r", "\t", "\r\n"])
func aBlankCharacterKeyPressesTheFocusedControl(_ k: String) throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.focusedHit = PlatformHit(role: "AXButton", texts: ["Copy code"], windowId: 11, focused: true)
    let escaped = k.replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\t", with: "\\t")
    expectRefusal(act(sc, #"{"kind":"key","key":"\#(escaped)"}"#), path: "focused_control")
    #expect(platform.performed.isEmpty)
}

@Test func aFocusReadThatFailsOnceIsTriedAgain() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.focusFailures = 1
    sent(act(sc, key("return", [])))
    platform.focusFailures = 2
    expectRefusal(act(sc, key("return", [])), path: "focused_unverified")
}

// b9's seventh review (14e12bd): a tab in typed text moves focus mid-action,
// a control-character key is Enter to AppKit, and Return in a text field
// presses the window's default button.
@Test(arguments: ["x\t ", "\u{19}", "a\u{3}", "\u{1b}"])
func typedTextWithControlCharactersIsRefused(_ text: String) throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let body = try #require(String(data: try JSONEncoder().encode(text), encoding: .utf8))
    expectRefusal(act(sc, #"{"kind":"type","text":\#(body)}"#), path: "type_control_character")
    #expect(platform.performed.isEmpty)
}

@Test(arguments: ["\u{3}", "\u{1}", "\u{7f}"])
func aControlCharacterKeyIsRefused(_ k: String) throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    let body = try #require(String(data: try JSONEncoder().encode(k), encoding: .utf8))
    expectRefusal(act(sc, #"{"kind":"key","key":\#(body)}"#), path: "key_not_printable")
    #expect(platform.performed.isEmpty)
}

@Test func returnInAFieldWhoseWindowDefaultsToCopyIsRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.focusedHit = PlatformHit(role: "AXTextField", texts: [], windowId: 11, focused: true, editable: true,
                                      defaultButtonTexts: ["Copy"])
    expectRefusal(act(sc, key("return", [])), path: "default_button")
    expectRefusal(act(sc, #"{"kind":"key","key":"\n"}"#), path: "default_button")
    expectRefusal(act(sc, #"{"kind":"type","text":"a\n"}"#), path: "default_button")
    // b9's eighth review: "\r\n" is one Character; judged by scalar.
    expectRefusal(act(sc, #"{"kind":"type","text":"x\r\n"}"#), path: "default_button")
    expectRefusal(act(sc, #"{"kind":"type","text":"x\r"}"#), path: "default_button")
    expectRefusal(act(sc, #"{"kind":"key","key":"\r\n"}"#), path: "default_button")
    // Space and plain text do not reach the default button.
    sent(act(sc, key("space", [])))
    sent(act(sc, #"{"kind":"type","text":"ab"}"#))
    platform.focusedHit?.defaultButtonTexts = ["Send"]
    sent(act(sc, key("return", [])))
}

// Codex (e514647, P1): open Edit, arrow down to Paste, press Return. With a
// menu open, Return and Space are refused whatever focus says.
@Test func returnOrSpaceWhileAMenuIsOpenIsRefused() throws {
    let platform = FakePlatform()
    let sc = try scene(platform)
    platform.menuShown = true
    for k in ["return", "space", "enter"] { expectRefusal(act(sc, key(k, [])), path: "menu_open") }
    expectRefusal(act(sc, #"{"kind":"key","key":" "}"#), path: "menu_open")
    expectRefusal(act(sc, #"{"kind":"type","text":"p "}"#), path: "menu_open")
    // Arrows still move through it; only activation is refused.
    sent(act(sc, key("down", [])))
    platform.menuShown = nil
    expectRefusal(act(sc, key("return", [])), path: "menu_unverified")
    platform.menuShown = false
    sent(act(sc, key("return", [])))
}
