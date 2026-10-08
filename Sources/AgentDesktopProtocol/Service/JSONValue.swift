import Foundation

/// A JSON value as received on the wire, with object keys kept in their
/// original order. Produced only by `StrictJSON.parse`, which refuses
/// duplicate keys, so `object` never holds the same key twice.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    /// `raw` is the number exactly as written; `value` its Double reading.
    case number(raw: String, value: Double)
    case string(String)
    case array([JSONValue])
    case object([(key: String, value: JSONValue)])

    public static func == (lhs: JSONValue, rhs: JSONValue) -> Bool {
        switch (lhs, rhs) {
        case (.null, .null): return true
        case let (.bool(a), .bool(b)): return a == b
        case let (.number(_, a), .number(_, b)): return a == b
        case let (.string(a), .string(b)): return a == b
        case let (.array(a), .array(b)): return a == b
        case let (.object(a), .object(b)):
            // JSON object equality ignores member order.
            guard a.count == b.count else { return false }
            let bm = Dictionary(uniqueKeysWithValues: b.map { ($0.key, $0.value) })
            return a.allSatisfy { bm[$0.key] == $0.value }
        default: return false
        }
    }

    public static func int(_ v: Int) -> JSONValue { .number(raw: String(v), value: Double(v)) }
    public static func double(_ v: Double) -> JSONValue {
        if v == v.rounded(), abs(v) < 9.007199254740992e15 {
            return .number(raw: String(Int64(v)), value: v)
        }
        return .number(raw: String(v), value: v)
    }
    public static func obj(_ members: [(String, JSONValue)]) -> JSONValue {
        .object(members.map { (key: $0.0, value: $0.1) })
    }

    public subscript(key: String) -> JSONValue? {
        guard case let .object(members) = self else { return nil }
        return members.first(where: { $0.key == key })?.value
    }

    public var stringValue: String? { if case let .string(s) = self { return s }; return nil }
    public var boolValue: Bool? { if case let .bool(b) = self { return b }; return nil }
    public var doubleValue: Double? { if case let .number(_, v) = self { return v }; return nil }
    /// The value as an exact integer, or nil when it is not one.
    public var intValue: Int? {
        guard case let .number(_, v) = self, v.isFinite, v == v.rounded(),
              abs(v) <= 9_007_199_254_740_991 else { return nil }
        return Int(v)
    }
    public var arrayValue: [JSONValue]? { if case let .array(a) = self { return a }; return nil }
    public var objectMembers: [(key: String, value: JSONValue)]? {
        if case let .object(m) = self { return m }; return nil
    }
    public var isNull: Bool { if case .null = self { return true }; return false }

    /// Replace or append one member of an object; non-objects are returned unchanged.
    public func setting(_ key: String, _ value: JSONValue) -> JSONValue {
        guard case var .object(members) = self else { return self }
        if let i = members.firstIndex(where: { $0.key == key }) {
            members[i].value = value
        } else {
            members.append((key: key, value: value))
        }
        return .object(members)
    }

    // MARK: Encoding

    /// Compact JSON, members in stored order. Never emits a line feed, so a
    /// result is always exactly one JSONL line.
    public func encoded() -> String {
        var out = ""
        write(into: &out)
        return out
    }

    public func encodedData() -> Data { Data(encoded().utf8) }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case let .bool(b): out += b ? "true" : "false"
        case let .number(raw, _): out += raw
        case let .string(s): JSONValue.writeString(s, into: &out)
        case let .array(items):
            out += "["
            for (i, item) in items.enumerated() {
                if i > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case let .object(members):
            out += "{"
            for (i, m) in members.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(m.key, into: &out)
                out += ":"
                m.value.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 || scalar.value == 0x2028 || scalar.value == 0x2029 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}

public struct StrictJSONError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Kind: String, Sendable {
        case syntax, duplicateKey, tooDeep, invalidUTF8, trailingData, nonFiniteNumber
    }
    public let kind: Kind
    public let offset: Int
    public let detail: String
    public var description: String { "\(kind.rawValue) at byte \(offset): \(detail)" }
}

/// RFC 8259 JSON parser that rejects what the wire contract forbids:
/// duplicate object keys, nesting beyond `maxDepth`, invalid UTF-8,
/// lone surrogate escapes, numbers that overflow to infinity, and any
/// non-whitespace after the single top-level value.
public enum StrictJSON {
    public static let defaultMaxDepth = 64

