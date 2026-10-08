import AppKit
import CoreGraphics
import Foundation
import SecondScreenCore
import Vision

/// The agent's view of an iPhone through iPhone Mirroring on an agent
/// screen. What was found running it by hand:
///
/// - Background clicks reach the phone, and so do plain keys (Delete,
///   Return) and ⌘1 / ⌘2, which agentdesktop sends with the app made front for
///   the instant the key is queued.
/// - Nothing scrolls or swipes: wheel events, trackpad phases and drags,
///   in the background or with the real pointer and the app in front, are
///   all ignored. So the model is offered no scroll, drag or long press.
/// - Typed text reaches the phone's keyboard as key codes, so a Chinese
///   keyboard turns every character into "a". Text is pasted instead: ⌘V
///   with ⌘ pressed as a key of its own, in the background (a ⌘V through
///   the menus, even with Mirroring in front, types "v"). The phone may ask
///   to "Allow Paste", pressed only when it is the system's alert, then
///   fetches the clipboard over the air for seconds. The whole paste holds
///   a clipboard lease against other agent processes, saves every item and
///   type on the clipboard (or refuses to paste if it cannot) and puts them
///   back. It reports `paste.confirmed` only when the text is read back off
///   the screen, `paste.delivered` when the phone went quiet but the text
///   was not seen, and fails as `paste.unknown` when the paste never
///   settled. A trailing newline presses Return only after a confirmed paste.
/// - Without the phone the window shows a status page ("iPhone in Use",
///   "连接暂停", …); see `IPhoneConnectionState`.
///
/// Observation and input are bound to one window: `frame()` binds
/// Mirroring's window by pid and window ID, a screenshot captures that
/// window alone and records an `IPhoneObservation`, and every input names
/// the window and is refused (`stale_observation`, nothing sent) when the
/// window is gone or has moved or resized since it was read. When the
/// window changes while input is being sent the result is
/// `action_delivery_unknown`, and further input is refused until the
/// window is read again. Reading never presses anything: reconnecting is
/// `reconnect(timeout:)` of its own.
///
/// Points are global; the screenshot is the mirroring window alone.
public final class IPhoneAgentScreen: AgentScreen {
    public static let bundleID = "com.apple.ScreenContinuity"

    public let screen: String
    public let system: IPhoneMirroringSystem

    private var screenFrame: CGRect = .zero
    private var windowFrame: CGRect = .zero
    /// The window `frame()` bound, with the frame it had then.
    public private(set) var binding: IPhoneWindow?
    /// What the last screenshot showed.
    public private(set) var observation: IPhoneObservation?
    /// Set when input may have reached something else; input is refused
    /// until the window is read again.
    private var invalidated: String?
    /// This screen's own paste is under way: its own presses (Allow Paste,
    /// Return) go through, while everyone else waits for it.
    private var ownPaste = false

    /// Checked before each input and during each wait in here; once true,
    /// nothing more is sent.
    public var isCancelled: () -> Bool = { false }
    /// After it, nothing more is sent and waits end.
    public var deadline: Date?

    public init(screen: String, system: IPhoneMirroringSystem = LiveIPhoneMirroringSystem()) {
        self.screen = screen
        self.system = system
    }

