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
        // Status output. The server wrote two single-line forms about its
        // own Runs ("任务 <run> 已结束：阶段 …", "正在停止任务 <run>：阶段 …");
        // kept only when the whole text is exactly one such line about a Run
        // of this session. Anything else that carries a status marker is
        // treated as /runs output, where an argument could be any text
        // (with "：" or newlines in it): only lines that are exactly
        // "<known run>：阶段 …" or "<known run>：状态待核实…" stay (b9).
        if !text.contains("\n"), let run = Self.ownRunLine(text), runIds.contains(run),
           !text.contains("：状态待核实") {
            return (ACPRedactor.redact(text), ACPRedactor.redact(text) == text ? .kept : .changed)
        }
        var changed = false
        let isStatus = text.contains("：状态待核实") || text.contains("：阶段 ")
        let lines = !isStatus ? text.components(separatedBy: "\n") : text.components(separatedBy: "\n").map { line -> String in
            if let sep = line.range(of: "："), runIds.contains(String(line[..<sep.lowerBound])),
               line[sep.upperBound...].hasPrefix("阶段 ") || line[sep.upperBound...].hasPrefix("状态待核实") {
                return line
            }
            changed = true
            return "（不属于本会话的任务，已清除）"
        }
        let out = ACPRedactor.redact(lines.joined(separator: "\n"))
        return (out, changed || out != text ? .changed : .kept)
    }

    /// The run id of "任务 <run> 已结束：阶段 …" or "正在停止任务 <run>：阶段 …",
    /// when the line has exactly that shape (one "：", no spaces in the id).
    static func ownRunLine(_ line: String) -> String? {
        guard line.components(separatedBy: "：").count == 2 else { return nil }
        let head = line.components(separatedBy: "：")[0]
        let tail = line.components(separatedBy: "：")[1]
        guard tail.hasPrefix("阶段 ") else { return nil }
        if head.hasPrefix("任务 "), head.hasSuffix(" 已结束") {
            let run = String(head.dropFirst(3).dropLast(4))
            return run.isEmpty || run.contains(" ") ? nil : run
        }
        if head.hasPrefix("正在停止任务 ") {
            let run = String(head.dropFirst(7))
            return run.isEmpty || run.contains(" ") ? nil : run
        }
        return nil
    }
}
