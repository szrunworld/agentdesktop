import CoreGraphics
import Foundation
import SecondScreenCore
import Testing
@testable import TarsAgent

/// A Mac with iPhone Mirroring that exists only in memory.
class FakeMirroring: IPhoneMirroringSystem {
    var pids: [pid_t] = [42]
    var screen: CGRect? = CGRect(x: 3000, y: 0, width: 525, height: 1001)
    var windowsByPID: [pid_t: [IPhoneWindow]] = [
        42: [IPhoneWindow(pid: 42, windowID: 7, frame: CGRect(x: 3010, y: 40, width: 330, height: 720))],
    ]
    var ocr: [String] = []
    var ax: [String] = []
    var buttons: [String] = []
    var pressed: [String] = []
    var delivered: [ControlRequest] = []
    /// Runs after each input is delivered, as the window server might.
    var afterDeliver: (() -> Void)?
    /// What the next captures return, the window's frame otherwise.
    var captureFrame: CGRect?
    var blank = false
    var running: Set<pid_t> = [42]
    var terminateAccepted = true
    var exitsAfterSleeps = 0
    var clock = Date(timeIntervalSince1970: 1_000_000)
    var sleeps = 0
    var onSleep: (() -> Void)?
    var createFails = false
    var pasteInProgress = false
    func whileNoPaste(_ body: () -> Void) -> Bool {
        guard !pasteInProgress else { return false }
        body()
        return true
    }
    var deliverThrows = false
    let inputBarrier = HostFlag(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdesktop-barrier-\(UUID().uuidString)/iphone-input-barrier"))
    var createdScreens = 0

    func mirroringPIDs() -> [pid_t] { pids }
    func screenFrame(named name: String) throws -> CGRect? { screen }
    func windows(pid: pid_t) -> [IPhoneWindow] { windowsByPID[pid] ?? [] }

    func captureWindow(screen: String, pid: pid_t, windowID: CGWindowID) throws -> IPhoneWindowCapture {
        guard let window = windows(pid: pid).first(where: { $0.windowID == windowID }) else {
            throw IPhoneError("capture_failed", "gone")
        }
        let frame = captureFrame ?? window.frame
        return IPhoneWindowCapture(image: Self.image(blank: blank, width: Int(frame.width), height: Int(frame.height)),
                                   windowID: windowID, frame: frame)
    }

    struct TransportLost: Error {}
    func deliver(_ request: ControlRequest) throws -> ControlResponse {
        delivered.append(request)
        if deliverThrows, request.command == .input { throw TransportLost() }
        if request.command == .screenCreate {
            if createFails { return .failure("a screen named \"\(request.screen ?? "")\" already exists") }
            createdScreens += 1
            screen = CGRect(x: 3000, y: 0, width: 525, height: 1001)
        }
        afterDeliver?()
        return ControlResponse()
    }

    func recognizedText(in image: CGImage) -> [String] { ocr }
    /// Texts of other windows of the app, such as its Settings.
    var axOtherWindows: [String] = []
    var buttonsOtherWindows: [String] = []
    func accessibilityLabels(pid: pid_t, windowID: CGWindowID?) -> [String] {
        windowID == nil ? ax + axOtherWindows : ax
    }

    func pressButton(titled titles: Set<String>, pid: pid_t, windowID: CGWindowID?) -> String? {
        if windowID == nil, let title = buttonsOtherWindows.first(where: titles.contains) {
            pressed.append(title)
            return title
        }
        guard let title = buttons.first(where: titles.contains) else { return nil }
        pressed.append(title)
        return title
    }

    func terminate(pid: pid_t) -> Bool { terminateAccepted }
    func isRunning(pid: pid_t) -> Bool { running.contains(pid) }
    var now: Date { clock }

    func sleep(_ seconds: TimeInterval) {
        clock = clock.addingTimeInterval(seconds)
        sleeps += 1
        if exitsAfterSleeps > 0, sleeps >= exitsAfterSleeps { running.removeAll() }
        onSleep?()
    }

    func move(_ id: CGWindowID, to frame: CGRect) {
        windowsByPID[42] = windowsByPID[42]?.map { $0.windowID == id ? IPhoneWindow(pid: 42, windowID: id, frame: frame) : $0 }
    }

    var inputs: [ControlRequest] { delivered.filter { $0.command == .input } }

    static func image(blank: Bool, width: Int, height: Int) -> CGImage {
        let context = CGContext(data: nil, width: max(width, 1), height: max(height, 1), bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(gray: 0.92, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if !blank {
            context.setFillColor(red: 0.1, green: 0.3, blue: 0.8, alpha: 1)
            context.fill(CGRect(x: width / 4, y: height / 4, width: width / 2, height: height / 3))
        }
        return context.makeImage()!
    }
}

func tap(_ x: Double, _ y: Double) -> InputAction {
    var action = InputAction(.click)
    action.x = x
    action.y = y
    return action
}

@Suite struct IPhoneObservationBindingTests {
    @Test func aScreenshotRecordsTheWindowAndGeometryItShowed() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let frame = try phone.frame()
        _ = try phone.screenshot(size: CGSize(width: frame.width * 2, height: frame.height * 2))
        let seen = try #require(phone.observation)
        #expect(seen.pid == 42 && seen.windowID == 7)
        #expect(seen.frame == frame)
        #expect(seen.pixelSize == CGSize(width: 660, height: 1440))
        #expect(seen.capturedAt == fake.clock)
        #expect(seen.geometryVersion == IPhoneObservation.geometryVersion(windowID: 7, frame: frame, pixelSize: seen.pixelSize))
    }

    @Test func inputNamesTheBoundWindow() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        let response = try phone.perform(tap(3100, 300))
        #expect(response.ok)
        #expect(fake.inputs.count == 1)
        #expect(fake.inputs[0].windowID == 7)
        #expect(fake.inputs[0].pid == 42)
    }

    @Test func keepsTheBoundWindowWhenALargerOneAppears() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.windowsByPID[42]!.insert(IPhoneWindow(pid: 42, windowID: 9, frame: CGRect(x: 3000, y: 0, width: 500, height: 900)), at: 0)
        _ = try phone.frame()
        #expect(phone.binding?.windowID == 7)
    }

