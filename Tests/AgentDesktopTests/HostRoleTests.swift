import XCTest
@testable import AgentDesktop

final class HostRoleTests: XCTestCase {
    func testProductEndpointIsApartFromTheEngineHost() {
        let product = HostRole.productEndpoint.path
        XCTAssertTrue(product.hasSuffix("/Application Support/AgentDesktop/control.sock"), product)
        XCTAssertFalse(product.contains("/2ndscreen/"), "the product must not share 2ndscreen.app's socket")
    }

    func testSerialNumbersKeepHostsApart() {
        // 2ndscreen.app: primary 1, agents 100…, side instances 900…; vdisplay 2.
        XCTAssertEqual(HostRole.product.primaryDisplaySerial, 5)
        XCTAssertEqual(HostRole.product.agentSerialBase, 500)
        XCTAssertEqual(HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/x.sock")).agentSerialBase, 950)
    }

    func testSideInstanceUsesTheGivenSocket() {
        let role = HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/test.sock"))
        XCTAssertTrue(role.isSideInstance)
        XCTAssertEqual(role.endpoint.path, "/tmp/test.sock")
        XCTAssertFalse(HostRole.product.isSideInstance)
    }
}
