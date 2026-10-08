import AgentDesktopProtocol
import AgentDesktopACP
import Foundation

/// `--demo` only: a scripted Runtime with one free-text task. Each Run
/// emits three progress events and ends; nothing touches a screen.
final class ACPAgentServerDemoPort: ACPRuntimePort, @unchecked Sendable {
    private let lock = NSLock()
    private var runs: [String: (snapshot: ACPRunSnapshot, started: Date)] = [:]
    private var keys: [String: String] = [:]
    private var next = 0

    private func locked<T>(_ f: () throws -> T) rethrows -> T {
        lock.lock(); defer { lock.unlock() }
        return try f()
    }

    func caller() async throws -> ACPCaller {
        ACPCaller(principalId: "demo-owner", clientId: "acp-dev", connectionId: "demo")
    }

    func tasks() async throws -> [ACPExposedTask] {
        [ACPExposedTask(taskType: "demo.echo", displayName: "演示任务", description: "演示：三步进度后结束",
                        inputSchema: .obj([("type", .string("object")),
                                           ("properties", .obj([("text", .obj([("type", .string("string")),
                                                                               ("maxLength", .int(200))]))]))]),
                        allowFreeText: true, requiresApproval: false, dataClassification: "public")]
    }

    func submit(_ s: ACPSubmission) async throws -> ACPSubmissionReceipt { locked { submitLocked(s) } }

    private func submitLocked(_ s: ACPSubmission) -> ACPSubmissionReceipt {
        if let id = keys[s.submissionKey], let r = runs[id] { return .duplicate(r.snapshot) }
        next += 1
        let id = "demo-run-\(next)"
        let snap = ACPRunSnapshot(runId: id, phase: "running", outcome: nil, quiescence: "not_confirmed",
                                  lifetime: "connection_scoped")
        runs[id] = (snap, Date())
        keys[s.submissionKey] = id
        return .accepted(snap)
    }

    func snapshot(runId: String) async throws -> ACPRunSnapshot { try locked { try snapshotLocked(runId) } }

    private func snapshotLocked(_ runId: String) throws -> ACPRunSnapshot {
        guard var r = runs[runId] else { throw ACPError(code: -32002, reason: "not_found", message: "no run") }
        if r.snapshot.phase != "ended", Date().timeIntervalSince(r.started) > 1.6 {
            r.snapshot.phase = "ended"
            r.snapshot.outcome = r.snapshot.quiescence == "pending" ? "cancelled" : "success"
            r.snapshot.quiescence = "confirmed"
            runs[runId] = r
        }
        return r.snapshot
    }

    func cancel(runId: String, requestId: String) async throws -> ACPRunSnapshot {
        try locked {
            if runs[runId]?.snapshot.phase != "ended" {
                runs[runId]?.snapshot.phase = "stopping"
                runs[runId]?.snapshot.quiescence = "pending"
            }
            return try snapshotLocked(runId)
        }
    }

    func events(runId: String, after cursor: Int?) -> AsyncThrowingStream<ACPRuntimeEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                for i in 1...3 where i > (cursor ?? 0) {
                    try? await Task.sleep(for: .milliseconds(400))
                    cont.yield(ACPRuntimeEvent(runId: runId, cursor: i, type: "demo.progress", payload: .int(i)))
                }
                cont.finish()
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }

    func pending(runId: String) async throws -> [ACPPendingDecision] {
        throw ACPError(code: -32601, reason: "capability_missing", message: "no approvals in demo")
    }
    func decide(approvalId: String, allow: Bool) async throws {
        throw ACPError(code: -32601, reason: "capability_missing", message: "no approvals in demo")
    }
    func answer(questionId: String, text: String) async throws {
        throw ACPError(code: -32601, reason: "capability_missing", message: "no questions in demo")
    }
    func connectionLost() async {}
}

/// `--demo` only: shows progress counters and hides all free text.
struct ACPAgentServerDemoProjector: ACPEventProjector {
    func project(_ event: ACPRuntimeEvent, policy: ACPPrivacyPolicy) -> [ACPSessionUpdate] {
        [.agentThought("演示进度 \(event.cursor)/3")]
    }
    func redact(_ text: String, policy: ACPPrivacyPolicy) -> String { "[已隐藏]" }
}
