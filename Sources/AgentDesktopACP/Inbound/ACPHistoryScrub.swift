import Foundation

/// How a history line written before format 2 is kept (Kevin's S4 ruling on
/// #141): user lines never keep text; agent lines keep their useful content
/// (task accepted, status, results, timeline) and lose only what echoed the
/// user's input or a Runtime question. The templates that echoed are the
/// ones the server's `say` used before format 2:
/// - "没有 /<word> 这个命令。…"            → the user's first word
/// - "/<cmd> 的输入不符合要求，未创建任务：…" → field names the user typed
/// - "任务 <run> 需要你的回答：<question>…"  → the Runtime's question
/// - "Runtime 拒绝了这个任务…"             → older builds: the Runtime's message
/// - "/runs <arg>" status lines            → any argument, as "<arg>：…"
/// Every other agent line is kept, redacted again.
///
/// All matching is on Unicode scalars, never on Characters: a user-typed
/// prepend mark (e.g. U+0600) merges with the server's "：" into one
/// grapheme, which Character-level `contains`/`firstIndex` then miss (b9,
/// fifth review). Status values are the schema's enums only.
enum ACPHistoryScrub {
    enum Outcome: Equatable { case kept, changed }

    static func legacyAgent(_ text: String, runIds: Set<String>) -> (String, Outcome) {
        if startsWith(text, "没有 /"), has(text, "这个命令") {
            return ("没有这个命令。", .changed)
        }
        if let i = scalarIndex(of: scalars("的输入不符合要求，未创建任务"), in: scalars(text)) {
            let command = String(String.UnicodeScalarView(scalars(text)[..<i])).trimmingCharacters(in: .whitespaces)
            let safe = startsWith(command, "/") && command.unicodeScalars.dropFirst().allSatisfy(isPlainNameScalar)
            return ((safe ? command : "命令") + " 的输入不符合要求，未创建任务。", .changed)
        }
        if startsWith(text, "任务 "), let i = scalarIndex(of: scalars(" 需要你的回答"), in: scalars(text)) {
            let run = String(String.UnicodeScalarView(scalars(text)[3..<max(3, i)]))
            let shown = runIds.contains(run) ? "任务 \(run)" : "任务"
            return ("\(shown) 需要你的回答（问题内容不保存）。", .changed)
        }
        if startsWith(text, "Runtime 拒绝了这个任务") {
            return ("Runtime 拒绝了这个任务。", .changed)
        }
        // Status output. Every line is matched whole (b9, fourth and fifth
        // reviews): a /runs argument could be any text, with "：" or any
        // newline in it. When the text carries a status marker anywhere,
        // only lines that are exactly one of the server's status forms about
        // a Run of this session stay; every other line is cleared.
        let lines = scalarLines(text)
        let isStatus = has(text, "：状态待核实") || has(text, "：阶段 ")
        var changed = lines.count > 1 && text.unicodeScalars.contains { isNewlineScalar($0) && $0 != "\n" }
        let kept = !isStatus ? lines : lines.map { line -> String in
            if isKnownStatusLine(line, runIds: runIds) { return line }
            changed = true
            return "（不属于本会话的任务，已清除）"
        }
        let out = ACPRedactor.redact(kept.joined(separator: "\n"))
        return (out, changed || !scalarsEqual(out, text) ? .changed : .kept)
    }

    // MARK: Status forms

    static let phases: Set<String> = ["queued", "running", "waiting_approval", "waiting_input", "stopping", "ended"]
    static let outcomes: Set<String> = ["success", "failed", "cancelled"]
    static let quiescence: Set<String> = ["not_confirmed", "pending", "confirmed"]
    static let unverified = "状态待核实（不会自动重试）"
    static let unknownOutcome = "结果未知 · 需要核实（不会自动重试）"

