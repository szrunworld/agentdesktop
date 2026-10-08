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
///   key events; a test keeps it so). Scrolling neither.
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
    static func refusal(_ action: PlatformAction, snapshotElement: PlatformElement?, pid: Int32, windowId: UInt32,
                        platform: DesktopPlatform) -> String? {
        switch action.kind {
        case .type, .scroll:
            return nil
        case .key:
            return keyRefusal(action, pid: pid, platform: platform)
        case .click:
            return clickRefusal(action, snapshotElement: snapshotElement, pid: pid, windowId: windowId, platform: platform)
        }
    }

    static func keyRefusal(_ action: PlatformAction, pid: Int32, platform: DesktopPlatform) -> String? {
        let key = (action.key ?? "").lowercased()
        if functionKeys.contains(key) { return "function_key" }
        let mods = action.modifiers.map { $0.lowercased() }
        let command = mods.contains { commandModifiers.contains($0) }
        let control = mods.contains { controlModifiers.contains($0) }
        guard command || control else { return nil }
        // The character the engine's key code gives, with and without the
        // modifiers: layouts that type Dvorak but use QWERTY for cmd differ.
        var characters: [String] = []
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
        // Shortcuts the app (or the user, in System Settings) gave to paste,
        // copy or cut.
        guard let menu = platform.menuItems(pid: pid) else { return "menu_unverified" }
        let pressed = Set(characters.map { combo(mods, $0) } + (key.count == 1 ? [combo(mods, key)] : []))
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
        let texts = hit.texts + (snapshotElement.map { [$0.label, $0.value].compactMap { $0 } } ?? [])
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
        "قص", "วาง", "คัดลอก", "ตัด", "dán", "tempel", "salin", "potong", "tampal", "enganxa", "retalla", "zalijepi",
        "kopiraj", "izreži", "ielīmēt", "kopēt", "izgriezt", "įklijuoti", "kopijuoti", "iškirpti", "einsetzen",
        "plak", "kopieer", "knip", "sijoita", "скопировать", "복사하기", "오려두기", "lipește", "copiază", "decupează",
        "скопіювати", "สำเนา", "cắt",
    ]
    /// Beginnings for scripts without spaces, and multi-word names.
    static let prefixes: [String] = [
        "粘贴", "拷贝", "复制", "剪切", "貼上", "拷貝", "複製", "剪下", "貼り付け", "貼付", "ペースト", "コピー", "カット", "切り取り", "붙여넣기", "복사", "잘라내기", "klistra in", "lim inn", "sao chép", "चिपकाएँ", "कॉपी", "काटें", "sæt ind", "klipp ut", "पेस्ट",
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
        return combo(Array(parts.dropLast()), key)
    }
}
