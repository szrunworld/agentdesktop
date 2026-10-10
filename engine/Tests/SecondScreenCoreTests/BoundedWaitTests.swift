import Darwin
import Foundation
import Testing
@testable import EngineTestSupport

// The waits with deadlines the engine tests use (#183): they return when the
// awaited thing happens, and when it does not, they fail with what was
// awaited, the stage, how long, and evidence; a timeout is never a pass.

/// Runs a blocking self-test body on a thread of its own: these waits block
/// on purpose, and on the cooperative pool (one thread under the strict
/// pool) they would starve the rest of the run.
private func offPool<T>(_ body: @escaping () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { c in
        Thread { c.resume(with: Result { try body() }) }.start()
    }
}

@Suite struct BoundedWaitTests {
    @Test func aSignalledWaitReturns() throws {
        // (Created at 0 and signalled: a semaphore released below the value
        // it was created with is a libdispatch trap.)
        let s = DispatchSemaphore(value: 0)
        s.signal()
        try Bounded.wait(s, 30, for: "a signal already given", stage: "start")
    }

    @Test func aWaitThatRunsOutFailsWithWhatItWaitedForAndEvidence() async throws {
        try await offPool {
            let s = DispatchSemaphore(value: 0)
            let start = Date()
            do {
                try Bounded.wait(s, 0.2, for: "a signal never given", stage: "the only stage")
                Issue.record("a wait that ran out returned")
            } catch let e as WaitTimedOut {
                #expect(e.what == "a signal never given")
                #expect(e.stage == "the only stage")
                #expect(e.description.contains("timed out after 0.2 s waiting for a signal never given"))
                let note = String(e.evidence.split(separator: ",")[0])
                let text = try String(contentsOfFile: note.components(separatedBy: " (")[0], encoding: .utf8)
                #expect(text.contains("waiting for: a signal never given"))
                #expect(e.evidence.contains("-sample.txt"), "\(e.evidence)")
            }
            #expect(Date().timeIntervalSince(start) >= 0.2)
        }
    }

    @Test func aFailedSampleNeverHidesTheTimeout() {
        // The test still fails for the wait; the evidence says the collection
        // failed and why.
        let e = Bounded.timedOut("x", "y", 0.1, sampler: "/nonexistent/sample")
        #expect(e.description.hasPrefix("timed out after 0.1 s waiting for x (stage: y)"))
        #expect(e.evidence.contains("sample collection failed"), "\(e.evidence)")
    }

    @Test func aQueueThatNeverDrainsFailsTheSync() async throws {
        try await offPool {
            let queue = DispatchQueue(label: "bounded-sync-test")
            let release = DispatchSemaphore(value: 0)
            queue.async { _ = release.wait(timeout: .now() + 30) }
            defer { release.signal() }
            #expect(throws: WaitTimedOut.self) {
                try Bounded.sync(queue, 0.2, for: "the queue to drain", stage: "blocked")
            }
            release.signal()
            try Bounded.sync(queue, 30, for: "the queue to drain", stage: "released")
        }
    }
}
