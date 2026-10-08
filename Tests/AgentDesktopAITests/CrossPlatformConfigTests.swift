import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopAI

// The same 32-step configuration script the C# store runs
// (windows/tests/AgentDesktop.AI.Tests/Fixtures/cross-platform-config.json):
// both platforms must answer every step the same way.
@Suite("Cross-platform configuration script")
struct CrossPlatformConfigTests {
    static let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    static func lookup(_ v: JSONValue?, _ path: String) -> JSONValue? {
        var cur = v
        for part in path.split(separator: ".") {
            if let i = Int(part), let arr = cur?.arrayValue { cur = arr.indices.contains(i) ? arr[i] : nil }
            else { cur = cur?[String(part)] }
        }
        return cur
    }

    static func substitute(_ v: JSONValue, _ saved: [String: JSONValue]) -> JSONValue {
        func resolve(_ ref: String) -> JSONValue? {
            let parts = ref.split(separator: ".", maxSplits: 1).map(String.init)
            guard let base = saved[parts[0]] else { return nil }
            return parts.count == 1 ? base : lookup(base, parts[1])
        }
        switch v {
        case let .string(s):
            if s.hasPrefix("${"), s.hasSuffix("}"), s.filter({ $0 == "$" }).count == 1 {
                return resolve(String(s.dropFirst(2).dropLast())) ?? v
            }
            var out = s
            while let r = out.range(of: #"\$\{[^}]+\}"#, options: .regularExpression) {
                let ref = String(out[r].dropFirst(2).dropLast())
                let val = resolve(ref)
                out.replaceSubrange(r, with: val?.stringValue ?? val?.encoded() ?? "")
            }
            return .string(out)
        case let .array(items): return .array(items.map { substitute($0, saved) })
        case let .object(members): return .object(members.map { (key: $0.key, value: substitute($0.value, saved)) })
        default: return v
        }
    }

    @Test func scriptMatchesTheCSharpVerdicts() async throws {
        let fixture = try StrictJSON.parse(Data(contentsOf: Self.repo.appendingPathComponent(
            "windows/tests/AgentDesktop.AI.Tests/Fixtures/cross-platform-config.json")))
        let steps = try #require(fixture["steps"]?.arrayValue)
        #expect(steps.count >= 30)
        let h = try Harness(options: ConfigOptions(allowLoopbackHTTP: true))
        let other = ServiceRouter(handlers: h.service.handlers(callerScope: "other"))
        var saved: [String: JSONValue] = [:]
        var secrets: [String] = []
        for step in steps {
            let name = step["name"]?.stringValue ?? "?"
            let params = Self.substitute(step["params"] ?? .obj([]), saved)
            if let k = params["credential"]?["apiKey"]?.stringValue { secrets.append(k) }
            let router = step["caller"]?.stringValue == "other" ? other : h.router
            let reply = try await h.call(step["command"]!.stringValue!, params, key: step["key"]?.stringValue, router: router)
            let expect = Self.substitute(step["expect"]!, saved)
            let ok = reply["ok"]?.boolValue == true
            #expect(ok == expect["ok"]?.boolValue, "\(name): \(reply.encoded())")
            let result = reply["result"]
            for f in expect["fields"]?.objectMembers ?? [] {
                #expect(Self.lookup(result, f.key) ?? .null == f.value, "\(name): field \(f.key)")
            }
            for f in expect["notEqual"]?.objectMembers ?? [] {
                #expect(Self.lookup(result, f.key) != f.value, "\(name): \(f.key) must differ")
            }
            if let n = expect["itemCount"]?.intValue {
                #expect(result?["items"]?.arrayValue?.count == n, "\(name): item count")
            }
            if let code = expect["code"]?.stringValue {
                #expect(reply["error"]?["code"]?.stringValue == code, "\(name): \(reply.encoded())")
            }
            for d in expect["details"]?.objectMembers ?? [] {
                #expect(reply["error"]?["details"]?[d.key] == d.value, "\(name): details.\(d.key)")
            }
            let paths = Set(reply["error"]?["details"]?["fieldErrors"]?.arrayValue?.compactMap { $0["path"]?.stringValue } ?? [])
            for p in expect["fieldErrorPaths"]?.arrayValue?.compactMap(\.stringValue) ?? [] {
                #expect(paths.contains(p), "\(name): fieldError \(p) in \(paths)")
            }
            if let s = expect["save"]?.stringValue, let result { saved[s] = result }
        }
        let all = h.responses.all.joined()
        for k in Set(secrets) { #expect(!all.contains(k), "a key leaked into a response") }
    }
}
