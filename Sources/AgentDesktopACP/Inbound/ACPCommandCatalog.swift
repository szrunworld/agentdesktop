import AgentDesktopContracts
import CryptoKit
import Foundation

/// Read and control commands every session has. They never start a task.
public enum ACPCommandFixed: String, CaseIterable, Sendable {
    case help
    case status
    case runs
    case cancel

    var info: ACPCommandInfo {
        switch self {
        case .help: return ACPCommandInfo(name: "help", description: "列出可用命令")
        case .status: return ACPCommandInfo(name: "status", description: "查看本会话任务的状态", inputHint: "[runId]")
        case .runs: return ACPCommandInfo(name: "runs", description: "列出本会话的任务")
        case .cancel: return ACPCommandInfo(name: "cancel", description: "请求停止本会话正在运行的任务", inputHint: "[runId]")
        }
    }
}

/// What one prompt asks for.
public enum ACPCommandParse: Equatable, Sendable {
    case empty
    case fixed(ACPCommandFixed, argument: String)
    case task(ACPExposedTask, argument: String)
    /// Free text routed to the one task that declared `allowFreeText`.
    case freeText(ACPExposedTask, text: String)
    case unknownCommand(String)
    case freeTextNotAllowed
    case ambiguousFreeText([String])
}

/// `available_commands`: one command per task the caller may start (from
/// `ACPRuntimePort.tasks()`, never hard-coded business) plus the fixed
/// read/control commands.
public struct ACPCommandCatalog: Sendable {
    public let tasks: [ACPExposedTask]
    /// command name → task
    public let taskCommands: [(name: String, task: ACPExposedTask)]

    public init(tasks: [ACPExposedTask]) {
        self.tasks = tasks
        let fixed = Set(ACPCommandFixed.allCases.map(\.rawValue))
        var used = fixed
        var out: [(String, ACPExposedTask)] = []
        for t in tasks {
            var name = Self.slug(t.taskType)
            if name.isEmpty { name = "task" }
            if fixed.contains(name) { name += "-task" }
            var n = name, i = 2
            while used.contains(n) { n = "\(name)-\(i)"; i += 1 }
            used.insert(n)
            out.append((n, t))
        }
        taskCommands = out
    }

    public var commands: [ACPCommandInfo] {
        let task = taskCommands.map { entry in
            ACPCommandInfo(name: entry.name,
                           description: entry.task.description.isEmpty ? entry.task.displayName : entry.task.description,
                           inputHint: ACPCommandInput.hint(for: entry.task.inputSchema))
        }
        return task + ACPCommandFixed.allCases.map(\.info)
    }

    public func parse(_ text: String) -> ACPCommandParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .empty }
        if trimmed.hasPrefix("/") {
            let body = trimmed.dropFirst()
            let name = body.prefix(while: { !$0.isWhitespace })
            let argument = body.dropFirst(name.count).trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = name.lowercased()
            if let f = ACPCommandFixed(rawValue: lower) { return .fixed(f, argument: argument) }
            if let entry = taskCommands.first(where: { $0.name == lower }) {
                return .task(entry.task, argument: argument)
            }
            return .unknownCommand(String(name))
        }
        let free = taskCommands.filter { $0.task.allowFreeText }
        switch free.count {
        case 0: return .freeTextNotAllowed
        case 1: return .freeText(free[0].task, text: trimmed)
        default: return .ambiguousFreeText(free.map(\.name))
        }
    }

    public func commandName(for task: ACPExposedTask) -> String? {
        taskCommands.first(where: { $0.task == task })?.name
    }

    static func slug(_ s: String) -> String {
        var out = ""
        var lastDash = false
        for ch in s.lowercased() {
            if ch.isASCII, ch.isLetter || ch.isNumber {
                out.append(ch); lastDash = false
            } else if !lastDash, !out.isEmpty {
                out.append("-"); lastDash = true
            }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }
}

/// Turning a command's argument text into task input.
public enum ACPCommandInput {
    public enum Problem: Error, Equatable, Sendable {
        case notJSONObject
        case needsJSON(hint: String)
    }

