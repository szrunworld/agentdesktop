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

@MainActor struct CapabilityPollingTests {
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
    @Test func cancelledPollingDoesNotClaimOperationCancelled() async {
        let client = PollingClient(failures: 0, cancellation: true)
        let model = CapabilityTestModel(client: client, guiProfileId: "p", clock: FastClock())
        await model.start()
        #expect(model.phase == .unknown)
        #expect(await client.reads == 1)
    }
}
