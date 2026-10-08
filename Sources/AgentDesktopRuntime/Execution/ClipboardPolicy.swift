import Foundation

/// G2 (Kevin, 2026-10-08/09): an agent's input never goes through the
/// system clipboard. The clipboard is the user's: pasting would put what the
/// user last copied (often a password or a key) into an app an agent drives,
/// and copying or cutting would overwrite it. For now no agent may use it at
/// all; using it later needs its own explicit grant, which does not exist
/// yet.
///
/// The rule does not depend on what a caller says about its input, and no
/// run mode, origin or principal lifts it: it is applied in `act` right
/// before the input is sent, the one place every entry (CLI, MCP, SDK, ACP,
/// independent agents, the GUI explorer) reaches the platform. Where the
/// Runtime cannot tell whether an input would use the clipboard, it refuses
/// (fail closed):
///
/// - Keys: what the engine actually sends is judged under the current
///   keyboard layout (a Dvorak cmd+"." is paste). With cmd or ctrl, the
///   character v, c or x is refused, as is any combination the target app's
///   menu bar gives to a paste, copy or cut item (shortcuts the user moved);
///   an unreadable layout or menu bar refuses. F2–F4 (cut, copy, paste in
///   Office) are refused.
/// - Clicks, by element or by point: the element under the point is read
///   again just before sending. A menu item is allowed only once read and
///   seen not to paste, copy or cut; anything outside the bound window that
///   is not a menu, and anything accessibility cannot read, is refused; any
///   control whose name says paste, copy or cut (in the languages macOS
///   ships) is refused.
/// - Typing never uses the clipboard (accessibility value writes or unicode
///   key events; a test keeps it so). Scrolling neither. But typed text goes
///   to the focused element, and its target may be clicked first: both are
///   checked like a click.
/// - Return and Space (by name or as a blank character) press the focused
///   control. Before them and before any typing the focused element is read
///   now: a control named paste, copy or cut is refused, and an unreadable
///   focus refuses.
///
/// Not covered, by its nature: an app that reads the clipboard by itself
/// after an ordinary input (a terminal running `pbpaste`, a web page reading
/// the clipboard in a click handler), and app-specific keys outside its menu
/// bar. The docs say so.
enum ClipboardPolicy {
    static let clipboardKeys: Set<String> = ["v", "c", "x"]
    static let commandModifiers: Set<String> = ["cmd", "command", "meta"]
    static let controlModifiers: Set<String> = ["ctrl", "control"]
    /// Cut, copy and paste in Microsoft Office for Mac, sent as key codes.
    static let functionKeys: Set<String> = ["f2", "f3", "f4"]

    /// Why sending this action would or might use the clipboard, or nil.
    /// `menu` is the target app's menu bar, read before the Desktop's lock
    /// was taken (`needsMenu`), for that `pid`; nil when unreadable.
    static func refusal(_ action: PlatformAction, snapshotElement: PlatformElement?, pid: Int32, windowId: UInt32,
                        menu: (pid: Int32, items: [PlatformMenuItem]?)?, platform: DesktopPlatform) -> String? {
        switch action.kind {
        case .scroll:
            return nil
        case .type:
            // The text goes to whatever has focus (directly, or when writing
            // a field's value fails): a space or newline typed into a focused
            // "Copy" button presses it.
            if let refused = focusRefusal(pid: pid, platform: platform) { return refused }
            // Typing into a field the engine must first click (a web field
            // without focus) is a click: the element must be a text field.
            let point = action.point ?? snapshotElement?.frame.map { ($0.x + $0.width / 2, $0.y + $0.height / 2) }
            guard snapshotElement != nil || action.point != nil else { return nil }
            guard let point else { return "hit_unavailable" }
            return typeRefusal(at: point, label: snapshotElement.map { [$0.label, $0.value].compactMap { $0 } } ?? [],
                               pid: pid, windowId: windowId, platform: platform)
        case .key:
            return keyRefusal(action, pid: pid, menu: menu?.pid == pid ? menu?.items : nil, platform: platform)
        case .click:
            return clickRefusal(action, snapshotElement: snapshotElement, pid: pid, windowId: windowId, platform: platform)
        }
    }

    /// Keys that move or edit, pressed alone, are not looked up in the menu
    /// bar (every Return or arrow would otherwise read it): moving paste onto
    /// one of them is left out (docs).
    static let plainKeys: Set<String> = ["return", "enter", "tab", "space", "escape", "esc", "delete", "backspace",
                                         "forwarddelete", "left", "right", "up", "down", "home", "end", "pageup", "pagedown"]
    static let keyAliases: [String: String] = ["enter": "return", "esc": "escape", "backspace": "delete"]

