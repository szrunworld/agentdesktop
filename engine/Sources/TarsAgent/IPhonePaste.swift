import AppKit
import CoreGraphics
import Foundation
import SecondScreenCore

/// What became of text pasted into the phone.
///
/// Pressing ⌘V proves only that the key reached iPhone Mirroring. The phone
/// may then ask to "Allow Paste" and fetch the clipboard over the air, which
/// takes seconds, and none of that says the field got the text. So a paste
/// ends in one of:
public enum PasteOutcome: Equatable {
    /// Nothing reached the phone: the clipboard was busy or could not be
    /// saved, or ⌘V was refused. Safe to try again.
    case notDelivered(String)
    /// ⌘V reached the phone and it stopped showing a paste in progress, but
    /// the text was not seen on screen (a protected field, emoji, text too
    /// short or scrolled out of view, ...). Why it was not checked, if known.
    case delivered(String?)
    /// The text appeared on screen where it was not before.
    case confirmed
    /// ⌘V may have reached the phone and the paste never settled: it was
    /// still pasting, the permission prompt kept coming back, pressing it
    /// failed, or the window could not be read. The field may or may not
    /// hold the text, so neither paste again nor press Return.
    case unknown(String)

    /// The `route` a response carries for it.
    public var route: String {
        switch self {
        case .notDelivered: return "paste.not_delivered"
        case .delivered: return "paste.delivered"
        case .confirmed: return "paste.confirmed"
        case .unknown: return "paste.unknown"
        }
    }

    /// Only text seen in the field may be followed by Return: submitting
    /// what may be half pasted, or not pasted, sends the wrong thing.
    public var allowsReturn: Bool { self == .confirmed }

    /// The response to a `type` action that pasted, and pressed Return for a
    /// trailing newline when `submit` and the outcome allows it.
    public func response(submit: Bool, clipboardRestored: Bool = true,
                         pressReturn: () throws -> ControlResponse) rethrows -> ControlResponse {
        var response: ControlResponse
        switch self {
        case .notDelivered(let why):
            response = .failure("nothing was pasted: \(why)")
        case .unknown(let why):
            response = .failure("the paste did not finish (\(why)); the field may or may not hold the text. "
                + (submit ? "Return was not pressed. " : "")
                + "Look at the screen before typing again")
        case .delivered(let why):
            if submit {
                response = .failure("the text was pasted but not seen on screen"
                    + (why.map { " (\($0))" } ?? "")
                    + ", so Return was not pressed; look at the field and press Return if it is right "
                    + "rather than typing again")
            } else {
                response = ControlResponse()
            }
        case .confirmed:
            response = submit ? try pressReturn() : ControlResponse()
        }
        if !clipboardRestored {
            let note = "clipboard_withheld: the phone may still fetch the Mac's clipboard, so it was left holding "
                + "the typed text and the user's earlier contents were not put back"
            response.error = response.error.map { "\($0). \(note)" } ?? note
        }
        response.route = route
        return response
    }
}

/// A line of text read off the phone's window. `box` is normalised to the
/// window, origin top left.
public struct PhoneText: Equatable {
    public var text: String
    public var box: CGRect
    public init(_ text: String, _ box: CGRect) {
        self.text = text
        self.box = box
    }
    var center: CGPoint { CGPoint(x: box.midX, y: box.midY) }
}

/// What a paste needs from the phone, so the logic can run without one.
public protocol PhonePasteDriver {
    /// The text on the phone's screen now. Throws when it cannot be read.
    func look() throws -> [PhoneText]
    /// ⌘V into iPhone Mirroring.
    func pressPaste() throws -> ControlResponse
    /// A tap at a point normalised to the window, origin top left.
    func tap(_ point: CGPoint) throws -> ControlResponse
    func pause(_ seconds: TimeInterval)
    /// Stop all further input to the phone, from any process, until it is
    /// looked at again: what the field holds is unknown.
    func blockInput(_ reason: String)
}

