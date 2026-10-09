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
    func withoutPaste<T>(_ body: () throws -> T) throws -> T? {
        guard !pasteInProgress else { return nil }
        return try body()
    }
    func whileNoPaste(_ body: () -> Void) -> Bool {
        guard !pasteInProgress else { return false }
        body()
        return true
    }
    var deliverThrows = false
    var inputBarrier = HostFlag(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdesktop-barrier-\(UUID().uuidString)/iphone-input-barrier"))
    var createdScreens = 0
    /// Shared between fakes to stand for two processes on one Mac.
    var reconnectGate = HostFlag(url: FileManager.default.temporaryDirectory
        .appendingPathComponent("agentdesktop-gate-\(UUID().uuidString)/iphone-reconnect-unconfirmed"))

    func mirroringPIDs() -> [pid_t] { pids }
    func screenFrame(named name: String) throws -> CGRect? { screen }
    /// Windows without a title are the phone's window.
    func windows(pid: pid_t) -> [IPhoneWindow] {
        (windowsByPID[pid] ?? []).map { window in
            var titled = window
            if titled.title == nil { titled.title = "iPhone Mirroring" }
            return titled
        }
    }

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

    /// Runs as text is recognised, as a slow read might let time pass.
    var onRecognize: (() -> Void)?
    func recognizedText(in image: CGImage) -> [String] {
        onRecognize?()
        return ocr
    }
    /// Texts of other windows of the app, such as its Settings.
    var axOtherWindows: [String] = []
    var buttonsOtherWindows: [String] = []
    /// Accessibility cannot be read (no permission, a failed read).
    var axUnreadable = false
    func accessibilityLabels(pid: pid_t, windowID: CGWindowID?) -> [String]? {
        if axUnreadable { return nil }
        return windowID == nil ? ax + axOtherWindows : ax
    }

    /// Runs as a press begins, before the button is looked for.
    var onPress: (() -> Void)?
    func pressButton(titled titles: Set<String>, pid: pid_t, windowID: CGWindowID?) -> String? {
        onPress?()
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

    /// Second independent review: a status page that exposes only its
    /// buttons through accessibility is not the phone; a tap is refused.
    @Test(arguments: [["Try Again"], ["继续", "取消"], ["Resume"], ["OK"]])
    func aStatusPagesButtonsAloneAreNotReady(controls: [String]) throws {
        #expect(IPhoneConnection.classify(controls).state == .uncertain)
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        fake.ax = controls
        fake.ocr = ["Connection Interrupted"]
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("not_connected") == true)
        #expect(fake.inputs.isEmpty)
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
        // The page's own Resume button, through accessibility.
        fake.ax = ["继续"]
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
        // Read off the picture, a title counts when the page's own controls
        // show through accessibility that it is a status page...
        // (A status control with no phrase read at all is still a status
        // page, so where the picture shows the phone it is uncertain.)
        let withControl: IPhoneConnectionState = state == .ready ? .uncertain : state
        #expect(IPhoneConnection.classify(["Try Again"], ocr: texts).state == withControl)
        #expect(IPhoneConnection.classify(["重试"], ocr: texts).state == withControl)
        // ...and on OCR alone it is not known: it could be the phone's own
        // screen or a page whose texts were not exposed. Never ready.
        let alone = IPhoneConnection.classify([], ocr: texts).state
        #expect(alone == (state == .ready ? .ready : .uncertain))
        // Accessibility that could not be read says nothing: never ready.
        #expect(IPhoneConnection.classify(nil, ocr: texts).state == .uncertain)
    }

    @Test func unreadableAccessibilityIsUncertainNotEmpty() {
        #expect(IPhoneConnection.classify(nil).state == .uncertain)
        #expect(IPhoneConnection.classify(nil, ocr: ["9:41", "微信"]).state == .uncertain)
        #expect(IPhoneConnection.classify([]).state == .ready)
    }

    @Test func aSentenceWithAStatusPhraseIsUncertainOnOCRAlone() {
        let line = "Connecting to the server, please keep this app open while we finish syncing your messages"
        // It may be a phone app's; it may be a status page: refused, not guessed.
        #expect(IPhoneConnection.classify([], ocr: [line]).state == .uncertain)
        // Mirroring's own text counts however long.
        #expect(IPhoneConnection.classify([line]).state == .reconnecting)
    }

    /// Codex on #126: with the status page's control showing through
    /// accessibility, its full message read by OCR matches the rules that
    /// are sentence fragments. Requiring the phrase at the start of the line
    /// called these pages ready, so their picture went out as the phone's.
    @Test(arguments: [
        ("iPhone Mirroring has ended due to iPhone use", IPhoneConnectionState.phoneInUse),
        // "is no longer in use" is a phone-in-use rule.
        ("Your iPhone is no longer in use", IPhoneConnectionState.phoneInUse),
        ("Your macOS user password or Touch ID is required to access your iPhone", IPhoneConnectionState.authRequired),
    ] as [(String, IPhoneConnectionState)])
    func aStatusPagesFullMessageCountsWithItsControl(message: String, state: IPhoneConnectionState) {
        #expect(IPhoneConnection.classify(["OK"], ocr: [message]).state == state)
        #expect(IPhoneConnection.classify(["Try Again"], ocr: [message]).state == state)
        // Without the page's control the same words could be a phone app's,
        // or the page's: not known, so not ready.
        #expect(IPhoneConnection.classify([], ocr: [message]).state == .uncertain)
    }

    /// Codex review of #61 / #95, settled by the safety review of #126: a
    /// phone app showing one short line that reads like a status title
    /// cannot be told from a status page whose texts were not exposed, so
    /// it is `uncertain` and refused, never guessed to be the phone. The
    /// cost: such an app's screen is not handed out.
    @Test(arguments: [
        "Connecting to Wi-Fi", "Timed Out", "Unlock iPhone", "已超时", "正在连接", "解锁iPhone",
        "Connection Interrupted", "iPhone in Use",
    ])
    func aShortStatusLineOnOCRAloneIsUncertain(line: String) throws {
        #expect(IPhoneConnection.classify([], ocr: [line]).state == .uncertain)
        #expect(IPhoneConnection.classify([], ocr: ["9:41", line, "Settings"]).state == .uncertain)
        // The screenshot is refused, and a paste's look at the phone (which
        // uses the same check) is not taken for a quiet phone.
        let fake = FakeMirroring()
        fake.ocr = ["9:41", line]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(try phone.connectionState().state == .uncertain)
        do {
            _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
            Issue.record("an uncertain window was handed out as the phone")
        } catch let error as IPhoneError {
            #expect(error.code == "not_connected" && error.reason == "uncertain")
        }
        #expect(fake.pressed.isEmpty && fake.delivered.isEmpty)
    }

    @Test func aScreenshotIsRefusedWhenAccessibilityCannotBeRead() throws {
        let fake = FakeMirroring()
        fake.axUnreadable = true
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(try phone.connectionState().state == .uncertain)
        #expect(throws: IPhoneError.self) { try phone.screenshot(size: CGSize(width: 330, height: 720)) }
    }

    @Test func aStatusTitleInThePictureCountsWithTheStatusPagesControls() throws {
        let fake = FakeMirroring()
        fake.ocr = ["Timed Out"]
        fake.ax = ["Try Again"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(try phone.connectionState().state == .disconnected)
        // Controls of another window of the app are no evidence (F6).
        fake.ax = []
        fake.axOtherWindows = ["Try Again"]
        #expect(try phone.connectionState().state == .uncertain)
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
        #expect(report.outcome == .ready && report.phase == .ready)
        #expect(report.readyReadings == IPhoneConnectionTracker.defaultStableReadings)
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

    @Test func reconnectPressesNothingWhenUncertain() throws {
        let fake = FakeMirroring()
        fake.ocr = ["Connection Paused"]
        fake.buttonsOtherWindows = ["Resume"]
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect()
        #expect(report.state == .uncertain && report.pressed == nil)
        #expect(fake.pressed.isEmpty)
    }

    /// Codex review of #61: once stopped, reconnect presses nothing.
    @Test func aReconnectAlreadyCancelledPressesNothing() throws {
        let fake = FakeMirroring()
        fake.ax = ["Connection Paused"]
        fake.buttons = ["Resume"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.isCancelled = { true }
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 20) }
        #expect(fake.pressed.isEmpty)
        #expect(fake.sleeps == 0)
    }

    @Test func aReconnectPastItsDeadlinePressesNothing() throws {
        let fake = FakeMirroring()
        fake.ax = ["Connection Interrupted"]
        fake.buttons = ["Try Again"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.deadline = fake.clock
        #expect(throws: IPhoneError("deadline_exceeded", "the deadline passed; nothing more is sent")) {
            try phone.reconnect(timeout: 20)
        }
        #expect(fake.pressed.isEmpty)
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

/// Safety review of #126: only the phone's own window is bound.
@Suite struct IPhoneWindowBindingTests {
    @Test func theSettingsWindowAloneIsNotBound() throws {
        let fake = FakeMirroring()
        fake.windowsByPID[42] = [IPhoneWindow(pid: 42, windowID: 9, frame: CGRect(x: 3010, y: 40, width: 480, height: 600),
                                              title: "iPhone Mirroring Settings")]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        #expect(throws: IPhoneError.self) { try phone.frame() }
        #expect(phone.binding == nil)
        #expect(try phone.perform(tap(3100, 300)).ok == false)
        #expect(fake.inputs.isEmpty)
    }

    @Test func aLargerSettingsWindowIsNotBoundOverThePhone() throws {
        let fake = FakeMirroring()
        fake.windowsByPID[42] = [
            IPhoneWindow(pid: 42, windowID: 9, frame: CGRect(x: 3010, y: 10, width: 500, height: 980), title: "iPhone镜像设置"),
            IPhoneWindow(pid: 42, windowID: 7, frame: CGRect(x: 3010, y: 40, width: 330, height: 720), title: "iPhone镜像"),
        ]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.frame()
        #expect(phone.binding?.windowID == 7)
    }

    @Test func anUntitledWindowIsNotTakenForThePhone() throws {
        let fake = FakeMirroring()
        fake.windowsByPID[42] = [IPhoneWindow(pid: 42, windowID: 9, frame: CGRect(x: 3010, y: 40, width: 330, height: 720),
                                              title: "")]
        #expect(throws: IPhoneError.self) { try IPhoneAgentScreen(screen: "phone", system: fake).frame() }
    }
}

/// Safety review of #126: before input, Mirroring's own texts are read
/// again, so a phone gone since the screenshot is not tapped.
@Suite struct IPhoneInputStatusRecheckTests {
    @Test func inputIsRefusedWhenAStatusPageAppearedSinceTheScreenshot() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        fake.ax = ["Connection Interrupted", "Try Again"]
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("not_connected (disconnected)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func inputIsRefusedWhenAccessibilityCannotBeRead() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        fake.axUnreadable = true
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("not_connected (uncertain)") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func inputGoesThroughWhileThePhoneShows() throws {
        let fake = FakeMirroring()
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(try phone.perform(tap(3100, 300)).ok)
        #expect(fake.inputs.count == 1)
    }
}

/// 2026-10-09 F8: after Resume, reconnect reported ready on one look, and
/// seconds later Mirroring showed "iPhone Mirroring Is Locked". Ready now
/// takes steady looks of the current connection generation.
@Suite struct IPhoneReconnectGenerationTests {
    static let needed = IPhoneConnectionTracker.defaultStableReadings

    /// Paused, with Resume; ready from the first look after the press.
    func pausedPhone() -> (FakeMirroring, IPhoneAgentScreen) {
        let fake = FakeMirroring()
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        return (fake, IPhoneAgentScreen(screen: "phone", system: fake))
    }

    @Test func readyOnlyAfterSteadyLooksSinceThePress() throws {
        let (fake, phone) = pausedPhone()
        var phases: [IPhoneConnectionPhase] = []
        let start = fake.clock
        fake.onSleep = {
            if fake.sleeps == 1 { fake.ax = [] }
            phases.append(phone.connection.phase)
        }
        let report = try phone.reconnect(timeout: 20)
        #expect(report.outcome == .ready && report.isReady)
        #expect(report.pressed == "Resume" && fake.pressed == ["Resume"])
        #expect(report.readyReadings == Self.needed)
        #expect(fake.sleeps == Self.needed)
        #expect(fake.clock.timeIntervalSince(start) >= Double(Self.needed - 1))
        // Connecting after the press, then connected, verifying, ready.
        #expect(phases.first == .connecting)
        #expect(phone.connection.phase == .ready && !phone.connection.awaitingConfirmation)
        #expect(try phone.screenshot(size: CGSize(width: 330, height: 720)).isEmpty == false)
        #expect(try phone.perform(tap(3100, 300)).ok)
    }

    /// F8 itself: ready right after Resume, then locked. Not ready, and no
    /// input until a reconnect confirms the phone.
    @Test func readyThenLockedIsNeverReported() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = {
            if fake.sleeps == 1 { fake.ax = [] }
            if fake.sleeps == 3 { fake.ax = ["iPhone Mirroring Is Locked"] }
        }
        let report = try phone.reconnect(timeout: 20)
        #expect(report.outcome == .needsUser && !report.isReady)
        #expect(report.state == .authRequired && report.label == "iPhone Mirroring Is Locked")
        #expect(report.phase == .disconnected && report.pressed == "Resume")
        #expect(fake.pressed == ["Resume"])
        // Even if the next screenshot happens to show the phone, input waits
        // for a reconnect that confirms it.
        fake.ax = []
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        let refused = try phone.perform(tap(3100, 300))
        #expect(refused.error?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake.inputs.isEmpty)
        fake.onSleep = nil
        let again = try phone.reconnect(timeout: 20)
        #expect(again.outcome == .ready && again.pressed == nil)
        #expect(try phone.perform(tap(3100, 300)).ok)
        #expect(fake.inputs.count == 1)
    }

    @Test func readyThenDisconnectedTimesOutUnconfirmed() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = {
            if fake.sleeps == 1 { fake.ax = [] }
            if fake.sleeps == 3 { fake.ax = ["Connection Interrupted"]; fake.buttons = [] }
        }
        let report = try phone.reconnect(timeout: 8)
        #expect(report.outcome == .pressedUnconfirmed && report.timedOut && !report.isReady)
        #expect(report.state == .disconnected && report.readyReadings == 0)
        #expect(phone.connection.awaitingConfirmation)
    }

    /// A moment of ready at the timeout is not ready: the stable window
    /// never closed.
    @Test func readyAtTheTimeoutIsStillUnconfirmed() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = { if fake.sleeps == 2 { fake.ax = [] } }
        let report = try phone.reconnect(timeout: 3)
        #expect(report.state == .ready)
        #expect(report.outcome == .pressedUnconfirmed && report.timedOut && !report.isReady)
        #expect(report.readyReadings < Self.needed)
    }

    /// Two reconnects back to back: the ready looks of the first do not
    /// count toward the second, which needs its own after its own press.
    @Test func aQuickSecondReconnectStartsCountingAgain() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = { if fake.sleeps == 1 { fake.ax = [] } }
        let first = try phone.reconnect(timeout: Double(Self.needed - 2))
        #expect(first.outcome == .pressedUnconfirmed && first.readyReadings == Self.needed - 2)
        #expect(first.generation == 2)

        fake.ax = ["Connection Interrupted", "Try Again"]
        fake.buttons = ["Try Again"]
        let sleepsBefore = fake.sleeps
        var readingsSeen: [Int] = []
        fake.onSleep = {
            fake.ax = []
            readingsSeen.append(phone.connection.readyStreak)
        }
        let second = try phone.reconnect(timeout: 20)
        #expect(second.outcome == .ready && second.pressed == "Try Again")
        #expect(second.generation == 4)
        #expect(fake.sleeps - sleepsBefore == Self.needed)
        // Counting started from nothing after the second press.
        #expect(readingsSeen.first == 0)
    }

    /// A slow look of an earlier generation, arriving after a new press,
    /// is dropped: ready looks from before do not make the new one ready.
    @Test func aLateLookOfAnEarlierGenerationIsIgnored() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = { if fake.sleeps == 1 { fake.ax = [] } }
        _ = try phone.reconnect(timeout: Double(Self.needed - 2))
        let old = phone.connection.generation

        fake.ax = ["Connection Paused", "Resume"]
        var accepted: [Bool] = []
        fake.onSleep = {
            // The phone stays paused; only stale "ready" looks arrive.
            for step in 0..<Self.needed {
                accepted.append(phone.record(IPhoneConnectionObservation(
                    generation: old, state: .ready, windowID: 7,
                    at: fake.clock.addingTimeInterval(Double(step)))))
            }
        }
        let report = try phone.reconnect(timeout: 5)
        #expect(accepted.allSatisfy { !$0 } && !accepted.isEmpty)
        #expect(report.outcome == .pressedUnconfirmed && !report.isReady)
        #expect(report.readyReadings == 0)
        #expect(report.state == .disconnected)
    }

    /// Codex review of d1304fe: a reconnect held back by the barrier is not
    /// a confirmation; lowering the barrier with a screenshot does not let
    /// input through until a reconnect reports ready.
    @Test func aBarrierStillUpKeepsItFromReady() throws {
        let (fake, phone) = pausedPhone()
        try fake.inputBarrier.raise("may hold a half-finished paste")
        fake.onSleep = { if fake.sleeps == 1 { fake.ax = [] } }
        let report = try phone.reconnect(timeout: 20)
        #expect(report.outcome == .notReady && !report.isReady)
        #expect(report.blockedBy?.contains("half-finished paste") == true)
        #expect(phone.connection.awaitingConfirmation)
        fake.onSleep = nil
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(fake.inputBarrier.reason(now: fake.clock) == nil)
        let refused = try phone.perform(tap(3100, 300))
        #expect(refused.error?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake.inputs.isEmpty)
        let again = try phone.reconnect(timeout: 20)
        #expect(again.outcome == .ready)
        #expect(try phone.perform(tap(3100, 300)).ok)
    }

    /// Codex review of d1304fe: the last ready look landing on the timeout
    /// does not make it ready; a little more time does.
    @Test func theLastReadyLookAtTheTimeoutIsNotReady() throws {
        let (fake, phone) = pausedPhone()
        fake.onSleep = { if fake.sleeps == 1 { fake.ax = [] } }
        let atTimeout = try phone.reconnect(timeout: Double(Self.needed))
        #expect(atTimeout.outcome == .pressedUnconfirmed && atTimeout.timedOut)
        #expect(atTimeout.readyReadings == Self.needed && atTimeout.phase == .ready)
        #expect(phone.connection.awaitingConfirmation)

        let (fake2, phone2) = pausedPhone()
        fake2.onSleep = { if fake2.sleeps == 1 { fake2.ax = [] } }
        let inTime = try phone2.reconnect(timeout: Double(Self.needed) + 0.5)
        #expect(inTime.outcome == .ready && !inTime.timedOut)
    }

    @Test func aWindowSwappedMidwayStartsTheCountAgain() throws {
        let (fake, phone) = pausedPhone()
        var streakAtSwap = -1
        fake.onSleep = {
            if fake.sleeps == 1 { fake.ax = [] }
            if fake.sleeps == 3 {
                streakAtSwap = phone.connection.readyStreak
                fake.windowsByPID[42] = [IPhoneWindow(pid: 42, windowID: 9, frame: CGRect(x: 3010, y: 40, width: 330, height: 720))]
            }
        }
        let report = try phone.reconnect(timeout: 20)
        #expect(streakAtSwap == 2)
        #expect(report.outcome == .ready && phone.binding?.windowID == 9)
        #expect(fake.sleeps == 2 + Self.needed)
    }
}

