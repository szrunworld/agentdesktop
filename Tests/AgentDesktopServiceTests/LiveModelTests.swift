import AgentDesktopAI
import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopService

// T12 / TRN-008 / CFG-008 against a real model. Skipped unless
// AGENTDESKTOP_LIVE_ARK=1; it reads ARK_API_KEY and ARK_MODEL from the
// environment or ~/.config/2ndscreen/ark.env, sends at most three model
// calls through the composed service and never touches a desktop. The key
// goes through the in-memory credential store and is never printed.
@Suite("Live model", .enabled(if: ProcessInfo.processInfo.environment["AGENTDESKTOP_LIVE_ARK"] == "1"))
struct LiveModelTests {
    static func arkSettings() -> (key: String, model: String)? {
        var values = ProcessInfo.processInfo.environment
        let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/2ndscreen/ark.env")
        if let text = try? String(contentsOf: file, encoding: .utf8) {
            for line in text.split(separator: "\n") where !line.hasPrefix("#") {
                let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2, values[parts[0]] == nil { values[parts[0]] = parts[1] }
            }
        }
        guard let key = values["ARK_API_KEY"], !key.isEmpty else { return nil }
        return (key, values["ARK_MODEL"] ?? "doubao-seed-2-1-lite-260915")
    }

    @Test func fourLevelCapabilityTestOnArk() async throws {
        let ark = try #require(Self.arkSettings(), "no ARK_API_KEY")
        let dir = URL(fileURLWithPath: "/tmp/adlive-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
            databasePath: dir.appendingPathComponent("config.sqlite").path, credentials: InMemoryCredentialStore()))
        let router = service.router(callerScope: "owner", trustedOwner: true)
        func ok(_ command: String, _ params: JSONValue, key: String? = nil) async throws -> JSONValue {
            var m: [(String, JSONValue)] = [("schemaVersion", .string("agentdesktop.ai/1")),
                                            ("requestId", .string(UUID().uuidString.lowercased())),
                                            ("command", .string(command)), ("params", params)]
            if let key { m.append(("context", .obj([("idempotencyKey", .string(key))]))) }
            var out = await router.respond(toBody: JSONValue.obj(m).encodedData())
            out.removeLast()
            let v = try StrictJSON.parse(out)
            guard v["ok"]?.boolValue == true, let r = v["result"] else {
                throw ContractError(.internalError, "\(command): \(v["error"]?.encoded() ?? "?")")
            }
            return r
        }
        let conn = try await ok("ai.connections.create", .obj([
            ("name", .string("Ark live")), ("protocol", .string("openai_chat")),
            ("baseUrl", .string("https://ark.cn-beijing.volces.com/api/v3")), ("timeoutMs", .int(60000)),
            ("credential", .obj([("apiKey", .string(ark.key))])),
        ]), key: "live-conn-0001")
        let model = try await ok("ai.modelProfiles.create", .obj([
            ("name", .string("Ark model")), ("connectionId", conn["connectionId"]!), ("connectionRevision", conn["revision"]!),
            ("modelId", .string(ark.model)), ("requestOptions", .obj([("temperature", .int(0))])), ("maxOutputTokens", .int(512)),
        ]), key: "live-model-0001")
        let gui = try await ok("ai.profiles.create", .obj([
            ("name", .string("UI-TARS live")), ("modelProfileId", model["modelProfileId"]!),
            ("modelProfileRevision", model["revision"]!), ("adapterId", .string("uitars_v1")),
            ("adapterVersion", .string("1.0.0")), ("promptVersion", .string("uitars-prompt-1")),
            ("parserVersion", .string("uitars-parser-1")), ("coordinateProtocol", .string("normalized_1000")),
            ("limits", GuiLimits.ceiling.json), ("allowedFallbackProfileRefs", .array([])),
        ]), key: "live-gui-0001")
        let started = try await ok("ai.tests.start", .obj([("guiProfileId", gui["guiProfileId"]!),
                                                          ("expectedRevision", gui["revision"]!),
                                                          ("fixtureId", .string("synthetic_gui_v1"))]), key: "live-test-0001")
        var op: JSONValue = .null
        for _ in 0..<240 {
            op = try await ok("ai.operations.get", .obj([("operationId", started["operationId"]!)]))
            if ["succeeded", "failed", "cancelled"].contains(op["state"]?.stringValue ?? "") { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        let report = op.encoded()
        #expect(!report.contains(ark.key))
        let evidence = dir.appendingPathComponent("capability-test.json")
        try Data(report.utf8).write(to: evidence)
        print("LIVE capability test: \(op["state"]?.stringValue ?? "?") evidence=\(evidence.path)")
        for level in op["result"]?["levels"]?.arrayValue ?? [] {
            print("  \(level["level"]?.stringValue ?? "?"): \(level["status"]?.stringValue ?? "?") \(level["reasonCode"]?.stringValue ?? "")")
        }
        let usage = try await ok("ai.usage.summary", .obj([("from", .string("2026-01-01T00:00:00Z")), ("to", .string("2099-01-01T00:00:00Z"))]))
        print("  usage: attempts=\(usage["inferenceAttempts"]?.encoded() ?? "?") missingUsage=\(usage["attemptsMissingUsage"]?.encoded() ?? "?") tokens=\(usage["reportedTokens"]?.encoded() ?? "?")")
        #expect(op["state"]?.stringValue == "succeeded", "\(report)")
    }
}
