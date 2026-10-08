import Foundation
import Testing
@testable import AgentDesktop

struct HostRoleTests {
    @Test func productEndpointUsesAgentDesktop() {
        let product = HostRole.productEndpoint.path
        #expect(product.hasSuffix("/Application Support/AgentDesktop/control.sock"), "\(product)")
    }

    @Test func serialNumbersKeepHostsApart() {
        // Product and test instances use distinct serial ranges.
        #expect(HostRole.product.primaryDisplaySerial == 5)
        #expect(HostRole.product.agentSerialBase == 500)
        #expect(HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/x.sock")).agentSerialBase == 950)
    }

    @Test func sideInstanceUsesTheGivenSocket() {
        let role = HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/test.sock"))
        #expect(role.isSideInstance)
        #expect(role.endpoint.path == "/tmp/test.sock")
        #expect(!HostRole.product.isSideInstance)
    }

    // A test copy never touches the login Keychain; the product always does.
    @Test func testCopiesKeepKeysOutOfTheKeychain() {
        let side = HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/adt-x/side.sock"))
        guard case let .files(directory) = side.credentialBackend else {
            Issue.record("a test copy must not use the Keychain")
            return
        }
        #expect(directory.path.hasPrefix(side.runtimeRecordsDirectory.path))
        #expect(HostRole.product.credentialBackend == .keychain)
    }
}
