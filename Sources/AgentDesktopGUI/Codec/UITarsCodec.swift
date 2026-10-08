import AgentDesktopProtocol
import Foundation

// Migrated from 2ndscreen da5677c Sources/TarsAgent/ActionParser.swift and
// Planner.swift (MIT, szrunworld; the reply format follows
// @ui-tars/action-parser, Apache-2.0, ByteDance). The old parser was
// lenient on purpose: it guessed the coordinate scale from magnitudes,
// read several actions per reply and recovered broken boxes. uitars_v1 is
// strict instead (spec §06.2, §08): one call, a fixed set of actions and
// arguments, the profile's explicit coordinate protocol, and refusal of
// anything else.

/// The uitars_v1 production adapter.
public struct UITarsCodec: GuiActionCodec {
    public static let adapterVersion = "1.0.0"
    public static let promptVersion = "uitars-prompt-1"
    public static let parserVersion = "uitars-parser-1"
    /// What one `scroll` moves, in source pixels. Part of parserVersion.
    public static let scrollAmountPixels = 300

    public let provenance: AdapterProvenance

    public init(coordinateProtocol: CoordinateProtocol) {
        provenance = AdapterProvenance(adapterId: .uitarsV1, adapterVersion: Self.adapterVersion,
                                       promptVersion: Self.promptVersion, parserVersion: Self.parserVersion,
                                       coordinateProtocol: coordinateProtocol)
    }

    public func decode(_ modelOutput: String, context: CodecContext) throws -> DecodedSuggestion {
        guard modelOutput.unicodeScalars.count <= CodecLimits.maxReplyScalars else {
            throw invalidAction("reply is too long")
        }
        let (thought, callText) = try Self.split(modelOutput)
        let call = try UITarsCall.parse(callText)
        let body = try interpret(call, context: context)
        return DecodedSuggestion(body: body, thought: thought)
    }

