import Foundation

/// One way an instance fails its schema. `path` is a JSON pointer into the
/// instance ("" is the root), `keyword` the schema keyword that failed.
public struct SchemaViolation: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let keyword: String
    public let message: String
    public var description: String { "\(path.isEmpty ? "/" : path): \(keyword): \(message)" }
}

public enum SchemaError: Error, Equatable, Sendable {
    case unknownDocument(String)
    case unresolvedReference(String)
    case unsupportedKeyword(String, at: String)
    case invalidSchema(String)
}

/// A JSON Schema 2020-12 validator for the keywords the AgentDesktop AI/GUI
/// contract uses. Unknown assertion keywords are refused when a document is
/// loaded, so a schema change that needs a new keyword fails loudly instead
/// of being silently ignored. `format` is asserted (date-time, uuid, uri).
public final class SchemaRegistry: @unchecked Sendable {
    /// Keywords the validator implements.
    public static let assertionKeywords: Set<String> = [
        "type", "enum", "const",
        "minLength", "maxLength", "pattern", "format",
        "minimum", "maximum", "exclusiveMinimum", "exclusiveMaximum",
        "required", "properties", "additionalProperties", "minProperties", "maxProperties",
        "dependentRequired",
        "items", "prefixItems", "minItems", "maxItems", "uniqueItems",
        "allOf", "anyOf", "oneOf", "not", "if", "then", "else",
        "$ref",
    ]
    /// Keywords that carry no assertion.
    public static let annotationKeywords: Set<String> = [
        "$schema", "$id", "$defs", "title", "description", "writeOnly", "readOnly",
        "default", "examples", "$comment", "deprecated",
    ]

    private var documents: [String: JSONValue] = [:]   // by absolute $id
    private var regexCache: [String: NSRegularExpression] = [:]
    private let lock = NSLock()

    public init() {}

    /// Load a schema document. Its `$id` names it; relative `$ref`s inside it
    /// resolve against that id.
    @discardableResult
    public func add(_ document: JSONValue) throws -> String {
        guard let id = document["$id"]?.stringValue, URL(string: id) != nil else {
            throw SchemaError.invalidSchema("schema document needs an absolute $id")
        }
        try Self.checkKeywords(document, at: "")
        lock.lock(); defer { lock.unlock() }
        documents[id] = document
        return id
    }

    public func add(jsonData: Data) throws -> String {
        try add(try StrictJSON.parse(jsonData))
    }

    public var documentIds: [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(documents.keys)
    }

    /// The schema at `documentId#pointer` (pointer like "/$defs/AiConnection").
    public func schema(documentId: String, pointer: String) throws -> JSONValue {
        lock.lock(); let doc = documents[documentId]; lock.unlock()
        guard let doc else { throw SchemaError.unknownDocument(documentId) }
        guard let s = Self.resolvePointer(pointer, in: doc) else {
            throw SchemaError.unresolvedReference("\(documentId)#\(pointer)")
        }
        return s
    }

    /// Validate `instance` against `documentId#pointer`. Returns the violations
    /// found (empty means valid), capped at `limit`.
    public func validate(_ instance: JSONValue, documentId: String, pointer: String,
                         limit: Int = 50) throws -> [SchemaViolation] {
        let schema = try schema(documentId: documentId, pointer: pointer)
        var ctx = Context(registry: self, limit: limit)
        try ctx.validate(instance, schema: schema, docId: documentId, path: "")
        return ctx.violations
    }

    // MARK: - Loading checks

    private static func checkKeywords(_ schema: JSONValue, at location: String) throws {
        switch schema {
        case .bool: return
        case let .object(members):
            for m in members {
                let here = "\(location)/\(m.key)"
                if m.key == "$defs" || m.key == "properties" {
                    guard let sub = m.value.objectMembers else { throw SchemaError.invalidSchema(here) }
                    for s in sub { try checkKeywords(s.value, at: "\(here)/\(s.key)") }
                    continue
                }
                if m.key == "dependentRequired" { continue }
                guard assertionKeywords.contains(m.key) || annotationKeywords.contains(m.key) else {
                    throw SchemaError.unsupportedKeyword(m.key, at: location.isEmpty ? "/" : location)
                }
                switch m.key {
                case "items", "not", "if", "then", "else", "additionalProperties":
                    try checkKeywords(m.value, at: here)
                case "allOf", "anyOf", "oneOf", "prefixItems":
                    guard let arr = m.value.arrayValue else { throw SchemaError.invalidSchema(here) }
                    for (i, s) in arr.enumerated() { try checkKeywords(s, at: "\(here)/\(i)") }
                default: break
                }
            }
        default:
            throw SchemaError.invalidSchema("schema at \(location) is neither object nor boolean")
        }
    }

    static func resolvePointer(_ pointer: String, in doc: JSONValue) -> JSONValue? {
        if pointer.isEmpty || pointer == "/" { return doc }
        var cur = doc
        for rawPart in pointer.split(separator: "/", omittingEmptySubsequences: false).dropFirst() {
            let part = rawPart.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            if let arr = cur.arrayValue {
                guard let idx = Int(part), arr.indices.contains(idx) else { return nil }
                cur = arr[idx]
            } else if let next = cur[part] {
                cur = next
            } else {
                return nil
            }
        }
        return cur
    }

