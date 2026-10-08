import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// Layer: Real (written, NOT RUN). Against a real Runtime on a side
/// instance (CURTEST_REAL_ENDPOINT, a test copy's socket under /tmp/adt-*,
/// never the product endpoint) with a prepared ended Run
/// (CURTEST_REAL_RUN_ID, at least three events).
///
/// Every test is disabled until the Runtime owner ships the cursor contract
/// (07 R10 `Run.lastEventSequence`, 11-run-cursor.md §四 P1–P5). Enabling
/// them is the Runtime owner's and the coordinator's call, not this
/// workpack's; until they pass on a real instance the cursor is not done.
@Suite(.enabled(if: CurTestReal.endpoint != nil)) struct CurRealRuntimeCursorTests {
    @Test("[Real · not run] run.show carries lastEventSequence equal to the last stored sequence (CUR-R01, P1)",
          .disabled(.init(rawValue: CurTestReal.waiting)))
    func runShowCarriesLastEventSequence() throws {
        let runId = try #require(CurTestReal.endedRunId)
        let client = try CurTestReal.factory()(.control)
        defer { client.close() }
        _ = try client.handshake()
        let run = try client.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))
        let events = try CurTestReal.allEvents(client, runId)
        let last = try #require(run["lastEventSequence"]?.intValue)
        #expect(last == events.last?["sequence"]?.intValue)
        // P2: sequences are 1…N without holes.
        let seqs = events.compactMap { $0["sequence"]?.intValue }
        #expect(seqs == Array(1...max(seqs.count, 1)).prefix(seqs.count).map { $0 })
    }

    @Test("[Real · not run] subscribing at lastEventSequence of an ended Run delivers nothing and closes (CUR-R02, P4)",
          .disabled(.init(rawValue: CurTestReal.waiting)))
    func subscribeAtLastDeliversNothing() throws {
        let runId = try #require(CurTestReal.endedRunId)
        let make = try CurTestReal.factory()
        let control = make(.control)
        defer { control.close() }
        _ = try control.handshake()
        let last = try #require(try control.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))["lastEventSequence"]?.intValue)
        let events = make(.events)
        defer { events.close() }
        _ = try events.handshake()
        _ = try events.subscribe(runId: runId, after: last)
        var frames = 0
        loop: for _ in 0..<200 {
            switch try events.nextEvent() {
            case .frame: frames += 1
            case .idle: continue
            case .closed: break loop
            }
        }
        #expect(frames == 0)
    }

    @Test("[Real · not run] a per-Run cursor ahead of lastEventSequence is refused with events_cursor_expired (CUR-R03, P3)",
          .disabled(.init(rawValue: CurTestReal.waiting)))
    func cursorAheadIsRefused() throws {
        let runId = try #require(CurTestReal.endedRunId)
        let make = try CurTestReal.factory()
        let control = make(.control)
        defer { control.close() }
        _ = try control.handshake()
        let last = try #require(try control.call(RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])))["lastEventSequence"]?.intValue)
        let events = make(.events)
        defer { events.close() }
        _ = try events.handshake()
        do {
            _ = try events.subscribe(runId: runId, after: last + 1000)
            Issue.record("a cursor ahead of the Run was accepted")
        } catch let e as RuntimeError {
            #expect(e.code == "events_cursor_expired")
            #expect(e.details?["lastEventSequence"]?.intValue == last)
        }
        do {
            _ = try control.call(RuntimeRequest(.runEvents, params: .obj([("runId", .string(runId)), ("after", .int(last + 1000))])))
            Issue.record("run.events accepted a cursor ahead of the Run")
        } catch let e as RuntimeError {
            #expect(e.code == "events_cursor_expired")
        }
    }

    @Test("[Real · not run] the bridge resumes from a mid cursor with no loss and no repeat (CUR-R04)",
          .disabled(.init(rawValue: CurTestReal.waiting)))
    func bridgeResumesFromMidCursor() async throws {
        let runId = try #require(CurTestReal.endedRunId)
        let port = try CurTestReal.port()
        let snap = try await port.snapshot(runId: runId)
        let last = try #require(snap.lastCursor)
        try #require(last >= 3)
        let mid = last / 2
        let (events, error) = await CurTestBridge.drain(port.events(runId: runId, after: mid), limit: 10_000)
        #expect(error == nil)
        #expect(events.map(\.cursor) == Array((mid + 1)...last))
        await port.connectionLost()
    }

    @Test("[Real · not run] session/load replays exactly lastEventSequence events before the answer (CUR-R05)",
          .disabled(.init(rawValue: CurTestReal.waiting)))
    func loadReplaysUpToLastCursorBeforeAnswer() async throws {
        let runId = try #require(CurTestReal.endedRunId)
        let port = try CurTestReal.port()
        let last = try #require(try await port.snapshot(runId: runId).lastCursor)
        let caller = try await port.caller()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("curtest-real-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ACPFileSessionStore(directory: dir)
        try store.save(ACPSessionBinding(acpSessionId: "s1", principalId: caller.principalId, clientId: caller.clientId,
                                         cwd: "/tmp/p", title: "t", runIds: [runId], lastCursor: [:], options: [],
                                         createdAt: "2026-10-08T00:00:00Z", updatedAt: "2026-10-08T00:00:00Z", revision: 1))
        let connection = STestConnection()
        let server = ACPAgentServer(connection: connection, runtime: port, projector: STestProjector(), store: store)
        let task = Task { await server.run() }
        connection.request(1, .resumeSession(sessionId: "s1", cwd: nil, replay: true))
        guard case .resumed? = await connection.waitReply(1) else { Issue.record("not loaded"); return }
        // STestProjector turns every non-text event into one thought.
        let thoughts = connection.updatesBeforeReply(1, "s1").filter { if case .agentThought = $0 { return true }; return false }
        #expect(thoughts.count == last)
        connection.close()
        await task.value
    }

    @Test("[Real · not run] another client cannot read this Run's events by runId (CUR-R06, ACP-31-03)",
          .disabled("waiting for Run.lastEventSequence / cursor contract and A4: a second, paired identity (07 R4)"))
    func otherClientCannotReadEvents() throws {
        let runId = try #require(CurTestReal.endedRunId)
        // A4: the paired test identity's endpoint/credential; not available before PR3.
        let otherEndpoint = try CurTestReal.checkedEndpoint(try #require(ProcessInfo.processInfo.environment["CURTEST_REAL_OTHER_ENDPOINT"]))
        let other = ACPBridgeConfiguration.socketFactory(endpoint: Endpoint(path: otherEndpoint, source: .environment))
        let c = other(.events)
        defer { c.close() }
        _ = try c.handshake()
        for request in [RuntimeRequest(.runShow, params: .obj([("runId", .string(runId))])),
                        RuntimeRequest(.runEvents, params: .obj([("runId", .string(runId)), ("after", .int(0))]))] {
            do {
                _ = try c.call(request)
                Issue.record("\(request.method) answered for another client's Run")
            } catch let e as RuntimeError {
                #expect(e.code == "not_found")
            }
        }
        do {
            _ = try c.subscribe(runId: runId, after: 0)
            Issue.record("events.subscribe opened another client's Run")
        } catch let e as RuntimeError {
            #expect(e.code == "not_found")
        }
    }

    @Test("[Real · not run] a Delegated Run ended by disconnect stays ended after reconnect; no new Run (CUR-R07, ACP-30-01/02)",
          .disabled("waiting for Run.lastEventSequence / cursor contract and A6 unit.run (07 R1): ACP cannot start a Run today"))
    func delegatedRunNotResumedAfterReconnect() async throws {
        let first = try CurTestReal.port()
        let receipt = try await first.submit(ACPSubmission(submissionKey: "curtest-r07-\(UUID().uuidString)", acpSessionId: "s1",
                                                           taskType: "unit.run", input: RTest.validInput, desktopId: nil))
        guard case let .accepted(run) = receipt else { Issue.record("not accepted: \(receipt)"); return }
        await first.connectionLost()
        let second = try CurTestReal.port()
        // Bounded wait for owner_lost to finish the Run.
        var snap = try await second.snapshot(runId: run.runId)
        for _ in 0..<100 where snap.phase != "ended" {
            try await Task.sleep(for: .milliseconds(100))
            snap = try await second.snapshot(runId: run.runId)
        }
        #expect(snap.phase == "ended")
        #expect(snap.lifetime == "connection_scoped")
        let last = try #require(snap.lastCursor)
        // Reading after the end delivers nothing new and starts nothing.
        let (events, error) = await CurTestBridge.drain(second.events(runId: run.runId, after: last))
        #expect(error == nil && events.isEmpty)
        #expect(try await second.snapshot(runId: run.runId).lastCursor == last)
        await second.connectionLost()
    }
}