/// The tracker alone: generations, spacing, resets.
@Suite struct IPhoneConnectionTrackerTests {
    let t0 = Date(timeIntervalSince1970: 2_000_000)

    func look(_ generation: Int, _ state: IPhoneConnectionState, _ seconds: Double, window: CGWindowID? = 7)
        -> IPhoneConnectionObservation {
        IPhoneConnectionObservation(generation: generation, state: state, windowID: window, at: t0.addingTimeInterval(seconds))
    }

    @Test func phasesGoConnectingConnectedVerifyingReady() {
        var tracker = IPhoneConnectionTracker(stableReadings: 3, spacing: 1)
        let g = tracker.begin(at: t0, pressed: true)
        #expect(tracker.phase == .connecting && tracker.awaitingConfirmation)
        tracker.record(look(g, .ready, 0.5)); #expect(tracker.phase == .connected)
        tracker.record(look(g, .ready, 1.0)); #expect(tracker.phase == .connected)  // too soon: not counted
        tracker.record(look(g, .ready, 1.5)); #expect(tracker.phase == .verifying)
        tracker.record(look(g, .ready, 2.5)); #expect(tracker.phase == .ready)
        #expect(tracker.isReady(window: 7) && !tracker.isReady(window: 8))
        // Steady looks alone do not lift the gate; a reported ready does.
        #expect(tracker.awaitingConfirmation)
        tracker.confirm()
        #expect(!tracker.awaitingConfirmation)
    }