    /// Empty → `{}`; `{…}` → that object; otherwise the text fills the one
    /// string property the schema declares (or `text` when it declares none).
    public static func input(argument: String, schema: JSONValue) -> Result<JSONValue, Problem> {
        let trimmed = argument.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return .success(.object([])) }
        if trimmed.hasPrefix("{") {
            guard let v = try? StrictJSON.parse(trimmed), v.objectMembers != nil else { return .failure(.notJSONObject) }
            return .success(v)
        }
        if let p = primaryTextProperty(schema) { return .success(.obj([(p, .string(trimmed))])) }
        if (schema["properties"]?.objectMembers ?? []).isEmpty, schema["additionalProperties"]?.boolValue != false {
            return .success(.obj([("text", .string(trimmed))]))
        }
        return .failure(.needsJSON(hint: hint(for: schema) ?? "{}"))
    }

    static func primaryTextProperty(_ schema: JSONValue) -> String? {
        let props = schema["properties"]?.objectMembers ?? []
        let strings = props.filter { ACPCommandInputValidator.types($0.value).contains("string") }.map(\.key)
        if strings.count == 1 { return strings[0] }
        let required = Set((schema["required"]?.arrayValue ?? []).compactMap(\.stringValue))
        let requiredStrings = strings.filter { required.contains($0) }
        return requiredStrings.count == 1 ? requiredStrings[0] : nil
    }

    /// A display hint built from property names only.
    public static func hint(for schema: JSONValue) -> String? {
        let props = schema["properties"]?.objectMembers ?? []
        if props.isEmpty { return nil }
        if let p = primaryTextProperty(schema) { return "<\(p)>" }
        return "{" + props.map { "\"\($0.key)\": …" }.joined(separator: ", ") + "}"
    }
}

/// The JSON Schema subset a task input is checked against before it is
/// submitted: type, properties, required, additionalProperties (false),
/// enum, const, min/maxLength, minimum/maximum, items, min/maxItems. Other
/// keywords are left to the Runtime, which validates again. Problems name
/// paths and rules, never values.
public enum ACPCommandInputValidator {
    public static func validate(_ value: JSONValue, schema: JSONValue) -> [String] {
        var out: [String] = []
        check(value, schema, path: "$", into: &out)
        return out
    }

    static func types(_ schema: JSONValue) -> [String] {
        if let s = schema["type"]?.stringValue { return [s] }
        return (schema["type"]?.arrayValue ?? []).compactMap(\.stringValue)
    }

    private static func typeName(_ v: JSONValue) -> String {
        switch v {
        case .null: return "null"
        case .bool: return "boolean"
        case .number: return v.intValue != nil ? "integer" : "number"
        case .string: return "string"
        case .array: return "array"
        case .object: return "object"
        }
    }

    private static func matches(_ v: JSONValue, _ type: String) -> Bool {
        let actual = typeName(v)
        if type == "number" { return actual == "number" || actual == "integer" }
        return actual == type
    }

    private static func check(_ v: JSONValue, _ schema: JSONValue, path: String, into out: inout [String]) {
        guard schema.objectMembers != nil else { return }
        let ts = types(schema)
        if !ts.isEmpty, !ts.contains(where: { matches(v, $0) }) {
            out.append("\(path)：应为 \(ts.joined(separator: "/"))")
            return
        }
        if let e = schema["enum"]?.arrayValue, !e.contains(v) { out.append("\(path)：不在允许的取值内") }
        if let c = schema["const"], c != v { out.append("\(path)：不是允许的值") }
        switch v {
        case let .string(s):
            if let n = schema["minLength"]?.intValue, s.count < n { out.append("\(path)：至少 \(n) 个字符") }
            if let n = schema["maxLength"]?.intValue, s.count > n { out.append("\(path)：最多 \(n) 个字符") }
        case let .number(_, d):
            if let m = schema["minimum"]?.doubleValue, d < m { out.append("\(path)：不能小于 \(m)") }
            if let m = schema["maximum"]?.doubleValue, d > m { out.append("\(path)：不能大于 \(m)") }
        case let .array(items):
            if let n = schema["minItems"]?.intValue, items.count < n { out.append("\(path)：至少 \(n) 项") }
            if let n = schema["maxItems"]?.intValue, items.count > n { out.append("\(path)：最多 \(n) 项") }
            if let s = schema["items"] {
                for (i, item) in items.enumerated() { check(item, s, path: "\(path)[\(i)]", into: &out) }
            }
        case let .object(members):
            let props = schema["properties"]?.objectMembers ?? []
            for r in (schema["required"]?.arrayValue ?? []).compactMap(\.stringValue)
            where !members.contains(where: { $0.key == r }) {
                out.append("\(path).\(r)：必填")
            }
            for m in members {
                if let p = props.first(where: { $0.key == m.key }) {
                    check(m.value, p.value, path: "\(path).\(m.key)", into: &out)
                } else if schema["additionalProperties"]?.boolValue == false {
                    out.append("\(path)：不接受字段 \(m.key)")
                }
            }
        default:
            break
        }
    }
}

/// The submission key of one prompt turn. Same session, same position in
/// the session and same request → same key, so an editor retry reaches the
/// Runtime's request ledger as the same request and maps to the same Run.
public enum ACPPromptSubmissionKey {
    public static func make(sessionId: String, ordinal: Int, taskType: String, input: JSONValue) -> String {
        let material = "acp-submission/1\n\(sessionId)\n\(ordinal)\n\(taskType)\n\(input.encoded())"
        let digest = SHA256.hash(data: Data(material.utf8))
        return "acp1-" + digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