/// What the phone shows of a paste from the Mac.
public enum PastePrompt: Equatable {
    /// The system's paste permission alert, and where its Allow button is
    /// (normalised to the window).
    case allow(CGPoint)
    /// "Pasting from …" progress.
    case pasting
    /// An "Allow Paste" that is not shown to be the system's alert and was
    /// not on screen before the paste: not pressed, and not a sign the paste
    /// is over either.
    case unverifiedAllow
    case none

    public static let pastingLabels = ["Pasting from", "正在从"]
    public static let allowPasteLabels: Set<String> = ["Allow Paste", "允许粘贴"]
    public static let denyPasteLabels: Set<String> = ["Don't Allow Paste", "Do Not Allow Paste", "不允许粘贴"]
    /// The alert's message, "“Notes” would like to paste from “Mac”",
    /// matched in part as it may wrap.
    public static let promptPhrases = ["would like to paste", "想要粘贴"]

    /// Where the system alert sits: the middle of the screen. Normal content
    /// up in a navigation bar or down on a keyboard is not it.
    static let alertRegion = CGRect(x: 0.1, y: 0.2, width: 0.8, height: 0.65)
    /// How close (in window widths and heights) a label must be to one on
    /// the screen before ⌘V to count as that same page text.
    static let baselineTolerance: CGFloat = 0.02
    /// How far apart (in window heights) the alert's parts can be.
    static let alertSpan: CGFloat = 0.3

    /// How far from the middle (in window widths) the alert's lines sit:
    /// the system alert centres its message and stacked buttons, while page
    /// text (a note, a chat) runs from the left edge.
    static let centreTolerance: CGFloat = 0.08

    /// Reads `seen`. An Allow button is pressed only with the whole alert
    /// around it: in the middle of the screen, horizontally centred, with
    /// both the Don't Allow button and the alert's message near it. Page
    /// content can show the button labels (2026-10-08: pasted text holding
    /// "Allow Paste" and "Don't Allow Paste" was pressed twice); missing a
    /// real alert costs an unknown outcome, pressing page text costs a tap
    /// on whatever it is. `baseline` is what was on screen before ⌘V; an
    /// "Allow Paste" already there is page content.
    public static func read(_ seen: [PhoneText], baseline: [PhoneText]?) -> PastePrompt {
        func centred(_ line: PhoneText) -> Bool {
            alertRegion.contains(line.center) && abs(line.box.midX - 0.5) <= centreTolerance
        }
        let allows = seen.filter { allowPasteLabels.contains(clean($0.text)) }
        let denies = seen.filter { denyPasteLabels.contains(clean($0.text)) && centred($0) }
        let messages = seen.filter { line in
            let text = clean(line.text)
            return promptPhrases.contains { text.range(of: $0, options: .caseInsensitive) != nil } && centred(line)
        }
        // The same label at the same place before ⌘V is page content (a page,
        // a picture of one): never pressed. Matched one candidate at a time,
        // so page text elsewhere does not hide a real alert (F9, Codex on
        // #127: a note holding "Allow Paste" kept the system's own prompt
        // from ever being accepted).
        func wasThere(_ line: PhoneText) -> Bool {
            (baseline ?? []).contains { old in
                clean(old.text) == clean(line.text)
                    && abs(old.center.x - line.center.x) <= baselineTolerance
                    && abs(old.center.y - line.center.y) <= baselineTolerance
            }
        }
        let fresh = allows.filter { !wasThere($0) }
        for allow in fresh where centred(allow) {
            func near(_ part: PhoneText) -> Bool { abs(part.center.y - allow.center.y) <= alertSpan }
            if denies.contains(where: near), messages.contains(where: near) { return .allow(allow.center) }
        }
        if seen.contains(where: { line in isProgress(line, before: baseline) }) {
            return .pasting
        }
        if !fresh.isEmpty { return .unverifiedAllow }
        return .none
    }

