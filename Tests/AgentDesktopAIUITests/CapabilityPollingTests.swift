import AgentDesktopAIUI
import AgentDesktopProtocol
import Foundation
import Testing

private actor PollingClient: ContractClient {
    var failures: Int
    var reads = 0
    let cancellation: Bool
    init(failures: Int, cancellation: Bool = false) { self.failures = failures; self.cancellation = cancellation }
    func guiCapabilities() async throws -> JSONValue { .obj([]) }
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        switch command {
        case "ai.profiles.get": return .obj([("revision", .int(1))])
        case "ai.tests.start": return .obj([("operationId", .string("op"))])
        case "ai.operations.get":
            reads += 1
            if cancellation { throw CancellationError() }
            if failures > 0 { failures -= 1; throw ContractError(.upstreamUnavailable, "temporary read failure") }
            return .obj([("state", .string("cancelled"))])
        default: throw ContractError(.internalError, "unexpected command")
        }
    }
}

/// Holds each pause until the test releases it, so a test can act while
/// the status loop is between reads.
private actor PauseGate {
    private(set) var entered = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    func pause() async {
        entered += 1
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    /// Releases every held pause and lets later ones pass at once.
    func open() {
        isOpen = true
        release()
    }
    func release() {
        let w = waiters
        waiters = []
        w.forEach { $0.resume() }
    }
    func waitForPause(_ n: Int) async {
        while entered < n { try? await Task.sleep(nanoseconds: 1_000_000) }
    }
}

private struct GateClock: PollClock {
    let gate: PauseGate
    func pause(milliseconds: Int) async throws {
        await gate.pause()
        try Task.checkCancellation()
    }
}

/// Reads stay "running" for `runningReads` answered reads, then end; the
/// first read can fail; cancel answers as told.
private actor CancelClient: ContractClient {
    var reads = 0
    let runningReads: Int
    let cancelFails: Bool
    let failFirstRead: Bool
    init(runningReads: Int, cancelFails: Bool, failFirstRead: Bool = false) {
        self.runningReads = runningReads; self.cancelFails = cancelFails; self.failFirstRead = failFirstRead
    }
    func guiCapabilities() async throws -> JSONValue { .obj([]) }
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        switch command {
        case "ai.profiles.get": return .obj([("revision", .int(1))])
        case "ai.tests.start": return .obj([("operationId", .string("op"))])
        case "ai.operations.get":
            reads += 1
            if failFirstRead && reads == 1 { throw ContractError(.upstreamUnavailable, "status read failed") }
            let answered = failFirstRead ? reads - 1 : reads
            return .obj([("state", .string(answered <= runningReads ? "running" : "cancelled"))])
        case "ai.operations.cancel":
            if cancelFails { throw ContractError(.upstreamUnavailable, "cancel not delivered") }
            return .obj([("terminal", .bool(true)), ("state", .string("cancelled"))])
        default: throw ContractError(.internalError, "unexpected command")
        }
    }
}

/// Answers reads from a script (`nil` = a failed read; the last answer
/// repeats). Cancel can be held until the test releases it.
private actor ScriptClient: ContractClient {
    var reads = 0
    var cancels = 0
    var script: [String?]
    let cancelAnswer: JSONValue
    let cancelGate: PauseGate?
    /// Holds read number `readGate.0` until the test releases `readGate.1`.
    let readGate: (Int, PauseGate)?
    init(script: [String?], cancelAnswer: JSONValue, cancelGate: PauseGate? = nil, readGate: (Int, PauseGate)? = nil) {
        self.script = script; self.cancelAnswer = cancelAnswer; self.cancelGate = cancelGate; self.readGate = readGate
    }
    func guiCapabilities() async throws -> JSONValue { .obj([]) }
    func send(_ command: String, _ params: JSONValue, idempotencyKey: String?) async throws -> JSONValue {
        switch command {
        case "ai.profiles.get": return .obj([("revision", .int(1))])
        case "ai.tests.start": return .obj([("operationId", .string("op"))])
        case "ai.operations.get":
            reads += 1
            let next = script.count > 1 ? script.removeFirst() : script[0]
            if let (n, g) = readGate, n == reads { await g.pause() }
            guard let state = next else { throw ContractError(.upstreamUnavailable, "status read failed") }
            return .obj([("state", .string(state))])
        case "ai.operations.cancel":
            cancels += 1
            if let g = cancelGate { await g.pause() }
            return cancelAnswer
        default: throw ContractError(.internalError, "unexpected command")
        }
    }
}

private let notTerminal = JSONValue.obj([("terminal", .bool(false)), ("state", .string("cancelling"))])

