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

    /// How long one accessibility question may take. A hung app answers
    /// nothing; the caller then refuses.
    public static let messagingTimeout: Float = 0.2

    /// The element at `point` (global top-left points) as the app reports it.
    /// Nil when accessibility does not answer.
    public static func hit(at point: CGPoint, pid: pid_t) -> Hit? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        var found: AXUIElement?
        guard AXUIElementCopyElementAtPosition(app, Float(point.x), Float(point.y), &found) == .success,
              let element = found else { return nil }
        AXUIElementSetMessagingTimeout(element, messagingTimeout)
        let role: String = attribute(element, kAXRoleAttribute) ?? "AXUnknown"
        var windowElement: AXUIElement? = attribute(element, kAXWindowAttribute)
        if windowElement == nil { windowElement = attribute(element, kAXTopLevelUIElementAttribute) }
        var inMenu = role == kAXMenuItemRole as String || role == kAXMenuRole as String || role == kAXMenuBarItemRole as String
        var node: AXUIElement? = element
        for _ in 0..<16 where !inMenu {
            guard let current = node, let parent: AXUIElement = attribute(current, kAXParentAttribute) else { break }
            let parentRole: String? = attribute(parent, kAXRoleAttribute)
            if parentRole == kAXMenuRole as String || parentRole == kAXMenuBarRole as String { inMenu = true }
            node = parent
        }
        return Hit(role: role, texts: texts(of: element), shortcut: shortcut(of: element),
                   windowID: windowElement.flatMap(WindowMover.windowID(of:)), inMenu: inMenu)
    }

    /// The items of the app's menu bar menus (first level) that have a
    /// keyboard equivalent. Nil when the menu bar cannot be read. Reading
    /// a menu's items does not open it.
    public static func menuItems(pid: pid_t, limit: Int = 600) -> [MenuItem]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        guard let bar: AXUIElement = attribute(app, kAXMenuBarAttribute) else { return nil }
        var items: [MenuItem] = []
        var seen = 0
        for top in (attribute(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            for menu in (attribute(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                for item in (attribute(menu, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
                    seen += 1
                    if seen > limit { return items }
                    if let s = shortcut(of: item) { items.append(MenuItem(texts: texts(of: item), shortcut: s)) }
                }
            }
        }
        return items
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

    static func shortcut(of element: AXUIElement) -> String? {
        guard let char: String = attribute(element, kAXMenuItemCmdCharAttribute) else { return nil }
        let mods: Int = attribute(element, kAXMenuItemCmdModifiersAttribute) ?? 0
        return shortcut(char: char, modifiers: mods)
    }

    static func texts(of element: AXUIElement) -> [String] {
        var out: [String] = []
        for name in [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXPlaceholderValue"] {
            if let t: String = attribute(element, name), !t.isEmpty { out.append(t) }
        }
        if let v: String = attribute(element, kAXValueAttribute), !v.isEmpty, v.count <= 64 { out.append(v) }
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