    @Test func aMovedWindowIsRefusedAndNothingIsSent() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.move(7, to: CGRect(x: 3010, y: 40, width: 720, height: 330))  // turned landscape
        let response = try phone.perform(tap(3100, 300))
        #expect(!response.ok)
        #expect(response.error?.hasPrefix("stale_observation (moved)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func aRemadeWindowIsRefused() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.windowsByPID[42] = [IPhoneWindow(pid: 42, windowID: 8, frame: CGRect(x: 3010, y: 40, width: 330, height: 720))]
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("stale_observation (window_gone)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func aRestartedMirroringIsRefused() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.pids = [43]
        fake.windowsByPID[43] = fake.windowsByPID[42]!.map { IPhoneWindow(pid: 43, windowID: $0.windowID, frame: $0.frame) }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("stale_observation (process_restarted)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func aMirroringWindowOverThePhoneIsRefused() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        // Its settings window, in front.
        fake.windowsByPID[42]!.insert(IPhoneWindow(pid: 42, windowID: 11, frame: CGRect(x: 3050, y: 100, width: 200, height: 200)), at: 0)
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("stale_observation (other_window_of_process_in_front)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func aWindowThatMovesWhileTheScreenshotIsTakenIsRefused() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.captureFrame = CGRect(x: 3010, y: 60, width: 330, height: 720)
        #expect(throws: IPhoneError.self) { try phone.screenshot(size: CGSize(width: 330, height: 720)) }
        #expect(phone.observation == nil)
    }

    @Test func aChangeDuringTheSendIsUnknownAndStopsFurtherInput() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        fake.afterDeliver = { fake.move(7, to: CGRect(x: 3010, y: 40, width: 400, height: 720)) }
        let first = try phone.perform(tap(3100, 300))
        #expect(first.error?.hasPrefix("action_delivery_unknown (target_changed_during_dispatch)") == true)
        fake.afterDeliver = nil
        let second = try phone.perform(tap(3100, 300))
        #expect(second.error?.hasPrefix("stale_observation") == true)
        #expect(fake.inputs.count == 1)
        // Reading the window's geometry is not a look at the phone.
        _ = try phone.frame()
        #expect(try phone.perform(tap(3100, 300)).error?.hasPrefix("stale_observation") == true)
        // Another process, a new CLI command, is blocked too.
        let next = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try next.frame()
        #expect(try next.perform(tap(3100, 300)).error?.hasPrefix("stale_observation") == true)
        #expect(fake.inputs.count == 1)
        // A screenshot lowers the barrier for everyone.
        _ = try next.screenshot(size: CGSize(width: 400, height: 720))
        #expect(try phone.perform(tap(3100, 300)).ok)
    }

    /// Independent review: a screenshot taken while another process is in a
    /// paste must not lower the barrier that paste raised.
    @Test func aScreenshotDuringAPasteKeepsTheBarrier() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        try fake.inputBarrier.raise("may hold a half-finished paste")
        fake.pasteInProgress = true
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(fake.inputBarrier.reason() != nil)
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

    @Test func noInputBeforeTheWindowIsRead() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("no_observation") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func geometryVersionFollowsWindowFrameAndSize() {
        let frame = CGRect(x: 10, y: 20, width: 330, height: 720)
        let size = CGSize(width: 660, height: 1440)
        let base = IPhoneObservation.geometryVersion(windowID: 7, frame: frame, pixelSize: size)
        #expect(base == IPhoneObservation.geometryVersion(windowID: 7, frame: frame.offsetBy(dx: 0.1, dy: 0), pixelSize: size))
        #expect(base != IPhoneObservation.geometryVersion(windowID: 8, frame: frame, pixelSize: size))
        #expect(base != IPhoneObservation.geometryVersion(windowID: 7, frame: frame.offsetBy(dx: 5, dy: 0), pixelSize: size))
        #expect(base != IPhoneObservation.geometryVersion(windowID: 7, frame: frame, pixelSize: CGSize(width: 330, height: 720)))
    }
}

@Suite struct IPhoneCaptureTests {
    @Test func aFlatFrameIsNotPassedOffAsTheScreen() throws {
        let fake = FakeMirroring()
        fake.blank = true
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        do {
            _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
            Issue.record("a blank frame was returned")
        } catch let error as IPhoneError {
            #expect(error.code == "capture_failed" && error.reason == "blank_frame")
        }
        #expect(phone.observation == nil)
    }