@MainActor struct CapabilityPollingTests {
    @Test func cancelFromUnknownKeepsReadingUntilTheEnd() async {
        let client = ScriptClient(script: [nil, nil, nil, "cancelling", "cancelled"], cancelAnswer: notTerminal)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .unknown)
        await model.cancel()
        #expect(model.phase == .finished("cancelled"))
        #expect(!model.isPolling)
        #expect(model.canStart)
        #expect(await client.reads == 5)
    }
    @Test func lateCancelAnswerDoesNotOverwriteAnEndAlreadyRead() async {
        let gate = PauseGate()
        let client = ScriptClient(script: [nil, nil, nil, "succeeded"],
                                  cancelAnswer: .obj([("terminal", .bool(true)), ("state", .string("cancelled"))]),
                                  cancelGate: gate)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .unknown)
        let cancelling = Task { await model.cancel() }
        await gate.waitForPause(1)
        await model.poll()
        #expect(model.phase == .finished("succeeded"))
        await gate.release()
        await cancelling.value
        #expect(model.phase == .finished("succeeded"))
        #expect(model.canStart)
    }
    @Test func staleCancellingReadDoesNotUndoATerminalCancel() async {
        let readGate = PauseGate()
        // Read 2 leaves before the terminal cancel answer and comes back
        // "cancelling" after it; read 3 would be the end.
        let client = ScriptClient(script: ["running", "cancelling", "cancelled"],
                                  cancelAnswer: .obj([("terminal", .bool(true)), ("state", .string("cancelled"))]),
                                  readGate: (2, readGate))
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        let running = Task { await model.start() }
        await readGate.waitForPause(1)
        await model.cancel()
        #expect(model.phase == .finished("cancelled"))
        await readGate.release()
        await running.value
        #expect(model.phase == .finished("cancelled"))
        #expect(model.canStart)
        #expect(await client.reads == 2)
    }
    @Test func readFailuresAfterATerminalCancelKeepTheEnd() async {
        let pauses = PauseGate()
        let client = ScriptClient(script: ["running", nil],
                                  cancelAnswer: .obj([("terminal", .bool(true)), ("state", .string("cancelled"))]))
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: GateClock(gate: pauses))
        let running = Task { await model.start() }
        await pauses.waitForPause(1)
        await model.cancel()
        #expect(model.phase == .finished("cancelled"))
        await pauses.open()
        await running.value
        #expect(model.phase == .finished("cancelled"))
        #expect(model.problem == nil)
        #expect(!model.canCancel)
        #expect(model.canStart)
    }
    @Test func terminalCancelWaitsForTheOldLoopBeforeStartingAgain() async {
        let gate = PauseGate()
        let client = CancelClient(runningReads: 1, cancelFails: false)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: GateClock(gate: gate))
        let running = Task { await model.start() }
        await gate.waitForPause(1)
        await model.cancel()
        #expect(model.phase == .finished("cancelled"))
        #expect(model.isPolling)
        #expect(!model.canStart)
        await gate.release()
        await running.value
        #expect(!model.isPolling)
        #expect(model.canStart)
    }
    @Test func cancelErrorSurvivesASuccessfulStatusRead() async {
        let gate = PauseGate()
        let client = CancelClient(runningReads: 2, cancelFails: true)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: GateClock(gate: gate))
        let running = Task { await model.start() }
        await gate.waitForPause(1)
        await model.cancel()
        let cancelProblem = model.problem
        #expect(cancelProblem?.code == .upstreamUnavailable)
        await gate.release()
        await gate.waitForPause(2)
        #expect(model.problem == cancelProblem)
        await gate.release()
        await running.value
        #expect(model.phase == .finished("cancelled"))
        #expect(model.problem == cancelProblem)
    }

    @Test func transientReadFailureRecoversWithoutResubmission() async {
        let client = PollingClient(failures: 1)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .finished("cancelled"))
        #expect(model.problem == nil)
        #expect(await client.reads == 2)
    }
    @Test func repeatedReadFailureIsUnknownAndCanBeQueriedAgain() async {
        let client = PollingClient(failures: 3)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .unknown)
        #expect(!model.canStart)
        #expect(await client.reads == 3)
        await model.poll()
        #expect(model.phase == .finished("cancelled"))
        #expect(await client.reads == 4)
    }
    @Test func cancelErrorEqualToTheReadErrorSurvivesASuccessfulRead() async {
        let gate = PauseGate()
        let client = CancelClient(runningReads: 1, cancelFails: true, failFirstRead: true)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: GateClock(gate: gate))
        let running = Task { await model.start() }
        await gate.waitForPause(1)
        let readProblem = model.problem
        await model.cancel()
        let cancelProblem = model.problem
        #expect(cancelProblem != nil)
        #expect(cancelProblem == readProblem)
        await gate.release()
        await gate.waitForPause(2)
        #expect(model.problem == cancelProblem)
        await gate.release()
        await running.value
        #expect(model.phase == .finished("cancelled"))
        #expect(model.problem == cancelProblem)
    }
    @Test func unknownStatusStillAllowsCancel() async {
        let client = PollingClient(failures: 3)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        #expect(!model.canCancel)
        await model.start()
        #expect(model.phase == .unknown)
        #expect(model.canCancel)
    }
    @Test func cancelledPollingDoesNotClaimOperationCancelled() async {
        let client = PollingClient(failures: 0, cancellation: true)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .unknown)
        #expect(await client.reads == 1)
    }
}
