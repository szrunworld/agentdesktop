import AgentDesktopClient
import Foundation
import Testing
@testable import AgentDesktopACP

/// Read-only smoke against a real side instance. Runs only when
/// RTEST_SMOKE_ENDPOINT names a test copy's Runtime socket (never the
/// product endpoint): caller, tasks and a snapshot of an unknown Run.
@Suite(.enabled(if: RTestSmoke.endpoint != nil)) struct RuntimeBridgeSmokeTests {
    @Test func callerTasksSnapshotReadOnly() async throws {
        let path = try #require(RTestSmoke.endpoint)
        #expect(!path.contains("/Library/Application Support/AgentDesktop/"))
        let port = ACPBridgeRuntimePort(
            makeClient: ACPBridgeConfiguration.socketFactory(endpoint: Endpoint(path: path, source: .environment)),
            log: try ACPSubmissionLog(path: RTest.tempLogPath()))
        let caller = try await port.caller()
        let tasks = try await port.tasks()
        var snapshotReason = "none"
        do { _ = try await port.snapshot(runId: "run_does_not_exist") } catch let e as ACPError { snapshotReason = e.reason }
        print("RTEST_SMOKE caller=\(caller) tasks=\(tasks.map(\.taskType)) snapshot(unknown)=\(snapshotReason)")
        #expect(caller.principalId == "local:\(getuid())")
        #expect(snapshotReason == "not_found")
        await port.connectionLost()
    }
}

enum RTestSmoke {
    static var endpoint: String? {
        ProcessInfo.processInfo.environment["RTEST_SMOKE_ENDPOINT"].flatMap { $0.isEmpty ? nil : $0 }
    }
}