    fileprivate func resolveRef(_ ref: String, from docId: String) throws -> (JSONValue, String) {
        let parts = ref.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let docPart = parts.first.map(String.init) ?? ""
        let fragment = parts.count > 1 ? String(parts[1]) : ""
        var targetId = docId
        if !docPart.isEmpty {
            guard let base = URL(string: docId), let url = URL(string: docPart, relativeTo: base) else {
                throw SchemaError.unresolvedReference(ref)
            }
            targetId = url.absoluteString
        }
        return (try schema(documentId: targetId, pointer: fragment), targetId)
    }

    fileprivate func regex(_ pattern: String) throws -> NSRegularExpression {
        lock.lock(); defer { lock.unlock() }
        if let r = regexCache[pattern] { return r }
        guard let r = try? NSRegularExpression(pattern: pattern) else {
            throw SchemaError.invalidSchema("pattern does not compile: \(pattern)")
        }
        regexCache[pattern] = r
        return r
    }

    // MARK: - Validation

    private struct Context {
        let registry: SchemaRegistry
        let limit: Int
        var violations: [SchemaViolation] = []
        var refDepth = 0

        init(registry: SchemaRegistry, limit: Int) {
            self.registry = registry
            self.limit = limit
        }

        mutating func add(_ path: String, _ keyword: String, _ message: String) {
            if violations.count < limit {
                violations.append(SchemaViolation(path: path, keyword: keyword, message: message))
            }
        }

        /// Validate into a scratch context; true when it found no violations.
        func passes(_ instance: JSONValue, schema: JSONValue, docId: String, path: String) throws -> Bool {
            var scratch = Context(registry: registry, limit: 1)
            scratch.refDepth = refDepth
            try scratch.validate(instance, schema: schema, docId: docId, path: path)
            return scratch.violations.isEmpty
        }