    @Test func confirmDoesNothingBeforeReady() {
        var tracker = IPhoneConnectionTracker(stableReadings: 2, spacing: 1)
        let g = tracker.begin(at: t0, pressed: true)
        tracker.record(look(g, .ready, 1))
        tracker.confirm()
        #expect(tracker.awaitingConfirmation && tracker.phase == .connected)
    }

    @Test func anyOtherLookStartsOver() {
        var tracker = IPhoneConnectionTracker(stableReadings: 3, spacing: 1)
        let g = tracker.begin(at: t0, pressed: true)
        for (state, phase) in [(IPhoneConnectionState.uncertain, IPhoneConnectionPhase.connecting),
                               (.reconnecting, .connecting), (.authRequired, .disconnected), (.disconnected, .disconnected)] {
            tracker.begin(at: t0, pressed: true)
            let g = tracker.generation
            tracker.record(look(g, .ready, 1)); tracker.record(look(g, .ready, 2))
            tracker.record(look(g, state, 3))
            #expect(tracker.readyStreak == 0 && tracker.phase == phase)
            tracker.record(look(g, .ready, 4))
            #expect(tracker.phase == .connected)
        }
        _ = g
    }

    @Test func looksOfEarlierGenerationsOrBeforeThePressAreDropped() {
        var tracker = IPhoneConnectionTracker(stableReadings: 2, spacing: 1)
        let first = tracker.begin(at: t0, pressed: true)
        tracker.record(look(first, .ready, 1))
        let second = tracker.begin(at: t0.addingTimeInterval(5), pressed: true)
        let r1 = tracker.record(look(first, .ready, 6))
        #expect(!r1)
        let r2 = tracker.record(look(first, .ready, 7))
        #expect(!r2)
        let beforePress = tracker.record(look(second, .ready, 4))  // began before the press
        #expect(!beforePress)
        #expect(tracker.phase == .connecting && tracker.readyStreak == 0)
        let r3 = tracker.record(look(second, .ready, 6))
        #expect(r3)
        let r4 = tracker.record(look(second, .ready, 7))
        #expect(r4)
        #expect(tracker.phase == .ready)
    }