    @Test func blankDetection() {
        #expect(IPhoneFrames.isBlank(FakeMirroring.image(blank: true, width: 200, height: 400)))
        #expect(!IPhoneFrames.isBlank(FakeMirroring.image(blank: false, width: 200, height: 400)))
    }

    @Test func scratchPathsAreUniquePerRequest() {
        let paths = (0..<50).map { _ in IPhoneFrames.scratchPath() }
        #expect(Set(paths).count == 50)
        #expect(paths.allSatisfy { $0.hasPrefix(NSTemporaryDirectory()) && $0.hasSuffix(".png") })
        #expect(!paths[0].contains("-\(getpid()).png"))
    }

    @Test func aStatusPageIsNotAScreenshot() throws {
        let fake = FakeMirroring()
        fake.ocr = ["连接暂停"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        do {
            _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
            Issue.record("a status page was returned as the phone")
        } catch let error as IPhoneError {
            #expect(error.code == "not_connected" && error.reason == "disconnected")
        }
    }
}

@Suite struct IPhoneConnectionTests {
    @Test(arguments: [
        (["iPhone in Use"], IPhoneConnectionState.phoneInUse),
        (["iPhone 使用中"], .phoneInUse),
        (["因iPhone被使用，iPhone镜像已结束。"], .phoneInUse),
        (["iPhone相机使用中"], .phoneInUse),
        (["Connection Paused"], .disconnected),
        (["连接暂停"], .disconnected),
        (["连接中断"], .disconnected),
        (["未找到iPhone"], .disconnected),
        (["Unable to Connect to iPhone"], .disconnected),
        (["无法连接 iPhone"], .disconnected),
        (["Unlock Your iPhone"], .authRequired),
        (["解锁iPhone"], .authRequired),
        (["iPhone镜像已锁定"], .authRequired),
        (["Mac已锁定"], .authRequired),
        (["正在解锁Kevin的iPhone"], .reconnecting),
        (["Connecting to Kevin's iPhone"], .reconnecting),
        (["正在连接"], .reconnecting),
        (["Wi‑Fi Off"], .needsUser),
        (["蓝牙已关闭"], .needsUser),
        (["iCloud已退出登录"], .needsUser),
        (["欢迎使用iPhone镜像"], .needsUser),
        (["9:41", "微信", "Settings"], .ready),
        ([], .ready),
    ] as [([String], IPhoneConnectionState)])
    func classifiesStatusPagesInEnglishAndChinese(texts: [String], state: IPhoneConnectionState) {
        #expect(IPhoneConnection.classify(texts).state == state)
        #expect(IPhoneConnection.classify([], ocr: texts).state == state)
    }

    @Test func aPhoneAppSentenceIsNotAStatusPage() {
        let line = "Connecting to the server, please keep this app open while we finish syncing your messages"
        #expect(IPhoneConnection.classify([], ocr: [line]).state == .ready)
        // Mirroring's own text counts however long.
        #expect(IPhoneConnection.classify([line]).state == .reconnecting)
    }