    /// Whether the menu bar must be read for this action (before the lock):
    /// any modified key, and function keys alone.
    static func needsMenu(_ action: PlatformAction) -> Bool {
        guard action.kind == .key else { return false }
        let key = (action.key ?? "").lowercased()
        if !action.modifiers.isEmpty { return true }
        return key.count > 1 && !plainKeys.contains(key)
    }

    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXSearchField", "AXComboBox", "AXSecureTextField"]

    static func typeRefusal(at point: (x: Double, y: Double), label: [String], pid: Int32, windowId: UInt32,
                            platform: DesktopPlatform) -> String? {
        guard let hit = platform.clipboardHit(at: point, pid: pid) else { return "hit_unavailable" }
        guard hit.windowId == windowId, !hit.inMenu else { return "outside_bound_window" }
        let role = String(hit.role.split(separator: "/").first ?? "")
        // The engine may click the element first (a web field without focus,
        // judged on its side): only a text field or editable text, never a
        // control, and nothing named paste, copy or cut.
        guard hit.editable || textRoles.contains(role) else { return "type_target_not_text" }
        if (hit.texts + hit.ancestorTexts + label).contains(where: names) { return "control" }
        return nil
    }

    /// Keys that press the focused control. A key given as a blank character
    /// (" ", "\n", "\r", "\t") counts too.
    static let pressingKeys: Set<String> = ["return", "enter", "space"]

    static func presses(_ key: String) -> Bool {
        pressingKeys.contains(key) || (!key.isEmpty && key.allSatisfy { $0.isWhitespace || $0.isNewline })
    }

    /// The app's focused element, read now (once more if the first read
    /// fails: a page may be busy for a moment). A control named paste, copy
    /// or cut, or carrying a clipboard shortcut, is refused; an unreadable
    /// focus refuses. A text field or editable text with focus is fine.
    static func focusRefusal(pid: Int32, platform: DesktopPlatform) -> String? {
        guard let focused = platform.focusedControl(pid: pid) ?? platform.focusedControl(pid: pid) else {
            return "focused_unverified"
        }
        let role = String(focused.role.split(separator: "/").first ?? "")
        if focused.editable || textRoles.contains(role) { return nil }
        if let s = focused.shortcut, isClipboardShortcut(s) { return "focused_control" }
        if (focused.texts + focused.ancestorTexts).contains(where: names) { return "focused_control" }
        return nil
    }

    static func keyRefusal(_ action: PlatformAction, pid: Int32, menu: [PlatformMenuItem]?, platform: DesktopPlatform) -> String? {
        let key = (action.key ?? "").lowercased()
        if functionKeys.contains(key) { return "function_key" }
        // Return or Space presses whatever has focus: a "Copy" button reached
        // with Tab is a click on it.
        if presses(key), let refused = focusRefusal(pid: pid, platform: platform) { return refused }
        let mods = action.modifiers.map { $0.lowercased() }
        // Shift+Delete is cut in Windows guests (virtual machines, remote desktops).
        if key == "forwarddelete" && mods.contains("shift") { return "shortcut" }
        let command = mods.contains { commandModifiers.contains($0) }
        let control = mods.contains { controlModifiers.contains($0) }
        var characters: [String] = []
        if command || control {
            // The character the engine's key code gives, with and without the
            // modifiers: layouts that type Dvorak but use QWERTY for cmd differ.
            for state in [action.modifiers, []] {
                switch platform.keyCharacter(key, modifiers: state) {
                case .unknown: return "layout_unknown"
                case .named: break
                case let .character(c): characters.append(c.lowercased())
                }
            }
            if characters.contains(where: clipboardKeys.contains) || (key.count == 1 && clipboardKeys.contains(key)) {
                return "shortcut"
            }
        }
        // Any other modified or named key may be what the app (or the user,
        // in System Settings) gave to paste, copy or cut: F6, option+P, cmd+F5.
        guard needsMenu(action) else { return nil }
        guard let menu else { return "menu_unverified" }
        var pressed = Set(characters.map { combo(mods, $0) })
        pressed.insert(combo(mods, keyAliases[key] ?? key))
        if menu.contains(where: { isClipboardItem(texts: $0.texts, shortcut: $0.shortcut) && pressed.contains(normalised(shortcut: $0.shortcut)) }) {
            return "menu_shortcut"
        }
        return nil
    }