    @Test func aLookOlderThanTheLatestIsDropped() {
        var tracker = IPhoneConnectionTracker(stableReadings: 2, spacing: 1)
        let g = tracker.begin(at: t0, pressed: true)
        tracker.record(look(g, .authRequired, 3))
        let r5 = tracker.record(look(g, .ready, 1))
        #expect(!r5)
        let r6 = tracker.record(look(g, .ready, 2))
        #expect(!r6)
        #expect(tracker.phase == .disconnected)
    }

    @Test func aCheckWithoutAPressDoesNotClearAnUnconfirmedOne() {
        var tracker = IPhoneConnectionTracker(stableReadings: 2, spacing: 1)
        tracker.begin(at: t0, pressed: true)
        let g = tracker.begin(at: t0.addingTimeInterval(1), pressed: false)
        #expect(tracker.awaitingConfirmation)
        tracker.record(look(g, .authRequired, 2))
        #expect(tracker.awaitingConfirmation)
        tracker.record(look(g, .ready, 3)); tracker.record(look(g, .ready, 4))
        tracker.confirm()
        #expect(!tracker.awaitingConfirmation)
    }

    @Test func aReadyLookWithNoWindowIsNotReady() {
        var tracker = IPhoneConnectionTracker(stableReadings: 1, spacing: 1)
        let g = tracker.begin(at: t0, pressed: true)
        tracker.record(look(g, .ready, 1, window: nil))
        #expect(tracker.phase == .connecting && !tracker.isReady(window: nil))
    }
}