    public static func parse(_ data: Data, maxDepth: Int = defaultMaxDepth) throws -> JSONValue {
        try data.withUnsafeBytes { raw -> JSONValue in
            var p = Parser(bytes: raw.bindMemory(to: UInt8.self), maxDepth: maxDepth)
            p.skipWhitespace()
            let v = try p.parseValue(depth: 0)
            p.skipWhitespace()
            guard p.i == p.bytes.count else {
                throw StrictJSONError(kind: .trailingData, offset: p.i, detail: "data after the JSON value")
            }
            return v
        }
    }

    public static func parse(_ text: String, maxDepth: Int = defaultMaxDepth) throws -> JSONValue {
        try parse(Data(text.utf8), maxDepth: maxDepth)
    }

    private struct Parser {
        let bytes: UnsafeBufferPointer<UInt8>
        let maxDepth: Int
        var i = 0

        init(bytes: UnsafeBufferPointer<UInt8>, maxDepth: Int) {
            self.bytes = bytes
            self.maxDepth = maxDepth
        }

        func fail(_ kind: StrictJSONError.Kind, _ detail: String) -> StrictJSONError {
            StrictJSONError(kind: kind, offset: i, detail: detail)
        }

        mutating func skipWhitespace() {
            while i < bytes.count {
                switch bytes[i] {
                case 0x20, 0x09, 0x0A, 0x0D: i += 1
                default: return
                }
            }
        }

        mutating func parseValue(depth: Int) throws -> JSONValue {
            guard depth <= maxDepth else { throw fail(.tooDeep, "nesting deeper than \(maxDepth)") }
            guard i < bytes.count else { throw fail(.syntax, "unexpected end of input") }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try parseObject(depth: depth)
            case UInt8(ascii: "["): return try parseArray(depth: depth)
            case UInt8(ascii: "\""): return .string(try parseString())
            case UInt8(ascii: "t"): try expectLiteral("true"); return .bool(true)
            case UInt8(ascii: "f"): try expectLiteral("false"); return .bool(false)
            case UInt8(ascii: "n"): try expectLiteral("null"); return .null
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
            default: throw fail(.syntax, "unexpected character")
            }
        }

        mutating func expectLiteral(_ word: String) throws {
            for b in word.utf8 {
                guard i < bytes.count, bytes[i] == b else { throw fail(.syntax, "invalid literal") }
                i += 1
            }
        }