        mutating func validate(_ instance: JSONValue, schema: JSONValue, docId: String, path: String) throws {
            if case let .bool(b) = schema {
                if !b { add(path, "false", "no value is allowed here") }
                return
            }
            guard case .object = schema else { throw SchemaError.invalidSchema("non-object schema") }

            if let ref = schema["$ref"]?.stringValue {
                refDepth += 1
                defer { refDepth -= 1 }
                guard refDepth < 64 else { throw SchemaError.invalidSchema("$ref recursion too deep at \(ref)") }
                let (target, targetDoc) = try registry.resolveRef(ref, from: docId)
                try validate(instance, schema: target, docId: targetDoc, path: path)
            }

            if let t = schema["type"] {
                let types = t.arrayValue?.compactMap(\.stringValue) ?? [t.stringValue].compactMap { $0 }
                if !types.contains(where: { Self.isType(instance, $0) }) {
                    add(path, "type", "expected \(types.joined(separator: " or "))")
                    return
                }
            }
            if let c = schema["const"], c != instance { add(path, "const", "must equal \(c.encoded())") }
            if let e = schema["enum"]?.arrayValue, !e.contains(instance) {
                add(path, "enum", "must be one of \(e.map { $0.encoded() }.joined(separator: ", "))")
            }

            switch instance {
            case let .string(s):
                let len = s.unicodeScalars.count
                if let m = schema["minLength"]?.intValue, len < m { add(path, "minLength", "shorter than \(m)") }
                if let m = schema["maxLength"]?.intValue, len > m { add(path, "maxLength", "longer than \(m)") }
                if let p = schema["pattern"]?.stringValue {
                    let re = try registry.regex(p)
                    let range = NSRange(s.startIndex..., in: s)
                    if re.firstMatch(in: s, range: range) == nil { add(path, "pattern", "does not match \(p)") }
                }
                if let f = schema["format"]?.stringValue, !Formats.check(f, s) {
                    add(path, "format", "not a valid \(f)")
                }
            case let .number(_, v):
                if let m = schema["minimum"]?.doubleValue, v < m { add(path, "minimum", "less than \(m)") }
                if let m = schema["maximum"]?.doubleValue, v > m { add(path, "maximum", "greater than \(m)") }
                if let m = schema["exclusiveMinimum"]?.doubleValue, v <= m { add(path, "exclusiveMinimum", "not greater than \(m)") }
                if let m = schema["exclusiveMaximum"]?.doubleValue, v >= m { add(path, "exclusiveMaximum", "not less than \(m)") }
            case let .array(items):
                if let m = schema["minItems"]?.intValue, items.count < m { add(path, "minItems", "fewer than \(m) items") }
                if let m = schema["maxItems"]?.intValue, items.count > m { add(path, "maxItems", "more than \(m) items") }
                if schema["uniqueItems"]?.boolValue == true {
                    for i in items.indices where items[..<i].contains(items[i]) {
                        add("\(path)/\(i)", "uniqueItems", "duplicate item")
                    }
                }
                var start = 0
                if let prefix = schema["prefixItems"]?.arrayValue {
                    for (i, s) in prefix.enumerated() where i < items.count {
                        try validate(items[i], schema: s, docId: docId, path: "\(path)/\(i)")
                    }
                    start = prefix.count
                }
                if let itemSchema = schema["items"] {
                    for i in items.indices where i >= start {
                        try validate(items[i], schema: itemSchema, docId: docId, path: "\(path)/\(i)")
                    }
                }
            case let .object(members):
                let keys = Set(members.map(\.key))
                if let m = schema["minProperties"]?.intValue, members.count < m { add(path, "minProperties", "fewer than \(m) members") }
                if let m = schema["maxProperties"]?.intValue, members.count > m { add(path, "maxProperties", "more than \(m) members") }
                for r in schema["required"]?.arrayValue?.compactMap(\.stringValue) ?? [] where !keys.contains(r) {
                    add(path, "required", "missing \"\(r)\"")
                }
                if let dr = schema["dependentRequired"]?.objectMembers {
                    for d in dr where keys.contains(d.key) {
                        for need in d.value.arrayValue?.compactMap(\.stringValue) ?? [] where !keys.contains(need) {
                            add(path, "dependentRequired", "\"\(d.key)\" requires \"\(need)\"")
                        }
                    }
                }
                let props = schema["properties"]?.objectMembers ?? []
                let propMap = Dictionary(uniqueKeysWithValues: props.map { ($0.key, $0.value) })
                for m in members {
                    let child = "\(path)/\(Self.escape(m.key))"
                    if let ps = propMap[m.key] {
                        try validate(m.value, schema: ps, docId: docId, path: child)
                    } else if let ap = schema["additionalProperties"] {
                        if case .bool(false) = ap {
                            add(child, "additionalProperties", "unknown member \"\(m.key)\"")
                        } else {
                            try validate(m.value, schema: ap, docId: docId, path: child)
                        }
                    }
                }
            default: break
            }

            if let all = schema["allOf"]?.arrayValue {
                for s in all { try validate(instance, schema: s, docId: docId, path: path) }
            }
            if let any = schema["anyOf"]?.arrayValue {
                var ok = false
                for s in any where try passes(instance, schema: s, docId: docId, path: path) { ok = true; break }
                if !ok { add(path, "anyOf", "matches none of \(any.count) alternatives") }
            }
            if let one = schema["oneOf"]?.arrayValue {
                var n = 0
                for s in one where try passes(instance, schema: s, docId: docId, path: path) { n += 1 }
                if n != 1 { add(path, "oneOf", "matches \(n) of \(one.count) alternatives, expected exactly 1") }
            }
            if let not = schema["not"], try passes(instance, schema: not, docId: docId, path: path) {
                add(path, "not", "matches a forbidden schema")
            }
            if let cond = schema["if"] {
                if try passes(instance, schema: cond, docId: docId, path: path) {
                    if let then = schema["then"] { try validate(instance, schema: then, docId: docId, path: path) }
                } else if let els = schema["else"] {
                    try validate(instance, schema: els, docId: docId, path: path)
                }
            }
        }

        static func escape(_ key: String) -> String {
            key.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
        }

        static func isType(_ v: JSONValue, _ t: String) -> Bool {
            switch (t, v) {
            case ("null", .null), ("boolean", .bool), ("string", .string),
                 ("array", .array), ("object", .object), ("number", .number): return true
            case ("integer", .number): return v.intValue != nil
            default: return false
            }
        }
    }
}

/// Assertions for the `format` values the contract uses.
public enum Formats {
    private static let uuid = try! NSRegularExpression(
        pattern: "^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")
    private static let dateTime = try! NSRegularExpression(
        pattern: "^(\\d{4})-(\\d{2})-(\\d{2})[Tt](\\d{2}):(\\d{2}):(\\d{2})(\\.\\d+)?([Zz]|[+-](\\d{2}):(\\d{2}))$")
    private static let scheme = try! NSRegularExpression(pattern: "^[A-Za-z][A-Za-z0-9+.-]*:")

    public static func check(_ format: String, _ s: String) -> Bool {
        let range = NSRange(s.startIndex..., in: s)
        switch format {
        case "uuid":
            return uuid.firstMatch(in: s, range: range) != nil
        case "date-time":
            guard let m = dateTime.firstMatch(in: s, range: range) else { return false }
            func n(_ i: Int) -> Int? {
                let r = m.range(at: i)
                guard r.location != NSNotFound, let rr = Range(r, in: s) else { return nil }
                return Int(s[rr])
            }
            guard let y = n(1), let mo = n(2), let d = n(3), let h = n(4), let mi = n(5), let se = n(6) else { return false }
            let days = [31, (y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)) ? 29 : 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31]
            guard (1...12).contains(mo), (1...days[mo - 1]).contains(d), h < 24, mi < 60, se < 61 else { return false }
            if let oh = n(9), let om = n(10) { return oh < 24 && om < 60 }
            return true
        case "uri":
            return scheme.firstMatch(in: s, range: range) != nil && URL(string: s) != nil
        default:
            return true
        }
    }
}
