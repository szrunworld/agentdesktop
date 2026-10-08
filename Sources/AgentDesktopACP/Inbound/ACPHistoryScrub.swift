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
enum ACPHistoryScrub {
    enum Outcome: Equatable { case kept, changed }

    static func legacyAgent(_ text: String, runIds: Set<String>) -> (String, Outcome) {
        if text.hasPrefix("没有 /"), text.contains("这个命令") {
            return ("没有这个命令。", .changed)
        }
        if let r = text.range(of: "的输入不符合要求，未创建任务") {
            let command = text[..<r.lowerBound].trimmingCharacters(in: .whitespaces)
            let safe = command.hasPrefix("/") && command.dropFirst().allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
            return ((safe ? command : "命令") + " 的输入不符合要求，未创建任务。", .changed)
        }
        if text.hasPrefix("任务 "), let r = text.range(of: " 需要你的回答") {
            let run = String(text[text.index(text.startIndex, offsetBy: 3)..<r.lowerBound])
            let shown = runIds.contains(run) ? "任务 \(run)" : "任务"
            return ("\(shown) 需要你的回答（问题内容不保存）。", .changed)
        }
        if text.hasPrefix("Runtime 拒绝了这个任务") {
            return ("Runtime 拒绝了这个任务。", .changed)
        }
        // Status output. Every line is matched whole (b9, fourth review):
        // a /runs argument could be any text after a known run id, with
        // "：" or any newline character in it. Kept are exactly
        // "<run>：状态待核实（不会自动重试）", "<run>：<describe>",
        // "任务 <run> 已结束：<describe>" and "正在停止任务 <run>：<describe>"
        // for Runs of this session, where <describe> is the server's own
        // status format with plain tokens. Every other line of a text that
        // carries a status marker is cleared.
        let split = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init)
        var changed = split.count > 1 && text.contains(where: { $0.isNewline && $0 != "\n" })
        let isStatus = text.contains("：状态待核实") || text.contains("：阶段 ")
        let lines = !isStatus ? split : split.map { line -> String in
            if Self.isKnownStatusLine(line, runIds: runIds) { return line }
            changed = true
            return "（不属于本会话的任务，已清除）"
        }
        let out = ACPRedactor.redact(lines.joined(separator: "\n"))
        return (out, changed || out != text ? .changed : .kept)
    }

    static let unverified = "状态待核实（不会自动重试）"

    /// One whole line in one of the server's status forms, about a Run of
    /// this session.
    static func isKnownStatusLine(_ line: String, runIds: Set<String>) -> Bool {
        guard let sep = line.firstIndex(of: "：") else { return false }
        let head = String(line[..<sep])
        let tail = String(line[line.index(after: sep)...])
        let run: String
        if head.hasPrefix("任务 "), head.hasSuffix(" 已结束") {
            run = String(head.dropFirst(3).dropLast(4))
        } else if head.hasPrefix("正在停止任务 ") {
            run = String(head.dropFirst(7))
        } else {
            run = head
            if tail == unverified { return runIds.contains(run) }
        }
        return runIds.contains(run) && isDescribe(tail)
    }

    /// `ACPAgentServer.describe` exactly: "阶段 <t>", then optionally
    /// "，结果未知 · 需要核实（不会自动重试）" or "，结果 <t>", then optionally
    /// "，输入静止 <t>"; <t> is a plain token (a–z, 0–9, "_").
    static func isDescribe(_ s: String) -> Bool {
        func token(_ t: Substring) -> Bool {
            !t.isEmpty && t.unicodeScalars.allSatisfy { ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "_" }
        }
        var parts = s.components(separatedBy: "，")[...]
        guard let first = parts.popFirst(), first.hasPrefix("阶段 "), token(first.dropFirst(3)) else { return false }
        if let p = parts.first, p == "结果未知 · 需要核实（不会自动重试）" || (p.hasPrefix("结果 ") && token(p.dropFirst(3))) {
            parts = parts.dropFirst()
        }
        if let p = parts.first, p.hasPrefix("输入静止 "), token(p.dropFirst(5)) {
            parts = parts.dropFirst()
        }
        return parts.isEmpty
    }
}
