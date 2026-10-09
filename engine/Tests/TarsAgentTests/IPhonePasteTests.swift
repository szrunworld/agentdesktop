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
    var onPause: (() -> Void)?

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

    private(set) var blocked: [String] = []
    func blockInput(_ reason: String) {
        blocked.append(reason)
        log.append("block")
    }

    func pause(_ seconds: TimeInterval) {
        onPause?()
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

    @Test func chineseSystemAlert() {
        let screen = [line("“备忘录”想要粘贴来自“Mac”的内容", x: 0.2, y: 0.42, width: 0.6),
                      line("不允许粘贴", y: 0.5), line("允许粘贴", y: 0.56)]
        #expect(isAllow(PastePrompt.read(screen, baseline: [])))
    }

    /// Half an alert is not the alert: both buttons without the message,
    /// or one button with it, could be page content.
    @Test func halfAnAlertIsNotPressed() {
        let buttons = [line("不允许粘贴", y: 0.5), line("允许粘贴", y: 0.56)]
        #expect(PastePrompt.read(buttons, baseline: []) == .unverifiedAllow)
        let messageAndAllow = [line("“备忘录”想要粘贴来自“Mac”的内容", x: 0.2, y: 0.45, width: 0.6),
                               line("允许粘贴", y: 0.56)]
        #expect(PastePrompt.read(messageAndAllow, baseline: []) == .unverifiedAllow)
    }

    /// I08 as it failed on a device (2026-10-08): pasted note text holding
    /// the alert's words, left-aligned mid-screen, was pressed twice.
    @Test func leftAlignedPageTextIsNotPressed() {
        let note = [
            line("Notes would like to paste from Mac", x: 0.04, y: 0.40, width: 0.5),
            line("Allow Paste", x: 0.04, y: 0.44, width: 0.15),
            line("Don't Allow Paste", x: 0.04, y: 0.47, width: 0.22),
            line("允许粘贴", x: 0.04, y: 0.50, width: 0.12),
            line("不允许粘贴", x: 0.04, y: 0.53, width: 0.15),
        ]
        #expect(PastePrompt.read(note, baseline: []) == .unverifiedAllow)
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

    /// F9 / Codex on #127: page text "Allow Paste" elsewhere on the page does
    /// not hide the system's own alert, which is then pressed.
    @Test func pageTextElsewhereDoesNotHideTheRealAlert() {
        let page = [line("Allow Paste", x: 0.04, y: 0.3, width: 0.15), line("Don't Allow Paste", x: 0.04, y: 0.33, width: 0.2)]
        #expect(isAllow(PastePrompt.read(page + alert, baseline: page)))
        // The same alert already on screen before ⌘V is still never pressed.
        #expect(PastePrompt.read(page + alert, baseline: page + alert) == .none)
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

    /// Unconfirmed text is `.delivered` only when the phone was seen
    /// fetching and then finished; quiet alone may come before a slow fetch.
    static let noTransfer = PasteFixtures.noTransfer

    @Test func textAlreadyOnScreenIsNotConfirmation() {
        let message = [line("see you at 5", y: 0.2)]
        let quiet = ScriptedPhone(baseline: message + keyboard, [message + keyboard])
        #expect(fast().paste("see you at 5", verify: true, driver: quiet) == Self.noTransfer)
        let fetched = ScriptedPhone(baseline: message + keyboard, [message + keyboard + pasting, message + keyboard])
        #expect(fast().paste("see you at 5", verify: true, driver: fetched)
            == .delivered("the text was not seen on screen"))
    }

    /// F10 (device, 2026-10-09): Vision read "R0" as "RO". Text seen only up
    /// to OCR's confusions is delivered, never confirmed, and no Return.
    @Test func ocrConfusionsAreDeliveredNotConfirmed() {
        let phone = ScriptedPhone(baseline: keyboard,
                                  [keyboard + pasting, keyboard + [line("retest RO plain", y: 0.3)]])
        #expect(fast().paste("retest R0 plain", verify: true, driver: phone) == .delivered(PasteWatcher.ocrSimilar))
        // "PAY1OO" for "PAY100": seen, not confirmed, and Return withheld.
        let pay = ScriptedPhone(baseline: keyboard, [keyboard + pasting, keyboard + [line("PAY1OO", y: 0.3)]])
        let outcome = fast().paste("PAY100", verify: true, driver: pay)
        #expect(outcome == .delivered(PasteWatcher.ocrSimilar))
        #expect(!outcome.allowsReturn)
        // An exact reading still confirms.
        let exact = ScriptedPhone(baseline: keyboard, [keyboard + [line("retest R0 plain", y: 0.3)]])
        #expect(fast().paste("retest R0 plain", verify: true, driver: exact) == .confirmed)
        // Nothing alike on screen: still unknown.
        let none = ScriptedPhone(baseline: keyboard, [keyboard + [line("something else", y: 0.3)]])
        #expect(fast().paste("retest R0 plain", verify: true, driver: none) == PasteFixtures.noTransfer)
    }

    /// Codex on #127: a look-alike alone does not prove the fetch is over:
    /// other text may read alike, and the user's clipboard must not go back
    /// while the phone may still fetch it.
    @Test func ocrConfusionsWithoutATransferAreUnknown() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + [line("RO", y: 0.3)]])
        guard case .unknown(let why) = fast().paste("R0", verify: true, driver: phone) else {
            Issue.record("a look-alike with no transfer seen must stay unknown")
            return
        }
        #expect(why.hasPrefix("no_transfer_seen"))
    }

    /// A protected field shows dots.
    @Test func deliveredWhenTheTextIsNotSeen() {
        let dots = keyboard + [line("••••••••", y: 0.3)]
        #expect(fast().paste("hunter22", verify: true, driver: ScriptedPhone(baseline: keyboard, [dots]))
            == Self.noTransfer)
        let fetched = ScriptedPhone(baseline: keyboard, [keyboard + pasting, dots])
        #expect(fast().paste("hunter22", verify: true, driver: fetched) == .delivered("the text was not seen on screen"))
    }

    @Test func emojiCannotBeChecked() {
        #expect(fast().paste("👍🎉", verify: true, driver: ScriptedPhone(baseline: keyboard, [keyboard])) == Self.noTransfer)
        let fetched = ScriptedPhone(baseline: keyboard, [keyboard + pasting, keyboard])
        #expect(fast().paste("👍🎉", verify: true, driver: fetched) == .delivered("too little readable text to check"))
    }

    @Test func noCheckWithoutABaseline() {
        let after = keyboard + [line("hello", y: 0.3)]
        #expect(fast().paste("hello", verify: true, driver: ScriptedPhone(baseline: nil, [after])) == Self.noTransfer)
        let fetched = ScriptedPhone(baseline: nil, [keyboard + pasting, after])
        #expect(fast().paste("hello", verify: true, driver: fetched)
            == .delivered("the screen before the paste could not be read"))
    }

    @Test func notVerifiedWhenAskedNotTo() {
        let after = keyboard + [line("hello", y: 0.3)]
        #expect(fast().paste("hello", verify: false, driver: ScriptedPhone(baseline: keyboard, [after])) == Self.noTransfer)
        let fetched = ScriptedPhone(baseline: keyboard, [keyboard + pasting, after])
        #expect(fast().paste("hello", verify: false, driver: fetched) == .delivered(nil))
    }

    /// Independent review: a system-looking alert already on screen before
    /// ⌘V (a page, a picture of one) is never pressed.
    @Test func anAlertShownBeforeThePasteIsNotPressed() {
        #expect(PastePrompt.read(alert + keyboard, baseline: alert + keyboard) == .none)
        #expect(isAllow(PastePrompt.read(alert + keyboard, baseline: keyboard)))
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

    @Test func pasteKeyThatFailedMidwayIsUnknown() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        var midway = ControlResponse.failure("action_delivery_unknown (transport_error): the socket closed")
        midway.route = "key.unknown"
        phone.pasteResponse = midway
        guard case .unknown = fast().paste("hello", verify: true, driver: phone) else {
            Issue.record("a ⌘V that may have reached the phone must not count as not delivered")
            return
        }
    }

    /// #180: the input barrier refused the ⌘V before sending ("stale_observation
    /// (delivery_unknown)" names an earlier input's unknown result): nothing
    /// was sent, so nothing was pasted.
    @Test func pasteKeyRefusedByTheBarrierIsNotDelivered() {
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        phone.pasteResponse = .failure("stale_observation (delivery_unknown): the window may hold the result of an "
            + "input whose delivery failed midway after an earlier input; take a screenshot before any more input")
        guard case .notDelivered = fast().paste("hello", verify: true, driver: phone) else {
            Issue.record("a ⌘V refused before sending was not sent")
            return
        }
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
        transaction.pending = HostFlag(url: lock.deletingLastPathComponent().appendingPathComponent("clipboard.pending"))
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
        #expect(transaction(pasteboard, lock).paste("hello", verify: true, driver: phone).outcome == .confirmed)
        #expect(phone.pasted == ["hello"])
        #expect(pasteboard.data(forType: .png) == Data([1, 2, 3]))
        #expect(pasteboard.string(forType: .string) == nil)
    }

    /// #180: a ⌘V the barrier refused hands the user's clipboard back at
    /// once; it raises no barrier of its own and waits for no fetch.
    @Test func aPasteTheBarrierRefusedRestoresTheClipboardAtOnce() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("USER", forType: .string)
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        phone.pasteboard = pasteboard
        phone.pasteResponse = .failure("stale_observation (delivery_unknown): take a screenshot before any more input")
        let result = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone)
        guard case .notDelivered = result.outcome else {
            Issue.record("expected notDelivered, got \(result.outcome)")
            return
        }
        #expect(result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "USER")
        #expect(phone.blocked.isEmpty)
    }

    @Test func refusesAPromiseAndLeavesTheClipboard() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("x", forType: NSPasteboard.PasteboardType("com.apple.pasteboard.promised-file-url"))
        let changeCount = pasteboard.changeCount
        let phone = ScriptedPhone(baseline: keyboard, [keyboard])
        phone.pasteboard = pasteboard
        guard case .notDelivered = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone).outcome else {
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
        guard case .notDelivered = busy.paste("hello", verify: true, driver: phone).outcome else {
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
            results[index] = transaction(pasteboard, lock).paste(text, verify: true, driver: phone).outcome
        }
        for (index, (text, phone)) in phones.enumerated() {
            #expect(results[index] == .confirmed)
            #expect(phone.pasted == [text])
            // The clipboard held this agent's text for its whole wait.
            #expect(phone.log.dropFirst().allSatisfy { $0 == "hold:\(text)" })
        }
        #expect(pasteboard.string(forType: .string) == "the user's")
    }

    /// A paste that times out while the phone may still fetch the clipboard
    /// must not let it fetch the user's data: the typed text stays there.
    @Test func stillPastingWithholdsTheUsersClipboard() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret-token", forType: .string)
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + pasting])
        phone.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 5
        let result = paste.paste("hello", verify: true, driver: phone)
        #expect(result.outcome == .unknown("timed_out: the phone was still pasting"))
        #expect(!result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "hello")
        #expect(phone.taps.isEmpty)
    }

    /// An Allow Paste left on screen could be pressed later, by anyone: the
    /// user's contents stay away from it too.
    @Test func aLingeringPromptWithholdsTheUsersClipboard() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret-token", forType: .string)
        let phone = ScriptedPhone(baseline: keyboard, [alert])
        phone.pasteboard = pasteboard
        phone.tapResponse = .failure("tap refused")
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 5
        let result = paste.paste("hello", verify: true, driver: phone)
        guard case .unknown = result.outcome else {
            Issue.record("expected unknown")
            return
        }
        #expect(!result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    /// Once the phone is seen done with the clipboard, the user's contents
    /// go back even though the paste itself stays unknown.
    @Test func restoresOnceThePhoneIsSeenDone() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret-token", forType: .string)
        let stillPasting = [[PhoneText]?](repeating: keyboard + pasting, count: 10)
        let phone = ScriptedPhone(baseline: keyboard, stillPasting + [keyboard])
        phone.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 5
        let result = paste.paste("hello", verify: true, driver: phone)
        #expect(result.outcome == .unknown("timed_out: the phone was still pasting"))
        #expect(result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "secret-token")
    }

    @Test func aWithheldClipboardIsSaidInTheResponse() {
        let response = PasteOutcome.unknown("timed_out: x").response(submit: true, clipboardRestored: false) {
            Issue.record("Return pressed")
            return ControlResponse()
        }
        #expect(!response.ok)
        #expect(response.error?.contains("clipboard_withheld") == true)
        #expect(response.route == "paste.unknown")
    }

    /// A ⌘V that failed on its way out shows nothing; quiet screens after it
    /// prove nothing, so the user's contents stay away from the clipboard.
    @Test func quietWithoutSeeingThePasteDoesNotRestore() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret-token", forType: .string)
        let phone = ThrowingPastePhone(baseline: keyboard, [keyboard])
        phone.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 5
        let result = paste.paste("hello", verify: true, driver: phone)
        guard case .unknown = result.outcome else {
            Issue.record("expected unknown")
            return
        }
        #expect(!result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    /// While a withheld clipboard may still be fetched, no other paste may
    /// put its text there, from this process or another.
    @Test func aWithheldClipboardKeepsOtherPastesOut() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        let first = ScriptedPhone(baseline: keyboard, [keyboard + pasting])
        first.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 3
        #expect(!paste.paste("agent A", verify: true, driver: first).clipboardRestored)
        let second = ScriptedPhone(baseline: keyboard, [keyboard + [line("agent B", y: 0.3)]])
        second.pasteboard = pasteboard
        let next = transaction(pasteboard, lock).paste("agent B", verify: true, driver: second)
        guard case .notDelivered(let why) = next.outcome else {
            Issue.record("expected notDelivered")
            return
        }
        #expect(why.hasPrefix("clipboard_pending"))
        #expect(second.pasted.isEmpty)
        #expect(pasteboard.string(forType: .string) == "agent A")
    }

    @Test func thePendingMarkExpires() throws {
        let (_, lock) = scratch()
        let flag = HostFlag(url: lock.deletingLastPathComponent().appendingPathComponent("clipboard.pending"))
        try flag.raise("x", until: Date().addingTimeInterval(-1))
        #expect(flag.reason() == nil)
        try flag.raise("y", until: Date().addingTimeInterval(60))
        #expect(flag.reason() == "y")
        flag.lower()
        #expect(flag.reason() == nil)
    }

    /// F7 (device, 2026-10-08): a copy made while the phone fetches may be
    /// what it pastes; unless our text is seen, the outcome is unknown.
    @Test func aCopyDuringThePasteMakesItUnknown() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + pasting, keyboard])
        phone.pasteboard = pasteboard
        phone.onPause = {
            if phone.looks == 1 {
                pasteboard.clearContents()
                pasteboard.setString("USER-SECRET", forType: .string)
            }
        }
        let result = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone)
        guard case .unknown(let why) = result.outcome else {
            Issue.record("expected unknown, got \(result.outcome)")
            return
        }
        #expect(why.hasPrefix("user_copied_during_paste"))
        #expect(pasteboard.string(forType: .string) == "USER-SECRET")
    }

    /// Codex on #127: a copy noticed only after the phone went quiet turns
    /// a delivered paste unknown late; input is blocked then too, inside
    /// the lease, not left to the screen after the lease is gone.
    @Test func aLateUnknownFromACopyBlocksInput() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + pasting, keyboard])
        phone.pasteboard = pasteboard
        phone.onPause = {
            if phone.looks == 2 {
                pasteboard.clearContents()
                pasteboard.setString("USER-SECRET", forType: .string)
            }
        }
        let result = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone)
        guard case .unknown(let why) = result.outcome else {
            Issue.record("expected unknown, got \(result.outcome)")
            return
        }
        #expect(why.hasPrefix("user_copied_during_paste"))
        #expect(phone.blocked == ["may hold what the user copied during a paste"])
        #expect(pasteboard.string(forType: .string) == "USER-SECRET")
    }

    /// Codex on #127: the same progress words elsewhere on the page (a
    /// picture of an earlier sheet) do not hide the real sheet.
    @Test func progressWordsElsewhereDoNotHideTheRealSheet() {
        let old = line("Pasting from Mac", x: 0.05, y: 0.3, width: 0.5)
        #expect(PastePrompt.read([old, line("Pasting from Mac", y: 0.05)], baseline: [old]) == .pasting)
        #expect(PastePrompt.read([old], baseline: [old]) == .none)
    }

    /// The device fix: with the phone still fetching, its Cancel is pressed.
    @Test func aCopyDuringThePasteCancelsThePhonesFetch() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let sheet = [line("Pasting from \u{201C}MacBook Pro\u{201D}…", x: 0.2, y: 0.47, width: 0.6),
                     line("Cancel", x: 0.4, y: 0.58, width: 0.2)]
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + sheet])
        phone.pasteboard = pasteboard
        phone.onPause = {
            if phone.looks == 1 {
                pasteboard.clearContents()
                pasteboard.setString("USER-SECRET", forType: .string)
            }
        }
        let result = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone)
        #expect(result.outcome == .unknown("user_copied_during_paste: something else was copied to the Mac's "
            + "clipboard while the phone was fetching it; the phone's paste was cancelled"))
        #expect(phone.taps.count == 1)
        if let tap = phone.taps.first { #expect(abs(tap.x - 0.5) < 1e-9 && abs(tap.y - 0.595) < 1e-9) }
    }

    /// Codex on #127: a page that already showed a centred progress-like
    /// line with a Cancel under it is page content. When the real transfer
    /// adds its own sheet, only that sheet's Cancel is pressed; with no
    /// fresh Cancel, nothing is, and the stop is not claimed.
    @Test func aCopyDuringThePasteNeverPressesAPagesOwnSheet() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        let pageSheet = [line("Pasting from the archive", x: 0.2, y: 0.47, width: 0.6),
                         line("Cancel", x: 0.4, y: 0.58, width: 0.2)]
        let realProgress = line("Pasting from \u{201C}MacBook Pro\u{201D}…", x: 0.2, y: 0.27, width: 0.6)
        func run(_ during: [PhoneText]) -> (PasteTransaction.Result, ScriptedPhone) {
            pasteboard.clearContents()
            pasteboard.setString("before", forType: .string)
            let phone = ScriptedPhone(baseline: pageSheet + keyboard, [pageSheet + keyboard + during])
            phone.pasteboard = pasteboard
            phone.onPause = {
                if phone.looks == 1 {
                    pasteboard.clearContents()
                    pasteboard.setString("USER-SECRET", forType: .string)
                }
            }
            return (transaction(pasteboard, lock).paste("hello", verify: true, driver: phone), phone)
        }

        let (alone, untouched) = run([realProgress])
        guard case .unknown(let why) = alone.outcome else {
            Issue.record("expected unknown, got \(alone.outcome)")
            return
        }
        #expect(why.contains("no system Cancel"))
        #expect(untouched.taps.isEmpty)

        let (withCancel, phone) = run([realProgress, line("Cancel", x: 0.4, y: 0.36, width: 0.2)])
        #expect(withCancel.outcome == .unknown("user_copied_during_paste: something else was copied to the Mac's "
            + "clipboard while the phone was fetching it; the phone's paste was cancelled"))
        #expect(phone.taps.count == 1)
        if let tap = phone.taps.first { #expect(abs(tap.y - 0.375) < 1e-9) }
    }

    /// Codex on #78: an Allow Paste the user accepted can vanish before the
    /// transfer shows; that quiet is not the end of the fetch.
    @Test func anAcceptedPromptThenQuietIsNotDone() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("secret-token", forType: .string)
        // The prompt is pressed (and accepted), then the phone goes quiet
        // without ever showing the transfer or the text.
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + alert, keyboard])
        phone.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 6
        let result = paste.paste("hello", verify: true, driver: phone)
        #expect(phone.taps.count == 1)
        #expect(result.outcome == PasteFixtures.noTransfer)
        #expect(!result.clipboardRestored)
        #expect(pasteboard.string(forType: .string) == "hello")
    }

    /// Second review: chat text that begins like the progress line
    /// ("正在从公司出发") was already there; it is not this paste's progress.
    @Test func progressWordsAlreadyOnThePageDoNotHoldThePaste() {
        let chat = [line("正在从公司出发", x: 0.05, y: 0.3, width: 0.5)]
        let phone = ScriptedPhone(baseline: chat + keyboard, [chat + keyboard + [line("hello", y: 0.4)]])
        #expect(fast().paste("hello", verify: true, driver: phone) == .confirmed)
    }

    /// Codex on #78: input is blocked as soon as the outcome is unknown,
    /// before the wait for the phone to finish.
    @Test func inputIsBlockedBeforeTheSettlingWait() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + pasting])
        phone.pasteboard = pasteboard
        var paste = transaction(pasteboard, lock)
        paste.settleLooks = 3
        _ = paste.paste("hello", verify: true, driver: phone)
        #expect(phone.blocked == ["may hold a half-finished paste"])
        guard let block = phone.log.firstIndex(of: "block") else {
            Issue.record("input was not blocked")
            return
        }
        // Every look after the block belongs to the settling wait.
        #expect(phone.log.count > block + 1)
    }

    /// Codex on #95: a page's own centred controls are not the system's.
    @Test func aCopyDuringThePasteNeverPressesPageControls() {
        let (pasteboard, lock) = scratch()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let page = [line("Allow Paste", y: 0.5), line("Don't Allow Paste", y: 0.56), line("Cancel", x: 0.4, y: 0.62, width: 0.2)]
        let phone = ScriptedPhone(baseline: keyboard, [keyboard + page])
        phone.pasteboard = pasteboard
        phone.onPause = {
            if phone.looks == 1 {
                pasteboard.clearContents()
                pasteboard.setString("USER-SECRET", forType: .string)
            }
        }
        let result = transaction(pasteboard, lock).paste("hello", verify: true, driver: phone)
        guard case .unknown(let why) = result.outcome else {
            Issue.record("expected unknown")
            return
        }
        #expect(why.contains("no system Cancel"))
        #expect(phone.taps.isEmpty)
    }

    /// Codex on #127: checking the raising and removing it must not
    /// interleave with another process raising a new one. One raiser races
    /// a lowerer of the older raising, 50 times; the newer must survive.
    /// The window is narrow, so this guards against regressions; it does
    /// not prove the cross-process lock (a device check covers that).
    @Test func loweringARaisingNeverDeletesANewerOne() throws {
        let (_, lock) = scratch()
        let flag = HostFlag(url: lock.deletingLastPathComponent().appendingPathComponent("barrier"))
        for _ in 0..<50 {
            try flag.raise("old")
            let old = try #require(flag.generation())
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { try? flag.raise("new") } else { flag.lower(ifStill: old) }
            }
            #expect(flag.reason() == "new")
            flag.lower()
        }
    }

    @Test func aBarrierRaisedSinceIsNotLowered() throws {
        let (_, lock) = scratch()
        let flag = HostFlag(url: lock.deletingLastPathComponent().appendingPathComponent("barrier"))
        try flag.raise("first")
        let seen = try #require(flag.generation())
        try flag.raise("second")
        flag.lower(ifStill: seen)
        #expect(flag.reason() == "second")
        let now = try #require(flag.generation())
        flag.lower(ifStill: now)
        #expect(flag.reason() == nil)
    }
}

