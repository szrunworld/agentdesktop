import Foundation
import Testing
@testable import AgentDesktop

private func sampleTask(_ state: TaskUiState, executor: TaskView.Executor?, stale: Bool = false) -> TaskView {
    var t = SampleTaskClient.samples[0]
    t.state = state
    t.executor = executor
    t.heartbeat = .init(at: "", stale: stale)
    return t
}

struct StateDisplayTests {
    @Test func aStopIsSettledOnlyOnTheExecutorsOwnEvidence() {
        let running = TaskView.Executor(ownerPid: 1, epoch: "e", stopped: false)
        let stopped = TaskView.Executor(ownerPid: nil, epoch: "e", stopped: true)
        #expect(TaskStateDisplay.label(sampleTask(.stopping, executor: running)) == "停止中")
        #expect(TaskStateDisplay.label(sampleTask(.cancelled, executor: running)) == "停止中")
        #expect(TaskStateDisplay.label(sampleTask(.cancelled, executor: stopped)) == "已停止")
        #expect(TaskStateDisplay.label(sampleTask(.pausing, executor: running)) == "暂停中")
        #expect(TaskStateDisplay.label(sampleTask(.paused, executor: running)) == "暂停中")
        #expect(TaskStateDisplay.label(sampleTask(.paused, executor: stopped)) == "已暂停")
        #expect(!TaskStateDisplay.isSettledStop(sampleTask(.stopping, executor: running)))
        #expect(TaskStateDisplay.isSettledStop(sampleTask(.cancelled, executor: stopped)))
        #expect(!TaskStateDisplay.isSettledStop(sampleTask(.succeeded, executor: stopped)), "only a pause or cancel is a stop")
    }

    @Test func withoutAnExecutorRecordAStopStaysUnsettledAndSaysWhy() {
        for state in [TaskUiState.paused, .cancelled] {
            let task = sampleTask(state, executor: nil)
            #expect(!TaskStateDisplay.isSettledStop(task))
            #expect(TaskStateDisplay.label(task) == (state == .paused ? "暂停中" : "停止中"))
            #expect(TaskStateDisplay.note(task) == TaskStateDisplay.noExecutorEvidence)
        }
        for state in [TaskUiState.pausing, .stopping] {
            #expect(TaskStateDisplay.note(sampleTask(state, executor: nil)) == TaskStateDisplay.noExecutorEvidence)
            #expect(TaskStateDisplay.note(sampleTask(state, executor: .init(ownerPid: 1, epoch: nil, stopped: false))) == nil)
        }
        #expect(TaskStateDisplay.note(sampleTask(.running, executor: nil)) == nil)
    }

    @Test func aStaleHeartbeatIsNeverShownAsRunning() {
        #expect(TaskStateDisplay.label(sampleTask(.running, executor: nil, stale: true)) == "失联")
        #expect(TaskStateDisplay.label(sampleTask(.running, executor: nil, stale: false)) == "执行中")
    }

