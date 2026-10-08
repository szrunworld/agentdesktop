import AgentDesktopContracts
import Foundation

/// UI conditions of a GUI unit (runtime.schema.json Condition), evaluated by
/// the Runtime on its own fresh observation — never on a model's claim.
enum Conditions {
    /// Invisible bidirectional formatting (LRM, RLM, ALM, embeddings and
    /// isolates, BOM) is not text a person sees: dropped before comparing,
    /// as the GUI verifier does. Everything else compares exactly.
    static func visible(_ s: String) -> String {
        let hidden: Set<UInt32> = [0x200E, 0x200F, 0x061C, 0xFEFF, 0x202A, 0x202B, 0x202C, 0x202D, 0x202E, 0x2066, 0x2067, 0x2068, 0x2069]
        return String(String.UnicodeScalarView(s.unicodeScalars.filter { !hidden.contains($0.value) }))
            .precomposedStringWithCanonicalMapping
    }

    static func matches(_ e: PlatformElement, _ m: JSONValue) -> Bool {
        if let role = m["role"]?.stringValue, e.role != role, !e.role.hasPrefix(role + "/") { return false }
        if let label = m["label"]?.stringValue, visible(e.label ?? "") != visible(label) { return false }
        if let part = m["labelContains"]?.stringValue,
           !(visible(e.label ?? "") + "\u{0}" + visible(e.value ?? "")).contains(visible(part)) { return false }
        return true
    }

    static func evaluate(_ c: JSONValue, _ elements: [PlatformElement]) -> Bool {
        if let all = c["all"]?.arrayValue { return all.allSatisfy { evaluate($0, elements) } }
        if let any = c["any"]?.arrayValue { return any.contains { evaluate($0, elements) } }
        if let inner = c["not"] { return !evaluate(inner, elements) }
        switch c["kind"]?.stringValue {
        case "elementPresent": return elements.contains { matches($0, c) }
        case "elementAbsent": return !elements.contains { matches($0, c) }
        case "elementTextEquals":
            let want = visible(c["text"]?.stringValue ?? "")
            return elements.contains { matches($0, c) && visible($0.value ?? $0.label ?? "") == want }
        default: return false
        }
    }

    /// The first elementTextEquals reachable through `all`: what a model
    /// explorer can be asked to reach (its verifier knows only that).
    static func explorerTarget(_ c: JSONValue) -> JSONValue? {
        if c["kind"]?.stringValue == "elementTextEquals" { return c }
        for sub in c["all"]?.arrayValue ?? [] { if let t = explorerTarget(sub) { return t } }
        return nil
    }
}