    /// A "Pasting from …" / "正在从…" line that was not on screen before
    /// ⌘V. Chat text such as "正在从公司出发" begins the same way; already
    /// there, it is page content, not this paste's progress.
    static func isProgress(_ line: PhoneText, before baseline: [PhoneText]?) -> Bool {
        let text = clean(line.text)
        guard pastingLabels.contains(where: { text.hasPrefix($0) }) else { return false }
        return !(baseline ?? []).contains { clean($0.text) == text }
    }

    static func clean(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
    }
}

/// Presses ⌘V and watches the phone until the paste settles.
public struct PasteWatcher {
    public var interval: TimeInterval = 0.5
    /// Looks before giving up: with each look taking about a second, some
    /// twenty seconds, enough for a slow transfer.
    public var maxLooks = 25
    /// Looks in a row with no prompt or progress before the paste is over.
    public var quietLooks = 3
    /// Presses of Allow Paste before its coming back counts as a failure.
    public var maxAllowPresses = 2
    /// Whether something else has written the Mac's clipboard since the
    /// text was put there (the user copied). Checked at every look: the
    /// phone would paste that instead, so the paste is stopped on the phone.
    public var othersWrote: (() -> Bool)?
    /// Told what was on screen before ⌘V.
    public var onBaseline: (([PhoneText]?) -> Void)?

    public init() {}

    /// The centred line reading one of `labels`, as a tap point.
    static func centredButton(_ labels: Set<String>, in seen: [PhoneText]) -> CGPoint? {
        seen.first { line in
            labels.contains(PastePrompt.clean(line.text))
                && PastePrompt.alertRegion.contains(line.center)
                && abs(line.box.midX - 0.5) <= PastePrompt.centreTolerance
        }?.center
    }

    static let cancelLabels: Set<String> = ["Cancel", "取消"]

    /// The button that stops the phone's paste, only where it is the
    /// system's: Don't Allow inside the whole alert `read` recognised, or
    /// Cancel under a centred "Pasting from" line. A page's own centred
    /// "Cancel" or "Don't Allow Paste" is never pressed.
    static func systemStopButton(_ seen: [PhoneText], prompt: PastePrompt) -> CGPoint? {
        func centred(_ line: PhoneText) -> Bool {
            PastePrompt.alertRegion.contains(line.center) && abs(line.box.midX - 0.5) <= PastePrompt.centreTolerance
        }
        switch prompt {
        case .allow(let allow):
            return seen.first { line in
                PastePrompt.denyPasteLabels.contains(PastePrompt.clean(line.text)) && centred(line)
                    && abs(line.center.y - allow.y) <= PastePrompt.alertSpan
            }?.center
        case .pasting:
            let sheets = seen.filter { line in
                PastePrompt.pastingLabels.contains { PastePrompt.clean(line.text).hasPrefix($0) } && centred(line)
            }
            return seen.first { line in
                cancelLabels.contains(PastePrompt.clean(line.text)) && centred(line)
                    && sheets.contains { sheet in
                        line.center.y > sheet.center.y && line.center.y - sheet.center.y <= PastePrompt.alertSpan
                    }
            }?.center
        case .unverifiedAllow, .none:
            return nil
        }
    }

    /// The clipboard changed under a paste in progress: stop the phone from
    /// fetching it (Cancel on its "Pasting from" sheet, Don't Allow on its
    /// prompt) and say whether that was done. Seen on a device: Cancel kept
    /// the user's copy out of the field.
    private func stopForeignPaste(_ seen: [PhoneText], prompt: PastePrompt,
                                  driver: PhonePasteDriver) -> PasteOutcome {
        let why = "user_copied_during_paste: something else was copied to the Mac's clipboard while the phone was "
            + "fetching it"
        guard let button = Self.systemStopButton(seen, prompt: prompt) else {
            return .unknown(why + "; no system Cancel or Don't Allow Paste was on screen to stop it, so the phone may "
                + "have pasted that, possibly the user's data")
        }
        guard let tapped = try? driver.tap(button), tapped.ok else {
            return .unknown(why + "; stopping the phone's paste failed, so it may have pasted that, possibly the "
                + "user's data")
        }
        return .unknown(why + "; the phone's paste was cancelled")
    }

