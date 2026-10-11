import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

// Layer: Mock. The whole shipped ACP stack over real pipes
// (ACPStdioConnection → ACPAgentServer → ACPBridgeRuntimePort → fake
// runtime/1 → ACPProjector → ACPWireV1), editor side scripted. Shows what a
// Zed prompt does to unit.run today. Not A6, not a real editor.

@Suite("UR · Mock · full ACP stack over pipes, prompt → unit.run", .serialized)
struct UnitRunServerTests {
    static let inputJSON = #"{"mode":"explore","goal":{"description":"打开计算器的「关于计算器」窗口"},"verification":{"all":[{"kind":"element_text_equals","role":"static_text","text":"关于计算器"}]},"allowedActions":["click","wait"]}"#

    private func start() async throws -> (URTestRuntime, URTestPipeEditor, String, [URL]) {
        let rt = URTestRuntime(try URTestScenario.load("ur-normal"))
        let store = URTestPipeEditor.tempDir("store"), cwd = URTestPipeEditor.tempDir("cwd")
        let ed = URTestPipeEditor(port: try URTestFlow.port(rt), storeDir: store)
        try await ed.initialize()
        let sid = try await ed.newSession(cwd: cwd)
        return (rt, ed, sid, [store, cwd])
    }

    private func stopReason(_ ed: URTestPipeEditor, _ id: Int) async throws -> String? {
        try await ed.waitFrame(timeout: 20) { $0["id"]?.intValue == id && $0["method"] == nil }["result"]?["stopReason"]?.stringValue
    }

    /// E2E class "approval rejected", editor side: Ask mode asks before the
    /// task; a reject creates nothing.
    @Test("[Mock] rejectedConfirmationSendsNoUnitRun") func rejectedConfirmationSendsNoUnitRun() async throws {
        let (rt, ed, sid, dirs) = try await start()
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let commands = try await ed.waitFrame { $0["params"]?["update"]?["sessionUpdate"]?.stringValue == "available_commands_update" }
        #expect(commands.encoded().contains("\"unit-run\""))
        let withDesk = Self.inputJSON.replacingOccurrences(of: #"{"mode""#, with: #"{"desktopId":"desk_A","mode""#)
        let p = ed.prompt(sid, "/unit-run \(withDesk)")
        try await ed.answerPermission(ACPWireV1.rejectOnceId)
        #expect(try await stopReason(ed, p) == "end_turn")
        #expect(ed.text.contains("未获批准，未创建任务"))
        #expect(rt.count("unit.run") == 0)
        await ed.disconnect()
        #expect(ed.schemaProblems.isEmpty, "\(ed.schemaProblems)")
    }

    /// The editor supplies an explicit Desktop, and the same value reaches
    /// Runtime's unit.run after the editor confirmation.
    @Test("[Mock] allowedPromptReachesUnitRunOnChosenDesktop") func allowedPromptReachesUnitRunOnChosenDesktop() async throws {
        let (rt, ed, sid, dirs) = try await start()
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let withDesk = Self.inputJSON.replacingOccurrences(of: #"{"mode""#, with: #"{"desktopId":"desk_A","mode""#)
        let p = ed.prompt(sid, "/unit-run \(withDesk)")
        try await ed.answerPermission(ACPWireV1.allowOnceId)
        _ = try await stopReason(ed, p)
        #expect(rt.count("unit.run") == 1)
        #expect(rt.with { rt.unitRunParams.first?["desktopId"] } == .string("desk_A"))
        await ed.disconnect()
        #expect(ed.schemaProblems.isEmpty, "\(ed.schemaProblems)")
    }

    @Test("[Mock] missingDesktopIsRefusedBeforeApproval") func missingDesktopIsRefusedBeforeApproval() async throws {
        let (rt, ed, sid, dirs) = try await start()
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let p = ed.prompt(sid, "/unit-run \(Self.inputJSON)")
        #expect(try await stopReason(ed, p) == "end_turn")
        #expect(ed.text.contains("desktopId") && ed.text.contains("必填"))
        #expect(rt.count("unit.run") == 0)
        await ed.disconnect()
        #expect(ed.schemaProblems.isEmpty, "\(ed.schemaProblems)")
    }

    /// Gap UR-G6: a refusal made locally by the bridge (nothing was sent) is
    /// worded as the Runtime's. Pinned on today's behaviour; when S/R word it
    /// as a local refusal, the known issue disappears and this test says so.
    @Test("[Mock] localRefusalShouldNotBeAttributedToTheRuntime") func localRefusalShouldNotBeAttributedToTheRuntime() async throws {
        let (rt, ed, sid, dirs) = try await start()
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let input = Self.inputJSON.replacingOccurrences(of: #"{"mode""#, with: #"{"desktopId":"desk_A","origin":"gui_explorer","mode""#)
        let p = ed.prompt(sid, "/unit-run \(input)")
        try await ed.answerPermission(ACPWireV1.allowOnceId)
        #expect(try await stopReason(ed, p) == "refusal")
        // It really was local: no unit.run, no Run.
        #expect(rt.count("unit.run") == 0)
        #expect(rt.with { rt.runs.isEmpty })
        #expect(ed.text.contains("ownership_escalation_denied"))
        withKnownIssue("UR-G6: a local refusal is shown as 「Runtime 拒绝了这个任务」") {
            #expect(!ed.text.contains("Runtime 拒绝了这个任务"))
        }
        await ed.disconnect()
        #expect(ed.schemaProblems.isEmpty, "\(ed.schemaProblems)")
    }

    /// Escalation typed by the user in the editor: refused, never sent.
    @Test("[Mock] escalationInThePromptIsRefused") func escalationInThePromptIsRefused() async throws {
        let (rt, ed, sid, dirs) = try await start()
        defer { dirs.forEach { try? FileManager.default.removeItem(at: $0) } }
        let input = Self.inputJSON.replacingOccurrences(of: #"{"mode""#, with: #"{"desktopId":"desk_A","lifetime":"platform_durable","mode""#)
        let p = ed.prompt(sid, "/unit-run \(input)")
        try await ed.answerPermission(ACPWireV1.allowOnceId)
        _ = try await stopReason(ed, p)
        #expect(ed.text.contains("ownership_escalation_denied"))
        #expect(rt.count("unit.run") == 0)
        await ed.disconnect()
        #expect(ed.schemaProblems.isEmpty, "\(ed.schemaProblems)")
    }
}
