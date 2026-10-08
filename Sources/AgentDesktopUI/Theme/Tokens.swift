import SwiftUI

/// Design v2.0 visual system (Design Guide v2.0 "VISUAL SYSTEM"; values
/// kept in docs/design/v2/tokens.json, which TokensTests holds equal).
/// Pages take sizes and colours from here only.
public enum ADColor {
    /// Canvas behind panels.
    public static let canvas = Color(hex: 0xF5F6F2)
    /// Panels, cards, dialogs.
    public static let panel = Color(hex: 0xFFFFFF)
    /// Main text.
    public static let ink = Color(hex: 0x25352C)
    /// Primary actions and the selected entry's text.
    public static let primary = Color(hex: 0x416B53)
    /// Background of the selected entry.
    public static let selected = Color(hex: 0xE0E9D8)
    /// Hairlines and borders.
    public static let line = Color(hex: 0xDFE4DC)
    /// Secondary text.
    public static let muted = Color(hex: 0x64735F)

    public static let hex: [String: UInt32] = [
        "canvas": 0xF5F6F2, "panel": 0xFFFFFF, "ink": 0x25352C, "primary": 0x416B53,
        "selected": 0xE0E9D8, "line": 0xDFE4DC, "muted": 0x64735F,
    ]
}

/// Status colours. Design rule: colour and text always appear together;
/// a tone is never shown without its words (see StateBadge).
public enum StatusTone: String, CaseIterable, Sendable {
    /// Green: running / available.
    case running
    /// Grey: ready / stopped.
    case idle
    /// Amber: taken over / waiting / unknown.
    case attention
    /// Red: stop actions and errors.
    case danger

    public var foregroundHex: UInt32 {
        switch self {
        case .running: return 0x2F6B43
        case .idle: return 0x5F6B5C
        case .attention: return 0x8A5A00
        case .danger: return 0xB3261E
        }
    }

    public var backgroundHex: UInt32 {
        switch self {
        case .running: return 0xE3EFDF
        case .idle: return 0xEEF0EB
        case .attention: return 0xFBEFD5
        case .danger: return 0xFBE4E1
        }
    }

    public var foreground: Color { Color(hex: foregroundHex) }
    public var background: Color { Color(hex: backgroundHex) }
}

/// Type scale: titles 27 / 17, body 14, actions and notes 12, identifiers 10–12.
public enum ADFont {
    public static let pageTitleSize: CGFloat = 27
    public static let sectionTitleSize: CGFloat = 17
    public static let bodySize: CGFloat = 14
    public static let noteSize: CGFloat = 12
    public static let identifierSize: CGFloat = 11
    public static let eyebrowSize: CGFloat = 10

    public static let pageTitle = Font.system(size: pageTitleSize, weight: .bold)
    public static let sectionTitle = Font.system(size: sectionTitleSize, weight: .semibold)
    public static let body = Font.system(size: bodySize)
    public static let bodyStrong = Font.system(size: bodySize, weight: .semibold)
    public static let note = Font.system(size: noteSize)
    public static let noteStrong = Font.system(size: noteSize, weight: .semibold)
    /// Protocol identifiers (desktopId, requestId…) use a separate face.
    public static let identifier = Font.system(size: identifierSize, design: .monospaced)
    public static let code = Font.system(size: noteSize, design: .monospaced)
    public static let eyebrow = Font.system(size: eyebrowSize, weight: .bold)
}

/// Spacing rhythm 4 / 8 / 12 / 16 / 24 / 32.
public enum ADSpace {
    public static let xs: CGFloat = 4
    public static let s: CGFloat = 8
    public static let m: CGFloat = 12
    public static let l: CGFloat = 16
    public static let xl: CGFloat = 24
    public static let xxl: CGFloat = 32
    public static let all: [CGFloat] = [xs, s, m, l, xl, xxl]
}

public enum ADRadius {
    public static let button: CGFloat = 7
    public static let panel: CGFloat = 12
}

/// Window layout at the 1440 × 1000 design base.
public enum ADLayout {
    public static let sidebarWidth: CGFloat = 206
    public static let titleBarHeight: CGFloat = 54
    public static let statusBarHeight: CGFloat = 28
    public static let contentPadding: CGFloat = 32
    public static let buttonMinHeight: CGFloat = 36
    public static let designSize = CGSize(width: 1440, height: 1000)
}

extension Color {
    public init(hex: UInt32) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: 1)
    }
}
