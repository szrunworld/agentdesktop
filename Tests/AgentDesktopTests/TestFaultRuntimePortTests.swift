import AgentDesktopProtocol
import AgentDesktopUI
import Foundation
import Testing
@testable import AgentDesktop

// The fault port exists for test copies only and never blocks a thread.
@Suite("Test fault port")
struct TestFaultRuntimePortTests {
    @Test func onlyASideInstanceWithAFileUnderTmpAdtIsWrapped() {
        let base = MockRuntime.sample()
        let side = HostRole.sideInstance(socket: URL(fileURLWithPath: "/tmp/adt-x/s.sock"))
        #expect(TestFaultRuntimePort.wrap(base, role: .product, environment: ["AGENTDESKTOP_TEST_FAULT_FILE": "/tmp/adt-x/f"]) === base)
        #expect(TestFaultRuntimePort.wrap(base, role: side, environment: [:]) === base)
        #expect(TestFaultRuntimePort.wrap(base, role: side, environment: ["AGENTDESKTOP_TEST_FAULT_FILE": "/Users/x/f"]) === base)
        #expect(TestFaultRuntimePort.wrap(base, role: side, environment: ["AGENTDESKTOP_TEST_FAULT_FILE": "/tmp/adt-x/f"]) is TestFaultRuntimePort)
    }

    @Test func parse() {
        #expect(TestFaultRuntimePort.parse("") == .init())
        let f = TestFaultRuntimePort.parse("delay run.list 1500\ndelay * 10\nbogus\ndelay x -1\n")
        #expect(f.delay(for: "run.list") == 1500 && f.delay(for: "desktop.list") == 10 && !f.offline)
        #expect(TestFaultRuntimePort.parse("offline").offline)
    }

    @Test func switchesWhileRunning() async throws {
        let dir = "/tmp/adt-fault-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let file = dir + "/fault"
        let port = TestFaultRuntimePort(base: MockRuntime.sample(), file: file)
        _ = try await port.call("desktop.list")
        try "offline".write(toFile: file, atomically: true, encoding: .utf8)
        await #expect(throws: RuntimeError.self) { try await port.call("desktop.list") }
        try "delay desktop.list 150".write(toFile: file, atomically: true, encoding: .utf8)
        let t0 = Date()
        _ = try await port.call("desktop.list")
        #expect(Date().timeIntervalSince(t0) >= 0.14)
        try "".write(toFile: file, atomically: true, encoding: .utf8)
        _ = try await port.call("desktop.list")
    }
}
