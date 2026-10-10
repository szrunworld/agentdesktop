import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// What the Runtime's clipboard rule (G2) reads from the system to judge an
/// input before it is sent. Everything here only reads: accessibility
/// attributes and the keyboard layout. Nothing is pressed, opened, focused
/// or changed, and no permission beyond Accessibility (already needed for
/// input) is used.
public enum ClipboardProbe {
    /// The accessibility element at a screen point, as far as G2 needs it.
    public struct Hit: Equatable, Sendable {
        /// The role without its subrole: "AXButton", not "AXButton/AXToggle".
        public var role: String
        /// Title, description, help and a short value: everything that may
        /// name what pressing it does.
        public var texts: [String]
        /// A menu item's keyboard equivalent, such as "cmd+V".
        public var shortcut: String?
        /// The window the element belongs to, if accessibility says.
        public var windowID: CGWindowID?
        /// The element is part of a menu (an item, or inside a menu).
        public var inMenu: Bool
        /// Names of the controls around it (up to three levels up): an icon
        /// inside a "Copy" button names nothing itself.
        public var ancestorTexts: [String] = []
        /// The element has keyboard focus (typing there needs no click).
        public var focused = false
        /// The element is editable text (a field, or rich text a web page
        /// marks editable).
        public var editable = false
        /// Names of the focused element's window's default button: what
        /// Return in a text field presses.
        public var defaultButtonTexts: [String] = []
    }

    /// One menu item of an app's menu bar with a keyboard equivalent.
    public struct MenuItem: Equatable, Sendable {
        public var texts: [String]
        public var shortcut: String
    }

    /// What a key sends under the current keyboard layout.
    public enum KeyCharacter: Equatable, Sendable {
        /// A named key with no character: return, an arrow, F5…
        case named
        /// The character the key's code produces with these modifiers.
        case character(String)
        /// The layout could not be read: nothing can be said.
        case unknown
    }

    /// How long one accessibility question may take, set on every element
    /// read (the timeout is per reference, never inherited). A hung app
    /// answers nothing; the caller then refuses. The first question to an
    /// app takes about 0.1 s (measured on Calculator, 2026-10-09).
    public static let messagingTimeout: Float = 0.3
    /// How long one whole probe may take; past it the probe answers nothing.
    public static let budget: TimeInterval = 1.0
    /// Menu bars read again at most this often per app.
    public static let menuCacheSeconds: TimeInterval = 5

    /// Reads with a timeout on each element and one deadline for the probe.
    /// Only "no value" or "not supported" mean an attribute is absent; any
    /// other error (a timeout, an app that cannot answer) spoils the whole
    /// probe, which then answers nothing.
    final class Reader {
        let deadline = Date().addingTimeInterval(ClipboardProbe.budget)
        private(set) var failed = false
        var expired: Bool { failed || Date() >= deadline }
        func read<T>(_ element: AXUIElement, _ name: String) -> T? {
            guard !expired else { return nil }
            AXUIElementSetMessagingTimeout(element, ClipboardProbe.messagingTimeout)
            var value: CFTypeRef?
            switch AXUIElementCopyAttributeValue(element, name as CFString, &value) {
            case .success: return value as? T
            case .noValue, .attributeUnsupported: return nil
            default:
                failed = true
                return nil
            }
        }
    }