enum PasteFixtures {
    static let noTransfer = PasteOutcome.unknown("no_transfer_seen: the phone was never seen fetching the clipboard "
        + "and the text is not on screen, so the fetch may still come")
}

@Suite struct AgentIndeterminateResults {
    /// Second review: a paste that went in, then failed (its Return refused),
    /// stops the run: the model would type the text again.
    @Test func aFailedPasteThatMayHaveLandedStopsTheRun() {
        var confirmedButReturnRefused = ControlResponse.failure("not_connected (uncertain): …")
        confirmedButReturnRefused.route = "paste.confirmed"
        #expect(TarsAgent.isIndeterminate(confirmedButReturnRefused))
        var notDelivered = ControlResponse.failure("nothing was pasted")
        notDelivered.route = "paste.not_delivered"
        #expect(!TarsAgent.isIndeterminate(notDelivered))
    }

    @Test func anUnreadableMarkDoesNotStayUpForEver() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("agentdesktop-flag-\(UUID().uuidString)/mark")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: Data("garbage".utf8))
        let flag = HostFlag(url: url)
        #expect(flag.reason() != nil)
        let old = Date().addingTimeInterval(-(HostFlag.unreadableLifetime + 60))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
        #expect(flag.reason() == nil)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func unknownPastesAndDeliveriesStopTheRun() {
        var paste = ControlResponse.failure("the paste did not finish")
        paste.route = "paste.unknown"
        #expect(TarsAgent.isIndeterminate(paste))
        #expect(TarsAgent.isIndeterminate(.failure("action_delivery_unknown (target_changed_during_dispatch): x")))
        #expect(TarsAgent.isIndeterminate(.failure("stale_observation (delivery_unknown): the window moved")))
        #expect(!TarsAgent.isIndeterminate(.failure("stale_observation (moved): take a new screenshot")))
        var delivered = ControlResponse()
        delivered.route = "paste.delivered"
        #expect(!TarsAgent.isIndeterminate(delivered))
    }
}

/// A phone whose ⌘V request fails after it may have gone out.
final class ThrowingPastePhone: PhonePasteDriver {
    let inner: ScriptedPhone
    var pasteboard: NSPasteboard? {
        get { inner.pasteboard }
        set { inner.pasteboard = newValue }
    }
    init(baseline: [PhoneText]?, _ screens: [[PhoneText]?]) {
        inner = ScriptedPhone(baseline: baseline, screens)
    }
    struct Lost: Error {}
    func look() throws -> [PhoneText] { try inner.look() }
    func pressPaste() throws -> ControlResponse { throw Lost() }
    func tap(_ point: CGPoint) throws -> ControlResponse { try inner.tap(point) }
    func pause(_ seconds: TimeInterval) { inner.pause(seconds) }
    func blockInput(_ reason: String) { inner.blockInput(reason) }
}