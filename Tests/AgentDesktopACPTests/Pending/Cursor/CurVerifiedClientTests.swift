import AgentDesktopClient
import AgentDesktopProtocol
import Foundation
import Testing
@testable import AgentDesktopACP

/// [Mock] Post-connect identity check: even if the path was swapped after the
/// pre-connect check, nothing but the handshake reaches a Runtime that states
/// a non-test endpoint (Kevin's TOCTOU requirement on #141).
@Suite("[Mock] Real-test verified client")
struct CurVerifiedClientTests {
    final class FakeClient: RuntimeClient, @unchecked Sendable {
        var stated: String
        /// The next call fails as a lost connection (the inner client would
        /// reconnect on the call after it).
        var loseNextCall = false
        var calls: [String] = []
        var closed = false
        init(stated: String) { self.stated = stated }
        var endpoint: Endpoint { Endpoint(path: "/tmp/adt-x/side.runtime.sock", source: .option) }
        func handshake() throws -> RuntimeIdentity {
            calls.append("runtime.handshake")
            return RuntimeIdentity(instanceId: "i", pid: 1, startedAt: "2026-10-08T00:00:00Z", endpoint: stated, buildSource: "t")
        }
        func call(_ request: RuntimeRequest) throws -> JSONValue {
            if loseNextCall { loseNextCall = false; throw RuntimeError.connectionLost("gone") }
            calls.append(request.method); return .obj([])
        }
        func close() { closed = true }
    }

    @Test("[Mock] a Runtime stating the product endpoint gets only the handshake, then the connection closes")
    func productRuntimeIsRefusedAfterHandshake() throws {
        let fake = FakeClient(stated: NSHomeDirectory() + "/Library/Application Support/AgentDesktop/runtime.sock")
        let c = ACPTestVerifiedClient(fake)
        #expect(throws: ACPTestEndpointGuard.NotATestCopy.self) {
            _ = try c.call(RuntimeRequest(requestId: "r1", method: "run.show", params: .obj([("runId", .string("x"))])))
        }
        #expect(throws: ACPTestEndpointGuard.NotATestCopy.self) {
            _ = try c.call(RuntimeRequest(requestId: "r2", method: "run.cancel", params: .obj([])))
        }
        #expect(fake.calls == ["runtime.handshake"])
        let closed = fake.closed
        #expect(closed)
    }

    @Test("[Mock] a Runtime stating a test-copy endpoint is served")
    func testCopyRuntimeIsServed() throws {
        let dir = ACPTestScratch.tmp("curtest-vc")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeClient(stated: dir + "/side.runtime.sock")
        let c = ACPTestVerifiedClient(fake)
        _ = try c.call(RuntimeRequest(requestId: "r1", method: "run.show", params: .obj([])))
        #expect(fake.calls == ["runtime.handshake", "run.show"])
    }

    @Test("[Mock] after a lost connection the new connection is checked again before any request")
    func reconnectIsVerifiedAgain() throws {
        let dir = ACPTestScratch.tmp("curtest-rc")
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let fake = FakeClient(stated: dir + "/side.runtime.sock")
        let c = ACPTestVerifiedClient(fake)
        _ = try c.call(RuntimeRequest(requestId: "r1", method: "run.show", params: .obj([])))
        fake.loseNextCall = true
        #expect(throws: RuntimeError.self) { _ = try c.call(RuntimeRequest(requestId: "r2", method: "run.show", params: .obj([]))) }
        // The socket was swapped meanwhile: the reconnected Runtime is the product.
        fake.stated = NSHomeDirectory() + "/Library/Application Support/AgentDesktop/runtime.sock"
        #expect(throws: ACPTestEndpointGuard.NotATestCopy.self) {
            _ = try c.call(RuntimeRequest(requestId: "r3", method: "run.cancel", params: .obj([])))
        }
        #expect(fake.calls == ["runtime.handshake", "run.show", "runtime.handshake"])
    }
}
