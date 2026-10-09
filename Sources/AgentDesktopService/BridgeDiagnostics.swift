import Foundation

/// Test-only timeline of `RuntimeBridge.answer` (#166): when a call entered
/// the bridge, when its task was created and started, when the connection
/// thread began to wait, and how the wait ended. Internal: only a test that
/// imports the service with `@testable` can hand one to the bridge; the
/// product never does, and with none the bridge does what it always did.
///
/// It records the method name only: no params, no requestId, no credential.
///
/// The task's own stages are only appended to memory: `onEvent` (which may
/// write to stderr) is called on the connection thread, never on the
/// cooperative thread whose availability is what the timeline measures, and
/// never before the waiter is signalled (b9 and Codex on 062f5db).
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
        /// The service answered and the waiter was signalled.
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
    private var reported = 0
    private let onEvent: (@Sendable (Event) -> Void)?

    init(onEvent: (@Sendable (Event) -> Void)? = nil) { self.onEvent = onEvent }

    var events: [Event] { lock.withLock { recorded } }

    /// One call's stages.
    struct Trace: Sendable {
        let recorder: BridgeDiagnostics
        let call: UInt64
        let method: String

        /// On the connection thread: noted, and everything not yet passed
        /// to `onEvent` is passed now, in order.
        func note(_ stage: Stage) { recorder.note(call, stage, method: method, report: true) }

        /// On the task: noted in memory only.
        func noteInTask(_ stage: Stage, taskPriority: UInt8? = nil) {
            recorder.note(call, stage, method: method, taskPriority: taskPriority, report: false)
        }
    }

    /// A new call, with `entered` noted.
    func begin(method: String) -> Trace {
        let call = lock.withLock { () -> UInt64 in nextCall += 1; return nextCall }
        note(call, .entered, method: method, report: true)
        return Trace(recorder: self, call: call, method: method)
    }

    private func note(_ call: UInt64, _ stage: Stage, method: String, taskPriority: UInt8? = nil, report: Bool) {
        let now = DispatchTime.now().uptimeNanoseconds
        var tid: UInt64 = 0
        pthread_threadid_np(nil, &tid)
        let due = lock.withLock { () -> ArraySlice<Event> in
            if stage == .entered { entered[call] = now }
            let start = entered[call] ?? now
            recorded.append(Event(call: call, stage: stage, method: method, uptimeNanos: now, sinceEnteredNanos: now &- start,
                                  threadId: tid, mainThread: Thread.isMainThread, taskPriority: taskPriority))
            guard report, onEvent != nil else { return [] }
            defer { reported = recorded.count }
            return recorded[reported...]
        }
        for e in due { onEvent?(e) }
    }
}