    /// Whether a failed ⌘V may still have reached the phone, as the screen
    /// says of input whose delivery failed after it went out.
    static func mayHaveReached(_ response: ControlResponse) -> Bool {
        if response.route?.hasSuffix(".unknown") == true { return true }
        guard let error = response.error else { return false }
        return error.hasPrefix("action_delivery_unknown") || error.contains("(delivery_unknown)")
    }

    /// `verify`: whether the text may be read back off the screen to
    /// confirm it. Without that the best outcome is `.delivered`.
    public func paste(_ text: String, verify: Bool, driver: PhonePasteDriver) -> PasteOutcome {
        let baseline = try? driver.look()
        onBaseline?(baseline)
        let pressed: ControlResponse
        do {
            pressed = try driver.pressPaste()
        } catch {
            // The request may have gone out before it failed.
            return .unknown("⌘V: \(error.localizedDescription)")
        }
        guard pressed.ok else {
            // A send that failed midway (the transport broke, the window
            // changed under it) may have reached the phone: unknown, so the
            // clipboard is not handed back while the phone may fetch it.
            if Self.mayHaveReached(pressed) { return .unknown("⌘V: \(pressed.error ?? "delivery unknown")") }
            return .notDelivered(pressed.error ?? "⌘V failed")
        }

        var quiet = 0
        var presses = 0
        var blind = 0
        var last: PastePrompt?
        var settled: [PhoneText]?
        // Whether the phone was seen fetching ("Pasting from"). Quiet screens
        // after ⌘V without that may be a fetch not yet begun.
        var sawTransfer = false
        for _ in 0..<maxLooks {
            driver.pause(interval)
            guard let seen = try? driver.look(), !seen.isEmpty else {
                // Unreadable is not quiet: it proves nothing.
                blind += 1
                quiet = 0
                continue
            }
            let prompt = PastePrompt.read(seen, baseline: baseline)
            last = prompt
            if case .pasting = prompt { sawTransfer = true }
            if othersWrote?() == true {
                switch prompt {
                case .allow, .pasting, .unverifiedAllow: return stopForeignPaste(seen, prompt: prompt, driver: driver)
                case .none: break  // done or not begun; the transaction reports it
                }
            }
            switch prompt {
            case .allow(let point):
                quiet = 0
                guard presses < maxAllowPresses else {
                    return .unknown("\"Allow Paste\" came back after \(presses) presses")
                }
                presses += 1
                let tapped: ControlResponse
                do {
                    tapped = try driver.tap(point)
                } catch {
                    return .unknown("pressing \"Allow Paste\" failed: \(error.localizedDescription)")
                }
                guard tapped.ok else {
                    return .unknown("pressing \"Allow Paste\" failed: \(tapped.error ?? "no reason given")")
                }
            case .pasting, .unverifiedAllow:
                quiet = 0
            case .none:
                quiet += 1
            }
            if quiet >= quietLooks {
                settled = seen
                break
            }
        }
        guard let settled else {
            let state: String
            switch last {
            case .pasting?: state = "the phone was still pasting"
            case .allow?: state = "the phone was still asking to allow the paste"
            case .unverifiedAllow?: state = "an \"Allow Paste\" that is not the system's prompt was on screen; not pressed"
            case .none?, nil: state = blind > 0 ? "the phone's screen could not be read" : "the paste never settled"
            }
            return .unknown("timed_out: \(state)")
        }
        // The text on screen proves the paste is over. Without it, only a
        // fetch seen to start and end does: quiet alone may come before a
        // slow fetch, which would then get the user's restored clipboard.
        let checked = verify ? Self.check(text, before: baseline, after: settled) : .delivered(nil)
        // The text seen (exactly, or up to OCR's confusions) shows the fetch
        // is over as well as a seen transfer does.
        if checked == .confirmed || sawTransfer || checked == .delivered(Self.ocrSimilar) { return checked }
        return .unknown("no_transfer_seen: the phone was never seen fetching the clipboard and the text is not on "
            + "screen, so the fetch may still come")
    }