/// Codex review of b06c70f: the CLI makes a new screen, in a new process,
/// for every command, so the unconfirmed press is kept for the whole Mac.
@Suite struct IPhoneReconnectGateAcrossProcessesTests {
    static let needed = IPhoneConnectionTracker.defaultStableReadings

    /// Two Macs' worth of fakes sharing one gate file: two processes.
    func twoProcesses() -> (FakeMirroring, FakeMirroring) {
        let first = FakeMirroring()
        let second = FakeMirroring()
        second.reconnectGate = first.reconnectGate
        return (first, second)
    }

    @Test func anUnconfirmedPressInOneProcessRefusesInputInAnother() throws {
        let (fake1, fake2) = twoProcesses()
        defer { fake1.reconnectGate.lower() }
        fake1.ax = ["Connection Paused", "Resume"]
        fake1.buttons = ["Resume"]
        fake1.onSleep = { if fake1.sleeps == 1 { fake1.ax = [] } }
        let report = try IPhoneAgentScreen(screen: "phone", system: fake1).reconnect(timeout: 2)
        #expect(report.outcome == .pressedUnconfirmed)

        // The next command: a new screen, the phone momentarily ready.
        let phone2 = IPhoneAgentScreen(screen: "phone", system: fake2)
        _ = try phone2.screenshot(size: CGSize(width: 330, height: 720))
        // Typing pastes through the real clipboard, so it is left out here;
        // its ⌘V goes through the same check as these.
        for action in [tap(3100, 300), { var key = InputAction(.key); key.key = "home"; return key }()] {
            let refused = try phone2.perform(action)
            #expect(refused.error?.hasPrefix("not_connected (unconfirmed)") == true)
        }
        #expect(fake2.inputs.isEmpty)

        // A reconnect that confirms the phone, in any process, lifts it.
        let confirmed = try IPhoneAgentScreen(screen: "phone", system: fake2).reconnect(timeout: 20)
        #expect(confirmed.outcome == .ready)
        #expect(fake1.reconnectGate.reason(now: fake2.clock) == nil)
        #expect(try phone2.perform(tap(3100, 300)).ok)
    }

    /// Locked after the press (F8), seen by the next process.
    @Test func aPressThatEndedNeedingTheUserStaysUpForTheNextProcess() throws {
        let (fake1, fake2) = twoProcesses()
        defer { fake1.reconnectGate.lower() }
        fake1.ax = ["Connection Paused", "Resume"]
        fake1.buttons = ["Resume"]
        fake1.onSleep = {
            if fake1.sleeps == 1 { fake1.ax = [] }
            if fake1.sleeps == 2 { fake1.ax = ["iPhone Mirroring Is Locked"] }
        }
        let report = try IPhoneAgentScreen(screen: "phone", system: fake1).reconnect(timeout: 20)
        #expect(report.outcome == .needsUser)
        let phone2 = IPhoneAgentScreen(screen: "phone", system: fake2)
        _ = try phone2.screenshot(size: CGSize(width: 330, height: 720))
        #expect(try phone2.perform(tap(3100, 300)).error?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake2.inputs.isEmpty)
    }

    /// While the first is still polling, the second refuses already.
    @Test func inputIsRefusedWhileAnotherProcessIsStillVerifying() throws {
        let (fake1, fake2) = twoProcesses()
        defer { fake1.reconnectGate.lower() }
        let phone2 = IPhoneAgentScreen(screen: "phone", system: fake2)
        _ = try phone2.screenshot(size: CGSize(width: 330, height: 720))
        fake1.ax = ["Connection Paused", "Resume"]
        fake1.buttons = ["Resume"]
        var refusedMidway: String?
        fake1.onSleep = {
            if fake1.sleeps == 1 { fake1.ax = [] }
            if fake1.sleeps == 2 { refusedMidway = (try? phone2.perform(tap(3100, 300)))?.error }
        }
        let report = try IPhoneAgentScreen(screen: "phone", system: fake1).reconnect(timeout: 20)
        #expect(refusedMidway?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake2.inputs.isEmpty)
        #expect(report.outcome == .ready)
    }

    /// A press by another process while this one was verifying is not
    /// confirmed by it: the gate stays up and ready is not reported.
    @Test func aPressElsewhereDuringVerificationIsNotClearedByIt() throws {
        let (fake1, fake2) = twoProcesses()
        defer { fake1.reconnectGate.lower() }
        fake2.onSleep = {
            if fake2.sleeps == 2 { try? fake1.reconnectGate.raise("another process pressed Resume") }
        }
        let report = try IPhoneAgentScreen(screen: "phone", system: fake2).reconnect(timeout: 20)
        #expect(report.outcome == .notReady && !report.isReady)
        #expect(report.blockedBy?.contains("another") == true)
        #expect(fake1.reconnectGate.reason(now: fake1.clock) == "another process pressed Resume")
    }

