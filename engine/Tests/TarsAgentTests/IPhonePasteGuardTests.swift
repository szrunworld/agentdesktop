import CoreGraphics
import Foundation
import SecondScreenCore
import Testing
@testable import TarsAgent

/// The paste guards on the screen (#127): no barrier lowered, no frame handed
/// out and no input sent while another process pastes; failed deliveries are
/// unknown. Kept apart from IPhoneMirroringTests so the status work (#142)
/// and this one touch different files.
@Suite struct IPhonePasteGuardTests {
    /// Independent review: a screenshot taken while another process is in a
    /// paste must not lower the barrier that paste raised.
    @Test func aScreenshotDuringAPasteKeepsTheBarrier() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        try fake.inputBarrier.raise("may hold a half-finished paste")
        fake.pasteInProgress = true
        // Codex on #127: a frame taken during another's paste is not handed
        // out, and no input goes meanwhile.
        #expect(throws: IPhoneError.self) { try phone.screenshot(size: CGSize(width: 330, height: 720)) }
        #expect(fake.inputBarrier.reason() != nil)
        fake.inputBarrier.lower()
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("paste_in_progress") == true)
        #expect(fake.inputs.isEmpty)
        try fake.inputBarrier.raise("may hold a half-finished paste")
        fake.pasteInProgress = false
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(fake.inputBarrier.reason() == nil)
    }

    /// Independent review: an input whose transport failed may have landed.
    @Test func aFailedDeliveryIsUnknownAndBlocks() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.deliverThrows = true
        let first = try phone.perform(tap(3100, 300))
        #expect(first.error?.hasPrefix("action_delivery_unknown (transport_error)") == true)
        #expect(first.route == "click.unknown")
        #expect(TarsAgent.isIndeterminate(first))
        fake.deliverThrows = false
        let next = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try next.frame()
        #expect(try next.perform(tap(3100, 300)).error?.contains("delivery_unknown") == true)
    }

    /// The live check the screenshot relies on: a held lease (from any
    /// process) or a pending mark means a paste is under way, and nothing
    /// runs under `whileNoPaste`. Codex on #127: the last check and the
    /// lowering happen under the lease, so no paste can begin between them.
    @Test func theLiveSystemSeesAPasteUnderWay() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdesktop-live-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = LiveIPhoneMirroringSystem()
        live.leaseURL = directory.appendingPathComponent("clipboard.lock")
        live.pendingMark = HostFlag(url: directory.appendingPathComponent("clipboard.pending"))
        #expect(!live.pasteInProgress)
        var ran = false
        #expect(live.whileNoPaste { ran = true })
        #expect(ran)

        let held = try ClipboardLease.acquire(at: live.leaseURL, timeout: 1)
        #expect(live.pasteInProgress)
        ran = false
        #expect(!live.whileNoPaste { ran = true })
        #expect(!ran)
        held.release()

        try live.pendingMark.raise("pending", until: Date().addingTimeInterval(60))
        #expect(live.pasteInProgress)
        #expect(!live.whileNoPaste { ran = true })
        #expect(!ran)
        live.pendingMark.lower()

        // While the body runs, no paste can take the lease.
        #expect(live.whileNoPaste {
            #expect(throws: ClipboardLease.LeaseError.self) { try ClipboardLease.acquire(at: live.leaseURL, timeout: 0) }
        })
    }

    /// Codex on #127: the checks and the work run holding the lease, so a
    /// paste cannot begin between the check and the capture or dispatch.
    @Test func withoutPasteHoldsTheLeaseForTheWholeBody() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdesktop-without-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        var live = LiveIPhoneMirroringSystem()
        live.leaseURL = directory.appendingPathComponent("clipboard.lock")
        live.pendingMark = HostFlag(url: directory.appendingPathComponent("clipboard.pending"))
        let value = try live.withoutPaste { () -> Int in
            #expect(throws: ClipboardLease.LeaseError.self) { try ClipboardLease.acquire(at: live.leaseURL, timeout: 0) }
            return 7
        }
        #expect(value == 7)
        let held = try ClipboardLease.acquire(at: live.leaseURL, timeout: 1)
        var ran = false
        #expect(try live.withoutPaste { ran = true } == nil)
        #expect(!ran)
        held.release()
    }
}