        mutating func parseObject(depth: Int) throws -> JSONValue {
            i += 1
            var members: [(key: String, value: JSONValue)] = []
            var seen = Set<String>()
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: "\"") else { throw fail(.syntax, "expected a key") }
                let keyStart = i
                let key = try parseString()
                guard seen.insert(key).inserted else {
                    throw StrictJSONError(kind: .duplicateKey, offset: keyStart, detail: "duplicate key \"\(key)\"")
                }
                skipWhitespace()
                guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw fail(.syntax, "expected ':'") }
                i += 1
                skipWhitespace()
                let value = try parseValue(depth: depth + 1)
                members.append((key: key, value: value))
                skipWhitespace()
                guard i < bytes.count else { throw fail(.syntax, "unterminated object") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "}") { i += 1; return .object(members) }
                throw fail(.syntax, "expected ',' or '}'")
            }
        }

        mutating func parseArray(depth: Int) throws -> JSONValue {
            i += 1
            var items: [JSONValue] = []
            skipWhitespace()
            if i < bytes.count, bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
            while true {
                skipWhitespace()
                items.append(try parseValue(depth: depth + 1))
                skipWhitespace()
                guard i < bytes.count else { throw fail(.syntax, "unterminated array") }
                if bytes[i] == UInt8(ascii: ",") { i += 1; continue }
                if bytes[i] == UInt8(ascii: "]") { i += 1; return .array(items) }
                throw fail(.syntax, "expected ',' or ']'")
            }
        }

        mutating func parseHex4() throws -> UInt32 {
            guard i + 4 <= bytes.count else { throw fail(.syntax, "short \\u escape") }
            var v: UInt32 = 0
            for _ in 0..<4 {
                let c = bytes[i]
                let d: UInt32
                switch c {
                case UInt8(ascii: "0")...UInt8(ascii: "9"): d = UInt32(c - UInt8(ascii: "0"))
                case UInt8(ascii: "a")...UInt8(ascii: "f"): d = UInt32(c - UInt8(ascii: "a") + 10)
                case UInt8(ascii: "A")...UInt8(ascii: "F"): d = UInt32(c - UInt8(ascii: "A") + 10)
                default: throw fail(.syntax, "bad hex digit")
                }
                v = v * 16 + d
                i += 1
            }
            return v
        }

        mutating func parseString() throws -> String {
            i += 1
            var scalars = String.UnicodeScalarView()
            var runStart = i
            func flushRun(_ p: inout Parser, _ end: Int, into s: inout String.UnicodeScalarView) throws {
                if end > runStart {
                    let slice = UnsafeBufferPointer(rebasing: p.bytes[runStart..<end])
                    guard let text = String(bytes: slice, encoding: .utf8) else {
                        throw p.fail(.invalidUTF8, "invalid UTF-8 in string")
                    }
                    s.append(contentsOf: text.unicodeScalars)
                }
            }
            while true {
                guard i < bytes.count else { throw fail(.syntax, "unterminated string") }
                let c = bytes[i]
                if c == UInt8(ascii: "\"") {
                    try flushRun(&self, i, into: &scalars)
                    i += 1
                    return String(scalars)
                }
                if c < 0x20 { throw fail(.syntax, "control character in string") }
                if c == UInt8(ascii: "\\") {
                    try flushRun(&self, i, into: &scalars)
                    i += 1
                    guard i < bytes.count else { throw fail(.syntax, "bad escape") }
                    let e = bytes[i]
                    i += 1
                    switch e {
                    case UInt8(ascii: "\""): scalars.append("\"")
                    case UInt8(ascii: "\\"): scalars.append("\\")
                    case UInt8(ascii: "/"): scalars.append("/")
                    case UInt8(ascii: "b"): scalars.append("\u{08}")
                    case UInt8(ascii: "f"): scalars.append("\u{0C}")
                    case UInt8(ascii: "n"): scalars.append("\n")
                    case UInt8(ascii: "r"): scalars.append("\r")
                    case UInt8(ascii: "t"): scalars.append("\t")
                    case UInt8(ascii: "u"):
                        let hi = try parseHex4()
                        var code = hi
                        if (0xD800...0xDBFF).contains(hi) {
                            guard i + 1 < bytes.count, bytes[i] == UInt8(ascii: "\\"), bytes[i + 1] == UInt8(ascii: "u") else {
                                throw fail(.syntax, "lone high surrogate")
                            }
                            i += 2
                            let lo = try parseHex4()
                            guard (0xDC00...0xDFFF).contains(lo) else { throw fail(.syntax, "bad low surrogate") }
                            code = 0x10000 + ((hi - 0xD800) << 10) + (lo - 0xDC00)
                        } else if (0xDC00...0xDFFF).contains(hi) {
                            throw fail(.syntax, "lone low surrogate")
                        }
                        guard let s = Unicode.Scalar(code) else { throw fail(.syntax, "invalid code point") }
                        scalars.append(s)
                    default: throw fail(.syntax, "bad escape")
                    }
                    runStart = i
                    continue
                }
                i += 1
            }
        }

        mutating func parseNumber() throws -> JSONValue {
            let start = i
            if bytes[i] == UInt8(ascii: "-") { i += 1 }
            func digit(_ p: Parser) -> Bool {
                p.i < p.bytes.count && (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(p.bytes[p.i])
            }
            guard digit(self) else { throw fail(.syntax, "bad number") }
            if bytes[i] == UInt8(ascii: "0") {
                i += 1
                if digit(self) { throw fail(.syntax, "leading zero") }
            } else {
                while digit(self) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: ".") {
                i += 1
                guard digit(self) else { throw fail(.syntax, "bad fraction") }
                while digit(self) { i += 1 }
            }
            if i < bytes.count, bytes[i] == UInt8(ascii: "e") || bytes[i] == UInt8(ascii: "E") {
                i += 1
                if i < bytes.count, bytes[i] == UInt8(ascii: "+") || bytes[i] == UInt8(ascii: "-") { i += 1 }
                guard digit(self) else { throw fail(.syntax, "bad exponent") }
                while digit(self) { i += 1 }
            }
            let raw = String(decoding: UnsafeBufferPointer(rebasing: bytes[start..<i]), as: UTF8.self)
            guard let v = Double(raw), v.isFinite else {
                throw StrictJSONError(kind: .nonFiniteNumber, offset: start, detail: "number out of range")
            }
            return .number(raw: raw, value: v)
        }
    }
}
