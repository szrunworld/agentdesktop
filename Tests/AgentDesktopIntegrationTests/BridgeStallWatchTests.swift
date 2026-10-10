@testable import AgentDesktopService
import Foundation
import Testing

// #166: the stall watch decides from the bridge timelines alone, on a clock
// the test sets: no thread, no sampling, nothing left to scheduling.

private final class Clock: @unchecked Sendable {
    let lock = NSLock(); var at: UInt64 = 0
    func get() -> UInt64 { lock.withLock { at } }
    func set(_ v: UInt64) { lock.withLock { at = v } }
}

private func watch(_ clock: Clock, maxCaptures: Int = 5) -> BridgeStallWatch {
    BridgeStallWatch(after: 2, spacing: 3, maxCaptures: maxCaptures, now: { clock.get() }, capture: { _, _, _ in })
}

/// A call whose task was created (and, if `started`, began); its creation time.
private func created(_ r: BridgeDiagnostics, started: Bool = false) -> UInt64 {
    let t = r.begin(method: "ai.connections.list")
    t.note(.taskCreated)
    if started { t.noteInTask(.taskStarted, taskPriority: 21) }
    return r.events.last { $0.stage == .taskCreated }!.uptimeNanos
}

private let second: UInt64 = 1_000_000_000

@Test func aTaskWaitingPastTwoSecondsIsCapturedOnce() {
    let clock = Clock(), r = BridgeDiagnostics(), w = watch(clock)
    w.watch(r, label: "a")
    let t0 = created(r)
    clock.set(t0 + 2 * second)
    #expect(w.due() == nil, "two seconds is not past two seconds")
    clock.set(t0 + 2 * second + 1)
    let d = w.due()
    #expect(d?.stalls.map(\.call) == [1] && d?.index == 1)
    #expect(d?.stalls.first?.waitedNanos == 2 * second + 1)
    clock.set(t0 + 10 * second)
    #expect(w.due() == nil, "the same stall is captured once")
}

@Test func aStartedTaskIsNeverAStall() {
    let clock = Clock(), r = BridgeDiagnostics(), w = watch(clock)
    w.watch(r, label: "a")
    let t0 = created(r, started: true)
    clock.set(t0 + 60 * second)
    #expect(w.waiting().isEmpty && w.due() == nil)
}

@Test func capturesAreSpacedAndCapped() {
    let clock = Clock(), r = BridgeDiagnostics(), w = watch(clock, maxCaptures: 2)
    w.watch(r, label: "a")
    let t0 = created(r)
    clock.set(t0 + 3 * second)
    #expect(w.due()?.index == 1)
    _ = created(r)                                   // a second stall
    let t1 = r.events.last { $0.stage == .taskCreated }!.uptimeNanos
    clock.set(max(t0 + 5 * second, t1 + 3 * second))
    #expect(w.due() == nil, "within three seconds of the last capture")
    clock.set(max(t0 + 6 * second + 1, t1 + 3 * second))
    #expect(w.due()?.index == 2)
    _ = created(r)
    let t2 = r.events.last { $0.stage == .taskCreated }!.uptimeNanos
    clock.set(t2 + 30 * second)
    #expect(w.due() == nil, "at most two captures here")
}

@Test func everyWaitingTaskIsListedWithTheCapture() {
    let clock = Clock(), a = BridgeDiagnostics(), b = BridgeDiagnostics(), w = watch(clock)
    w.watch(a, label: "a")
    w.watch(b, label: "b")
    let t0 = created(a)
    _ = created(b, started: true)
    let t1 = created(b)
    clock.set(max(t0, t1) + 1 * second)
    #expect(w.due() == nil)
    clock.set(t0 + 2 * second + 1)
    let d = w.due()
    #expect(d?.stalls.map(\.label) == ["a"] || d?.stalls.count == 2)
    #expect(Set(d?.waiting.map { "\($0.label)#\($0.call)" } ?? []) == ["a#1", "b#2"])
}