    /// An unreadable record counts as up.
    @Test func anUnreadableGateRefusesInput() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        try FileManager.default.createDirectory(at: fake.reconnectGate.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: fake.reconnectGate.url)
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        #expect(try phone.perform(tap(3100, 300)).error?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake.inputs.isEmpty)
    }

    /// The gate cannot be recorded: nothing is pressed.
    @Test func noPressWhenTheGateCannotBeRaised() throws {
        let fake = FakeMirroring()
        // A file where the gate's directory should be.
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("agentdesktop-gate-file-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        fake.reconnectGate = HostFlag(url: blocker.appendingPathComponent("iphone-reconnect-unconfirmed"))
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect(timeout: 20)
        #expect(report.outcome == .notReady && report.pressed == nil)
        #expect(fake.pressed.isEmpty)
    }
}

/// Codex review of 066b83c: changes to the gate by overlapping reconnects
/// are made one process at a time (a lock beside the gate's file), so a
/// newer press is never lowered or overwritten by an older reconnect.
@Suite struct IPhoneReconnectGateLockTests {
    /// Integrating with #127: HostFlag locks "<flag>.lock" for each read and
    /// change, which the gate lock's holder makes (raising the gate); the
    /// same file for both deadlocked the process on its own flock.
    @Test func theGateLockIsNotTheFlagsOwnLock() {
        let gate = HostFlag(url: FileManager.default.temporaryDirectory.appendingPathComponent("gate-\(UUID().uuidString)"))
        #expect(HostFlagLock(for: gate, wait: 0).url.path != gate.url.path + ".lock")
    }

    /// Hold the gate's lock as another process would.
    static func holdLock(of gate: HostFlag) throws -> Int32 {
        try FileManager.default.createDirectory(at: gate.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(HostFlagLock(for: gate, wait: 0).url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0, flock(fd, LOCK_EX | LOCK_NB) == 0 else { throw IPhoneError("test", "cannot lock") }
        return fd
    }

    static func release(_ fd: Int32) {
        flock(fd, LOCK_UN)
        close(fd)
    }

    @Test func aPressWaitsForTheLockAndPressesNothingWithout() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let fd = try Self.holdLock(of: fake.reconnectGate)
        defer { Self.release(fd) }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.gateLockWait = 0.2
        let report = try phone.reconnect(timeout: 20)
        #expect(report.outcome == .notReady && report.pressed == nil)
        #expect(fake.pressed.isEmpty)
        #expect(fake.reconnectGate.reason(now: fake.clock) == nil)
    }

    /// Finding 1: the gate is compared and lowered as one step; while
    /// another process holds it, a confirming reconnect lowers nothing and
    /// does not report ready.
    @Test func aConfirmingReconnectLowersNothingWhileAnotherHoldsTheLock() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        try fake.reconnectGate.raise("an earlier press")
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.gateLockWait = 0.2
        var fd: Int32 = -1
        fake.onSleep = { if fake.sleeps == 1 { fd = (try? Self.holdLock(of: fake.reconnectGate)) ?? -1 } }
        let report = try phone.reconnect(timeout: 20)
        if fd >= 0 { Self.release(fd) }
        #expect(fd >= 0)
        #expect(report.outcome == .notReady && !report.isReady)
        #expect(fake.reconnectGate.reason(now: fake.clock) == "an earlier press")
        // Once free, a reconnect confirms and lowers it.
        fake.onSleep = nil
        #expect(try phone.reconnect(timeout: 20).outcome == .ready)
        #expect(fake.reconnectGate.reason(now: fake.clock) == nil)
    }

    /// Finding 2: reconnect B starts while A is between raising the gate
    /// and pressing. B cannot raise or press until A is done, and A's
    /// rollback (no button) leaves no press of B's unrecorded.
    @Test func anOverlappingPressCannotSlipBetweenRaiseAndRollback() throws {
        let fakeA = FakeMirroring()
        let fakeB = FakeMirroring()
        fakeB.reconnectGate = fakeA.reconnectGate
        defer { fakeA.reconnectGate.lower() }
        for fake in [fakeA, fakeB] {
            fake.ax = ["Connection Paused", "Resume"]
            fake.buttons = ["Resume"]
        }
        let phoneB = IPhoneAgentScreen(screen: "phone", system: fakeB)
        phoneB.gateLockWait = 0.2
        var reportB: IPhoneAgentScreen.ReconnectReport?
        fakeA.onPress = {
            reportB = try? phoneB.reconnect(timeout: 1)
            // B's press, had it gone through, took the button away.
            fakeA.buttons = []
        }
        let reportA = try IPhoneAgentScreen(screen: "phone", system: fakeA).reconnect(timeout: 20)
        #expect(reportA.outcome == .notReady && reportA.pressed == nil)
        #expect(reportB?.outcome == .notReady && reportB?.pressed == nil)
        #expect(fakeB.pressed.isEmpty)
    }

    @Test func noButtonPutsBackTheGateItFound() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        try fake.reconnectGate.raise("an earlier press")
        fake.ax = ["Connection Paused"]
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect(timeout: 20)
        #expect(report.outcome == .notReady && report.pressed == nil)
        #expect(fake.reconnectGate.reason(now: fake.clock) == "an earlier press")
    }
}

