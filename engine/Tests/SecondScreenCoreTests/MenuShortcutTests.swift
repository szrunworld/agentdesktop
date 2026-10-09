import Foundation
import Testing
@testable import SecondScreenCore

/// A menu item's keyboard equivalent as AXMenuItemCmdChar and
/// AXMenuItemCmdModifiers report it (G2 judges paste, copy and cut by it).
struct MenuShortcutTests {
    @Test(arguments: [
        ("v", 0, "cmd+V"), ("V", 1, "cmd+shift+V"), ("V", 3, "cmd+option+shift+V"), ("c", 0, "cmd+C"),
        ("x", 4, "cmd+ctrl+X"), ("V", 8, "V"), (" b ", 0, "cmd+B"),
    ])
    func theEquivalentReadsAsTheMenuShowsIt(_ char: String, _ mods: Int, _ expected: String) {
        #expect(ClipboardProbe.shortcut(char: char, modifiers: mods) == expected)
    }

    @Test func anItemWithoutAKeyHasNone() {
        #expect(ClipboardProbe.shortcut(char: "", modifiers: 0) == nil)
        #expect(ClipboardProbe.shortcut(char: "  ", modifiers: 0) == nil)
    }
}

/// Named keys are given by virtual key code (AXMenuItemCmdVirtualKey).
struct MenuVirtualKeyTests {
    @Test func namedKeysReadByTheEnginesOwnNames() {
        #expect(ClipboardProbe.shortcut(virtualKey: 96, modifiers: 0) == "cmd+F5")
        #expect(ClipboardProbe.shortcut(virtualKey: 97, modifiers: 8) == "F6")
        #expect(ClipboardProbe.shortcut(virtualKey: 117, modifiers: 1) == "cmd+shift+FORWARDDELETE")
        #expect(ClipboardProbe.shortcut(virtualKey: 999, modifiers: 0) == nil)
    }
}

/// Menus show named keys as glyphs or function-key codes (b9, round 3).
struct MenuGlyphTests {
    @Test(arguments: [("\u{F709}", "f6"), ("\u{F704}", "f1"), ("\u{F700}", "up"), ("\u{0008}", "delete"),
                      ("\u{238B}", "escape"), ("\u{2326}", "forwarddelete"), ("\u{F728}", "forwarddelete")])
    func glyphsAreReadAsTheEnginesKeyNames(_ glyph: String, _ name: String) {
        #expect(ClipboardProbe.namedKey(forMenuCharacter: glyph) == name)
    }

    @Test func lettersAreNotNamedKeys() {
        #expect(ClipboardProbe.namedKey(forMenuCharacter: "V") == nil)
    }
}
