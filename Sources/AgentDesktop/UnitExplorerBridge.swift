import AgentDesktopContracts
import AgentDesktopRuntime
import AgentDesktopService
import Foundation

/// GUI units' model exploration, run by the AI/GUI service in this process
/// (gui.runs.start, then gui.runs.get until it ends). Its inputs go through
/// the Runtime's ports like every other input.
final class UnitExplorerBridge: UnitExplorer, @unchecked Sendable {
    let service: AgentDesktopService

    init(service: AgentDesktopService) {
        self.service = service
    }

    private func call(_ command: String, _ params: JSONValue, key: String? = nil) -> JSONValue? {
        var m: [(String, JSONValue)] = [("schemaVersion", .string("agentdesktop.ai/1")), ("requestId", .string(UUID().uuidString.lowercased())),
                                        ("command", .string(command)), ("params", params)]
        if let key { m.append(("context", .obj([("idempotencyKey", .string(key))]))) }
        let router = service.router(callerScope: "uid:\(getuid())", trustedOwner: true)
        let body = JSONValue.obj(m).encodedData()
        final class Box: @unchecked Sendable { var data = Data() }
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        Task {
            box.data = await router.respond(toBody: body)
            done.signal()
        }
        done.wait()
        var out = box.data
        if out.last == 0x0A { out.removeLast() }
        guard let v = try? StrictJSON.parse(out), v["ok"]?.boolValue == true else { return nil }
        return v["result"]
    }

    func explore(desktopId: String, sessionId: String, goal: String, target: JSONValue, maxSteps: Int?,
                 deadline: Date) -> ExploreOutcome {
        var verification: [(String, JSONValue)] = [("kind", .string("element_text_equals")),
                                                   ("role", .string("static_text")), ("text", target["text"] ?? .string(""))]
        if target["role"]?.stringValue == "AXTextField" { verification[1] = ("role", .string("text_field")) }
        let start = call("gui.runs.start", .obj([
            ("desktopId", .string(desktopId)), ("sessionId", .string(sessionId)), ("goal", .string(goal)),
            ("verification", .obj(verification)),
            ("allowedActions", .array(["click", "type", "key"].map(JSONValue.string))),
        ]), key: "unit-" + UUID().uuidString.lowercased())
        guard let runId = start?["runId"]?.stringValue else {
            return ExploreOutcome(state: "failed", modelCalls: 0, guiRunId: nil, message: "the GUI service refused to start a run")
        }
        var run: JSONValue = .obj([])
        while Date() < deadline {
            run = call("gui.runs.get", .obj([("runId", .string(runId))])) ?? run
            if ["succeeded", "failed", "cancelled", "waiting_user"].contains(run["state"]?.stringValue ?? "") { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        let state = run["state"]?.stringValue ?? "unknown"
        if !["succeeded", "failed", "cancelled", "waiting_user"].contains(state) {
            _ = call("gui.runs.cancel", .obj([("runId", .string(runId))]), key: "unit-cancel-" + runId)
        }
        return ExploreOutcome(state: state, modelCalls: run["modelAttemptCount"]?.intValue ?? 0, guiRunId: runId,
                              message: run["error"]?["message"]?.stringValue)
    }
}
