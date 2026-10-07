import Foundation
import Testing
@testable import AgentDesktop

struct StateDisplayTests {
    private func task(_ state: TaskUiState, stopped: Bool?, stale: Bool = false) -> TaskView {
        var t = SampleTaskClient.samples[0]
        t.state = state
        t.executor = stopped.map { .init(ownerPid: nil, epoch: nil, stopped: $0) }
        t.heartbeat = .init(at: "", stale: stale)
        return t
    }

    @Test func aStopIsShownAsSettledOnlyWhenTheExecutorStopped() {
        #expect(TaskStateDisplay.label(task(.stopping, stopped: false)) == "停止中")
        #expect(TaskStateDisplay.label(task(.cancelled, stopped: false)) == "停止中")
        #expect(TaskStateDisplay.label(task(.cancelled, stopped: true)) == "已停止")
        #expect(TaskStateDisplay.label(task(.pausing, stopped: false)) == "暂停中")
        #expect(TaskStateDisplay.label(task(.paused, stopped: false)) == "暂停中")
        #expect(TaskStateDisplay.label(task(.paused, stopped: true)) == "已暂停")
        #expect(!TaskStateDisplay.isSettledStop(task(.stopping, stopped: false)))
        #expect(TaskStateDisplay.isSettledStop(task(.cancelled, stopped: true)))
    }

    @Test func aStaleHeartbeatIsNeverShownAsRunning() {
        #expect(TaskStateDisplay.label(task(.running, stopped: false, stale: true)) == "失联")
        #expect(TaskStateDisplay.label(task(.running, stopped: false, stale: false)) == "执行中")
    }

    @Test func everyStateAndOperationHasAWord() {
        for s in TaskUiState.allCases { #expect(!TaskStateDisplay.label(s).isEmpty) }
        for o in Operation.allCases { #expect(!TaskStateDisplay.label(o).isEmpty) }
    }
}

struct SampleCoverageTests {
    @Test func samplesCoverEveryStateAndEveryOperation() {
        let samples = SampleTaskClient.samples
        let states = Set(samples.map(\.state))
        #expect(states == Set(TaskUiState.allCases), "missing: \(Set(TaskUiState.allCases).subtracting(states))")
        let ops = Set(samples.flatMap(\.allowed))
        #expect(ops == Set(Operation.allCases), "missing: \(Set(Operation.allCases).subtracting(ops))")
        #expect(Set(samples.map(\.id)).count == samples.count)
    }

    @Test func samplesRoundTripThroughTheContractJSON() throws {
        for sample in SampleTaskClient.samples {
            let data = try JSONEncoder().encode(sample)
            let back = try JSONDecoder().decode(TaskView.self, from: data)
            #expect(back == sample)
        }
    }

    @Test func aCancelIsAcceptedFirstAndSettledOnlyWhenTheExecutorStops() async throws {
        let client = SampleTaskClient()
        let running = try await client.views().first { $0.state == .running && $0.allowed.contains(.cancel) }!
        let receipt = try await client.control(ControlRequest(taskId: running.id, operation: .cancel, payload: nil, requestId: "r1"))
        #expect(receipt.accepted)
        #expect(!receipt.executorStopped)
        #expect(receipt.settlesTo == [.cancelled])
        let stopping = try await client.view(running.id)
        #expect(stopping.state == .stopping)
        #expect(stopping.executor?.stopped == false)
        try await Task.sleep(for: .seconds(2))
        let settled = try await client.view(running.id)
        #expect(settled.state == .cancelled)
        #expect(settled.executor?.stopped == true)
    }

    @Test func anOperationTheServiceDoesNotAllowIsRefusedNotApplied() async throws {
        let client = SampleTaskClient()
        let queued = try await client.views().first { $0.state == .queued }!
        let receipt = try await client.control(ControlRequest(taskId: queued.id, operation: .resume, payload: nil, requestId: "r2"))
        #expect(!receipt.accepted)
        #expect(receipt.reason?.code == "conflict")
        #expect(try await client.view(queued.id).state == .queued)
    }
}

struct CLIParsingTests {
    @Test func proseAboutNoRunningHostIsOffline() {
        #expect(throws: TaskClientError.offline("2ndscreen is not running; open 2ndscreen.app first")) {
            try CLITaskClient.parse(stdout: "2ndscreen is not running; open 2ndscreen.app first\n", exitCode: 1)
        }
    }

    @Test func aMissingRuntimeIsACapabilityMissing() {
        let line = #"{"error":{"code":"capability_missing","message":"SECONDSCREEN_TASK_RUNTIME /x/task-runtime is not a directory"},"ok":false,"command":"status"}"#
        #expect(throws: TaskClientError.capabilityMissing("SECONDSCREEN_TASK_RUNTIME /x/task-runtime is not a directory")) {
            try CLITaskClient.parse(stdout: line, exitCode: 1)
        }
    }

    @Test func aRuntimeThatKnowsNoViewCommandIsACapabilityMissing() {
        let line = #"{"ok":false,"error":{"code":"invalid_input","message":"unknown command view"}}"#
        #expect(throws: TaskClientError.capabilityMissing("unknown command view")) {
            try CLITaskClient.parse(stdout: line, exitCode: 2)
        }
    }

    @Test func otherCodesKeepTheirMeaning() {
        let line = #"{"ok":false,"error":{"code":"not_found","message":"no task x"}}"#
        #expect(throws: TaskClientError.notFound("no task x")) { try CLITaskClient.parse(stdout: line, exitCode: 1) }
        #expect(throws: TaskClientError.self) { try CLITaskClient.parse(stdout: "", exitCode: 1) }
    }

    @Test func aServiceReplyDecodesAndItsVersionIsChecked() throws {
        let line = #"{"ok":true,"service":{"product":"Agent Desktop","bundleId":"com.agentdesktop.app","pid":12,"protocolVersion":"0","runtimeVersion":"0.3.0","engineRevision":"abc","capabilities":["task.view"]}}"#
        let reply = try CLITaskClient.parse(stdout: line, exitCode: 0)
        #expect(reply.service?.capabilities == ["task.view"])
        try CLITaskClient.checkVersion(reply.service!)
        var newer = reply.service!
        newer.protocolVersion = "1"
        #expect(throws: TaskClientError.versionMismatch(found: "1", supported: "0")) { try CLITaskClient.checkVersion(newer) }
    }

    @Test func aViewReplyDecodesUnknownUsageAsUnknownNotZero() throws {
        var sample = SampleTaskClient.samples[1]
        sample.usage = .init(modelCalls: .unknown, inputTokens: .known(3), outputTokens: .unknown, cost: nil)
        let data = try JSONEncoder().encode(["ok": AnyEncodable(true), "task": AnyEncodable(sample)])
        let reply = try CLITaskClient.parse(stdout: String(data: data, encoding: .utf8)!, exitCode: 0)
        #expect(reply.task?.usage?.modelCalls == .unknown)
        #expect(reply.task?.usage?.modelCalls.text == "未知")
        #expect(reply.task?.usage?.inputTokens == .known(3))
    }
}

private struct AnyEncodable: Encodable {
    let value: Encodable
    init(_ value: Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}
