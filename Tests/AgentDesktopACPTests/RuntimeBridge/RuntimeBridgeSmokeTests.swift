import AgentDesktopClient
import Foundation
import Testing
@testable import AgentDesktopACP

/// Read-only smoke against a Runtime this test launches and owns
/// (ACPTestRuntimeChild; ACP_TEST_RUNTIME_BINARY = a built AgentDesktopApp):
/// caller, tasks and a snapshot of an unknown Run, then the child-identity
/// cases on a real Runtime.
@Suite(.enabled(if: ACPTestRuntimeChild.binary != nil), .serialized) struct RuntimeBridgeSmokeTests {
    @Test func callerTasksSnapshotReadOnly() async throws {
        let child = try await offPool { try ACPTestRuntimeChild.launchRuntime() }
        defer { child.stop() }
        let port = ACPBridgeRuntimePort(
            makeClient: try ACPTestPinnedTransport.verifiedFactory(child: child, name: "agentdesktop-acp-smoke"),
            log: try ACPSubmissionLog(path: RTest.tempLogPath()))
        let caller = try await port.caller()
        let tasks = try await port.tasks()
        var snapshotReason = "none"
        do { _ = try await port.snapshot(runId: "run_does_not_exist") } catch let e as ACPError { snapshotReason = e.reason }
        print("RTEST_SMOKE child=\(child.pid) caller=\(caller) tasks=\(tasks.map(\.taskType)) snapshot(unknown)=\(snapshotReason)")
        #expect(caller.principalId == "local:\(getuid())")
        #expect(snapshotReason == "not_found")
        await port.connectionLost()
    }

    @Test func aRealRuntimeThatExitedCannotBeImpersonatedOnItsPath() async throws {
        let (firstOK, refused, bytes) = try await offPool { () -> (Bool, Bool, Int) in
            let child = try ACPTestRuntimeChild.launchRuntime()
            defer { child.stop() }
            // Works while it runs…
            let ok = try ACPTestPinnedTransport(path: child.runtimeEndpoint, timeout: 5, child: child)
            ok.close()
            // …then it exits and this process takes over the same path.
            child.terminate(reap: true)
            unlink(child.runtimeEndpoint)
            let impostor = try CurPinnedTransportTests.Listener(path: child.runtimeEndpoint)
            var refused = false
            do { _ = try ACPTestPinnedTransport(path: child.runtimeEndpoint, timeout: 1, child: child) }
            catch { refused = error is ACPTestPinnedTransport.Refused }
            return (true, refused, impostor.bytesAfterClose())
        }
        #expect(firstOK)
        #expect(refused)
        #expect(bytes == 0)
    }
}