    static func clickRefusal(_ action: PlatformAction, snapshotElement: PlatformElement?, pid: Int32, windowId: UInt32,
                             platform: DesktopPlatform) -> String? {
        let point = action.point ?? snapshotElement?.frame.map { ($0.x + $0.width / 2, $0.y + $0.height / 2) }
        guard let point else { return "hit_unavailable" }
        // Read now, not from the snapshot: a menu may have opened since, and
        // a control's name may have changed.
        guard let hit = platform.clipboardHit(at: point, pid: pid) else { return "hit_unavailable" }
        let role = String(hit.role.split(separator: "/").first ?? "")
        let texts = hit.texts + hit.ancestorTexts + (snapshotElement.map { [$0.label, $0.value].compactMap { $0 } } ?? [])
        if hit.inMenu || role == "AXMenuItem" || role == "AXMenuBarItem" {
            if let s = hit.shortcut, isClipboardShortcut(s) { return "menu_item" }
            if texts.contains(where: names) { return "menu_item" }
            // A menu item that says nothing about itself cannot be judged.
            if hit.shortcut == nil && texts.allSatisfy({ $0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                return "menu_item_unverified"
            }
            return nil
        }
        // Outside the bound window and not a menu: a sheet, a popover, a
        // panel or another app's window, which the snapshot never showed.
        guard hit.windowId == windowId else { return "outside_bound_window" }
        if texts.contains(where: names) { return "control" }
        return nil
    }

    // Names

    /// First words that mean paste, copy or cut in the languages macOS ships
    /// (whole words, so "Copyright" is not "Copy").
    static let words: Set<String> = [
        "paste", "copy", "cut", "coller", "copier", "couper", "einfügen", "kopieren", "ausschneiden", "pegar",
        "copiar", "cortar", "colar", "incolla", "copia", "taglia", "plakken", "kopiëren", "knippen", "вставить",
        "копировать", "вырезать", "вставити", "копіювати", "вирізати", "wklej", "kopiuj", "wytnij", "yapıştır",
        "kopyala", "kes", "kopiera", "klipp", "kopier", "indsæt", "kopiér", "klip", "liitä", "kopioi", "leikkaa",
        "vložit", "kopírovat", "vyjmout", "vložiť", "kopírovať", "vystrihnúť", "beillesztés", "másolás", "kivágás",
        "lipire", "copiere", "decupare", "επικόλληση", "αντιγραφή", "αποκοπή", "הדבק", "העתק", "גזור", "لصق", "نسخ",
        "قص", "dán", "tempel", "salin", "potong", "tampal", "enganxa", "retalla", "zalijepi", "kopiraj", "izreži",
        "ielīmēt", "kopēt", "izgriezt", "įklijuoti", "kopijuoti", "iškirpti", "einsetzen", "plak", "kopieer", "knip",
        "sijoita", "скопировать", "복사하기", "오려두기", "lipește", "copiază", "decupează", "скопіювати", "cắt", "yapiştir",
    ]
    /// Beginnings for scripts without spaces, and multi-word names.
    static let prefixes: [String] = [
        "粘贴", "拷贝", "复制", "剪切", "貼上", "拷貝", "複製", "剪下", "貼り付け", "貼付", "ペースト", "コピー", "カット", "切り取り", "붙여넣기", "복사", "잘라내기", "klistra in", "lim inn", "sao chép", "चिपकाएँ", "कॉपी", "काटें", "sæt ind", "klipp ut", "पेस्ट", "贴上", "วาง", "คัดลอก", "ตัด", "สำเนา",
    ]

    /// Whether a control's name says paste, copy or cut. Long texts (a
    /// paragraph that starts with "Copy…") are not names.
    static func names(_ text: String) -> Bool {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while t.hasSuffix("…") || t.hasSuffix(".") { t.removeLast() }
        guard !t.isEmpty, t.count <= 40 else { return false }
        if prefixes.contains(where: t.hasPrefix) { return true }
        let first = t.split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == ":" }).first.map(String.init) ?? t
        return words.contains(first)
    }

    static func isClipboardItem(texts: [String], shortcut: String) -> Bool {
        isClipboardShortcut(shortcut) || texts.contains(where: names)
    }

    /// cmd or ctrl with v, c or x, in any order or variant: "cmd+V",
    /// "cmd+option+shift+V", "ctrl+C".
    static func isClipboardShortcut(_ shortcut: String) -> Bool {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return false }
        return clipboardKeys.contains(key)
            && parts.dropLast().contains { commandModifiers.contains($0) || controlModifiers.contains($0) }
    }

    /// "cmd+shift+v" with the modifiers in one order.
    static func combo(_ modifiers: [String], _ character: String) -> String {
        let order = ["cmd", "ctrl", "option", "shift"]
        let canon = Set(modifiers.map { m -> String in
            switch m { case "command", "meta": "cmd"; case "control": "ctrl"; case "alt", "opt": "option"; default: m }
        })
        return (order.filter(canon.contains) + [character.lowercased()]).joined(separator: "+")
    }

    static func normalised(shortcut: String) -> String {
        let parts = shortcut.lowercased().split(separator: "+").map(String.init)
        guard let key = parts.last else { return shortcut.lowercased() }
        return combo(Array(parts.dropLast()), keyAliases[key] ?? key)
    }
}
