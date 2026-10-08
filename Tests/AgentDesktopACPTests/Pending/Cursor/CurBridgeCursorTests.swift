import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// Layer: Mock. `ACPBridgeRuntimePort` against `CurTestWire` (a fake
/// runtime/1). These prove the bridge's side of the cursor only: it resumes
/// after the last sequence it delivered, drops repeats and foreign frames,
/// maps cursor errors without retrying, and reads `lastEventSequence` only
/// when the Runtime sends it. Passing says nothing about the Runtime cursor
/// itself (docs/acp/11-run-cursor.md §五).
@Suite struct CurBridgeCursorTests {
    @Test("[Mock] bridge drops repeated and older sequences from a sloppy source (CUR-M01)")
    func dropsRepeatedAndOlderSequences() async throws {
        let wire = CurTestWire()
        wire.addRun("r1")
        for _ in 1...5 { wire.emit("r1") }
        wire.end("r1")
        wire.ignoreAfter = true
        wire.repeatFrames = true
        let port = try CurTestBridge.port(wire)
        let (events, error) = await CurTestBridge.drain(port.events(runId: "r1", after: 2))
        #expect(error == nil)
        #expect(events.map(\.cursor) == [3, 4, 5])
        #expect(wire.subscribeAfters() == [2])
        await port.connectionLost()
    }

    @Test("[Mock] after a dropped subscription the bridge resubscribes from the last delivered sequence (CUR-M02)")
    func resubscribesFromLastDelivered() async throws {
        let wire = CurTestWire()
        wire.addRun("r1")
        for _ in 1...6 { wire.emit("r1") }
        wire.dropAfterFrames = 2
        wire.dropsLeft = 1
        let port = try CurTestBridge.port(wire)
        let stream = port.events(runId: "r1", after: nil)
        // The Run ends once the first subscription dropped; the rest comes
        // from the drain (run.events) or a second subscription.
        let collector = Task { await CurTestBridge.drain(stream) }
        #expect(await sEventually { wire.methods().contains("run.events") || wire.subscribeAfters().count > 1 })
        wire.end("r1")
        let (events, error) = await collector.value
        #expect(error == nil)
        #expect(events.map(\.cursor) == [1, 2, 3, 4, 5, 6])
        // First subscription from 0; every later read starts after 2, never earlier.
        #expect(wire.subscribeAfters().first == 0)
        let laterAfters = wire.with { wire.calls.dropFirst().compactMap(\.after) }
        #expect(laterAfters.allSatisfy { $0 >= 2 })
        await port.connectionLost()
    }

    @Test("[Mock] frames naming another Run never reach the session (CUR-M03)")
    func dropsForeignFrames() async throws {
        let wire = CurTestWire()
        wire.addRun("mine")
        wire.emit("mine"); wire.emit("mine")
        wire.end("mine")
        wire.foreignFrames = [CurTestWire.event("theirs", 1), CurTestWire.event("theirs", 99)]
        let port = try CurTestBridge.port(wire)
        let (events, error) = await CurTestBridge.drain(port.events(runId: "mine", after: nil))
        #expect(error == nil)
        #expect(events.map(\.runId) == ["mine", "mine"])
        #expect(events.map(\.cursor) == [1, 2])
        await port.connectionLost()
    }

    @Test("[Mock] events_cursor_expired ends the stream with that reason, once, without retry (CUR-M04)")
    func cursorExpiredIsMappedNotRetried() async throws {
        let wire = CurTestWire()
        wire.addRun("r1", phase: "ended")
        wire.subscribeError = RuntimeError("events_cursor_expired", "cursor 3 is outside the stored events",
                                           phase: .handler, details: .obj([("latest", .int(9))]))
        let port = try CurTestBridge.port(wire)
        let (events, error) = await CurTestBridge.drain(port.events(runId: "r1", after: 3))
        #expect(events.isEmpty)
        let e = try #require(error as? ACPError)
        #expect(e.reason == "events_cursor_expired")
        #expect(e.code == ACPBridgeErrors.runtimeErrorCode)
        #expect(wire.subscribeAfters() == [3])
        // Nothing else was asked: no fallback that could resend work.
        #expect(Set(wire.methods()) == ["events.subscribe"])
        await port.connectionLost()
    }

    @Test("[Mock] a Run the caller cannot see ends the stream with not_found, no retry (CUR-M05)")
    func unknownRunIsNotFound() async throws {
        let wire = CurTestWire()
        let port = try CurTestBridge.port(wire)
        let (events, error) = await CurTestBridge.drain(port.events(runId: "someone-elses", after: 0))
        #expect(events.isEmpty)
        #expect((error as? ACPError)?.reason == "not_found")
        #expect(wire.subscribeAfters() == [0])
        await port.connectionLost()
    }

    @Test("[Mock] snapshot reads lastEventSequence only when the Runtime sends it (CUR-M06)")
    func snapshotLastCursorOnlyWhenPresent() async throws {
        let wire = CurTestWire()
        wire.addRun("absent")
        wire.emit("absent"); wire.emit("absent")
        wire.addRun("zero")
        wire.lastEventSequenceOverride["zero"] = 0
        wire.addRun("seven")
        wire.lastEventSequenceOverride["seven"] = 7
        let port = try CurTestBridge.port(wire)
        // Today's Runtime: absent → nil. The bridge does not count events itself.
        #expect(try await port.snapshot(runId: "absent").lastCursor == nil)
        #expect(try await port.snapshot(runId: "zero").lastCursor == 0)
        #expect(try await port.snapshot(runId: "seven").lastCursor == 7)
        #expect(!wire.methods().contains("run.events"))
        await port.connectionLost()
    }

    @Test("[Mock] after the control connection is lost: no stream, no submit, nothing restarted (CUR-M07)")
    func noResumeAfterConnectionLost() async throws {
        let wire = CurTestWire()
        wire.addRun("delegated")
        wire.emit("delegated")
        let port = try CurTestBridge.port(wire)
        await port.connectionLost()
        let connectionsBefore = wire.with { wire.connections }
        let (events, error) = await CurTestBridge.drain(port.events(runId: "delegated", after: 0))
        #expect(events.isEmpty)
        #expect((error as? ACPError)?.reason == "connection_lost")
        let receipt = try await port.submit(ACPSubmission(submissionKey: "k", acpSessionId: "s", taskType: "unit.run",
                                                          input: .obj([]), desktopId: nil))
        guard case let .refused(code, _) = receipt else { Issue.record("submit went through: \(receipt)"); return }
        #expect(code == "connection_lost")
        #expect(wire.with { wire.connections } == connectionsBefore)
        let methods = Set(wire.methods())
        #expect(methods.isDisjoint(with: ["unit.run", "run.start", "run.attach", "run.cancel"]))
    }
}
