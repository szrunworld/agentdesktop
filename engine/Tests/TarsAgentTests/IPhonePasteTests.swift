import AppKit
import CoreGraphics
import Foundation
import SecondScreenCore
import Testing
@testable import TarsAgent

/// A phone played from a script: each look returns the next screen (the
/// last one repeats); `nil` is a screen that cannot be read.
final class ScriptedPhone: PhonePasteDriver {
    var baseline: [PhoneText]?
    var screens: [[PhoneText]?]
    var pasteResponse = ControlResponse()
    var tapResponse = ControlResponse()
    var pauseSeconds: TimeInterval = 0
    var pasteboard: NSPasteboard?

    private(set) var looks = 0
    private(set) var taps: [CGPoint] = []
    private(set) var pasted: [String?] = []
    private(set) var log: [String] = []

    init(baseline: [PhoneText]? = [], _ screens: [[PhoneText]?]) {
        self.baseline = baseline
        self.screens = screens
    }

    struct Unreadable: Error {}

    func look() throws -> [PhoneText] {
        defer { looks += 1 }
        let screen: [PhoneText]?
        if looks == 0 {
            screen = baseline
        } else {
            screen = screens[min(looks - 1, screens.count - 1)]
        }
        guard let screen else { throw Unreadable() }
        return screen
    }

    func pressPaste() throws -> ControlResponse {
        let text = pasteboard?.string(forType: .string)
        pasted.append(text)
        log.append("paste:\(text ?? "")")
        return pasteResponse
    }

    func tap(_ point: CGPoint) throws -> ControlResponse {
        taps.append(point)
        return tapResponse
    }

    func pause(_ seconds: TimeInterval) {
        if pauseSeconds > 0 { Thread.sleep(forTimeInterval: pauseSeconds) }
        if let pasteboard { log.append("hold:\(pasteboard.string(forType: .string) ?? "")") }
    }
}

func line(_ text: String, x: CGFloat = 0.3, y: CGFloat, width: CGFloat = 0.4) -> PhoneText {
    PhoneText(text, CGRect(x: x, y: y, width: width, height: 0.03))
}

let keyboard = [line("q w e r t y u i o p", x: 0.05, y: 0.75, width: 0.9)]
let alert = [
    line("\u{201C}Notes\u{201D} would like to paste from \u{201C}Mac\u{201D}", x: 0.2, y: 0.42, width: 0.6),
    line("Don\u{2019}t Allow Paste", y: 0.50),
    line("Allow Paste", y: 0.56),
]
let pasting = [line("Pasting from Mac", y: 0.05)]
let allowButton = CGPoint(x: 0.5, y: 0.575)

func isAllow(_ prompt: PastePrompt, at point: CGPoint = allowButton) -> Bool {
    guard case .allow(let at) = prompt else { return false }
    return abs(at.x - point.x) < 1e-9 && abs(at.y - point.y) < 1e-9
}

func fast() -> PasteWatcher {
    var watcher = PasteWatcher()
    watcher.interval = 0
    watcher.maxLooks = 8
    return watcher
}

@Suite struct PastePromptReading {
    @Test func pressesTheSystemAlert() {
        let prompt = PastePrompt.read(alert + keyboard, baseline: keyboard)
        #expect(isAllow(prompt))
    }

    @Test func chineseAlertWithItsDenyButton() {
        let screen = [line("不允许粘贴", y: 0.5), line("允许粘贴", y: 0.56)]
        #expect(isAllow(PastePrompt.read(screen, baseline: [])))
    }

    @Test func chineseAlertWithItsMessage() {
        let screen = [line("“备忘录”想要粘贴来自“Mac”的内容", x: 0.2, y: 0.45, width: 0.6), line("允许粘贴", y: 0.56)]
        #expect(isAllow(PastePrompt.read(screen, baseline: [])))
    }

    /// I08: page content that says "Allow Paste" is never pressed.
    @Test func ignoresALoneAllowPaste() {
        let screen = [line("Allow Paste", y: 0.5)] + keyboard
        #expect(PastePrompt.read(screen, baseline: []) == .unverifiedAllow)
        // Already there before the paste: it is the page's.
        #expect(PastePrompt.read(screen, baseline: screen) == .none)
    }

    @Test func ignoresAnAllowPasteOutsideTheMiddle() {
        let screen = [line("Don't Allow Paste", y: 0.05), line("Allow Paste", y: 0.1)]
        #expect(PastePrompt.read(screen, baseline: []) == .unverifiedAllow)
    }

    @Test func ignoresEvidenceFarFromTheButton() {
        let screen = [line("Settings: would like to paste", y: 0.21), line("Allow Paste", y: 0.8)]
        #expect(PastePrompt.read(screen, baseline: []) == .unverifiedAllow)
    }

    @Test func aDenyButtonAloneIsNotAnAllowButton() {
        #expect(PastePrompt.read([line("Don't Allow Paste", y: 0.5)], baseline: []) == .none)
    }

