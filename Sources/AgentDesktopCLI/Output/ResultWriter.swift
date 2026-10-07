import AgentDesktopContracts
import AgentDesktopProtocol
import Foundation

/// Writes a command's outcome. JSON: exactly one object on stdout, the
/// Runtime's envelope (requestId is null for a command answered locally).
/// Text: a short human form on stdout. Errors in text form go to stderr;
/// stdout then stays empty.
struct ResultWriter {
    let format: OutputFormat
    let stdout: (String) -> Void
    let stderr: (String) -> Void

    func success(requestId: String?, data: JSONValue, text: () -> String) {
        switch format {
        case .json, .jsonl:
            stdout(RuntimeResponse(requestId: requestId, result: .success(data)).json.encoded())
        case .text:
            stdout(text())
        }
    }

    func failure(requestId: String?, _ error: RuntimeError) {
        switch format {
        case .json, .jsonl:
            stdout(RuntimeResponse(requestId: requestId, result: .failure(error)).json.encoded())
        case .text:
            var line = "agentdesktop: \(error.code): \(error.message)"
            if let hint = Self.hint(error) { line += "\n  \(hint)" }
            stderr(line)
        }
    }

    static func hint(_ e: RuntimeError) -> String? {
        switch e.code {
        case "runtime_offline": return "start it with: agentdesktop runtime start"
        case "invalid_argument": return "see: agentdesktop help"
        case "version_mismatch", "instance_mismatch": return "this CLI and the Runtime come from different builds; use the CLI inside the installed app"
        default: return nil
        }
    }
}

/// Plain-text tables, columns padded to their widest cell.
enum TextTable {
    static func render(_ header: [String], _ rows: [[String]]) -> String {
        var widths = header.map(width)
        for r in rows { for (i, c) in r.enumerated() where i < widths.count { widths[i] = max(widths[i], width(c)) } }
        func line(_ cells: [String]) -> String {
            cells.enumerated().map { i, c in
                i == cells.count - 1 ? c : c + String(repeating: " ", count: widths[i] - width(c))
            }.joined(separator: "  ")
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }

    /// Terminal columns: East Asian wide and fullwidth characters take two.
    static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { n, u in
            switch u.value {
            case 0x1100...0x115F, 0x2E80...0x303E, 0x3041...0x33FF, 0x3400...0x4DBF, 0x4E00...0x9FFF,
                 0xA000...0xA4CF, 0xAC00...0xD7A3, 0xF900...0xFAFF, 0xFE30...0xFE4F, 0xFF00...0xFF60,
                 0xFFE0...0xFFE6, 0x1F300...0x1F64F, 0x1F900...0x1F9FF, 0x20000...0x3FFFD:
                return n + 2
            case 0x0300...0x036F, 0x200B...0x200F, 0xFE00...0xFE0F:
                return n
            default:
                return n + 1
            }
        }
    }

    static func duration(_ seconds: Double) -> String {
        let s = Int(seconds)
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s % 3600 / 60)m"
    }
}
