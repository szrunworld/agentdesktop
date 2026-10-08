import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopACP

/// Golden fixtures under Fixtures/events: synthetic Runtime events and the
/// exact updates they must project to. `ETEST_REGEN=1 swift test` rewrites
/// the `expected` arrays (review the diff before committing).
@Suite struct ETestGoldenTests {
    static func files() -> [URL] {
        let all = (try? FileManager.default.contentsOfDirectory(at: ETest.fixturesDir, includingPropertiesForKeys: nil)) ?? []
        return all.filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    @Test func fixturesExist() {
        #expect(Self.files().count >= 10)
    }

    @Test(arguments: ETestGoldenTests.files().map(\.lastPathComponent))
    func golden(_ name: String) throws {
        let url = ETest.fixturesDir.appendingPathComponent(name)
        let doc = try StrictJSON.parse(Data(contentsOf: url))
        let policy = ETest.policy(doc["policy"])
        var session = ACPProjectorSession()
        var actual: [JSONValue] = []
        var allStrings: [String] = []
        for e in doc["events"]?.arrayValue ?? [] {
            let ev = ACPRuntimeEvent(runId: e["runId"]?.stringValue ?? "", cursor: e["cursor"]?.intValue ?? 0,
                                     type: e["type"]?.stringValue ?? "", payload: e["payload"] ?? .obj([]))
            let out = session.project(ev, policy: policy)
            actual.append(.array(out.map(ETest.encode)))
            allStrings += ETest.strings(out)
        }

        // Secrets planted in the inputs never come out, under any policy.
        for secret in (doc["mustNotContain"]?.arrayValue ?? []).compactMap(\.stringValue) {
            for s in allStrings { #expect(!s.contains(secret), "\(name): leaked \(secret) in \(s)") }
        }
        for s in allStrings { #expect(ETest.leaks(in: s).isEmpty, "\(name): pattern leak in \(s)") }
        for required in (doc["mustContain"]?.arrayValue ?? []).compactMap(\.stringValue) {
            #expect(allStrings.contains { $0.contains(required) }, "\(name): missing \(required)")
        }

        if ProcessInfo.processInfo.environment["ETEST_REGEN"] == "1" {
            let next = doc.setting("expected", .array(actual))
            try Data((ETestPretty.print(next) + "\n").utf8).write(to: url)
            return
        }
        let expected = doc["expected"]?.arrayValue ?? []
        #expect(expected.count == actual.count, "\(name): \(expected.count) expected vs \(actual.count) events")
        for (i, (e, a)) in zip(expected, actual).enumerated() {
            #expect(e == a, "\(name) event #\(i): got \(a.encoded())")
        }
    }
}

/// Stable pretty printer for fixtures (two-space indent, member order kept).
enum ETestPretty {
    static func print(_ v: JSONValue, _ indent: String = "") -> String {
        let inner = indent + "  "
        switch v {
        case let .object(m):
            if m.isEmpty { return "{}" }
            return "{\n" + m.map { inner + JSONValue.string($0.key).encoded() + ": " + print($0.value, inner) }
                .joined(separator: ",\n") + "\n" + indent + "}"
        case let .array(a):
            if a.isEmpty { return "[]" }
            if a.allSatisfy({ if case .string = $0 { return true }; return false }), a.count <= 1 {
                return "[" + a.map { $0.encoded() }.joined(separator: ", ") + "]"
            }
            return "[\n" + a.map { inner + print($0, inner) }.joined(separator: ",\n") + "\n" + indent + "]"
        default:
            return v.encoded()
        }
    }
}