/// Codex review of 98f049d: input checks the gate and is sent under the
/// gate's lock (shared), so a reconnect cannot raise it and press between
/// the check and the send; a reconnect that waited for the lock looks
/// again at whether it should still press.
@Suite struct IPhoneReconnectGateInputTests {
    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        func set() { lock.lock(); value = true; lock.unlock() }
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    }

    @Test func inputWaitsForAReconnectChangingTheGateAndSendsNothingWithout() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.gateLockWait = 0.2
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate)
        let refused = try phone.perform(tap(3100, 300))
        IPhoneReconnectGateLockTests.release(fd)
        #expect(refused.error?.hasPrefix("not_connected (unconfirmed)") == true)
        #expect(fake.inputs.isEmpty)
        #expect(try phone.perform(tap(3100, 300)).ok)
        #expect(fake.inputs.count == 1)
    }

    /// Input from other processes runs side by side: the lock is shared.
    @Test func inputsDoNotStopEachOther() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        phone.gateLockWait = 0.2
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        try FileManager.default.createDirectory(at: fake.reconnectGate.url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let fd = open(HostFlagLock(for: fake.reconnectGate, wait: 0).url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        #expect(fd >= 0 && flock(fd, LOCK_SH | LOCK_NB) == 0)
        defer { flock(fd, LOCK_UN); close(fd) }
        #expect(try phone.perform(tap(3100, 300)).ok)
    }

    @Test func aReconnectCancelledWhileItWaitedForTheLockPressesNothing() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            cancelled.set()
            IPhoneReconnectGateLockTests.release(fd)
        }
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 20) }
        #expect(fake.pressed.isEmpty)
        #expect(fake.reconnectGate.reason(now: fake.clock) == nil)
    }

    /// A Mac whose clock jumps a minute ahead once `late` is set.
    final class Clocked: FakeMirroring {
        let late = Flag()
        let start = Date(timeIntervalSince1970: 1_000_000)
        override var now: Date { late.isSet ? clock.addingTimeInterval(60) : clock }
    }

    @Test func aReconnectPastItsTimeoutWhenTheLockCamePressesNothing() throws {
        let fake = Clocked()
        defer { fake.reconnectGate.lower() }
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            fake.late.set()
            IPhoneReconnectGateLockTests.release(fd)
        }
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect(timeout: 5)
        #expect(report.pressed == nil && !report.isReady && report.timedOut)
        #expect(fake.pressed.isEmpty)
        #expect(fake.reconnectGate.reason(now: fake.start) == nil)
    }
}

/// Codex review of 3077ee7: whatever waited for the gate's lock looks
/// again, once it has it, at whether it was stopped or ran out of time.
@Suite struct IPhoneGateLockRecheckTests {
    typealias Flag = IPhoneReconnectGateInputTests.Flag
    typealias Clocked = IPhoneReconnectGateInputTests.Clocked

    /// Hold the lock from the first sleep; `then` runs 0.3 s later, just
    /// before it is let go.
    static func holdFromFirstSleep(_ fake: FakeMirroring, then: @escaping @Sendable () -> Void) {
        fake.onSleep = { [unowned fake] in
            guard fake.sleeps == 1, let fd = try? IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate) else { return }
            Thread.detachNewThread {
                Thread.sleep(forTimeInterval: 0.3)
                then()
                IPhoneReconnectGateLockTests.release(fd)
            }
        }
    }

    @Test func aReconnectCancelledWhileWaitingToLowerTheGateLowersNothing() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        try fake.reconnectGate.raise("an earlier press")
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        Self.holdFromFirstSleep(fake) { cancelled.set() }
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 20) }
        #expect(fake.reconnectGate.reason(now: fake.clock) == "an earlier press")
    }

    @Test func aReconnectOutOfTimeWhileWaitingToLowerTheGateLowersNothing() throws {
        let fake = Clocked()
        defer { fake.reconnectGate.lower() }
        try fake.reconnectGate.raise("an earlier press")
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let late = fake.late
        Self.holdFromFirstSleep(fake) { late.set() }
        let report = try phone.reconnect(timeout: Double(IPhoneConnectionTracker.defaultStableReadings) + 1)
        #expect(!report.isReady && report.timedOut)
        #expect(fake.reconnectGate.reason(now: fake.clock) == "an earlier press")
    }

    @Test func inputCancelledWhileWaitingForTheLockIsNotSent() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.3)
            cancelled.set()
            IPhoneReconnectGateLockTests.release(fd)
        }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("cancelled") == true)
        #expect(fake.inputs.isEmpty)
    }
}

/// Codex review of 1da88ee: a wait for the gate's lock ends as soon as the
/// caller is stopped or out of time, not after the lock's own 10 s.
@Suite struct IPhoneGateLockPromptnessTests {
    typealias Flag = IPhoneReconnectGateInputTests.Flag
    typealias Clocked = IPhoneReconnectGateInputTests.Clocked

    /// Hold the lock for the whole test; `then` runs 0.2 s in.
    static func holdAll(_ gate: HostFlag, then: @escaping @Sendable () -> Void) throws -> Int32 {
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: gate)
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.2)
            then()
        }
        return fd
    }

    @Test func aPressWaitEndsWhenCancelled() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        let fd = try Self.holdAll(fake.reconnectGate) { cancelled.set() }
        defer { IPhoneReconnectGateLockTests.release(fd) }
        let started = Date()
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 20) }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(fake.pressed.isEmpty)
    }

    @Test func aPressWaitEndsAtTheTimeout() throws {
        let fake = Clocked()
        defer { fake.reconnectGate.lower() }
        fake.ax = ["Connection Paused", "Resume"]
        fake.buttons = ["Resume"]
        let late = fake.late
        let fd = try Self.holdAll(fake.reconnectGate) { late.set() }
        defer { IPhoneReconnectGateLockTests.release(fd) }
        let started = Date()
        let report = try IPhoneAgentScreen(screen: "phone", system: fake).reconnect(timeout: 5)
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(report.timedOut && report.pressed == nil && !report.isReady)
        #expect(fake.pressed.isEmpty)
    }

    @Test func aLoweringWaitEndsWhenCancelled() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        try fake.reconnectGate.raise("an earlier press")
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        var fd: Int32 = -1
        fake.onSleep = {
            if fake.sleeps == 1 { fd = (try? Self.holdAll(fake.reconnectGate) { cancelled.set() }) ?? -1 }
        }
        let started = Date()
        #expect(throws: IPhoneError("cancelled", "stopped; nothing more is sent")) { try phone.reconnect(timeout: 20) }
        if fd >= 0 { IPhoneReconnectGateLockTests.release(fd) }
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(fake.reconnectGate.reason(now: fake.clock) == "an earlier press")
    }

    @Test func anInputWaitEndsWhenCancelled() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        let cancelled = Flag()
        phone.isCancelled = { cancelled.isSet }
        let fd = try Self.holdAll(fake.reconnectGate) { cancelled.set() }
        defer { IPhoneReconnectGateLockTests.release(fd) }
        let started = Date()
        let response = try phone.perform(tap(3100, 300))
        #expect(Date().timeIntervalSince(started) < 3)
        #expect(response.error?.hasPrefix("cancelled") == true)
        #expect(fake.inputs.isEmpty)
    }
}

