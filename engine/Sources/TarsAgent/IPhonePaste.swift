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
    /// How far apart (in window heights) the alert's parts can be.
    static let alertSpan: CGFloat = 0.3

    /// Reads `seen`. An Allow button is pressed only with the alert's
    /// structure around it: in the middle of the screen, with the Don't
    /// Allow button or the alert's message near it. `baseline` is what was
    /// on screen before ⌘V; an "Allow Paste" already there is page content.
    public static func read(_ seen: [PhoneText], baseline: [PhoneText]?) -> PastePrompt {
        let allows = seen.filter { allowPasteLabels.contains(clean($0.text)) }
        let evidence = seen.filter { line in
            let text = clean(line.text)
            return denyPasteLabels.contains(text)
                || promptPhrases.contains { text.range(of: $0, options: .caseInsensitive) != nil }
        }
        for allow in allows where alertRegion.contains(allow.center) {
            let near = evidence.contains { part in
                alertRegion.contains(part.center) && abs(part.center.y - allow.center.y) <= alertSpan
                    && part != allow
            }
            if near { return .allow(allow.center) }
        }
        if seen.contains(where: { line in pastingLabels.contains { clean(line.text).hasPrefix($0) } }) {
            return .pasting
        }
        let allowBefore = (baseline ?? []).contains { allowPasteLabels.contains(clean($0.text)) }
        if !allows.isEmpty && !allowBefore { return .unverifiedAllow }
        return .none
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
    public var quietLooks = 2
    /// Presses of Allow Paste before its coming back counts as a failure.
    public var maxAllowPresses = 2

    public init() {}

    /// `verify`: whether the text may be read back off the screen to
    /// confirm it. Without that the best outcome is `.delivered`.
    public func paste(_ text: String, verify: Bool, driver: PhonePasteDriver) -> PasteOutcome {
        let baseline = try? driver.look()
        let pressed: ControlResponse
        do {
            pressed = try driver.pressPaste()
        } catch {
            // The request may have gone out before it failed.
            return .unknown("⌘V: \(error.localizedDescription)")
        }
        guard pressed.ok else { return .notDelivered(pressed.error ?? "⌘V failed") }

        var quiet = 0
        var presses = 0
        var blind = 0
        var last: PastePrompt?
        var settled: [PhoneText]?
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
        guard verify else { return .delivered(nil) }
        return Self.check(text, before: baseline, after: settled)
    }

    /// After a paste that did not settle: watch up to `looks` more times for
    /// the phone to show neither a paste prompt nor a paste in progress, on
    /// a screen that could be read. Nothing is pressed. True only when the
    /// phone is seen to be done with the clipboard, so the user's contents
    /// can go back without the phone fetching them.
    public func settles(looks: Int, driver: PhonePasteDriver) -> Bool {
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
                    || PastePrompt.pastingLabels.contains { text.hasPrefix($0) }
                    || PastePrompt.promptPhrases.contains { text.range(of: $0, options: .caseInsensitive) != nil }
            }
            quiet = prompting ? 0 : quiet + 1
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
        return now > was ? .confirmed : .delivered("the text was not seen on screen")
    }

    static func normalize(_ text: String) -> String {
        String(text.lowercased().filter { $0.isLetter || $0.isNumber })
    }

    /// Non-overlapping occurrences of `needle` in the screen's text read top
    /// to bottom, left to right.
    static func occurrences(of needle: String, in seen: [PhoneText]) -> Int {
        let lines = seen.sorted { a, b in
            abs(a.box.midY - b.box.midY) > 0.01 ? a.box.midY < b.box.midY : a.box.minX < b.box.minX
        }
        var haystack = Substring(lines.map { normalize($0.text) }.joined())
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
                let loan = try PasteboardLoan.with(text, on: pasteboard, restoreAfter: { outcome in
                    // A paste that settled is done with the clipboard. One that
                    // did not may still be fetched (a prompt left up, a slow
                    // transfer): restore only once the phone is seen done.
                    guard case .unknown = outcome else { return true }
                    return watcher.settles(looks: settleLooks, driver: driver)
                }) {
                    watcher.paste(text, verify: verify, driver: driver)
                }
                return Result(outcome: loan.value, clipboardRestored: loan.restored || pasteboard.string(forType: .string) != text)
            }
        } catch {
            // The lease or the snapshot failed: the clipboard was not touched.
            return Result(outcome: .notDelivered(error.localizedDescription), clipboardRestored: true)
        }
    }
}
