import Foundation
import Testing

// #183: two threads of one process working on pasteboards at the same time,
// even on different named ones, can deadlock with the pasteboard daemon; it
// stalled the engine tests. #233 runs every pasteboard test one at a time:
// each suite that touches a pasteboard is `@MainActor` and
// `@Suite(.serialized)` (one main actor per process, so suites in different
// test modules do not overlap either). This keeps a new pasteboard test from
// slipping outside that (docs/security/clipboard-concurrency.md).
//
// Limits (b9 on #264): a textual check, not a compiler guarantee. It reads
// the Swift sources under engine/Tests, Swift Testing suites written as
// `struct` and top-level `@Test` functions; XCTest classes and the root
// package's tests are outside it.
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

    /// What reaches a pasteboard: AppKit itself, the module-level test
    /// helper, and the engine APIs that work on one (PasteTransaction uses
    /// the general pasteboard unless told otherwise). A file that has none
    /// of these cannot touch one (Codex on #264: a file calling only
    /// `scratchPasteboard()` has no `NSPasteboard` in it).
    static let pasteboardMarkers = ["NSPasteboard", "scratchPasteboard(", "PasteboardSnapshot", "PasteboardLoan",
                                    "PasteTransaction"]
    /// Within a suite, also the per-suite helpers of the serialized files.
    static let touchesPasteboard = pasteboardMarkers + ["scratch()", ".pasteboard ="]
    static let serializedFiles: Set<String> = ["PasteboardSnapshotTests.swift", "IPhonePasteTests.swift"]

    /// Each top-level `@Test` function in `text` (not inside a suite): its
    /// name and body up to the next declaration at column 0.
    static func topLevelTests(in text: String) -> [(name: String, body: String)] {
        let lines = text.components(separatedBy: "\n")
        var found: [(String, String)] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("@Test") {
            // The declaration is on this line or the next attribute lines.
            var j = i
            while j < lines.count, !lines[j].contains("func ") { j += 1 }
            guard j < lines.count, let range = lines[j].range(of: "func ") else { continue }
            let name = String(lines[j][range.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "_" })
            var end = j + 1
            while end < lines.count {
                let l = lines[end]
                if let first = l.first, first != "}", first != "/", !first.isWhitespace { break }
                end += 1
            }
            found.append((name, lines[j...min(end, lines.count) - 1].joined(separator: "\n")))
        }
        return found
    }

    /// (files touching a pasteboard outside the serialized files, suites or
    /// top-level tests touching one without the serialized suite's
    /// attributes, serialized suites found). A top-level `@Test` is never
    /// serialized with the suites: one that touches a pasteboard is refused
    /// (Codex on #264).
    static func violations(_ files: [(name: String, text: String)]) -> (outside: [String], unserialized: [String], serialized: Int) {
        var outside: [String] = []
        var unserialized: [String] = []
        var serialized = 0
        for (name, text) in files where pasteboardMarkers.contains(where: text.contains) {
            if !serializedFiles.contains(name) { outside.append(name) }
            for suite in suites(in: text) where touchesPasteboard.contains(where: suite.body.contains) {
                let attrs = suite.attributes.joined(separator: " ")
                if attrs.contains("@MainActor"), attrs.contains("@Suite(.serialized)") {
                    serialized += 1
                } else {
                    unserialized.append("\(name): \(suite.name)")
                }
            }
            for test in topLevelTests(in: text) where touchesPasteboard.contains(where: test.body.contains) {
                unserialized.append("\(name): top-level @Test \(test.name)")
            }
        }
        return (outside, unserialized, serialized)
    }

    @Test func onlyTheSerializedSuitesTouchAPasteboard() throws {
        let files = try Self.swiftFiles().map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
        #expect(files.count > 10)
        let found = Self.violations(files)
        #expect(found.outside.isEmpty, "pasteboards touched outside the two serialized files: \(found.outside)")
        #expect(found.unserialized.isEmpty,
                "suites that touch a pasteboard without @MainActor @Suite(.serialized): \(found.unserialized)")
        #expect(found.serialized >= 2, "the policy found \(found.serialized) serialized pasteboard suites")
    }

    @Test func aFileThatOnlyCallsTheSharedHelperIsCaught() {
        // Codex on #264: no `NSPasteboard` in it, only the module-level
        // helper (or an engine API that works on a pasteboard).
        for call in ["_ = scratchPasteboard()", "_ = try PasteboardSnapshot.capture(p)", "_ = PasteTransaction()"] {
            let text = "@Suite struct Sneaky {\n    @Test func t() throws { \(call) }\n}\n"
            let found = Self.violations([("SneakyTests.swift", text)])
            #expect(found.outside == ["SneakyTests.swift"], "\(call)")
            #expect(found.unserialized == ["SneakyTests.swift: Sneaky"], "\(call)")
        }
        // Codex on #264: a top-level @Test in an allowed file, outside any
        // suite, is not serialized with them.
        for attrs in ["@Test", "@MainActor\n@Test"] {
            let text = "func scratchPasteboard() -> NSPasteboard { NSPasteboard(name: .init(\"x\")) }\n\n"
                + "\(attrs) func looseOne() {\n    _ = scratchPasteboard()\n}\n"
            let found = Self.violations([("PasteboardSnapshotTests.swift", text)])
            #expect(found.outside.isEmpty)
            #expect(found.unserialized == ["PasteboardSnapshotTests.swift: top-level @Test looseOne"], "\(attrs)")
        }
        let clean = Self.violations([("PlainTests.swift", "@Suite struct Plain {\n    @Test func t() {}\n}\n")])
        #expect(clean.outside.isEmpty && clean.unserialized.isEmpty)
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
