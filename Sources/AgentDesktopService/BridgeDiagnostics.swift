import Foundation

/// Test-only timeline of `RuntimeBridge.answer` (#166): when a call entered
/// the bridge, when its task was created and started, when the connection
/// thread began to wait, and how the wait ended. Internal: only a test that
/// imports the service with `@testable` can hand one to the bridge; the
/// product never does, and with none the bridge does what it always did.
///
/// It records the method name only: no params, no requestId, no credential.
///
/// Every stage is only appended to memory when it happens; the bridge
/// never calls `onEvent` (which may write to stderr). A call's stages are
/// handed to `onEvent` on the recorder's own serial queue, asynchronously,
/// once that call's own wait has ended (`answered` or `timedOut`), and its
/// later stages as they come. So the hook never runs on the cooperative
/// thread the timeline measures, never delays the signal, the wait or the
/// reply, and never shows a call whose wait is still on (Codex on 062f5db,
/// 53dc980 and 42108c5; b9).
final class BridgeDiagnostics: @unchecked Sendable {
    enum Stage: String, Sendable {
        /// `answer` was called (on the connection thread).
        case entered
        /// The service task was created (noted after `Task.detached` returns,
        /// so a task that starts at once can note `taskStarted` first).
        case taskCreated
        /// The connection thread starts waiting for the task.
        case waitStarted
        /// The task began to run (on a cooperative thread).
        case taskStarted
        /// The service answered; the task is about to signal (noted in
        /// memory only, so it delays the signal by an append).
        case resultReady
        /// The wait ended with the service's answer.
        case answered
        /// The wait ended without one.
        case timedOut
    }

    struct Event: Sendable, CustomStringConvertible {
        /// Which call: one number per `answer`, from this recorder.
        let call: UInt64
        let stage: Stage
        let method: String
        /// Monotonic (`DispatchTime`, not the wall clock).
        let uptimeNanos: UInt64
        /// Since this call's `entered`, monotonic.
        let sinceEnteredNanos: UInt64
        /// The kernel's id of the thread the stage ran on, to match a
        /// `sample` of the process.
        let threadId: UInt64
        let mainThread: Bool
        /// The task's priority, at `taskStarted` only.
        let taskPriority: UInt8?

        var description: String {
            let ms = { (n: UInt64) in String(format: "%.1f", Double(n) / 1_000_000) }
            return "BRIDGE-DIAG call=\(call) stage=\(stage.rawValue) method=\(method) +\(ms(sinceEnteredNanos))ms"
                + " uptime=\(ms(uptimeNanos))ms thread=0x\(String(threadId, radix: 16))\(mainThread ? " main" : "")"
                + (taskPriority.map { " priority=\($0)" } ?? "")
        }
    }

    private let lock = NSLock()
    private var nextCall: UInt64 = 0
    private var entered: [UInt64: UInt64] = [:]
    private var recorded: [Event] = []
    /// Per call: stages not yet handed to `onEvent`, and whether its wait ended.
    private var unreported: [UInt64: [Event]] = [:]
    private var waitEnded: Set<UInt64> = []
    private let onEvent: (@Sendable (Event) -> Void)?
    private let reports = DispatchQueue(label: "agentdesktop.bridge.diagnostics")
    private static let reportsKey = DispatchSpecificKey<Bool>()

    init(onEvent: (@Sendable (Event) -> Void)? = nil) {
        self.onEvent = onEvent
        reports.setSpecific(key: Self.reportsKey, value: true)
    }

    /// Tests: whether the caller runs on a recorder's report queue.
    static var onReportQueue: Bool { DispatchQueue.getSpecific(key: reportsKey) == true }

    /// Tests: returns once every report queued so far has been handed on.
    func waitForReports() { reports.sync {} }

    var events: [Event] { lock.withLock { recorded } }

    /// Tests: the events noted after the first `count` (an incremental read,
    /// so a watcher copies only what is new while it holds the lock).
    func events(after count: Int) -> [Event] {
        lock.withLock { count < recorded.count ? Array(recorded[max(0, count)...]) : [] }
    }

    /// One call's stages.
    struct Trace: Sendable {
        let recorder: BridgeDiagnostics
        let call: UInt64
        let method: String

        /// On the connection thread.
        func note(_ stage: Stage) { recorder.note(call, stage, method: method) }

        /// On the task.
        func noteInTask(_ stage: Stage, taskPriority: UInt8? = nil) {
            recorder.note(call, stage, method: method, taskPriority: taskPriority)
        }
    }

    /// A new call, with `entered` noted.
    func begin(method: String) -> Trace {
        let call = lock.withLock { () -> UInt64 in nextCall += 1; return nextCall }
        note(call, .entered, method: method)
        return Trace(recorder: self, call: call, method: method)
    }

    private func note(_ call: UInt64, _ stage: Stage, method: String, taskPriority: UInt8? = nil) {
        let now = DispatchTime.now().uptimeNanoseconds
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        lock.withLock {
            if stage == .entered { entered[call] = now }
            let start = entered[call] ?? now
            let e = Event(call: call, stage: stage, method: method, uptimeNanos: now, sinceEnteredNanos: now &- start,
                          threadId: tid, mainThread: Thread.isMainThread, taskPriority: taskPriority)
            recorded.append(e)
            guard let onEvent else { return }
            unreported[call, default: []].append(e)
            if stage == .answered || stage == .timedOut { waitEnded.insert(call) }
            guard waitEnded.contains(call), let due = unreported.removeValue(forKey: call) else { return }
            // Queued under the lock (Codex on a756034, b9): a call's batches
            // reach the hook in the order they were noted. `async` never
            // waits, so the lock is held no longer.
            reports.async { for e in due { onEvent(e) } }
        }
    }
}
