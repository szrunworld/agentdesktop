import Foundation
import Testing
@testable import AgentDesktop

/// One Agent Desktop process at a time (Kevin, 2026-10-11): the second
/// launch, product or test copy, finds the lock held and learns who holds it.
@Suite struct SingleInstanceTests {
    private func tempLock() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("adt-single-\(UUID().uuidString)")
        return dir.appendingPathComponent("instance.lock").path
    }

    @Test func aSecondLaunchFindsTheFirstHolder() throws {
        let path = try tempLock()
        defer { try? FileManager.default.removeItem(atPath: (path as NSString).deletingLastPathComponent) }
        let first = SingleInstance.Holder(pid: 101, role: "product", bundlePath: "/Applications/Agent Desktop.app")
        guard case .acquired(let fd) = SingleInstance.acquire(at: path, as: first) else {
            Issue.record("the first launch takes the lock"); return
        }
        let second = SingleInstance.Holder(pid: 202, role: "test", bundlePath: "/tmp/copy/Agent Desktop.app")
        #expect(SingleInstance.acquire(at: path, as: second) == .held(first), "a test copy is refused while the product runs")
        #expect(SingleInstance.acquire(at: path, as: first) == .held(first), "so is a second product")
        close(fd)
        guard case .acquired(let again) = SingleInstance.acquire(at: path, as: second) else {
            Issue.record("once the holder has gone, the next launch takes the lock"); return
        }
        close(again)
    }

    @Test func theRefusalSaysWhoRunsAndThatThisLaunchQuits() {
        let product = SingleInstance.refusal(.init(pid: 7, role: "product", bundlePath: "/A.app"))
        #expect(product.contains("pid 7") && product.contains("/A.app") && product.contains("将退出"))
        #expect(SingleInstance.refusal(.init(pid: 8, role: "test", bundlePath: "/B.app")).contains("测试副本"))
        #expect(SingleInstance.refusal(nil).contains("将退出"))
        #expect(SingleInstance.confirmTitle == "确定退出")
    }

    // Codex P2 on 07cfe5f (#305): a product from before the lock is found
    // through its Runtime endpoint record, so the refused launch can bring
    // it forward too.
    @Test func aLegacyProductIsFoundThroughItsEndpointRecord() throws {
        let path = try tempLock()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let record = dir + "/runtime.sock.lock"
        try Data(#"{"product":"AgentDesktop","pid":70760,"listening":true}"#.utf8).write(to: URL(fileURLWithPath: record))
        let found = SingleInstance.legacyProduct(endpointRecord: record) { $0 == 70760 ? "/old/Agent Desktop.app" : nil }
        #expect(found == .init(pid: 70760, role: "product", bundlePath: "/old/Agent Desktop.app"))
        #expect(SingleInstance.legacyProduct(endpointRecord: record) { _ in nil } == nil, "no running app with that pid")
        #expect(SingleInstance.legacyProduct(endpointRecord: dir + "/missing") { _ in "/x.app" } == nil)
    }
}
