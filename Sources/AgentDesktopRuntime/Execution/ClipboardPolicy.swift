import Foundation

/// G2 (Kevin, 2026-10-08): input never travels through the system
/// clipboard. The clipboard is the user's: pasting would put whatever the
/// user last copied (often a password) into an app an agent drives, and
/// copying or cutting would overwrite it. The rule does not depend on what
/// a caller says about its text, and no run mode, origin or principal lifts
/// it, so every entry (CLI, MCP, SDK, ACP, independent agents, the GUI
/// explorer) is held to it at the one place input is resolved before it is
/// sent (`RuntimeService.platformAction`).
///
/// Typing itself never uses the clipboard on macOS: `act type` goes through
/// accessibility value writes or unicode key events (InputEngine,
/// BackgroundInput; a test keeps it that way). What remains are actions
/// that ask the app to use the clipboard for us, refused here.
enum ClipboardPolicy {
    /// Command with one of these: paste, copy, cut, and their variants with
    /// shift or option (paste and match style, …).
    static let shortcutKeys: Set<String> = ["v", "c", "x"]
    static let commandModifiers: Set<String> = ["cmd", "command", "meta"]
    /// Controls whose press uses the clipboard, matched on the whole label.
    static let pressedRoles: Set<String> = ["AXMenuItem", "AXMenuBarItem", "AXButton", "AXMenuButton"]
    static let clipboardLabels: Set<String> = [
        "paste", "copy", "cut", "paste and match style", "paste and retain style", "paste style", "copy style",
        "粘贴", "拷贝", "复制", "剪切", "粘贴并匹配样式", "粘贴并保留样式", "粘贴样式", "拷贝样式",
    ]

    /// Which clipboard path the action would take, or nil.
    static func path(of action: PlatformAction, pressing element: PlatformElement?) -> String? {
        if action.kind == .key, let key = action.key?.lowercased(), shortcutKeys.contains(key),
           action.modifiers.contains(where: { commandModifiers.contains($0.lowercased()) }) {
            return "shortcut"
        }
        if action.kind == .click, let e = element, pressedRoles.contains(e.role),
           let label = e.label.map(normalised), clipboardLabels.contains(label) {
            return "control"
        }
        return nil
    }

    static func normalised(_ label: String) -> String {
        var l = label.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while l.hasSuffix("…") || l.hasSuffix(".") { l.removeLast() }
        return l
    }
}