    public static func pid() throws -> pid_t {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            throw AgentError("iPhone Mirroring is not running; run `agentdesktop iphone show`")
        }
        return app.processIdentifier
    }

    private func currentPID() throws -> pid_t {
        guard let pid = system.mirroringPIDs().first else {
            throw AgentError("iPhone Mirroring is not running; run `agentdesktop iphone show`")
        }
        return pid
    }

    /// Bind Mirroring's window on the screen and return its frame. Keeps
    /// the window already bound while it is there; otherwise takes the
    /// largest. Only reads: it presses nothing, even on a status page.
    public func frame() throws -> CGRect {
        guard let bounds = try system.screenFrame(named: screen) else {
            throw AgentError("no screen named \"\(screen)\"; run `agentdesktop iphone show`")
        }
        screenFrame = bounds
        let pid = try currentPID()
        let candidates = system.windows(pid: pid).filter { bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let window: IPhoneWindow
        if let bound = binding, bound.pid == pid, let same = candidates.first(where: { $0.windowID == bound.windowID }) {
            window = same
        } else if let largest = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            window = largest
        } else {
            throw AgentError("iPhone Mirroring has no window on screen \"\(screen)\"; run `agentdesktop iphone show`")
        }
        if binding != window { observation = nil }
        binding = window
        windowFrame = window.frame
        // Geometry is not a look at the phone: an input barrier stays up
        // until a screenshot shows what the last input left behind.
        return window.frame
    }

    public func screenshot(size: CGSize) throws -> Data {
        // Taken with no paste able to start or be under way in any process
        // (the clipboard lease held across the capture, Codex on #127): a
        // paste that began and ended between two samples would otherwise
        // leave a frame of a field in flux to act on. This screen's own
        // paste holds the lease itself, so it captures without it.
        if ownPaste { return try takeScreenshot(size: size) }
        guard let png = try system.withoutPaste({ try takeScreenshot(size: size) }) else {
            throw Self.pasteInProgress
        }
        return png
    }

    private func takeScreenshot(size: CGSize) throws -> Data {
        // An input that turns uncertain while this capture is taken raises a
        // barrier this picture predates: only the one already up is lowered.
        let barrierSeen = system.inputBarrier.generation(now: system.now)
        let capture = try capturedWindow()
        let status = state(of: capture)
        guard status.state == .ready else {
            throw IPhoneError("not_connected", reason: status.state.rawValue,
                              "iPhone Mirroring shows \"\(status.label ?? status.state.rawValue)\": \(status.state.hint)")
        }
        guard !IPhoneFrames.isBlank(capture.image) else {
            throw IPhoneError("capture_failed", reason: "blank_frame",
                              "the capture of window \(capture.windowID) is one flat colour, not the phone")
        }
        let png = try Images.png(Images.scaled(capture.image, to: size))
        observation = IPhoneObservation(pid: binding?.pid ?? 0, windowID: capture.windowID, frame: capture.frame,
                                        pixelSize: size, capturedAt: system.now)
        // Whoever took it can now see what an uncertain input left. With no
        // paste under way (the lease is held), the barrier seen at the start
        // can go; one raised since stays.
        invalidated = nil
        if !ownPaste, let barrierSeen { system.inputBarrier.lower(ifStill: barrierSeen) }
        return png
    }

    /// The mirroring window alone, at the screen's pixels.
    private func windowImage() throws -> CGImage {
        try capturedWindow().image
    }

    /// The bound window captured on its own, still where it was bound.
    private func capturedWindow() throws -> IPhoneWindowCapture {
        if binding == nil { _ = try frame() }
        guard let bound = binding else { throw IPhoneError("no_observation", "iPhone Mirroring's window is not bound") }
        let capture = try system.captureWindow(screen: screen, pid: bound.pid, windowID: bound.windowID)
        guard capture.windowID == bound.windowID, IPhoneObservation.sameFrame(capture.frame, bound.frame) else {
            throw IPhoneError.stale("moved", "window \(bound.windowID) moved or resized since it was read")
        }
        return capture
    }

    // MARK: Connection

    private func state(of capture: IPhoneWindowCapture) -> (state: IPhoneConnectionState, label: String?) {
        IPhoneConnection.classify(system.accessibilityLabels(pid: binding?.pid ?? 0, windowID: capture.windowID),
                                  ocr: system.recognizedText(in: capture.image))
    }

    /// What the window shows now. Reads only.
    public func connectionState() throws -> (state: IPhoneConnectionState, label: String?) {
        _ = try frame()
        return state(of: try capturedWindow())
    }

    public struct ReconnectReport {
        public var state: IPhoneConnectionState
        public var label: String?
        /// The button pressed, if one was.
        public var pressed: String?
        public var timedOut: Bool
    }

    /// Ask a disconnected Mirroring to connect again and wait, until
    /// `timeout` or `deadline`, for it to settle. Presses nothing when the
    /// phone is in use, locked or needs the user: those are for the user.
    public func reconnect(timeout: TimeInterval = 20) throws -> ReconnectReport {
        let until = min(deadline ?? .distantFuture, system.now.addingTimeInterval(timeout))
        var (state, label) = try connectionState()
        var pressed: String?
        switch state {
        case .ready, .phoneInUse, .authRequired, .needsUser:
            return ReconnectReport(state: state, label: label, pressed: nil, timedOut: false)
        case .disconnected:
            // Stopped already: press nothing, not even Connect or Resume.
            if let stop = stopReason() { throw stop }
            guard let pid = binding?.pid,
                  let title = system.pressButton(titled: IPhoneConnection.reconnectButtons, pid: pid, windowID: binding?.windowID)
            else { return ReconnectReport(state: state, label: label, pressed: nil, timedOut: false) }
            pressed = title
        case .reconnecting:
            break
        }
        while true {
            if let stop = stopReason() { throw stop }
            let left = until.timeIntervalSince(system.now)
            if left <= 0 { return ReconnectReport(state: state, label: label, pressed: pressed, timedOut: true) }
            system.sleep(min(1, left))
            // The window may be gone or remade while it connects.
            if let now = try? connectionState() { (state, label) = now }
            if state != .reconnecting && state != .disconnected {
                return ReconnectReport(state: state, label: label, pressed: pressed, timedOut: false)
            }
        }
    }

    // MARK: Cancellation

    private func stopReason() -> IPhoneError? {
        if isCancelled() { return IPhoneError("cancelled", "stopped; nothing more is sent") }
        if let deadline, system.now >= deadline {
            return IPhoneError("deadline_exceeded", "the deadline passed; nothing more is sent")
        }
        return nil
    }

    /// Sleep up to `seconds`, ending early when stopped.
    private func pause(_ seconds: TimeInterval) {
        let end = system.now.addingTimeInterval(seconds)
        while stopReason() == nil {
            let left = end.timeIntervalSince(system.now)
            if left <= 0 { return }
            system.sleep(min(0.1, left))
        }
    }

    public func perform(_ action: InputAction) throws -> ControlResponse {
        let pid = try currentPID()
        switch action.kind {
        case .scroll, .drag:
            return .failure("iPhone Mirroring ignores swipes and scrolling from the Mac; "
                + "use what is on screen, Home Screen, or search")
        case .click where action.durationMs != nil:
            return .failure("a long press is not possible through iPhone Mirroring")
        case .key where action.key == "home":
            return try send(key("1", ["cmd"]), pid: pid)
        case .key where action.key == "back":
            return .failure("an iPhone has no Back key; tap the app's own back button")
        case .type:
            guard var text = action.value, !text.isEmpty else { return ControlResponse() }
            let submit = text.hasSuffix("\n")
            if submit { text.removeLast() }
            if text.isEmpty { return try send(key("return", []), pid: pid) }
            let pasted = try paste(text, pid: pid)
            if case .unknown = pasted.outcome {
                // Whatever acts next depends on what the field holds, which
                // nobody knows: no input until the phone is read again.
                block("may hold a half-finished paste")
            }
            return try pasted.outcome.response(submit: submit, clipboardRestored: pasted.clipboardRestored) {
                try send(key("return", []), pid: pid)
            }
        default:
            return try send(action, pid: pid)
        }
    }

    /// Mirroring lists nothing through accessibility; the model goes by the
    /// screenshot.
    public func elements() throws -> [AXElementInfo] { [] }

    // MARK: Helpers

    private func key(_ name: String, _ modifiers: [String]) -> InputAction {
        var action = InputAction(.key)
        action.key = name
        action.modifiers = modifiers
        return action
    }

    /// Send `action` to the bound window, after checking it is still the
    /// window and geometry last read; a refusal sends nothing.
    private func send(_ action: InputAction, pid: pid_t) throws -> ControlResponse {
        if let stop = stopReason() { return .failure(stop.localizedDescription) }
        // The checks and the delivery run with no paste able to start in any
        // process (the clipboard lease held through dispatch, Codex on #127),
        // so no input lands in a field another process is pasting into. This
        // screen's own paste holds the lease and sends its presses itself.
        if ownPaste { return try dispatch(action, pid: pid) }
        guard let response = try system.withoutPaste({ try dispatch(action, pid: pid) }) else {
            return .failure(Self.pasteInProgress.localizedDescription)
        }
        return response
    }

    private func dispatch(_ action: InputAction, pid: pid_t) throws -> ControlResponse {
        let window: IPhoneWindow
        do {
            window = try verifiedTarget(pid: pid)
        } catch let refusal as IPhoneError {
            return .failure(refusal.localizedDescription)
        }
        var request = ControlRequest(command: .input)
        request.screen = screen
        request.pid = pid
        request.windowID = window.windowID
        request.input = action
        let response: ControlResponse
        do {
            response = try system.deliver(request)
        } catch {
            // The request may have gone out before the transport failed: the
            // input's effect is unknown, as when the window changes under it.
            block("may hold the result of an input whose delivery failed midway")
            var unknown = ControlResponse.failure(IPhoneError(
                "action_delivery_unknown", reason: "transport_error",
                "sending the input failed (\(error.localizedDescription)); it may or may not have reached the phone. "
                    + "Take a new screenshot before deciding on another action", notSent: false).localizedDescription)
            unknown.route = "\(action.kind.rawValue).unknown"
            return unknown
        }
        // Checking and sending cannot be one step: if the window changed
        // around the send, the input may have gone elsewhere. Unknown, not
        // success, and nothing more until the window is read again.
        if let changed = changedAfterSend(window, response) {
            block(changed)
            var unknown = ControlResponse.failure(IPhoneError(
                "action_delivery_unknown", reason: "target_changed_during_dispatch",
                "window \(window.windowID) \(changed) while input was sent; it may have reached something else. "
                    + "Take a new screenshot before deciding on another action", notSent: false).localizedDescription)
            unknown.route = response.route
            unknown.window = response.window
            return unknown
        }
        // Let the phone draw the result before the next screenshot.
        pause(0.6)
        return response
    }

    static let pasteInProgress = IPhoneError(
        "paste_in_progress", "another agent is pasting into the phone (or waiting out a paste the phone may still fetch); "
            + "nothing was sent: take a screenshot again once it is done")

    /// No more input to this phone, from this or any process, until a
    /// screenshot of it is taken.
    private func block(_ reason: String) {
        do {
            try system.inputBarrier.raise(reason)
        } catch {
            // Kept here at least, for this process, and said: other processes
            // will not see this barrier.
            invalidated = reason
            FileHandle.standardError.write(Data(("agentdesktop: the iPhone input barrier could not be shared with "
                + "other processes (\(error.localizedDescription)); only this process holds back input\n").utf8))
        }
    }

    /// The bound window as it is now, if input may still go to it.
    private func verifiedTarget(pid: pid_t) throws -> IPhoneWindow {
        if let reason = invalidated ?? system.inputBarrier.reason(now: system.now) {
            throw IPhoneError.stale("delivery_unknown", "the window \(reason) after an earlier input; "
                + "take a screenshot before any more input")
        }
        // Nor while another process is pasting: whatever this input was
        // planned on, the field is changing under it.
        guard let bound = binding else {
            throw IPhoneError("no_observation", "read iPhone Mirroring's window first (frame or screenshot)")
        }
        guard bound.pid == pid else {
            throw IPhoneError.stale("process_restarted", "iPhone Mirroring restarted (pid \(bound.pid) → \(pid))")
        }
        let windows = system.windows(pid: pid)
        guard let now = windows.first(where: { $0.windowID == bound.windowID }) else {
            throw IPhoneError.stale("window_gone", "window \(bound.windowID) is gone")
        }
        guard IPhoneObservation.sameFrame(now.frame, bound.frame) else {
            throw IPhoneError.stale("moved", "window \(bound.windowID) moved or resized since it was read")
        }
        // A click goes to a window of the same app lying over the point
        // (Mirroring's settings, a sheet): refuse rather than tap it.
        if let front = windows.prefix(while: { $0.windowID != bound.windowID })
            .first(where: { $0.frame.width >= 2 && $0.frame.height >= 2 && IPhoneObservation.overlaps($0.frame, bound.frame) }) {
            throw IPhoneError.stale("other_window_of_process_in_front",
                                    "iPhone Mirroring window \(front.windowID) lies over the phone window \(bound.windowID)")
        }
        return now
    }

    /// How the window changed while input was sent, or nil.
    private func changedAfterSend(_ window: IPhoneWindow, _ response: ControlResponse) -> String? {
        if let acted = response.window, acted.windowID != window.windowID { return "was not the window acted on" }
        guard let now = system.windows(pid: window.pid).first(where: { $0.windowID == window.windowID }) else {
            return "went away"
        }
        return IPhoneObservation.sameFrame(now.frame, window.frame) ? nil : "moved"
    }

    /// Paste `text` into the phone's focused field (see `PasteTransaction`).
    private func paste(_ text: String, pid: pid_t) throws -> PasteTransaction.Result {
        ownPaste = true
        defer { ownPaste = false }
        return PasteTransaction().paste(text, verify: true, driver: PhoneDriver(phone: self, pid: pid))
    }

    /// The phone for a paste: Vision reads the window, input goes to Mirroring.
    private struct PhoneDriver: PhonePasteDriver {
        let phone: IPhoneAgentScreen
        let pid: pid_t

        func look() throws -> [PhoneText] {
            // Stopped: no more looks count, so the paste ends unknown.
            if let stop = phone.stopReason() { throw stop }
            return try phone.pastePrompt()
        }

        func pressPaste() throws -> ControlResponse {
            var paste = phone.key("v", ["cmd"])
            paste.holdModifiers = true
            return try phone.send(paste, pid: pid)
        }

        func tap(_ point: CGPoint) throws -> ControlResponse {
            let frame = phone.windowFrame
            var tap = InputAction(.click)
            tap.x = frame.minX + point.x * frame.width
            tap.y = frame.minY + point.y * frame.height
            return try phone.send(tap, pid: pid)
        }

        func pause(_ seconds: TimeInterval) {
            if phone.stopReason() == nil { Thread.sleep(forTimeInterval: seconds) }
        }

        func blockInput(_ reason: String) { phone.block(reason) }
    }

    /// The text on the mirroring window, for `PastePrompt.read` and for
    /// checking the pasted text, boxes normalised with the origin top left.
    private func pastePrompt() throws -> [PhoneText] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let capture = try capturedWindow()
        // A status page ("iPhone in Use") is not a quiet phone: the paste's
        // fate cannot be read off it (2026-10-08: a paste the phone dropped
        // when it was picked up was reported delivered).
        let status = state(of: capture)
        guard status.state == .ready else {
            throw IPhoneError("not_connected", reason: status.state.rawValue,
                              "iPhone Mirroring shows \"\(status.label ?? status.state.rawValue)\" during the paste")
        }
        try VNImageRequestHandler(cgImage: capture.image).perform([request])
        return (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let box = observation.boundingBox  // normalised, bottom-left origin
            return PhoneText(text, CGRect(x: box.minX, y: 1 - box.maxY, width: box.width, height: box.height))
        }
    }

}