    /// After a paste that did not settle: watch up to `looks` more times for
    /// the phone to be seen transferring it ("Pasting from") and then to
    /// stop, on screens that could be read. Nothing is pressed. True only
    /// when the phone is seen to be done with the clipboard, so the user's
    /// contents can go back without the phone fetching them. Quiet screens
    /// alone prove nothing: a ⌘V that failed on its way out, or a fetch not
    /// yet begun, looks just as quiet; and an Allow Paste prompt that went
    /// away is not a finished transfer, which may start only after it.
    public func settles(looks: Int, driver: PhonePasteDriver, baseline: [PhoneText]? = nil) -> Bool {
        var transferred = false
        var quiet = 0
        for _ in 0..<looks {
            driver.pause(interval)
            guard let seen = try? driver.look(), !seen.isEmpty else {
                quiet = 0
                continue
            }
            let prompting = seen.contains { line in
                let text = PastePrompt.clean(line.text)
                return PastePrompt.allowPasteLabels.contains(text) || PastePrompt.denyPasteLabels.contains(text)
                    || PastePrompt.isProgress(line, before: baseline)
                    || PastePrompt.promptPhrases.contains { text.range(of: $0, options: .caseInsensitive) != nil }
            }
            let transferring = seen.contains { PastePrompt.isProgress($0, before: baseline) }
            if transferring { transferred = true }
            if prompting {
                quiet = 0
            } else if transferred {
                quiet += 1
            }
            if quiet >= quietLooks { return true }
        }
        return false
    }

    /// Whether `text` shows on screen more often after the paste than
    /// before. Only letters and digits are compared: OCR drops emoji and
    /// spacing, and splits lines.
    static func check(_ text: String, before: [PhoneText]?, after: [PhoneText]) -> PasteOutcome {
        let needle = normalize(text)
        guard needle.count >= 2 else { return .delivered("too little readable text to check") }
        guard let before else { return .delivered("the screen before the paste could not be read") }
        let was = occurrences(of: needle, in: before)
        let now = occurrences(of: needle, in: after)
        if now > was { return .confirmed }
        // F10 (device, 2026-10-09): Vision read "R0" as "RO", so a paste on
        // screen failed the exact check. Reading it again with the characters
        // OCR confuses folded together is evidence the text landed, not that
        // it is right: it may as well be "PAY1OO" for "PAY100". So it is
        // `.delivered` (no Return, never `.confirmed`), not `.unknown`.
        // A field's own value would settle it, but iPhone Mirroring exposes no
        // accessibility tree of the phone, so there is no exact source here.
        let loose = fold(needle)
        if occurrences(of: loose, in: before, folded: true) < occurrences(of: loose, in: after, folded: true) {
            return .delivered(Self.ocrSimilar)
        }
        return .delivered("the text was not seen on screen")
    }

    /// The reason `check` gives for text seen only with OCR-confusable
    /// characters folded together.
    static let ocrSimilar = "ocr_similar: text matching the pasted text up to characters OCR confuses "
        + "(0/O, 1/l/I, 5/S, 8/B, 2/Z) appeared on screen; not confirmed"

    /// The characters OCR mixes up, folded to one of each kind.
    static func fold(_ text: String) -> String {
        String(text.map { character -> Character in
            switch character {
            case "0", "o": return "o"
            case "1", "l", "i", "|": return "l"
            case "5", "s": return "s"
            case "8", "b": return "b"
            case "2", "z": return "z"
            default: return character
            }
        })
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Non-overlapping occurrences of `needle` in the screen's text read top
    /// to bottom, left to right.
    static func occurrences(of needle: String, in seen: [PhoneText], folded: Bool = false) -> Int {
        let lines = seen.sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.01 ? a.box.midY < b.box.midY : a.box.minX < b.box.minX
        }
        var haystack = Substring(lines.map { folded ? fold(normalize($0.text)) : normalize($0.text) }.joined())
        var count = 0
        while let range = haystack.range(of: needle) {
            count += 1
            haystack = haystack[range.upperBound...]
        }
        return count
    }
}