    /// Separate the reasoning from the single `Action:` line. A reply with
    /// no Action line, or more than one, is refused.
    static func split(_ text: String) throws -> (thought: String?, call: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw invalidAction("reply is empty") }
        let marker = try! NSRegularExpression(pattern: #"(?m)^[ \t]*Action[:：]"#)
        let matches = marker.matches(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed))
        guard matches.count == 1, let m = matches.first, let r = Range(m.range, in: trimmed) else {
            throw invalidAction(matches.isEmpty ? "reply has no Action line" : "reply has more than one Action line")
        }
        let before = String(trimmed[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        let call = String(trimmed[r.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        var thought: String?
        if !before.isEmpty {
            thought = before.replacingOccurrences(of: #"^(Thought|Action_Summary)[:：]\s*"#, with: "",
                                                  options: .regularExpression)
        }
        return (thought, call)
    }

    func interpret(_ call: UITarsCall, context: CodecContext) throws -> GuiProposalBody {
        func only(_ allowed: Set<String>, required: Set<String> = []) throws {
            for k in call.arguments.keys where !allowed.contains(k) {
                throw invalidAction("\(call.name) does not take \(k)")
            }
            for k in required where call.arguments[k] == nil {
                throw invalidAction("\(call.name) needs \(k)")
            }
        }
        func point(_ key: String) throws -> Point {
            guard let value = call.arguments[key] else { throw invalidAction("\(call.name) needs \(key)") }
            let raw = try UITarsCall.point(value)
            return try CoordinateMapper.sourcePixel(fromModel: raw, protocol: provenance.coordinateProtocol,
                                                    transform: context.transform)
        }

        switch call.name {
        case "click":
            try only(["start_box"], required: ["start_box"])
            return .action(.click(sourcePixel: try point("start_box")))
        case "type":
            try only(["content"], required: ["content"])
            let text = call.arguments["content"]!
            try SuggestionRules.checkType(text)
            return .action(.type(text: text))
        case "hotkey":
            try only(["key"], required: ["key"])
            let keys = try Self.keys(call.arguments["key"]!)
            try SuggestionRules.checkKeys(keys)
            return .action(.key(keys: keys))
        case "scroll":
            try only(["start_box", "direction"], required: ["start_box", "direction"])
            guard let dir = ScrollDirection(rawValue: call.arguments["direction"]!) else {
                throw invalidAction("scroll direction must be up, down, left or right")
            }
            return .action(.scroll(sourcePixel: try point("start_box"), direction: dir,
                                   amountPixels: Self.scrollAmountPixels))
        case "wait":
            try only([])
            // uitars `wait()` means one full wait of the bound profile.
            try SuggestionRules.checkWait(context.maxWaitMs, max: context.maxWaitMs)
            return .wait(milliseconds: context.maxWaitMs)
        case "finished":
            try only(["content"])
            let reason = call.arguments["content"] ?? "finished"
            try SuggestionRules.checkReason(reason, "finish reason")
            return .finish(reason: reason)
        case "call_user":
            try only(["content"])
            let message = call.arguments["content"] ?? "The model asked for a person."
            try SuggestionRules.checkReason(message, "needs_user message")
            return .needsUser(reasonCode: "model_requested_user", message: message)
        default:
            throw invalidAction("action \(call.name) is not in uitars_v1")
        }
    }

    /// UI-TARS key words to contract key names. "ctrl" stays Control: which
    /// modifier a platform uses for shortcuts is the Runtime's decision.
    static let keyWords: [String: String] = [
        "ctrl": "Control", "control": "Control", "shift": "Shift", "alt": "Alt", "option": "Alt",
        "cmd": "Meta", "command": "Meta", "meta": "Meta", "win": "Meta", "super": "Meta",
        "enter": "Enter", "return": "Enter", "tab": "Tab", "esc": "Escape", "escape": "Escape",
        "backspace": "Backspace", "delete": "Delete", "del": "Delete",
        "up": "ArrowUp", "down": "ArrowDown", "left": "ArrowLeft", "right": "ArrowRight",
        "arrowup": "ArrowUp", "arrowdown": "ArrowDown", "arrowleft": "ArrowLeft", "arrowright": "ArrowRight",
        "home": "Home", "end": "End", "pageup": "PageUp", "pagedown": "PageDown", "space": "Space",
    ]

    static func keys(_ text: String) throws -> [String] {
        let words = text.lowercased()
            .replacingOccurrences(of: #"page (up|down)"#, with: "page$1", options: .regularExpression)
            .split(whereSeparator: { $0 == " " || $0 == "+" }).map(String.init)
        guard !words.isEmpty else { throw invalidAction("hotkey has no keys") }
        return try words.map { word in
            if let k = keyWords[word] { return k }
            if word.count == 1, let s = word.unicodeScalars.first,
               ("a"..."z").contains(s) || ("0"..."9").contains(s) {
                return word.uppercased()
            }
            throw invalidAction("hotkey key \"\(word)\" is not allowed")
        }
    }

    /// The system prompt text for this adapter version. GuiAiProvider adds
    /// the task, history and current screenshot.
    public static func actionSpace(for proto: CoordinateProtocol) -> String {
        let coords = proto == .normalized1000
            ? "Coordinates are integers 0-999 on each axis of the screenshot."
            : "Coordinates are pixels of the screenshot."
        return """
        Output exactly one action, in this format:
        Thought: <one short sentence>
        Action: <one call>

        ## Action Space
        click(start_box='(x,y)')
        type(content='text')  # \\n presses Enter at the end
        hotkey(key='ctrl c')
        scroll(start_box='(x,y)', direction='down or up or right or left')
        wait()  # wait, then look again
        finished(content='why the task is done')
        call_user(content='what a person must do')

        \(coords)
        """
    }
}

/// One `name(key='value', …)` call, parsed strictly: quoted values with
/// escapes, no duplicate keys, nothing after the closing parenthesis.
struct UITarsCall: Equatable {
    let name: String
    let arguments: [String: String]

    static func parse(_ text: String) throws -> UITarsCall {
        var s = Substring(text.replacingOccurrences(of: "<|box_start|>", with: "")
                              .replacingOccurrences(of: "<|box_end|>", with: ""))
        func skipSpace() { while let c = s.first, c == " " || c == "\t" { s.removeFirst() } }
        func ident() -> String {
            var out = ""
            while let c = s.first, c.isASCII, c.isLetter || c.isNumber || c == "_" { out.append(c); s.removeFirst() }
            return out
        }
        let name = ident()
        guard !name.isEmpty, s.first == "(" else { throw invalidAction("action is not a call") }
        s.removeFirst()
        var args: [String: String] = [:]
        skipSpace()
        if s.first == ")" {
            s.removeFirst()
        } else {
            while true {
                skipSpace()
                var key = ident()
                if key == "point" { key = "start_box" }
                guard !key.isEmpty else { throw invalidAction("bad argument in \(name)") }
                skipSpace()
                guard s.first == "=" else { throw invalidAction("argument \(key) has no value") }
                s.removeFirst()
                skipSpace()
                guard let q = s.first, q == "'" || q == "\"" else { throw invalidAction("argument \(key) must be quoted") }
                s.removeFirst()
                var value = ""
                var closed = false
                while let c = s.first {
                    s.removeFirst()
                    if c == q { closed = true; break }
                    if c == "\\" {
                        guard let e = s.first else { break }
                        s.removeFirst()
                        switch e {
                        case "n": value.append("\n")
                        case "t": value.append("\t")
                        case "\\": value.append("\\")
                        case "'": value.append("'")
                        case "\"": value.append("\"")
                        default: throw invalidAction("bad escape in \(key)")
                        }
                        continue
                    }
                    if c == "\n" || c == "\r" { throw invalidAction("line break inside \(key)") }
                    value.append(c)
                }
                guard closed else { throw invalidAction("unterminated value for \(key)") }
                guard args[key] == nil else { throw invalidAction("argument \(key) appears twice") }
                args[key] = value
                skipSpace()
                if s.first == "," { s.removeFirst(); continue }
                if s.first == ")" { s.removeFirst(); break }
                throw invalidAction("expected , or ) in \(name)")
            }
        }
        guard s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw invalidAction("text after the action; exactly one action is allowed")
        }
        return UITarsCall(name: name, arguments: args)
    }

    /// A point in the model's own units: `(x,y)`, `[x,y]`, `[x y]`,
    /// `<point>x y</point>`, or a box `[x1,y1,x2,y2]` / `<bbox>…</bbox>`
    /// whose center is taken. No rescaling happens here.
    static func point(_ value: String) throws -> Point {
        var v = value.trimmingCharacters(in: .whitespaces)
        for (open, close) in [("<point>", "</point>"), ("<bbox>", "</bbox>")] where v.hasPrefix(open) {
            guard v.hasSuffix(close) else { throw invalidAction("unterminated \(open)") }
            v = String(v.dropFirst(open.count).dropLast(close.count))
        }
        if let f = v.first, f == "(" || f == "[" {
            guard let l = v.last, (f == "(" && l == ")") || (f == "[" && l == "]") else { throw invalidAction("unbalanced point") }
            v = String(v.dropFirst().dropLast())
        }
        let parts = v.split(whereSeparator: { $0 == "," || $0 == " " }).map(String.init)
        let numbers = parts.compactMap { p -> Double? in
            guard p.range(of: #"^\d+(\.\d+)?$"#, options: .regularExpression) != nil else { return nil }
            return Double(p)
        }
        guard numbers.count == parts.count else {
            // A negative or non-finite number is a coordinate outside the
            // domain; anything else is not a coordinate at all.
            if parts.allSatisfy({ $0.range(of: #"^[-+]?(\d+(\.\d+)?|inf|nan)$"#, options: [.regularExpression, .caseInsensitive]) != nil }) {
                throw ContractError(.coordinateOutOfBounds, "point is outside the model canvas")
            }
            throw invalidAction("point is not a list of numbers")
        }
        switch numbers.count {
        case 2:
            return Point(x: numbers[0], y: numbers[1])
        case 4:
            guard numbers[2] >= numbers[0], numbers[3] >= numbers[1] else { throw invalidAction("box corners are reversed") }
            return Point(x: (numbers[0] + numbers[2]) / 2, y: (numbers[1] + numbers[3]) / 2)
        default:
            throw invalidAction("a point has 2 numbers and a box 4")
        }
    }
}