    @Test func readsProgress() {
        #expect(PastePrompt.read(pasting, baseline: []) == .pasting)
        #expect(PastePrompt.read([line("正在从“Mac”粘贴", y: 0.05)], baseline: []) == .pasting)
    }
}

@Suite struct PasteOutcomes {
    @Test func confirmedWhenTheTextAppears() {
        let phone = ScriptedPhone(baseline: keyboard, [pasting, keyboard + [line("hello world", y: 0.3)]])
        #expect(fast().paste("Hello, world", verify: true, driver: phone) == .confirmed)
    }

    @Test func confirmsChineseAndWrappedText() {
        let after = keyboard + [line("你好，这是一段", y: 0.30), line("很长的中文消息", y: 0.34)]
        let phone = ScriptedPhone(baseline: keyboard, [after])
        #expect(fast().paste("你好，这是一段很长的中文消息", verify: true, driver: phone) == .confirmed)
    }

    @Test func confirmsMultilineText() {
        let after = keyboard + [line("first line", y: 0.30), line("second line", y: 0.34)]
        let phone = ScriptedPhone(baseline: keyboard, [after])
        #expect(fast().paste("first line\nsecond line", verify: true, driver: phone) == .confirmed)
    }

    @Test func textAlreadyOnScreenIsNotConfirmation() {
        let message = [line("see you at 5", y: 0.2)]
        let phone = ScriptedPhone(baseline: message + keyboard, [message + keyboard])
        #expect(fast().paste("see you at 5", verify: true, driver: phone)
            == .delivered("the text was not seen on screen"))
    }

    /// A protected field shows dots.
    @Test func deliveredWhenTheTextIsNotSeen() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + [line("••••••••", y: 0.3)]])
        #expect(fast().paste("hunter22", verify: true, driver: phone) == .delivered("the text was not seen on screen"))
    }

    @Test func emojiCannotBeChecked() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        #expect(fast().paste("👍🎉", verify: true, driver: phone) == .delivered("too little readable text to check"))
    }

    @Test func noCheckWithoutABaseline() {
        let phone = ScriptedPhone(baseline: nil, [keyboard + [line("hello", y: 0.3)]])
        #expect(fast().paste("hello", verify: true, driver: phone)
            == .delivered("the screen before the paste could not be read"))
    }

    @Test func notVerifiedWhenAskedNotTo() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + [line("hello", y: 0.3)]])
        #expect(fast().paste("hello", verify: false, driver: phone) == .delivered(nil))
    }

    @Test func pressesAllowThenConfirms() {
        let phone = ScriptedPhone(baseline: keyboard, [alert, pasting, keyboard + [line("hello", y: 0.3)]])
        #expect(fast().paste("hello", verify: true, driver: phone) == .confirmed)
        #expect(phone.taps.count == 1 && isAllow(.allow(phone.taps[0])))
    }

    /// I07: still pasting when time runs out.
    @Test func stillPastingIsUnknown() {
        let phone = ScriptedPhone(baseline: keyboard, [pasting])
        #expect(fast().paste("hello", verify: true, driver: phone) == .unknown("timed_out: the phone was still pasting"))
    }

    @Test func allowComingBackIsUnknown() {
        let phone = ScriptedPhone(baseline: keyboard, [alert])
        #expect(fast().paste("hello", verify: true, driver: phone)
            == .unknown("\"Allow Paste\" came back after 2 presses"))
        #expect(phone.taps.count == 2)
    }

    @Test func failedAllowPressIsUnknown() {
        let phone = ScriptedPhone(baseline: keyboard, [alert])
        phone.tapResponse = .failure("no window")
        #expect(fast().paste("hello", verify: true, driver: phone)
            == .unknown("pressing \"Allow Paste\" failed: no window"))
    }

    @Test func unreadableScreenIsUnknown() {
        let unreadable = ScriptedPhone(baseline: keyboard, [nil])
        #expect(fast().paste("hello", verify: true, driver: unreadable)
            == .unknown("timed_out: the phone's screen could not be read"))
        let blank = ScriptedPhone(baseline: keyboard, [[]])
        #expect(fast().paste("hello", verify: true, driver: blank)
            == .unknown("timed_out: the phone's screen could not be read"))
    }

    @Test func unverifiedAllowIsNotPressedAndNotQuiet() {
        let phone = ScriptedPhone(baseline: keyboard, [[line("Allow Paste", y: 0.5)] + keyboard])
        #expect(fast().paste("hello", verify: true, driver: phone) == .unknown(
            "timed_out: an \"Allow Paste\" that is not the system's prompt was on screen; not pressed"))
        #expect(phone.taps.isEmpty)
    }

    @Test func refusedPasteKeyIsNotDelivered() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        phone.pasteResponse = .failure("SkyLight refused")
        #expect(fast().paste("hello", verify: true, driver: phone) == .notDelivered("SkyLight refused"))
        #expect(phone.looks == 1)
    }
}