/// Codex review of 2cfa2f9: giving up is checked before the lock's own
/// wait runs out, so a caller stopped at that moment hears that it was
/// stopped, not that the lock was busy.
@Suite struct IPhoneGateLockGiveUpFirstTests {
    @Test func givingUpWinsOverTheWaitRunningOut() throws {
        let gate = FakeMirroring().reconnectGate
        defer { gate.lower() }
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: gate)
        defer { IPhoneReconnectGateLockTests.release(fd) }
        var ran = false
        #expect(throws: HostFlagLock.Failure.gaveUp) {
            try HostFlagLock(for: gate, wait: 0).locked(giveUp: { true }) { ran = true }
        }
        #expect(!ran)
    }

    @Test func anInputStoppedAsTheWaitRunsOutSaysCancelled() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        phone.gateLockWait = 0
        // Not stopped at the first check, stopped from then on.
        var calls = 0
        phone.isCancelled = { calls += 1; return calls >= 2 }
        let fd = try IPhoneReconnectGateLockTests.holdLock(of: fake.reconnectGate)
        defer { IPhoneReconnectGateLockTests.release(fd) }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("cancelled") == true)
        #expect(fake.inputs.isEmpty)
    }
}

/// Codex review of c74af97.
@Suite struct IPhonePreDispatchTests {
    /// A status page drawn as a picture, with nothing of it in
    /// accessibility: the check before input reads the picture too.
    @Test func aStatusPageSeenOnlyInThePictureRefusesInput() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        fake.ocr = ["iPhone in Use"]
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("not_connected (uncertain)") == true)
        #expect(fake.inputs.isEmpty)
    }

    /// An input whose window moved while it was sent raises the barrier
    /// before it lets go of the gate's lock; a reconnect waiting for the
    /// lock sees the barrier once it has it, and does not report ready.
    @Test func aReconnectWaitingOnAnInputSeesTheBarrierItRaised() throws {
        let input = FakeMirroring()
        let other = FakeMirroring()
        other.reconnectGate = input.reconnectGate
        other.inputBarrier = input.inputBarrier
        defer { input.reconnectGate.lower(); input.inputBarrier.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: input)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))

        let aboutToConfirm = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        other.onSleep = { if other.sleeps == IPhoneConnectionTracker.defaultStableReadings - 1 { aboutToConfirm.signal() } }
        final class Box: @unchecked Sendable { var report: IPhoneAgentScreen.ReconnectReport? }
        let box = Box()
        input.afterDeliver = {
            Thread.detachNewThread {
                box.report = try? IPhoneAgentScreen(screen: "phone", system: other).reconnect(timeout: 20)
                finished.signal()
            }
            // The reconnect has seen the phone ready and checked the
            // barrier (down); it now waits for the lock this input holds.
            _ = aboutToConfirm.wait(timeout: .now() + 5)
            Thread.sleep(forTimeInterval: 0.2)
            input.move(7, to: CGRect(x: 3020, y: 40, width: 330, height: 720))
        }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("action_delivery_unknown") == true)
        #expect(finished.wait(timeout: .now() + 15) == .success)
        #expect(box.report?.isReady == false)
        #expect(box.report?.blockedBy?.contains("input barrier") == true)
    }
}

/// Codex reviews of 1c2c76b and 550593c.
@Suite struct IPhoneLocaleAndBlankTests {
    /// A Mac in a language whose status pages are not recognised: its
    /// phone window is not bound, so a French "Connexion interrompue" page
    /// is never read as ready nor tapped. Fails closed.
    @Test func aPhoneWindowInAnUnrecognisedLanguageIsNotBound() throws {
        let fake = FakeMirroring()
        fake.windowsByPID[42] = [IPhoneWindow(pid: 42, windowID: 7, frame: CGRect(x: 3010, y: 40, width: 330, height: 720),
                                              title: "Recopie de l\u{2019}iPhone")]
        fake.ax = ["Connexion interrompue", "R\u{00E9}essayer"]
        fake.buttons = ["R\u{00E9}essayer"]
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        #expect(throws: IPhoneError.self) { try phone.frame() }
        #expect(throws: IPhoneError.self) { try phone.screenshot(size: CGSize(width: 330, height: 720)) }
        #expect(throws: IPhoneError.self) { try phone.reconnect(timeout: 5) }
        #expect(try phone.perform(tap(3100, 300)).ok == false)
        #expect(fake.inputs.isEmpty && fake.pressed.isEmpty)
    }

    /// A flat, undrawn capture before input says nothing: refused, as a
    /// screenshot of it is.
    @Test func aBlankCaptureBeforeInputRefusesIt() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        fake.blank = true
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("not_connected (uncertain)") == true)
        #expect(fake.inputs.isEmpty)
    }
}

/// Codex review of 520d6cf: stopped while the window was read before
/// input, nothing is sent.
@Suite struct IPhoneStopDuringPreDispatchTests {
    @Test func cancelledWhileTheWindowIsReadSendsNothing() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        var cancelled = false
        phone.isCancelled = { cancelled }
        fake.onRecognize = { cancelled = true }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("cancelled") == true)
        #expect(fake.inputs.isEmpty)
    }

    @Test func pastTheDeadlineWhileTheWindowIsReadSendsNothing() throws {
        let fake = FakeMirroring()
        defer { fake.reconnectGate.lower() }
        let phone = IPhoneAgentScreen(screen: "phone", system: fake)
        _ = try phone.screenshot(size: CGSize(width: 330, height: 720))
        phone.deadline = fake.clock.addingTimeInterval(1)
        fake.onRecognize = { fake.clock = fake.clock.addingTimeInterval(2) }
        let response = try phone.perform(tap(3100, 300))
        #expect(response.error?.hasPrefix("deadline_exceeded") == true)
        #expect(fake.inputs.isEmpty)
    }
}
