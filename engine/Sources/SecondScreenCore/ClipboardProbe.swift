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

    /// Reads with a timeout on each element and one deadline for the probe.
    struct Reader {
        let deadline = Date().addingTimeInterval(ClipboardProbe.budget)
        var expired: Bool { Date() >= deadline }
        func read<T>(_ element: AXUIElement, _ name: String) -> T? {
            guard !expired else { return nil }
            AXUIElementSetMessagingTimeout(element, ClipboardProbe.messagingTimeout)
            return WindowMover.copyAttribute(element, name)
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
        let hit = Hit(role: role, texts: texts(of: element, r), shortcut: shortcut(of: element, r),
                      windowID: windowElement.flatMap(WindowMover.windowID(of:)), inMenu: inMenu, ancestorTexts: ancestors)
        // An answer cut short by the deadline is no answer.
        return r.expired ? nil : hit
    }

    /// The items of the app's menu bar menus (first level) that have a
    /// keyboard equivalent. Nil when the menu bar cannot be read. Reading
    /// a menu's items does not open it.
    public static func menuItems(pid: pid_t, limit: Int = 600) -> [MenuItem]? {
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
        if let char: String = r.read(element, kAXMenuItemCmdCharAttribute),
           !char.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return shortcut(char: char, modifiers: mods)
        }
        // Named keys (F5, Delete…) are given as a virtual key code instead.
        guard let code: Int = r.read(element, kAXMenuItemCmdVirtualKeyAttribute) else { return nil }
        return shortcut(virtualKey: code, modifiers: mods)
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

    static func attribute<T>(_ element: AXUIElement, _ name: String) -> T? {
        WindowMover.copyAttribute(element, name)
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