@Suite struct PasteResponses {
    final class ReturnKey {
        var presses = 0
        func press() -> ControlResponse {
            presses += 1
            return ControlResponse()
        }
    }

    @Test func confirmedPressesReturn() {
        let key = ReturnKey()
        let response = PasteOutcome.confirmed.response(submit: true, pressReturn: key.press)
        #expect(response.ok && response.route == "paste.confirmed" && key.presses == 1)
    }

    @Test func confirmedWithoutSubmitPressesNothing() {
        let key = ReturnKey()
        let response = PasteOutcome.confirmed.response(submit: false, pressReturn: key.press)
        #expect(response.ok && key.presses == 0)
    }

    @Test func deliveredIsOkButNeverSubmits() {
        let key = ReturnKey()
        let plain = PasteOutcome.delivered(nil).response(submit: false, pressReturn: key.press)
        #expect(plain.ok && plain.route == "paste.delivered")
        let submit = PasteOutcome.delivered("x").response(submit: true, pressReturn: key.press)
        #expect(!submit.ok && submit.route == "paste.delivered")
        #expect(submit.error?.contains("Return was not pressed") == true)
        #expect(key.presses == 0)
    }

    @Test func unknownFailsAndNeverSubmits() {
        let key = ReturnKey()
        for submit in [false, true] {
            let response = PasteOutcome.unknown("timed_out: x").response(submit: submit, pressReturn: key.press)
            #expect(!response.ok && response.route == "paste.unknown")
            #expect(response.error?.contains("timed_out") == true)
        }
        #expect(key.presses == 0)
    }

    @Test func notDeliveredFails() {
        let response = PasteOutcome.notDelivered("busy").response(submit: true) { ControlResponse() }
        #expect(!response.ok && response.route == "paste.not_delivered")
    }
}

@Suite struct PasteTransactions {
    func transaction(_ pasteboard: NSPasteboard, _ lock: URL) -> PasteTransaction {
        var transaction = PasteTransaction()
        transaction.pasteboard = pasteboard
        transaction.leaseURL = lock
        transaction.leaseTimeout = 5
        transaction.watcher = fast()
        return transaction
    }

    func scratch() -> (NSPasteboard, URL) {
        (NSPasteboard(name: NSPasteboard.Name("agentdesktop-test-\(UUID().uuidString)")),
         FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdesktop-lease-\(UUID().uuidString)/clipboard.lock"))
    }

    @Test func pastesOurTextAndRestoresTheUsers() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setData(Data([1, 2, 3]), forType: .png)
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + [line("hello", y: 0.3)]])
        phone.pasteboard = pasteboard
        #expect(transaction(pasteboard, lock).paste("hello", verify: true, driver: phone) == .confirmed)
        #expect(phone.pasted == ["hello"])
        #expect(pasteboard.data(forType: .png) == Data([1, 2, 3]))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    @Test func refusesAPromiseAndLeavesTheClipboard() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        let changeCount = pasteboard.changeCount
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        phone.pasteboard = pasteboard
        guard case .notDelivered = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone) else {
            Issue.record("expected notDelivered")
            return
        }
        #expect(phone.pasted.isEmpty)
        #expect(pasteboard.changeCount == changeCount)
    }

    @Test func busyClipboardIsNotDelivered() throws {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        let held = try ClipboardLease.acquire(at: lock, timeout: 1)
        defer { held.release() }
        var busy = transaction(pasteboard, lock)
        busy.leaseTimeout = 0.1
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        guard case .notDelivered = busy.paste("hello", verify: true, driver: phone) else {
            Issue.record("expected notDelivered")
            return
        }
        #expect(phone.pasted.isEmpty)
    }

    /// I06: two agents pasting at once each paste their own text, one after
    /// the other, and the user's clipboard ends as it began.
    @Test func concurrentPastesDoNotInterleave() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("the user's", forType: .string)
        let phones = ["agent A", "agent B"].map { text -> (String, ScriptedPhone) in
            let phone = ScriptedPhone(baseline: keyboard, [keyboard + [line(text, y: 0.3)]])
            phone.pasteboard = pasteboard
            phone.pauseSeconds = 0.05
            return (text, phone)
        }
        let results = UnsafeMutableBufferPointer<PasteOutcome?>.allocate(capacity: 2)
        results.initialize(repeating: nil)
        defer { results.deallocate() }
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let (text, phone) = phones[index]
            results[index] = transaction(pasteboard, lock).paste(text, verify: true, driver: phone)
        }
        for (index, (text, phone)) in phones.enumerated() {
            #expect(results[index] == .confirmed)
            #expect(phone.pasted == [text])
            // The clipboard held this agent's text for its whole wait.
            #expect(phone.log.dropFirst().allSatisfy { $0 == "hold:\(text)" })
        }
        #expect(pasteboard.string(forType: .string) == "the user's")
    }
}
