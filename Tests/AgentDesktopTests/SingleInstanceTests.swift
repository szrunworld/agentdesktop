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
        try Data(#"{"product":"AgentDesktop","productVersion":"0.1.0-dev","pid":70760,"instanceId":"rt_1","endpoint":"/x/runtime.sock","listening":true,"since":"2026-10-11T14:56:28.162Z"}"#.utf8).write(to: URL(fileURLWithPath: record))
        let found = SingleInstance.legacyProduct(endpointRecord: record) { $0 == 70760 ? "/old/Agent Desktop.app" : nil }
        #expect(found == .init(pid: 70760, role: "product", bundlePath: "/old/Agent Desktop.app"))
        #expect(SingleInstance.legacyProduct(endpointRecord: record) { _ in nil } == nil, "no running app with that pid")
        #expect(SingleInstance.legacyProduct(endpointRecord: dir + "/missing") { _ in "/x.app" } == nil)
    }

    // Codex P2s on 8f7d1f9 (#305).
    @Test func aBarePidRecordStillNamesTheLegacyProduct() throws {
        let path = try tempLock()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let record = dir + "/runtime.sock.lock"
        try Data("4242\n".utf8).write(to: URL(fileURLWithPath: record))
        #expect(SingleInstance.legacyProduct(endpointRecord: record) { $0 == 4242 ? "/older.app" : nil }
                == .init(pid: 4242, role: "product", bundlePath: "/older.app"))
    }

    @Test func aHardLinkedLockIsNotRewritten() throws {
        let path = try tempLock()
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let target = dir + "/precious"
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: target))
        #expect(link(target, path) == 0)
        guard case .failed = SingleInstance.acquire(at: path, as: .init(pid: 1, role: "product", bundlePath: "/A.app")) else {
            Issue.record("a hard-linked lock is refused"); return
        }
        #expect(try String(contentsOfFile: target, encoding: .utf8) == "keep me")
    }

    @Test func anotherProcessOfTheBundleIsSeenBeforeItListens() {
        let apps = [SingleInstance.RunningApp(pid: 10, bundlePath: "/me.app", regular: true),
                    SingleInstance.RunningApp(pid: 11, bundlePath: "/copy.app", regular: false)]
        #expect(SingleInstance.otherRunning(me: 10, productPID: nil) { apps } == .init(pid: 11, role: "test", bundlePath: "/copy.app"))
        #expect(SingleInstance.otherRunning(me: 11, productPID: nil) { apps } == .init(pid: 10, role: "product", bundlePath: "/me.app"))
        #expect(SingleInstance.otherRunning(me: 10, productPID: nil) { [apps[0]] } == nil, "this process alone")
    }

    // Codex P2 on fe1d9f6 (#305): a product kept in the background
    // (保留后台) is accessory, like a test copy; the product's Runtime
    // record decides, so it is still brought forward.
    @Test func aBackgroundedProductIsStillTheProduct() {
        let apps = [SingleInstance.RunningApp(pid: 20, bundlePath: "/copy.app", regular: false),
                    SingleInstance.RunningApp(pid: 21, bundlePath: "/product.app", regular: false)]
        #expect(SingleInstance.otherRunning(me: 1, productPID: 21) { apps } == .init(pid: 21, role: "product", bundlePath: "/product.app"),
                "the product is preferred and named by its record")
        #expect(SingleInstance.otherRunning(me: 1, productPID: 99) { [apps[0]] } == .init(pid: 20, role: "test", bundlePath: "/copy.app"))
    }
}