/// The whole paste: the clipboard held against other agent processes, the
/// user's contents saved in full, the text put there, ⌘V and the wait, the
/// user's contents put back.
public struct PasteTransaction {
    public var pasteboard: NSPasteboard = .general
    public var leaseURL: URL = ClipboardLease.defaultURL
    /// How long to wait for another agent's paste to finish.
    public var leaseTimeout: TimeInterval = 45
    public var watcher = PasteWatcher()
    /// Extra looks, after a paste that did not settle, for the phone to be
    /// seen done with the clipboard before the user's contents go back.
    public var settleLooks = 30
    /// Raised when a paste leaves its text on the clipboard because the
    /// phone may still fetch it: until it expires, no agent process pastes,
    /// since its text could reach that phone instead. The lease alone ends
    /// with the process; this outlives it.
    public var pending: HostFlag = .named("clipboard.pending")
    /// How long a withheld clipboard is kept from other pastes. Universal
    /// Clipboard offers the Mac's clipboard only for a short while; two
    /// minutes is this backend's assumption, to be checked on a device (I07).
    public var pendingSeconds: TimeInterval = 120

    public init() {}

    /// What became of the paste, and of the user's clipboard.
    public struct Result: Equatable {
        public var outcome: PasteOutcome
        /// The user's contents are back (or they copied something new).
        /// False when they were withheld: the clipboard still holds the
        /// pasted text, because the phone might yet fetch it and must not
        /// get the user's data instead.
        public var clipboardRestored: Bool
    }

    public func paste(_ text: String, verify: Bool, driver: PhonePasteDriver) -> Result {
        do {
            return try ClipboardLease.with(at: leaseURL, timeout: leaseTimeout) {
                if let why = pending.reason() {
                    return Result(outcome: .notDelivered("clipboard_pending: \(why); nothing was pasted"),
                                  clipboardRestored: true)
                }
                var watcher = self.watcher
                final class Seen { var baseline: [PhoneText]? }
                let seen = Seen()
                watcher.onBaseline = { seen.baseline = $0 }
                let loan = try PasteboardLoan.with(text, on: pasteboard, restoreAfter: { (outcome: PasteOutcome) -> Bool in
                    // A paste that settled is done with the clipboard. One that
                    // did not may still be fetched (a prompt left up, a slow
                    // transfer): restore only once the phone is seen done.
                    guard case .unknown = outcome else { return true }
                    // Before the wait below, not after it: meanwhile another
                    // process must not type into a field in an unknown state.
                    driver.blockInput("may hold a half-finished paste")
                    return watcher.settles(looks: settleLooks, driver: driver, baseline: seen.baseline)
                }) { () -> PasteOutcome in
                    let ours = pasteboard.changeCount
                    watcher.othersWrote = { pasteboard.changeCount != ours }
                    return watcher.paste(text, verify: verify, driver: driver)
                }
                let restored = loan.restored || pasteboard.string(forType: .string) != text
                if !restored {
                    try? pending.raise("a paste that did not finish left its text on the clipboard for a phone "
                        + "that may still fetch it", until: Date().addingTimeInterval(pendingSeconds))
                }
                var outcome = loan.value
                var alreadySaid = false
                if case .unknown(let why) = outcome { alreadySaid = why.hasPrefix("user_copied_during_paste") }
                if loan.othersWrote, outcome != .confirmed, !alreadySaid {
                    // 2026-10-08 on a device: a copy made during the paste was
                    // what the phone pasted. That may be the user's data.
                    outcome = .unknown("user_copied_during_paste: something else was copied to the Mac's clipboard "
                        + "while the phone was fetching it, so the phone may have pasted that, possibly the "
                        + "user's data, instead of the text")
                }
                return Result(outcome: outcome, clipboardRestored: restored)
            }
        } catch {
            // The lease or the snapshot failed: the clipboard was not touched.
            return Result(outcome: .notDelivered(error.localizedDescription), clipboardRestored: true)
        }
    }
}