    /// The element at `point` (global top-left points) as the app reports it.
    /// Nil when accessibility does not answer.
    public static func hit(at point: CGPoint, pid: pid_t) -> Hit? {
        let r = Reader()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &found) == .success,
              let element = found, !r.expired else { return nil }
        guard let role: String = r.read(element, kAXRoleAttribute) else { return nil }
        var windowElement: AXUIElement? = r.read(element, kAXWindowAttribute)
        if windowElement == nil { windowElement = r.read(element, kAXTopLevelUIElementAttribute) }
        if let w = windowElement { AXUIElementSetMessagingTimeout(w, messagingTimeout) }
        var inMenu = role == kAXMenuItemRole as String || role == kAXMenuRole as String || role == kAXMenuBarItemRole as String
        var ancestors: [String] = []
        var node: AXUIElement? = element
        for depth in 0..<16 {
            guard let current = node, let parent: AXUIElement = r.read(current, kAXParentAttribute) else { break }
            let parentRole: String? = r.read(parent, kAXRoleAttribute)
            if parentRole == kAXMenuRole as String || parentRole == kAXMenuBarRole as String { inMenu = true }
            if depth < 3 { ancestors += texts(of: parent, r) }
            if inMenu && depth >= 2 { break }
            node = parent
        }
        var hit = Hit(role: role, texts: texts(of: element, r), shortcut: shortcut(of: element, r),
                      windowID: windowElement.flatMap(WindowMover.windowID(of:)), inMenu: inMenu, ancestorTexts: ancestors)
        hit.focused = (r.read(element, kAXFocusedAttribute) as Bool?) ?? false
        hit.editable = editable(element, role: role, r)
        // An answer cut short by the deadline is no answer.
        return r.expired ? nil : hit
    }

    /// Controls a click or a key presses; never editable text, even inside
    /// an editable region (a "Copy" button in a rich-text editor).
    static let pressableRoles: Set<String> = [
        "AXButton", "AXMenuButton", "AXPopUpButton", "AXMenuItem", "AXMenuBarItem", "AXLink", "AXCheckBox",
        "AXRadioButton", "AXCell", "AXRow", "AXTab", "AXDisclosureTriangle", "AXImage",
    ]

    static func editable(_ element: AXUIElement, role: String, _ r: Reader) -> Bool {
        guard !pressableRoles.contains(role) else { return false }
        if (r.read(element, "AXEditableAncestor") as AXUIElement?) != nil { return true }
        var settable: DarwinBoolean = false
        return [kAXTextFieldRole as String, kAXTextAreaRole as String, kAXComboBoxRole as String].contains(role)
            && AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success && settable.boolValue
    }

    /// The element that has keyboard focus in the app: what Return or Space
    /// would press. Nil when accessibility does not answer.
    public static func focused(pid: pid_t) -> Hit? {
        let r = Reader()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let element: AXUIElement = r.read(app, kAXFocusedUIElementAttribute) else {
            // No focused element is an answer (nothing to press), unless the
            // read failed. Keys still go to the app's focused window: say which.
            let focusedWindow: AXUIElement? = r.read(app, kAXFocusedWindowAttribute)
            return r.expired ? nil : Hit(role: "AXNone", texts: [], shortcut: nil,
                                          windowID: focusedWindow.flatMap(WindowMover.windowID(of:)), inMenu: false)
        }
        guard let role: String = r.read(element, kAXRoleAttribute) else { return nil }
        var ancestors: [String] = []
        var node: AXUIElement? = element
        for _ in 0..<3 {
            guard let current = node, let parent: AXUIElement = r.read(current, kAXParentAttribute) else { break }
            ancestors += texts(of: parent, r)
            node = parent
        }
        var window: AXUIElement? = r.read(element, kAXWindowAttribute)
        if window == nil { window = r.read(element, kAXTopLevelUIElementAttribute) }
        var hit = Hit(role: role, texts: texts(of: element, r), shortcut: shortcut(of: element, r),
                      windowID: window.flatMap(WindowMover.windowID(of:)), inMenu: false, ancestorTexts: ancestors)
        hit.focused = true
        hit.editable = editable(element, role: role, r)
        if let window, let button: AXUIElement = r.read(window, kAXDefaultButtonAttribute) {
            hit.defaultButtonTexts = texts(of: button, r)
        }
        return r.expired ? nil : hit
    }

    /// The items of the app's menu bar menus (first level) that have a
    /// keyboard equivalent. Nil when the menu bar cannot be read. Reading
    /// a menu's items does not open it.
    public static func menuItems(pid: pid_t, limit: Int = 3_000) -> [MenuItem]? {
        let r = Reader()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar: AXUIElement = r.read(app, kAXMenuBarAttribute) else { return nil }
        var items: [MenuItem] = []
        var seen = 0
        for top in (r.read(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (r.read(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (r.read(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    seen += 1
                    // A menu bar too large to read whole, or one read past
                    // the deadline, is not known: no answer, not a partial one.
                    if seen > limit || r.expired { return nil }
                    if let s = shortcut(of: item, r) { items.append(MenuItem(texts: texts(of: item, r), shortcut: s)) }
                }
            }
        }
        return r.expired ? nil : items
    }

    /// What the engine's key code for `name` (BackgroundInput's ANSI table)
    /// produces under the current layout with these modifiers.
    public static func character(forKey name: String, modifiers: [String]) -> KeyCharacter {
        guard let code = BackgroundInput.keyCode(name) else { return .unknown }
        // Named keys have no character to judge.
        if name.count > 1 { return .named }
        guard let layout = KeyboardLayout.shared.data else { return .unknown }
        var state: UInt32 = 0
        for m in modifiers.map({ $0.lowercased() }) {
            switch m {
            case "cmd", "command", "meta": state |= UInt32(cmdKey >> 8)
            case "shift": state |= UInt32(shiftKey >> 8)
            case "option", "alt", "opt": state |= UInt32(optionKey >> 8)
            case "ctrl", "control": state |= UInt32(controlKey >> 8)
            default: return .unknown
            }
        }
        var dead: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = layout.withUnsafeBytes { raw -> OSStatus in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return -1 }
            return UCKeyTranslate(base, code, UInt16(kUCKeyActionDown), state, UInt32(LMGetKbdType()),
                                  OptionBits(kUCKeyTranslateNoDeadKeysMask), &dead, chars.count, &length, &chars)
        }
        guard status == noErr, length > 0 else { return .unknown }
        return .character(String(utf16CodeUnits: chars, count: length).lowercased())
    }

    /// "cmd+shift+V" from AXMenuItemCmdChar and AXMenuItemCmdModifiers
    /// (bits: shift 1, option 2, control 4, and 8 for "no command key").
    public static func shortcut(char: String, modifiers: Int) -> String? {
        let key = char.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        var parts: [String] = []
        if modifiers & 8 == 0 { parts.append("cmd") }
        if modifiers & 4 != 0 { parts.append("ctrl") }
        if modifiers & 2 != 0 { parts.append("option") }
        if modifiers & 1 != 0 { parts.append("shift") }
        return (parts + [key.uppercased()]).joined(separator: "+")
    }

    static func shortcut(of element: AXUIElement, _ r: Reader) -> String? {
        let mods: Int = r.read(element, kAXMenuItemCmdModifiersAttribute) ?? 0
        // Named keys carry a virtual key code; their character is a glyph or
        // a private-use code (Safari's arrows U+F700, Finder's Delete U+0008,
        // Chrome's Esc U+238B), never a letter to compare.
        if let code: Int = r.read(element, kAXMenuItemCmdVirtualKeyAttribute), let s = shortcut(virtualKey: code, modifiers: mods) {
            return s
        }
        guard let char: String = r.read(element, kAXMenuItemCmdCharAttribute),
              !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if let named = namedKey(forMenuCharacter: char) { return shortcut(char: named, modifiers: mods) }
        // A control or private-use character with no name is no key to compare.
        if let v = char.unicodeScalars.first?.value, v < 0x20 || (0xE000...0xF8FF).contains(v) { return nil }
        return shortcut(char: char, modifiers: mods)
    }

    /// The engine's name for a key a menu shows as a glyph or function-key code.
    public static func namedKey(forMenuCharacter char: String) -> String? {
        guard let scalar = char.unicodeScalars.first, char.unicodeScalars.count == 1 else { return nil }
        let v = scalar.value
        // NSF1FunctionKey… : U+F704 is F1.
        if (0xF704...0xF70F).contains(v) { return "f\(v - 0xF704 + 1)" }
        let table: [UInt32: String] = [
            0xF700: "up", 0xF701: "down", 0xF702: "left", 0xF703: "right", 0xF728: "forwarddelete",
            0xF729: "home", 0xF72B: "end", 0xF72C: "pageup", 0xF72D: "pagedown",
            0x08: "delete", 0x7F: "delete", 0x09: "tab", 0x0D: "return", 0x03: "return", 0x1B: "escape",
            0x238B: "escape", 0x232B: "delete", 0x2326: "forwarddelete", 0x21E5: "tab", 0x21A9: "return", 0x2324: "return",
            0x2190: "left", 0x2192: "right", 0x2191: "up", 0x2193: "down", 0x2196: "home", 0x2198: "end",
            0x21DE: "pageup", 0x21DF: "pagedown", 0x20: "space",
        ]
        return table[v]
    }

    /// "cmd+F5" from a virtual key code, by the engine's own key names.
    public static func shortcut(virtualKey code: Int, modifiers: Int) -> String? {
        let names = ["f1", "f2", "f3", "f4", "f5", "f6", "f7", "f8", "f9", "f10", "f11", "f12", "return", "tab", "space",
                     "delete", "forwarddelete", "escape", "home", "end", "pageup", "pagedown", "left", "right", "up", "down"]
        guard let name = names.first(where: { BackgroundInput.keyCode($0).map(Int.init) == code }) else { return nil }
        return shortcut(char: name, modifiers: modifiers)
    }

    static func texts(of element: AXUIElement, _ r: Reader) -> [String] {
        var out: [String] = []
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
            if let t: String = r.read(element, name), !t.isEmpty { out.append(t) }
        }
        if let v: String = r.read(element, kAXValueAttribute), !v.isEmpty, v.count <= 64 { out.append(v) }
        return out
    }

    /// The window holding the app's keyboard focus, read now: the focused
    /// element's window, or the app's focused window when no element has
    /// focus. Nil when it cannot be read. Light enough to ask before each
    /// typed character.
    public static func focusedWindowID(pid: pid_t) -> CGWindowID? {
        let r = Reader()
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var window: AXUIElement?
        if let element: AXUIElement = r.read(app, kAXFocusedUIElementAttribute) {
            window = r.read(element, kAXWindowAttribute) ?? r.read(element, kAXTopLevelUIElementAttribute)
        } else {
            window = r.read(app, kAXFocusedWindowAttribute)
        }
        guard !r.expired else { return nil }
        return window.flatMap(WindowMover.windowID(of:))
    }

    /// Whether the app shows a menu now (a menu bar menu or a context menu
    /// is a window of its own at the pop-up menu level); nil when the window
    /// list cannot be read. Return or Space there activates the item the
    /// arrows selected, which accessibility focus does not always show.
    public static func menuOpen(pid: pid_t) -> Bool? {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else { return nil }
        let menuLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        return list.contains {
            ($0[kCGWindowOwnerPID as String] as? Int).map(pid_t.init) == pid && ($0[kCGWindowLayer as String] as? Int) == menuLevel
        }
    }

    /// Call once on the main thread at start: the keyboard layout is read
    /// there (Text Input Sources wants the main thread) and kept fresh when
    /// the user switches input sources. Until it has been read, every key
    /// with a character is `unknown`.
    public static func prepareKeyboardLayout() {
        if Thread.isMainThread { KeyboardLayout.shared.start() } else {
            DispatchQueue.main.async { KeyboardLayout.shared.start() }
        }
    }
}

/// The current keyboard layout's key translation data, read on the main
/// thread and handed to any thread.
final class KeyboardLayout: @unchecked Sendable {
    static let shared = KeyboardLayout()
    private let lock = NSLock()
    private var current: Data?
    private var observing = false

    var data: Data? { lock.withLock { current } }

    func start() {
        reload()
        let first = lock.withLock { () -> Bool in defer { observing = true }; return !observing }
        guard first else { return }
        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    private func reload() {
        var data: Data?
        for source in [TISCopyCurrentKeyboardLayoutInputSource(), TISCopyCurrentASCIICapableKeyboardLayoutInputSource()] {
            guard let s = source?.takeRetainedValue(),
                  let raw = TISGetInputSourceProperty(s, kTISPropertyUnicodeKeyLayoutData) else { continue }
            data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
            break
        }
        lock.withLock { current = data }
    }
}
