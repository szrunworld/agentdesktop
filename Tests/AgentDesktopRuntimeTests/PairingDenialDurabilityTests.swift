import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopRuntime

struct PairingDenialDurabilityTests {
    @Test(arguments: [false, true])
    func failedDenialIsUnknownAndRollsBack(rejectAudit: Bool) throws {
        let dir = try socketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hub.sqlite"
        let hub = try HubStore(path: path)
        let identity = RuntimeIdentity(instanceId: "denial", pid: getpid(), startedAt: Timestamp.string(Date()),
                                       endpoint: dir + "/runtime.sock", buildSource: "test")
        let s = RuntimeService(identity: identity, backend: FixedBackend(), platform: FakePlatform(), hub: hub)
        let owner = handshaken(s)
        let (app, _) = socketConnection(s)
        let id = try #require(data(call(s, app, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["act"]}}"#))?["pairingId"]?.stringValue)
        let db = try SQLiteDatabase(path: path)
        let trigger = rejectAudit
            ? "CREATE TRIGGER reject_denial BEFORE INSERT ON auth_events WHEN NEW.method = 'hub.pairing.deny' AND NEW.decision = 'denied' BEGIN SELECT RAISE(ABORT, 'injected audit failure'); END"
            : "CREATE TRIGGER reject_denial BEFORE UPDATE OF state ON pairings WHEN NEW.state = 'denied' BEGIN SELECT RAISE(ABORT, 'injected state failure'); END"
        try db.execute(trigger)
        let result = call(s, owner, "hub.pairing.deny", params: #"{"pairingId":"\#(id)"}"#)
        #expect(code(result) == "audit_unavailable")
        if case let .failure(e) = result.result { #expect(e.notSent != true) }
        #expect(hub.pairing(id)?.state == "requested")
        #expect(hub.clients().isEmpty)
        #expect(hub.collect(id) == nil)
        #expect(hub.auditEvents().contains { $0["method"]?.stringValue == "hub.pairing.deny" && $0["decision"]?.stringValue == "unknown" })
        #expect(try db.query("SELECT state FROM pairings WHERE pairing_id = ?", [.text(id)]).first?.first as? String == "requested")
        try db.execute("DROP TRIGGER reject_denial")
        #expect(data(call(s, owner, "hub.pairing.deny", params: #"{"pairingId":"\#(id)"}"#))?["state"]?.stringValue == "denied")
        #expect(code(call(s, owner, "hub.pairing.approve", params: #"{"pairingId":"\#(id)","grant":{"capabilities":["act"]}}"#)) == "conflict")
        #expect(hub.collect(id) == nil)
        let reopened = try HubStore(path: path)
        #expect(reopened.pairing(id)?.state == "denied")
        #expect(reopened.clients().isEmpty)
        #expect(reopened.collect(id) == nil)
    }
    /// Another owner connection decides the pairing between the check and
    /// the write: the answer is a definite conflict, not an unknown outcome.
    @Test func concurrentDecisionIsConflictNotUnknown() throws {
        let dir = try socketDirectory()
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let path = dir + "/hub.sqlite"
        let hub = try HubStore(path: path)
        let identity = RuntimeIdentity(instanceId: "denial-race", pid: getpid(), startedAt: Timestamp.string(Date()),
                                       endpoint: dir + "/runtime.sock", buildSource: "test")
        let s = RuntimeService(identity: identity, backend: FixedBackend(), platform: FakePlatform(), hub: hub)
        let owner = handshaken(s)
        let (app, _) = socketConnection(s)
        let id = try #require(data(call(s, app, "hub.pairing.start", params: #"{"agentName":"x","requested":{"capabilities":["act"]}}"#))?["pairingId"]?.stringValue)
        let db = try SQLiteDatabase(path: path)
        // The other decision lands first; the denial's conditional update then matches no row.
        try db.execute("""
            CREATE TRIGGER other_decision BEFORE UPDATE OF state ON pairings WHEN NEW.state = 'denied' BEGIN
            UPDATE pairings SET state = 'expired' WHERE pairing_id = NEW.pairing_id; SELECT RAISE(IGNORE); END
            """)
        let result = call(s, owner, "hub.pairing.deny", params: #"{"pairingId":"\#(id)"}"#)
        #expect(code(result) == "conflict")
        if case let .failure(e) = result.result { #expect(e.notSent == true) }
        #expect(hub.pairing(id)?.state == "expired")
        #expect(!hub.auditEvents().contains { $0["method"]?.stringValue == "hub.pairing.deny" })
    }
}
