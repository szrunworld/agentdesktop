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

    /// Bind Mirroring's phone window on the screen and return its frame.
    /// Only a window titled exactly as the phone's window
    /// (`IPhoneWindow.phoneWindowTitles`; other languages fail closed) is
    /// bound, never its Settings or
    /// another window however large; with none, nothing is bound. Keeps the
    /// window already bound while it is there. Only reads: it presses
    /// nothing, even on a status page.
    public func frame() throws -> CGRect {
        guard let bounds = try system.screenFrame(named: screen) else {
            throw AgentError("no screen named \"\(screen)\"; run `agentdesktop iphone show`")
        }
        screenFrame = bounds
        let pid = try currentPID()
        let onScreen = system.windows(pid: pid).filter { bounds.contains(CGPoint(x: $0.frame.midX, y: $0.frame.midY)) }
        let candidates = onScreen.filter(\.isPhoneWindow)
        let window: IPhoneWindow
        if let bound = binding, bound.pid == pid, let same = candidates.first(where: { $0.windowID == bound.windowID }) {
            window = same
        } else if let largest = candidates.max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }) {
            window = largest
        } else {
            binding = nil
            observation = nil
            let seen = onScreen.map { "\"\($0.title ?? "untitled")\"" }.joined(separator: ", ")
            throw IPhoneError("no_phone_window", "iPhone Mirroring has no phone window on screen \"\(screen)\""
                + (seen.isEmpty ? "" : " (only \(seen))") + "; run `agentdesktop iphone show`")
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
                              "iPhone Mirroring shows \"\(status.label ?? status.state.rawValue)\": \(status.state.hint(shown: status.label))")
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

    /// How `reconnect` ended.
    public enum ReconnectOutcome: String {
        /// The phone was seen ready, steadily, after any press: input may go on.
        case ready
        /// A button was pressed, but the phone was not seen ready for long
        /// enough before the timeout. Not a success; input stays refused.
        case pressedUnconfirmed = "pressed_unconfirmed"
        /// The phone is in use, locked, or Mirroring needs the user (password,
        /// Touch ID, Bluetooth…): nothing more is pressed.
        case needsUser = "needs_user"
        /// Not ready and nothing pressed: no button to press, the state
        /// unknown, or an input barrier still up.
        case notReady = "not_ready"
    }

    public struct ReconnectReport {
        public var outcome: ReconnectOutcome
        /// Where the last generation stood when it returned.
        public var phase: IPhoneConnectionPhase
        public var generation: Int
        /// Ready looks counted in a row, of `stableReadings` needed.
        public var readyReadings: Int
        /// What the window showed at the last look counted.
        public var state: IPhoneConnectionState
        public var label: String?
        /// The button pressed, if one was.
        public var pressed: String?
        public var timedOut: Bool
        /// Why a connection seen ready is still not reported ready.
        public var blockedBy: String?

        /// Only a confirmed ready is a success.
        public var isReady: Bool { outcome == .ready }
    }

    /// The connection as `reconnect` left it in this process. A press not
    /// yet confirmed ready keeps input refused.
    public private(set) var connection = IPhoneConnectionTracker()
    /// The host-wide reconnect gate as this reconnect last knew it: read at
    /// its start, or what it raised itself. Ready lowers the gate only if
    /// it still reads so, never a press another process made meanwhile.
    private var gateKnown: String?
    /// How long a reconnect waits for another process's change to the gate
    /// before it gives up, pressing or lowering nothing.
    var gateLockWait: TimeInterval = 10
    private var gateLock: HostFlagLock { HostFlagLock(for: system.reconnectGate, wait: gateLockWait) }

    /// Count a look at the window toward the connection; false when it was
    /// of an earlier generation and dropped.
    @discardableResult
    func record(_ look: IPhoneConnectionObservation) -> Bool {
        connection.record(look)
    }

    /// One look at the window, stamped with the generation current when it
    /// began. A look that fails is not ready.
    private func look() -> IPhoneConnectionObservation {
        let generation = connection.generation
        let at = system.now
        guard let (state, label) = try? connectionState() else {
            return IPhoneConnectionObservation(generation: generation, state: .uncertain, windowID: nil, at: at)
        }
        return IPhoneConnectionObservation(generation: generation, state: state, label: label,
                                           windowID: binding?.windowID, at: at)
    }

    /// Ask a disconnected Mirroring to connect again and wait, until
    /// `timeout` or `deadline`, for the phone to be ready. Presses nothing
    /// when the phone is in use, locked or needs the user: those are for
    /// the user.
    ///
    /// `phoneLocked`: the user says they have locked the phone. Mirroring's
    /// "iPhone in Use" page stays up after the phone is locked until its
    /// Connect is pressed (#182, seen on a device); nothing on the Mac shows
    /// whether the phone is locked, so it is pressed only on the user's word,
    /// and what follows is checked as after any press.
    ///
    /// Each call, and each press, starts a new connection generation (see
    /// `IPhoneConnectionTracker`): only looks taken after it count. Ready is
    /// reported only when the phone was seen ready
    /// `IPhoneConnectionTracker.defaultStableReadings` times in a row, a
    /// second or more apart, in the bound phone window, with the latest look
    /// ready and no input barrier up. A status page needing the user at any
    /// look ends it as `needsUser` (2026-10-09 F8: "ready" right after Resume,
    /// "iPhone Mirroring Is Locked" seconds later).
    public func reconnect(timeout: TimeInterval = 20, phoneLocked: Bool = false) throws -> ReconnectReport {
        let until = min(deadline ?? .distantFuture, system.now.addingTimeInterval(timeout))
        connection.begin(at: system.now, pressed: false)
        gateKnown = system.reconnectGate.reason(now: system.now)
        let generation = connection.generation
        let at = system.now
        let (state, label) = try connectionState()
        connection.record(IPhoneConnectionObservation(generation: generation, state: state, label: label,
                                                      windowID: binding?.windowID, at: at))
        var pressed: String?
        // The page that the user's lock ends, on the user's word only.
        func lockedInUse(_ state: IPhoneConnectionState, _ label: String?) -> Bool {
            phoneLocked && state == .phoneInUse && IPhoneConnection.endsOnLock(label)
        }
        let fromInUse = lockedInUse(state, label)
        switch state {
        case .phoneInUse where !fromInUse, .authRequired, .needsUser:
            return report(.needsUser, pressed: nil, timedOut: false)
        case .uncertain:
            return report(.notReady, pressed: nil, timedOut: false)
        case .disconnected, .phoneInUse:
            // Stopped already: press nothing, not even Connect or Resume.
            if let stop = stopReason() { throw stop }
            guard let pid = binding?.pid else { return report(.notReady, pressed: nil, timedOut: false) }
            // Every process refuses input from before the press until a
            // reconnect confirms the phone: the CLI runs each command in a
            // process of its own. Not recorded, not pressed.
            let gate = "iPhone Mirroring was asked to connect at \(system.now) (process \(getpid()), "
                + "\(UUID().uuidString)) and has not been confirmed ready"
            // Raising, pressing and putting back are one step against other
            // reconnects and against input: the gate then always names the
            // latest press, and no input is sent between raising and pressing.
            enum Press { case pressed(String), noButton, timedOut, changed(IPhoneConnectionState) }
            let press: Press
            let windowBefore = binding?.windowID
            do {
                press = try gateLock.locked(giveUp: { stopReason() != nil || system.now >= until }) { () throws -> Press in
                    // The wait for the lock may have outlasted the call:
                    // stopped or out of time, nothing is changed or pressed.
                    if let stop = stopReason() { throw stop }
                    if system.now >= until { return .timedOut }
                    // Nor if the page changed meanwhile (independent review
                    // of #142: a Welcome page's "继续" was pressed after the
                    // wait): only a disconnected phone is reconnected.
                    let (now, nowLabel) = (try? connectionState()) ?? (.uncertain, nil)
                    record(IPhoneConnectionObservation(generation: connection.generation, state: now, label: nowLabel,
                                                       windowID: binding?.windowID, at: system.now))
                    // The read takes time (a capture, OCR): stopped or out of
                    // time meanwhile, nothing is pressed (Codex on #142).
                    if let stop = stopReason() { throw stop }
                    if system.now >= until { return .timedOut }
                    // Another window since the look that chose to press:
                    // nothing is known of it yet (Codex on #142).
                    guard binding?.windowID == windowBefore else { return .changed(.uncertain) }
                    guard now == .disconnected || (fromInUse && lockedInUse(now, nowLabel)) else { return .changed(now) }
                    let before = system.reconnectGate.reason(now: system.now)
                    try system.reconnectGate.raise(gate)
                    guard let title = system.pressButton(titled: IPhoneConnection.reconnectButtons, pid: pid,
                                                         windowID: binding?.windowID)
                    else {
                        // Nothing pressed: the gate as it was, which nobody
                        // else could change meanwhile.
                        if let before { try? system.reconnectGate.raise(before) } else { system.reconnectGate.lower() }
                        return .noButton
                    }
                    return .pressed(title)
                }
            } catch let stop as IPhoneError {
                throw stop
            } catch HostFlagLock.Failure.gaveUp {
                if let stop = stopReason() { throw stop }
                return report(.notReady, pressed: nil, timedOut: true)
            } catch HostFlagLock.Failure.busy {
                // Another process held the lock all the wait: out of time.
                return report(.notReady, pressed: nil, timedOut: true)
            } catch {
                var refused = report(.notReady, pressed: nil, timedOut: false)
                refused.blockedBy = "cannot record the reconnect for other processes (\(error.localizedDescription)); nothing pressed"
                return refused
            }
            let title: String
            switch press {
            case .pressed(let pressedTitle): title = pressedTitle
            case .noButton: return report(.notReady, pressed: nil, timedOut: false)
            case .timedOut: return report(.notReady, pressed: nil, timedOut: true)
            case .changed(.phoneInUse), .changed(.authRequired), .changed(.needsUser):
                return report(.needsUser, pressed: nil, timedOut: false)
            case .changed: return report(.notReady, pressed: nil, timedOut: false)
            }
            gateKnown = gate
            pressed = title
            // What was seen before the press says nothing about after it.
            connection.begin(at: system.now, pressed: true)
        case .ready, .reconnecting:
            break
        }
        while true {
            if let done = try readyReport(pressed: pressed, until: until) { return done }
            if let stop = stopReason() { throw stop }
            let left = until.timeIntervalSince(system.now)
            if left <= 0 { return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: true) }
            system.sleep(min(connection.spacing, left))
            // The window may be gone or remade while it connects.
            let seen = look()
            connection.record(seen)
            switch seen.state {
            case .phoneInUse where fromInUse && pressed != nil && IPhoneConnection.endsOnLock(seen.label):
                // The page may stay a moment after Connect; if the phone was
                // not locked after all it stays, and the wait ends unconfirmed.
                break
            case .phoneInUse, .authRequired, .needsUser:
                return report(.needsUser, pressed: pressed, timedOut: false)
            case .ready, .reconnecting, .disconnected, .uncertain:
                break
            }
            if let stop = stopReason() { throw stop }
            // A look that ended at or past the timeout cannot make it ready:
            // the time to be sure of the phone is over.
            if system.now >= until {
                return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: true)
            }
        }
    }

    /// The report when the connection is ready in the bound window, nil
    /// while it is not. Throws when stopped.
    private func readyReport(pressed: String?, until: Date) throws -> ReconnectReport? {
        guard connection.isReady(window: binding?.windowID) else { return nil }
        if let reason = invalidated ?? system.inputBarrier.reason(now: system.now) {
            var blocked = report(.notReady, pressed: pressed, timedOut: false)
            blocked.blockedBy = "input barrier: \(reason); take a screenshot first"
            return blocked
        }
        // Compared and lowered as one step: a press by another process
        // meanwhile is not confirmed by looks begun before it, and is never
        // lowered here.
        enum Lowering {
            case lowered, pressedElsewhere(String?), timedOut, barrier(String), changed(IPhoneConnectionState), notLowered
        }
        let lowering: Lowering
        // The window the steady looks were of.
        let windowBefore = binding?.windowID
        do {
            lowering = try gateLock.locked(giveUp: { stopReason() != nil || system.now >= until }) { () throws -> Lowering in
                // The wait for the lock may have outlasted the call: stopped
                // or out of time, the looks are stale and nothing is lowered.
                if let stop = stopReason() { throw stop }
                if system.now >= until { return .timedOut }
                // An input that ran while this waited may have raised it.
                if let reason = invalidated ?? system.inputBarrier.reason(now: system.now) { return .barrier(reason) }
                // The looks that made it ready came before the wait: the
                // phone may have locked meanwhile (independent review of
                // #142). Read once more before confirming.
                let (now, nowLabel) = (try? connectionState()) ?? (.uncertain, nil)
                // What the report says is what this last read saw (Codex on
                // #142: needs_user beside a ready state).
                record(IPhoneConnectionObservation(generation: connection.generation, state: now, label: nowLabel,
                                                   windowID: binding?.windowID, at: system.now))
                // The read takes time: stopped or out of time meanwhile, the
                // phone is not confirmed (Codex on #142).
                if let stop = stopReason() { throw stop }
                if system.now >= until { return .timedOut }
                // The steady looks were of another window: one ready look of
                // this one confirms nothing (Codex on #142).
                guard binding?.windowID == windowBefore else { return .changed(.uncertain) }
                guard now == .ready else { return .changed(now) }
                let gate = system.reconnectGate.reason(now: system.now)
                guard gate == gateKnown else { return .pressedElsewhere(gate) }
                system.reconnectGate.lower()
                // Lowering swallows a failure to remove the record: ready only
                // once it is seen gone (Codex on #142).
                guard system.reconnectGate.reason(now: system.now) == nil else { return .notLowered }
                return .lowered
            }
        } catch let stop as IPhoneError {
            throw stop
        } catch HostFlagLock.Failure.gaveUp {
            if let stop = stopReason() { throw stop }
            return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: true)
        } catch HostFlagLock.Failure.busy {
            return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: true)
        } catch {
            var blocked = report(.notReady, pressed: pressed, timedOut: false)
            blocked.blockedBy = "cannot change the reconnect record for other processes (\(error.localizedDescription)); "
                + "run `agentdesktop iphone reconnect` again"
            return blocked
        }
        switch lowering {
        case .lowered:
            connection.confirm()
            return report(.ready, pressed: pressed, timedOut: false)
        case .changed(.phoneInUse), .changed(.authRequired), .changed(.needsUser):
            return report(.needsUser, pressed: pressed, timedOut: false)
        case .changed:
            return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: false)
        case .timedOut:
            return report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: true)
        case .barrier(let reason):
            var blocked = report(.notReady, pressed: pressed, timedOut: false)
            blocked.blockedBy = "input barrier: \(reason); take a screenshot first"
            return blocked
        case .notLowered:
            var blocked = report(pressed == nil ? .notReady : .pressedUnconfirmed, pressed: pressed, timedOut: false)
            blocked.blockedBy = "the reconnect record for other processes could not be removed; "
                + "run `agentdesktop iphone reconnect` again"
            return blocked
        case .pressedElsewhere(let gate):
            var blocked = report(.notReady, pressed: pressed, timedOut: false)
            blocked.blockedBy = "another reconnect pressed a button meanwhile (\(gate ?? "its record is gone")); "
                + "run `agentdesktop iphone reconnect` again"
            return blocked
        }
    }

    private func report(_ outcome: ReconnectOutcome, pressed: String?, timedOut: Bool) -> ReconnectReport {
        ReconnectReport(outcome: outcome, phase: connection.phase, generation: connection.generation,
                        readyReadings: connection.readyStreak, state: connection.latest?.state ?? .uncertain,
                        label: connection.latest?.label, pressed: pressed, timedOut: timedOut)
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
            // The whole paste, and the barrier an unknown one raises, under
            // the gate's lock (shared): no reconnect confirms the phone in
            // between.
            let pasted: PasteTransaction.Result
            do {
                pasted = try gateLock.locked(shared: true, giveUp: { stopReason() != nil }) {
                    let pasted = try paste(text, pid: pid)
                    if case .unknown = pasted.outcome {
                        // Whatever acts next depends on what the field holds,
                        // which nobody knows: no input until the phone is
                        // read again.
                        block("may hold a half-finished paste")
                    }
                    return pasted
                }
            } catch let gate as HostFlagLock.Failure {
                return .failure(refusal(gate).localizedDescription)
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
        let response: ControlResponse
        let unknown: Bool
        do {
            // Checked, sent and checked again under the reconnect gate's
            // lock, shared: a reconnect cannot raise the gate and press
            // between the check and the send, nor confirm the phone before a
            // barrier this input raises is up (other input is not held up).
            (response, unknown) = try gateLock.locked(shared: true, giveUp: { stopReason() != nil }) {
                () throws -> (ControlResponse, Bool) in
                // Stopped while waiting for the lock: nothing is sent.
                if let stop = stopReason() { throw stop }
                // And with no paste able to start in any process (the
                // clipboard lease held through dispatch, Codex on #127), so
                // no input lands in a field another process is pasting into.
                // This screen's own paste holds the lease and sends its
                // presses itself.
                if ownPaste { return try dispatch(action, pid: pid) }
                guard let sent = try system.withoutPaste({ try dispatch(action, pid: pid) }) else {
                    throw Self.pasteInProgress
                }
                return sent
            }
        } catch let refusal as IPhoneError {
            return .failure(refusal.localizedDescription)
        } catch let gate as HostFlagLock.Failure {
            return .failure(refusal(gate).localizedDescription)
        }
        // Let the phone draw the result before the next screenshot.
        if !unknown { pause(0.6) }
        return response
    }

    /// Checks the target, sends, and checks again; whether the input's
    /// effect is unknown. Run under the gate's lock and the clipboard lease.
    private func dispatch(_ action: InputAction, pid: pid_t) throws -> (ControlResponse, Bool) {
        let window = try verifiedTarget(pid: pid)
        // Reading the window (a capture, OCR) takes time: stopped meanwhile,
        // nothing is sent.
        if let stop = stopReason() { throw stop }
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
            return (unknown, true)
        }
        // Checking and sending cannot be one step: if the window changed
        // around the send, the input may have gone elsewhere. Unknown, not
        // success, and nothing more until the window is read again.
        guard let changed = changedAfterSend(window, response) else { return (response, false) }
        block(changed)
        var unknown = ControlResponse.failure(IPhoneError(
            "action_delivery_unknown", reason: "target_changed_during_dispatch",
            "window \(window.windowID) \(changed) while input was sent; it may have reached something else. "
                + "Take a new screenshot before deciding on another action", notSent: false).localizedDescription)
        unknown.route = response.route
        unknown.window = response.window
        return (unknown, true)
    }

    /// Why input was not sent when the gate's lock was not had.
    private func refusal(_ failure: HostFlagLock.Failure) -> IPhoneError {
        switch failure {
        case .gaveUp:
            return stopReason() ?? IPhoneError("cancelled", "stopped; nothing more is sent")
        case .busy(let path):
            return IPhoneError("not_connected", reason: "unconfirmed",
                               "a reconnect is changing the connection (another process holds \(path)); "
                                   + "run `agentdesktop iphone reconnect` until it reports ready")
        }
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
        // The phone may have gone since the screenshot: then the window is a
        // status page, and a tap could press Mirroring's own Try Again or
        // Resume. Read as a screenshot is: its accessibility texts and its
        // picture, captured again, since a status page may show its message
        // only in the picture. Unread or not captured, nothing is known,
        // which is not ready either.
        let capture: IPhoneWindowCapture
        do {
            capture = try system.captureWindow(screen: screen, pid: pid, windowID: bound.windowID)
        } catch {
            throw IPhoneError("not_connected", reason: IPhoneConnectionState.uncertain.rawValue,
                              "window \(bound.windowID) could not be captured to check it before input "
                                  + "(\(error.localizedDescription))")
        }
        guard capture.windowID == bound.windowID, IPhoneObservation.sameFrame(capture.frame, bound.frame) else {
            throw IPhoneError.stale("moved", "window \(bound.windowID) moved or resized since it was read")
        }
        // A flat, undrawn frame shows nothing to judge by, as for a screenshot.
        guard !IPhoneFrames.isBlank(capture.image) else {
            throw IPhoneError("not_connected", reason: IPhoneConnectionState.uncertain.rawValue,
                              "the capture of window \(bound.windowID) before input is one flat colour, not the phone")
        }
        let status = IPhoneConnection.classify(system.accessibilityLabels(pid: pid, windowID: bound.windowID),
                                               ocr: system.recognizedText(in: capture.image))
        guard status.state == .ready else {
            throw IPhoneError("not_connected", reason: status.state.rawValue,
                              "iPhone Mirroring shows \"\(status.label ?? status.state.rawValue)\": \(status.state.hint(shown: status.label))")
        }
        // A reconnect pressed a button and the phone was not seen ready for
        // long enough since: a moment of "ready" may still turn into a lock
        // screen (F8). Only a reconnect that confirms it lets input go on.
        if connection.awaitingConfirmation {
            throw IPhoneError("not_connected", reason: "unconfirmed",
                              "iPhone Mirroring was asked to connect (generation \(connection.generation), "
                                  + "\(connection.phase.rawValue)) and has not been confirmed ready; "
                                  + "run `agentdesktop iphone reconnect` again")
        }
        // The same for a press by any process (the CLI's reconnect is a
        // process of its own); an unreadable record counts as raised.
        if let gate = system.reconnectGate.reason(now: system.now) {
            throw IPhoneError("not_connected", reason: "unconfirmed",
                              gate + "; run `agentdesktop iphone reconnect` until it reports ready")
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