    /// One whole line, compared scalar by scalar, in one of the server's
    /// status forms about a Run of this session:
    /// "<run>：状态待核实（不会自动重试）", "<run>：<describe>",
    /// "任务 <run> 已结束：<describe>", "正在停止任务 <run>：<describe>".
    static func isKnownStatusLine(_ line: String, runIds: Set<String>) -> Bool {
        let v = scalars(line)
        guard let sep = v.firstIndex(of: "："), v[(sep + 1)...].firstIndex(of: "：") == nil else { return false }
        let head = String(String.UnicodeScalarView(v[..<sep]))
        let tail = String(String.UnicodeScalarView(v[(sep + 1)...]))
        if let run = strip(head, prefix: "任务 ", suffix: " 已结束") ?? strip(head, prefix: "正在停止任务 ", suffix: "") {
            return runIds.contains(run) && isDescribe(tail)
        }
        guard runIds.contains(head) else { return false }
        return scalarsEqual(tail, unverified) || isDescribe(tail)
    }

    /// `ACPAgentServer.describe` exactly, with schema enum values only:
    /// "阶段 <phase>", then optionally "，结果未知 · 需要核实（不会自动重试）"
    /// or "，结果 <outcome>", then optionally "，输入静止 <quiescence>".
    static func isDescribe(_ s: String) -> Bool {
        var parts = splitScalars(s, on: "，")[...]
        guard let first = parts.popFirst(), let phase = strip(first, prefix: "阶段 ", suffix: ""),
              phases.contains(phase) else { return false }
        if let p = parts.first {
            if scalarsEqual(p, unknownOutcome) {
                parts = parts.dropFirst()
            } else if let o = strip(p, prefix: "结果 ", suffix: ""), outcomes.contains(o) {
                parts = parts.dropFirst()
            }
        }
        if let p = parts.first, let q = strip(p, prefix: "输入静止 ", suffix: ""), quiescence.contains(q) {
            parts = parts.dropFirst()
        }
        return parts.isEmpty
    }

    // MARK: Scalar helpers

    static func scalars(_ s: String) -> [Unicode.Scalar] { Array(s.unicodeScalars) }

    static func scalarsEqual(_ a: String, _ b: String) -> Bool { scalars(a) == scalars(b) }

    static func startsWith(_ s: String, _ prefix: String) -> Bool {
        let v = scalars(s), p = scalars(prefix)
        return v.count >= p.count && Array(v.prefix(p.count)) == p
    }

    static func has(_ s: String, _ needle: String) -> Bool {
        scalarIndex(of: scalars(needle), in: scalars(s)) != nil
    }

    static func scalarIndex(of needle: [Unicode.Scalar], in hay: [Unicode.Scalar]) -> Int? {
        guard !needle.isEmpty, hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// `s` without `prefix` and `suffix`, compared scalar by scalar.
    static func strip(_ s: String, prefix: String, suffix: String) -> String? {
        let v = scalars(s), p = scalars(prefix), x = scalars(suffix)
        guard v.count >= p.count + x.count, Array(v.prefix(p.count)) == p, Array(v.suffix(x.count)) == x else { return nil }
        return String(String.UnicodeScalarView(v[p.count..<(v.count - x.count)]))
    }

    static func splitScalars(_ s: String, on sep: Unicode.Scalar) -> [String] {
        scalars(s).split(separator: sep, omittingEmptySubsequences: false).map { String(String.UnicodeScalarView($0)) }
    }

    static func isNewlineScalar(_ c: Unicode.Scalar) -> Bool {
        ["\n", "\r", "\u{0B}", "\u{0C}", "\u{85}", "\u{2028}", "\u{2029}"].contains(c)
    }

    /// Lines split on every newline scalar ("\r\n" counts once).
    static func scalarLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = String.UnicodeScalarView()
        var previousCR = false
        for c in text.unicodeScalars {
            if c == "\n", previousCR { previousCR = false; continue }
            previousCR = c == "\r"
            if isNewlineScalar(c) {
                lines.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(c)
            }
        }
        lines.append(String(current))
        return lines
    }

    static func isPlainNameScalar(_ c: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(c) || ("A"..."Z").contains(c) || ("0"..."9").contains(c) || c == "-" || c == "_"
    }
}
