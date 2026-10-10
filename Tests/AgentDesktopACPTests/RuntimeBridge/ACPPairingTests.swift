import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// [Mock] The dev bridge pairs as itself (`agentdesktop-acp-dev pair`), so the
/// confirmation window names the bridge and the keychain item is created by
/// the program that reads it when serving.
@Suite("[Mock] ACP bridge pairing")
struct ACPPairingTests {
    final class PairingClient: RuntimeClient, @unchecked Sendable {
        /// Replies to successive hub.pairing.status calls.
        var statuses: [JSONValue]
        var startError: RuntimeError?
        var requests: [RuntimeRequest] = []
        var handshakes = 0
        init(statuses: [JSONValue], startError: RuntimeError? = nil) {
            self.statuses = statuses
            self.startError = startError
        }
        var endpoint: Endpoint { Endpoint(path: "/tmp/adt-x/side.runtime.sock", source: .option) }
        func handshake() throws -> RuntimeIdentity {
            handshakes += 1
            return RuntimeIdentity(instanceId: "i", pid: 1, startedAt: "2026-10-10T00:00:00Z", endpoint: endpoint.path, buildSource: "t")
        }
        func call(_ request: RuntimeRequest) throws -> JSONValue {
            requests.append(request)
            switch request.method {
            case RuntimeMethod.pairingStart.rawValue:
                if let startError { throw startError }
                return .obj([("pairingId", .string("p1")), ("shortCode", .string("123-456"))])
            case RuntimeMethod.pairingStatus.rawValue:
                return statuses.isEmpty ? .obj([("state", .string("pending"))]) : statuses.removeFirst()
            default:
                Issue.record("pairing sent \(request.method)")
                return .obj([])
            }
        }
        func close() {}
        var methods: [String] { requests.map(\.method) }
    }

    static let endpoint = "/tmp/adt-x/side.runtime.sock"
    static let approved = JSONValue.obj([("state", .string("approved")),
                                         ("credential", .obj([("clientId", .string("app:abc")), ("token", .string("secret"))])),
                                         ("grant", ACPPairing.grant())])

    /// A clock that moves only when the flow sleeps.
    final class Clock: @unchecked Sendable {
        var t = Date(timeIntervalSince1970: 0)
        var sleeps = 0
        func now() -> Date { t }
        func sleep(_ s: Double) { sleeps += 1; t.addTimeInterval(s) }
    }

    func run(_ client: PairingClient, _ store: MemoryCredentialStore, grant: JSONValue = ACPPairing.grant(),
             timeout: Double = 5, clock: Clock = Clock()) throws -> ACPPairing.Outcome {
        try ACPPairing.pair(client: client, store: store, endpoint: Self.endpoint, name: "ACP", grant: grant,
                            timeout: timeout, now: clock.now, sleep: clock.sleep) { _ in }
    }

    @Test("[Mock] the grant covers every capability the bridge calls, on Desktops it creates")
    func grantCoversTheBridgesMethods() {
        let g = ACPPairing.grant(apps: ["com.example.app"])
        let caps = Set(g["capabilities"]?.arrayValue?.compactMap(\.stringValue) ?? [])
        // unit.run submits; run.show / run.cancel / events.subscribe need `run`.
        #expect(caps == ["observe", "act", "desktop.manage", "unit.run", "run"])
        #expect(g["desktops"]?.arrayValue?.compactMap(\.stringValue) == ["created"])
        #expect(g["apps"]?.arrayValue?.compactMap(\.stringValue) == ["com.example.app"])
        #expect(g["durationSeconds"] == nil)
        #expect(ACPPairing.grant()["apps"]?.arrayValue?.isEmpty == true)
    }

    @Test("[Mock] approval stores the credential under profile acp for that endpoint")
    func approvalStoresTheCredential() throws {
        let client = PairingClient(statuses: [Self.approved])
        let store = MemoryCredentialStore()
        let grant = ACPPairing.grant(apps: ["com.example.app"])
        let outcome = try run(client, store, grant: grant)
        #expect(outcome == .paired(clientId: "app:abc", grant: ACPPairing.grant()))
        #expect(try store.load(endpoint: Self.endpoint, profile: "acp") == ClientCredential(clientId: "app:abc", token: "secret"))
        #expect(client.handshakes == 1)
        #expect(client.methods == ["hub.pairing.start", "hub.pairing.status"])
        let start = client.requests[0].params
        #expect(start["agentName"]?.stringValue == "ACP")
        #expect(start["requested"] == grant)
        #expect(client.requests[1].params["pairingId"]?.stringValue == "p1")
    }

    @Test("[Mock] it keeps polling the same pairing while the user has not answered")
    func pendingIsPolled() throws {
        let pending = JSONValue.obj([("state", .string("pending"))])
        let client = PairingClient(statuses: [pending, pending, Self.approved])
        let clock = Clock()
        let store = MemoryCredentialStore()
        let outcome = try run(client, store, clock: clock)
        #expect(outcome == .paired(clientId: "app:abc", grant: ACPPairing.grant()))
        #expect(client.methods == ["hub.pairing.start", "hub.pairing.status", "hub.pairing.status", "hub.pairing.status"])
        #expect(clock.sleeps == 2)
    }

    @Test("[Mock] denied or expired stores nothing", arguments: ["denied", "expired"])
    func refusalStoresNothing(state: String) throws {
        let client = PairingClient(statuses: [.obj([("state", .string(state))])])
        let store = MemoryCredentialStore()
        #expect(try run(client, store) == .refused(pairingId: "p1", state: state))
        #expect(try store.load(endpoint: Self.endpoint, profile: "acp") == nil)
    }

    @Test("[Mock] no answer before the timeout stores nothing")
    func timeoutStoresNothing() throws {
        let client = PairingClient(statuses: [])
        let store = MemoryCredentialStore()
        let clock = Clock()
        #expect(try run(client, store, timeout: 3, clock: clock) == .timedOut(pairingId: "p1"))
        #expect(try store.load(endpoint: Self.endpoint, profile: "acp") == nil)
        #expect(clock.sleeps == 3)
    }

    @Test("[Mock] approved without a credential (already collected) fails and stores nothing")
    func collectedCredentialFails() throws {
        let client = PairingClient(statuses: [.obj([("state", .string("approved"))])])
        let store = MemoryCredentialStore()
        #expect(throws: RuntimeError.self) { try run(client, store) }
        #expect(try store.load(endpoint: Self.endpoint, profile: "acp") == nil)
    }

    @Test("[Mock] a Runtime refusal of the request is thrown as is, never retried")
    func startRefusalIsNotRetried() throws {
        let client = PairingClient(statuses: [], startError: RuntimeError("pairing_cooldown", "wait", phase: .handler))
        let store = MemoryCredentialStore()
        do {
            _ = try run(client, store)
            Issue.record("expected pairing_cooldown")
        } catch let e as RuntimeError {
            #expect(e.code == "pairing_cooldown")
        }
        #expect(client.methods == ["hub.pairing.start"])
        #expect(try store.load(endpoint: Self.endpoint, profile: "acp") == nil)
    }
}