    @Test func everyStateAndOperationHasAWord() {
        for s in TaskUiState.allCases { #expect(!TaskStateDisplay.label(s).isEmpty) }
        for o in TaskOperation.allCases { #expect(!TaskStateDisplay.label(o).isEmpty) }
    }

    @Test func receiptWordsFollowTheOperation() {
        func receipt(_ op: TaskOperation, accepted: Bool = true, stopped: Bool = false, settles: [TaskUiState] = []) -> ControlReceipt {
            ControlReceipt(requestId: "r", taskId: "t", operation: op, accepted: accepted, acceptedAt: nil,
                           reason: accepted ? nil : .init(code: "conflict", message: "no"), executorStopped: stopped, settlesTo: settles)
        }
        #expect(TaskStateDisplay.receiptLine(receipt(.cancel)).contains("等待执行者停止"))
        #expect(TaskStateDisplay.receiptLine(receipt(.cancel, stopped: true)).contains("执行者已停止"))
        #expect(TaskStateDisplay.receiptLine(receipt(.pause)).contains("等待执行者停止"))
        #expect(TaskStateDisplay.receiptLine(receipt(.resume, settles: [.running])) == "继续 已受理，任务将进入执行中")
        #expect(TaskStateDisplay.receiptLine(receipt(.approve, settles: [.running])).contains("执行中"))
        #expect(!TaskStateDisplay.receiptLine(receipt(.answer, settles: [.running])).contains("执行者"))
        #expect(TaskStateDisplay.receiptLine(receipt(.cancel, accepted: false)) == "取消 未受理：no")
    }
}

struct SampleCoverageTests {
    @Test func samplesCoverEveryStateAndEveryOperation() {
        let samples = SampleTaskClient.samples
        let states = Set(samples.map(\.state))
        #expect(states == Set(TaskUiState.allCases), "missing: \(Set(TaskUiState.allCases).subtracting(states))")
        let ops = Set(samples.flatMap(\.allowed))
        #expect(ops == Set(TaskOperation.allCases), "missing: \(Set(TaskOperation.allCases).subtracting(ops))")
        #expect(Set(samples.map(\.id)).count == samples.count)
    }

    @Test func samplesRoundTripThroughTheContractJSON() throws {
        for sample in SampleTaskClient.samples {
            let back = try JSONDecoder().decode(TaskView.self, from: try JSONEncoder().encode(sample))
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

    @Test func anAnswerWithoutItsFixedInputIsRefused() async throws {
        let client = SampleTaskClient()
        let asking = try await client.views().first { $0.allowed.contains(.answer) && $0.state == .waiting }!
        let bare = try await client.control(ControlRequest(taskId: asking.id, operation: .answer, payload: .object(["answer": .string("yes")]), requestId: "r3"))
        #expect(!bare.accepted)
        #expect(bare.reason?.code == "invalid_input")
        let full = try await client.control(ControlRequest(taskId: asking.id, operation: .answer,
                                                           payload: .object(["inboxId": .string("inbox-2"), "answer": .string("yes")]), requestId: "r4"))
        #expect(full.accepted)
        #expect(full.settlesTo == [.running])
    }
}

struct CLIParsingTests {
    static let service = #"{"host":{"product":"Agent Desktop","bundleId":"com.agentdesktop.app","pid":12,"controlProtocolVersion":"1","engineRevision":"abc"},"task":{"protocolVersion":"0","runtimeVersion":"0.3.0","capabilities":["task.view","task.control"]}}"#

    @Test func proseAboutNoRunningHostIsOffline() {
        #expect(throws: TaskClientError.offline("2ndscreen is not running; open 2ndscreen.app first")) {
            try CLITaskClient.parse(stdout: "2ndscreen is not running; open 2ndscreen.app first\n", exitCode: 1)
        }
    }

    @Test func aStructuredReplyWhoseWordsMentionNotRunningIsNotOffline() throws {
        let line = #"{"ok":true,"service":"# + Self.service + #","task":"# + fixtureTaskJSON(summary: "the app is not running; nothing to extract") + "}"
        let reply = try CLITaskClient.parse(stdout: line, exitCode: 0)
        #expect(reply.ok)
        #expect(reply.task?.result?.summary == "the app is not running; nothing to extract")
        let checked = try CLITaskClient.validated(reply, expecting: .view)
        #expect(checked.task != nil)
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
        #expect(throws: TaskClientError.self) { try CLITaskClient.parse(stdout: "[1,2]", exitCode: 0) }
    }

    @Test func everyReplyMustNameTheServiceAtThisVersionAndCarryItsField() throws {
        let noService = try CLITaskClient.parse(stdout: #"{"ok":true,"tasks":[]}"#, exitCode: 0)
        #expect(throws: TaskClientError.self) { try CLITaskClient.validated(noService, expecting: .views) }
        let noTasks = try CLITaskClient.parse(stdout: #"{"ok":true,"service":"# + Self.service + "}", exitCode: 0)
        #expect(throws: TaskClientError.self) { try CLITaskClient.validated(noTasks, expecting: .views) }
        let emptyTasks = try CLITaskClient.parse(stdout: #"{"ok":true,"service":"# + Self.service + #","tasks":[]}"#, exitCode: 0)
        #expect(try CLITaskClient.validated(emptyTasks, expecting: .views).tasks == [])
        let noReceipt = try CLITaskClient.parse(stdout: #"{"ok":true,"service":"# + Self.service + "}", exitCode: 0)
        #expect(throws: TaskClientError.self) { try CLITaskClient.validated(noReceipt, expecting: .control) }
        let newer = Self.service.replacingOccurrences(of: #""protocolVersion":"0""#, with: #""protocolVersion":"1""#)
        let other = try CLITaskClient.parse(stdout: #"{"ok":true,"service":"# + newer + #","tasks":[]}"#, exitCode: 0)
        #expect(throws: TaskClientError.versionMismatch(found: "1", supported: "0")) { try CLITaskClient.validated(other, expecting: .views) }
    }

    @Test func theSharedFixtureDecodesEveryContractType() throws {
        let url = try #require(Bundle.module.url(forResource: "task-view-sample", withExtension: "json", subdirectory: "Fixtures"))
        let text = try String(contentsOf: url, encoding: .utf8)
        let reply = try CLITaskClient.parse(stdout: text, exitCode: 0)
        let checked = try CLITaskClient.validated(reply, expecting: .view)
        #expect(checked.service?.host.pid == 4100)
        #expect(checked.service?.host.controlProtocolVersion == "1")
        #expect(checked.service?.task.capabilities.contains("task.control") == true)
        let task = try #require(checked.task)
        #expect(task.state == .waiting)
        #expect(task.waiting?.inboxId == "inbox-77")
        #expect(task.allowed == [.approve, .deny, .cancel])
        #expect(task.usage?.outputTokens == .unknown)
        #expect(task.usage?.cost == .unknown)
        #expect(task.usage?.modelCalls.text == "3")
        #expect(task.usage?.outputTokens.text == "未知")
        let inbox = try #require(reply.inbox?.first)
        #expect(inbox.action?.effect == "external-submit")
        #expect(inbox.expiresAt == "2026-10-07T13:35:00Z")
        let receipt = try #require(reply.receipt)
        #expect(receipt.accepted && !receipt.executorStopped && receipt.settlesTo == [.cancelled])
        // And back out: the Swift types produce JSON the other side reads.
        let again = try JSONDecoder().decode(TaskView.self, from: try JSONEncoder().encode(task))
        #expect(again == task)
    }

    @Test func costIsFractionalAndPayloadIsAnyJSON() throws {
        let usage = try JSONDecoder().decode(TaskView.Usage.self, from: Data(#"{"modelCalls":1,"inputTokens":2,"outputTokens":3,"cost":0.0125}"#.utf8))
        #expect(usage.cost == .known(0.0125))
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Count.self, from: Data(#""many""#.utf8)) }
        let request = ControlRequest(taskId: "t", operation: .resubmit,
                                     payload: .object(["input": .object(["url": .string("https://x"), "limit": .number(3), "flags": .array([.bool(true), .null])])]),
                                     requestId: "r")
        let back = try JSONDecoder().decode(ControlRequest.self, from: try JSONEncoder().encode(request))
        #expect(back == request)
        #expect(back.payload?["input"]?["url"]?.stringValue == "https://x")
    }

    private func fixtureTaskJSON(summary: String) -> String {
        var task = SampleTaskClient.samples[10]
        task.result = .init(summary: summary, outputPath: nil, verification: .init(platform: .passed, business: .none, notes: nil))
        return String(data: try! JSONEncoder().encode(task), encoding: .utf8)!
    }
}

@MainActor
struct AppModelTests {
    /// Answers after a delay, so a switch can land while a request is in flight.
    final class SlowClient: TaskClient {
        let scope = ClientScope(clientId: "t", agentIds: nil)
        let tag: String
        let delay: Duration
        init(tag: String, delay: Duration) { self.tag = tag; self.delay = delay }
        func service() async throws -> ServiceIdentity {
            try await Task.sleep(for: delay)
            var s = SampleTaskClient.identity
            s.task.runtimeVersion = tag
            return s
        }
        func views() async throws -> [TaskView] { try await Task.sleep(for: delay); var t = SampleTaskClient.samples[0]; t.id = tag; return [t] }
        func view(_ taskId: String) async throws -> TaskView { try await views()[0] }
        func control(_ request: ControlRequest) async throws -> ControlReceipt {
            ControlReceipt(requestId: request.requestId, taskId: request.taskId, operation: request.operation, accepted: true, acceptedAt: nil, reason: nil, executorStopped: false, settlesTo: [])
        }
    }

    @Test func aResultFromAClientThatWasSwitchedAwayIsDropped() async throws {
        let model = AppModel(role: .product, mode: .sample)
        model.switchClient(SlowClient(tag: "old", delay: .milliseconds(300)))
        let oldGen = model.generation
        try await Task.sleep(for: .milliseconds(50))
        model.switchClient(SlowClient(tag: "new", delay: .milliseconds(10)))
        #expect(model.generation == oldGen + 1)
        #expect(model.tasks.isEmpty && model.receipts.isEmpty)
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.tasks.map(\.id) == ["new"])
        if case .ready(let s) = model.serviceState { #expect(s.task.runtimeVersion == "new") } else { Issue.record("not ready: \(model.serviceState)") }
    }

    @Test func startIsIdempotentAndStopEndsTheOneTimerWithTheLastWindow() {
        let model = AppModel(role: .product, mode: .sample)
        #expect(!model.isPolling)
        model.start()
        model.start()
        #expect(model.isPolling)
        model.stop()
        #expect(model.isPolling, "one window still open")
        model.stop()
        #expect(!model.isPolling)
        model.stop()
        #expect(!model.isPolling)
    }

    @Test func aClickIsCheckedAgainstTheLatestViewNotTheCachedButtons() async throws {
        let model = AppModel(role: .product, mode: .sample)
        await model.refresh()
        let queued = try #require(model.tasks.first { $0.state == .queued })
        // The cached view allows cancel; the service's latest view decides.
        #expect(await model.refusal(for: .cancel, on: queued.id, payload: nil) == nil)
        #expect(await model.refusal(for: .resume, on: queued.id, payload: nil) == .notAllowedNow(.queued))
        let asking = try #require(model.tasks.first { $0.allowed.contains(.answer) && $0.state == .waiting })
        #expect(await model.refusal(for: .answer, on: asking.id, payload: .object(["answer": .string("x")])) == .inputMissing(["inboxId"]))
        let receipt = await model.send(.resume, to: queued, payload: nil)
        #expect(receipt?.accepted == false)
        #expect(receipt?.reason?.code == "conflict")
    }

    @Test func nothingIsSentWhileTheServiceIsNotReady() async {
        let model = AppModel(role: .product, mode: .sample)
        #expect(await model.refusal(for: .cancel, on: "sample-1", payload: nil) == .serviceNotReady)
    }
}