    /// F6 (device, 2026-10-08): Mirroring's Settings window, open beside
    /// the phone, says a password or Touch ID is required; that is not the
    /// phone's state, and its buttons are not the phone window's.
    @Test func anotherWindowsTextIsNotThePhonesState() throws {
        let fake = FakeMirroring()
        fake.axOtherWindows = ["Your macOS user password or Touch ID is required to access your iPhone"]
        fake.buttonsOtherWindows = ["Resume"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(try phone.connectionState().state == .ready)
        #expect(throws: Never.self) { try phone.screenshot(size: CGSize(width: 330, height: 720)) }
        #expect(fake.pressed.isEmpty)
    }

    @Test func readingStatePressesNothing() throws {
        let fake = FakeMirroring()
        fake.ax = ["Connection Paused"]
        fake.buttons = ["Resume"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(try phone.connectionState().state == .disconnected)
        _ = try? phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(fake.pressed.isEmpty)
        #expect(fake.delivered.isEmpty)
    }

    @Test func reconnectPressesResumeAndWaitsUntilReady() throws {
        let fake = FakeMirroring()
        fake.ax = ["连接暂停"]
        fake.buttons = ["继续"]
        fake.onSleep = { if fake.sleeps == 1 { fake.ax = ["正在连接"] } else if fake.sleeps == 3 { fake.ax = [] } }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let report = try phone.reconnect(timeout: 20)
        #expect(report.pressed == "继续")
        #expect(report.state == .ready)
        #expect(!report.timedOut)
    }

    @Test func reconnectLeavesAPhoneInUseAlone() throws {
        let fake = FakeMirroring()
        fake.ax = ["iPhone in Use"]
        fake.buttons = ["Try Again"]
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect()
        #expect(report.state == .phoneInUse && report.pressed == nil)
        #expect(fake.pressed.isEmpty)
    }

    @Test func reconnectGivesUpAtItsTimeout() throws {
        let fake = FakeMirroring()
        fake.ax = ["Connection Interrupted"]
        fake.buttons = ["Try Again"]
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect(timeout: 3)
        #expect(report.timedOut && report.state == .disconnected)
        #expect(fake.pressed == ["Try Again"])
        #expect(fake.sleeps <= 4)
    }

    @Test func aCancelledReconnectStopsWaiting() throws {
        let fake = FakeMirroring()
        fake.ax = ["Connecting to"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        var cancelled = false
        phone.isCancelled = { cancelled }
        fake.onSleep = { cancelled = true }
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 60) }
        #expect(fake.sleeps == 1)
    }

    @Test func nothingIsSentOnceCancelledOrPastTheDeadline() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        phone.isCancelled = { true }
        #expect(try phone.perform(tap(3100, 300)).error?.hasPrefix("cancelled") == true)
        phone.isCancelled = { false }
        phone.deadline = fake.clock
        #expect(try phone.perform(tap(3100, 300)).error?.hasPrefix("deadline_exceeded") == true)
        #expect(fake.inputs.isEmpty)
    }
}

@Suite struct IPhoneLifecycleTests {
    @Test func hideWaitsUntilMirroringHasExited() {
        let fake = FakeMirroring()
        fake.exitsAfterSleeps = 3
        let result = IPhoneLifecycle(system: fake).hide(timeout: 10)
        #expect(result.outcome == .exited && result.outcome.ok)
    }

    @Test func hideReportsATimeoutWhenMirroringStays() {
        let fake = FakeMirroring()
        let result = IPhoneLifecycle(system: fake).hide(timeout: 2)
        #expect(result.outcome == .timedOut && !result.outcome.ok)
        #expect(result.pids == [42])
    }

    @Test func hideTellsRequestedRefusedAndNotRunningApart() {
        let fake = FakeMirroring()
        #expect(IPhoneLifecycle(system: fake).hide(wait: false).outcome == .exitRequested)
        fake.terminateAccepted = false
        #expect(IPhoneLifecycle(system: fake).hide().outcome == .refused)
        fake.pids = []
        #expect(IPhoneLifecycle(system: fake).hide().outcome == .notRunning)
    }

    @Test func showTwiceMakesOneScreen() throws {
        let fake = FakeMirroring()
        fake.screen = nil
        fake.pids = []
        let first = try IPhoneLifecycle(system: fake).show(screen: "phone")
        #expect(first.ok && first.screenCreated && first.mirroring == "launched")
        fake.pids = [42]
        let second = try IPhoneLifecycle(system: fake).show(screen: "phone")
        #expect(second.ok && !second.screenCreated && second.mirroring == "moved")
        #expect(fake.createdScreens == 1)
        #expect(fake.delivered.filter { $0.command == .screenCreate }.count == 1)
    }

    @Test func showAcceptsAScreenAnotherShowJustMade() throws {
        let fake = FakeMirroring()
        fake.screen = nil
        fake.createFails = true
        // The second look finds the screen the other `show` made.
        final class Racing: FakeMirroring {
            var looks = 0
            override func screenFrame(named name: String) throws -> CGRect? {
                looks += 1
                return looks == 1 ? nil : CGRect(x: 3000, y: 0, width: 525, height: 1001)
            }
        }
        let racing = Racing()
        racing.createFails = true
        let shown = try IPhoneLifecycle(system: racing).show(screen: "phone")
        #expect(shown.ok && !shown.screenCreated)
        #expect(racing.looks == 2)
        // With no screen after all, it fails with the create's error.
        let alone = try IPhoneLifecycle(system: fake).show(screen: "phone")
        #expect(!alone.ok && alone.error?.contains("already exists") == true)
    }
}
