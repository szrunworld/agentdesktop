import Foundation
import Testing

// #183: two threads of one process working on pasteboards at the same time,
// even on different named ones, can deadlock with the pasteboard daemon; it
// stalled the engine tests. #233 runs every pasteboard test one at a time:
// each suite that touches a pasteboard is `@MainActor` and
// `@Suite(.serialized)` (one main actor per process, so suites in different
// test modules do not overlap either). This keeps a new pasteboard test from
// slipping outside that (docs/security/clipboard-concurrency.md).
@Suite struct PasteboardSerializationPolicyTests {
    static let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    static func swiftFiles() -> [URL] {
        (FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)?.compactMap { $0 as? URL } ?? [])
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent != "PasteboardSerializationPolicyTests.swift" }
    }

    /// Each suite in `text`: its attribute lines, and its body up to the next
    /// declaration at column 0.
    static func suites(in text: String) -> [(name: String, attributes: [String], body: String)] {
        let lines = text.components(separatedBy: "\n")
        var found: [(String, [String], String)] = []
        for (i, line) in lines.enumerated() {
            guard let range = line.range(of: "struct "), !line.hasPrefix(" "), line.hasPrefix("@") || line.hasPrefix("struct ")
            else { continue }
            var attributes = [String(line[..<range.lowerBound])]
            var j = i - 1
            while j >= 0, lines[j].hasPrefix("@") { attributes.append(lines[j]); j -= 1 }
            guard attributes.contains(where: { $0.contains("@Suite") }) else { continue }
            let name = String(line[range.upperBound...].prefix { $0.isLetter || $0.isNumber })
            var end = i + 1
            while end < lines.count {
                let l = lines[end]
                if let first = l.first, first != "}", first != "/", !first.isWhitespace { break }
                end += 1
            }
            found.append((name, attributes, lines[(i + 1)..<end].joined(separator: "\n")))
        }
        return found
    }

    static let touchesPasteboard = ["NSPasteboard", "scratchPasteboard(", "scratch()", ".pasteboard ="]

    @Test func onlyTheSerializedSuitesTouchAPasteboard() throws {
        let files = Self.swiftFiles()
        #expect(files.count > 10)
        var outside: [String] = []
        var unserialized: [String] = []
        var serializedSuites = 0
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("NSPasteboard") else { continue }
            if !["PasteboardSnapshotTests.swift", "IPhonePasteTests.swift"].contains(file.lastPathComponent) {
                outside.append(file.lastPathComponent)
            }
            for suite in Self.suites(in: text) where Self.touchesPasteboard.contains(where: suite.body.contains) {
                let attrs = suite.attributes.joined(separator: " ")
                if attrs.contains("@MainActor"), attrs.contains("@Suite(.serialized)") {
                    serializedSuites += 1
                } else {
                    unserialized.append("\(file.lastPathComponent): \(suite.name)")
                }
            }
        }
        #expect(outside.isEmpty, "pasteboards touched outside the two serialized files: \(outside)")
        #expect(unserialized.isEmpty, "suites that touch a pasteboard without @MainActor @Suite(.serialized): \(unserialized)")
        #expect(serializedSuites >= 2, "the policy found \(serializedSuites) serialized pasteboard suites")
    }

    @Test func theCheckSeesAnUnserializedSuite() {
        // The parser itself: a pasteboard suite without the attributes is
        // caught; with them it is not.
        let bad = "@Suite struct Loose {\n    @Test func t() { _ = scratchPasteboard() }\n}\n"
        let good = "@MainActor\n@Suite(.serialized) struct Tight {\n    @Test func t() { _ = scratchPasteboard() }\n}\n"
        let badSuites = Self.suites(in: bad)
        #expect(badSuites.map(\.name) == ["Loose"])
        #expect(!badSuites[0].attributes.joined().contains("@MainActor"))
        let goodSuites = Self.suites(in: good)
        #expect(goodSuites.map(\.name) == ["Tight"])
        #expect(goodSuites[0].attributes.joined(separator: " ").contains("@MainActor"))
        #expect(goodSuites[0].attributes.joined(separator: " ").contains("@Suite(.serialized)"))
    }
}
