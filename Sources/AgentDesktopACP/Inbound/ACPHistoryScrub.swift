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
        // /runs and /status lines: "<id>：阶段 …" or "<id>：状态待核实…".
        // Lines the server wrote about its own Runs ("任务 <run> 已结束：…",
        // "正在停止任务 <run>：…") are not of that form and are kept.
        var changed = false
        let lines = text.components(separatedBy: "\n").map { line -> String in
            guard !line.hasPrefix("任务 "), !line.hasPrefix("正在停止任务 "),
                  let sep = line.range(of: "："),
                  line[sep.upperBound...].hasPrefix("阶段 ") || line[sep.upperBound...].hasPrefix("状态待核实") else { return line }
            let id = String(line[..<sep.lowerBound])
            if runIds.contains(id) { return line }
            changed = true
            return "（不属于本会话的任务，已清除）"
        }
        let out = ACPRedactor.redact(lines.joined(separator: "\n"))
        return (out, changed || out != text ? .changed : .kept)
    }
}
