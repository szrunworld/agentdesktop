import AgentDesktopAI
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopService

// A4 R4: what a revoked client started in the AI service stops; nobody
// else's work is touched.

@Test func aRevokedClientsAIOperationsAreCancelledAndOthersAreNot() async throws {
    var template = Array("/tmp/adt-XXXXXX".utf8CString)
    let dir = String(cString: mkdtemp(&template)!)
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let service = try await AgentDesktopService.open(AgentDesktopServiceOptions(
        databasePath: dir + "/ai.sqlite", credentials: InMemoryCredentialStore()))
    let theirs = try await service.store.createOperation(kind: .modelRefresh, callerScope: "app:revoked", resourceId: "conn_1", resourceRevision: 1)
    let alsoTheirs = try await service.store.createOperation(kind: .capabilityTest, callerScope: "app:revoked", resourceId: "prof_1", resourceRevision: 1)
    let someoneElses = try await service.store.createOperation(kind: .modelRefresh, callerScope: "app:other", resourceId: "conn_2", resourceRevision: 1)
    let owners = try await service.store.createOperation(kind: .modelRefresh, callerScope: "uid:501", resourceId: "conn_3", resourceRevision: 1)
    await service.accessWithdrawn(clientId: "app:revoked")
    #expect(try await service.store.operationState(theirs) == .cancelled)
    #expect(try await service.store.operationState(alsoTheirs) == .cancelled)
    #expect(try await service.store.operationState(someoneElses) == .queued)
    #expect(try await service.store.operationState(owners) == .queued)
}
