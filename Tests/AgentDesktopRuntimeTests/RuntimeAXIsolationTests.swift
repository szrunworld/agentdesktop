import AgentDesktopContracts
import Foundation
import Testing
@testable import AgentDesktopProtocol
@testable import AgentDesktopRuntime

// RT-23A/B (MAC-001): a slow or stuck accessibility read delays only the
// observation that asked for it. It never holds the Desktop's lock, never
// runs on the main thread, is bounded per Desktop and overall, and the
// observation still returns its screenshot, marked as such.

private func observe(_ sc: Scene, on c: ConnectionState? = nil) -> RuntimeResponse {
    call(sc.s, c ?? sc.c, "observe", context: #"{"sessionId":"\#(sc.session)"}"#)
}

@Test func aStuckReadReturnsTheScreenshotWithoutElementsInTime() throws {
    let sc = try scene()
    sc.s.elementReadBudget = 0.3
    let gate = DispatchSemaphore(value: 0)
    sc.platform.axGate = gate
    defer { sc.platform.axGate = nil; for _ in 0..<30 { gate.signal() } }
    let start = Date()
    let o = try #require(data(observe(sc)))
    #expect(Date().timeIntervalSince(start) < 1.5)
    #expect(contract.validate(o, "Observation").isEmpty, "\(o.encoded())")
    #expect(o["image"] != .null)
    #expect(o["elements"]?.arrayValue?.isEmpty == true)
    #expect(o["coverage"]?["ax"]?.stringValue == "unavailable")
    #expect(o["coverage"]?["axReason"]?.stringValue == "deadline")
    // Old element references are void; an image point still works, so the
    // Desktop's lock was not held by the read.
    let snap = try #require(o["snapshotId"]?.stringValue)
    #expect(code(act(sc, clickContinue, snapshot: sc.snapshot)) == "stale_observation")
    #expect(data(act(sc, #"{"kind":"click","target":{"imagePoint":{"x":100,"y":100}}}"#, snapshot: snap)) != nil)
}

@Test func twentyTimeoutsInARowStayBoundedAndOthersKeepWorking() throws {
    let sc = try scene()
    sc.s.elementReadBudget = 0.1
    let gate = DispatchSemaphore(value: 0)
    sc.platform.axGate = gate
    defer { sc.platform.axGate = nil; for _ in 0..<40 { gate.signal() } }
    var reasons: [String] = []
    for _ in 0..<20 {
        let start = Date()
        let o = try #require(data(observe(sc)))
        #expect(Date().timeIntervalSince(start) < 1)
        reasons.append(o["coverage"]?["axReason"]?.stringValue ?? "")
        // The rest of the Runtime answers at once.
        let t0 = Date()
        #expect(data(call(sc.s, sc.c, "runtime.status")) != nil)
        #expect(Date().timeIntervalSince(t0) < 0.5)
    }
    // One stuck read for the Desktop, never a pile of them.
    #expect(sc.platform.axPeak == 1)
    #expect(sc.s.axReader.activeReads <= 1)
    #expect(reasons.first == "deadline")
    #expect(reasons.dropFirst().allSatisfy { $0 == "busy" })
    #expect(sc.platform.axThreads.allSatisfy { $0.hasPrefix("agentdesktop.ax.") })
    // Once the app answers again, observations read elements again.
    sc.platform.axGate = nil
    gate.signal()
    var complete = false
    for _ in 0..<20 where !complete {
        complete = data(observe(sc))?["coverage"]?["ax"]?.stringValue == "complete"
        if !complete { Thread.sleep(forTimeInterval: 0.05) }
    }
    #expect(complete)
}

@Test func aStuckReadOnOneDesktopDoesNotDelayAnother() throws {
    let sc = try scene()
    sc.s.elementReadBudget = 0.5
    let c2 = handshaken(sc.s)
    let d2 = try created(sc.s, c2)
    let gate = DispatchSemaphore(value: 0)
    sc.platform.axGate = gate
    // Desktop A's read hangs on another connection.
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async { _ = observe(sc); done.signal() }
    Thread.sleep(forTimeInterval: 0.1)
    // Desktop B: a screenshot-only observation is not held up.
    let t0 = Date()
    let o = try #require(data(call(sc.s, c2, "observe", params: #"{"elements":false}"#, context: #"{"desktopId":"\#(d2)"}"#)))
    #expect(Date().timeIntervalSince(t0) < 0.3)
    #expect(o["coverage"]?["ax"]?.stringValue == "not_requested")
    sc.platform.axGate = nil
    for _ in 0..<5 { gate.signal() }
    done.wait()
}

@Test func aTruncatedWalkIsPartial() throws {
    let sc = try scene()
    sc.platform.axTruncated = "limits"
    let o = try #require(data(observe(sc)))
    #expect(o["coverage"]?["ax"]?.stringValue == "partial")
    #expect(o["coverage"]?["axReason"]?.stringValue == "limits")
    #expect(o["elements"]?.arrayValue?.isEmpty == false)
}

@Test func waitingForABusyDesktopEndsAtTheDeadlineAndSendsNothing() throws {
    let sc = try scene()
    let d = try #require(sc.s.desktops.find(sc.desktop))
    d.lock.lock()
    defer { d.lock.unlock() }
    let deadline = Timestamp.string(Date().addingTimeInterval(0.2))
    let start = Date()
    let r = act(sc, clickContinue, deadline: deadline)
    #expect(Date().timeIntervalSince(start) < 1)
    #expect(code(r) == "deadline_exceeded")
    #expect(failure(r)?.notSent == true)
    #expect(sc.platform.performed.isEmpty)
}

@Test func anAppThatDoesNotAnswerAccessibilityStillHasItsScreenshot() throws {
    let sc = try scene()
    sc.platform.axFailure = PlatformError(.refused, "Probe does not expose window 11 to accessibility")
    let o = try #require(data(observe(sc)))
    #expect(o["image"] != .null)
    #expect(o["coverage"]?["ax"]?.stringValue == "unavailable")
    #expect(o["coverage"]?["axReason"]?.stringValue == "error")
    // A missing permission is not papered over.
    sc.platform.axFailure = PlatformError(.permission, "needs the Accessibility permission")
    #expect(code(observe(sc)) == "permission_denied")
}
