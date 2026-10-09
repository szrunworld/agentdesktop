import AppKit
import CoreGraphics
import Foundation
import SecondScreenCore
import Vision

// What IPhoneAgentScreen needs from the system, behind a protocol so the
// rules (binding, connection state, lifecycle) can be tested without a phone.

/// One window of iPhone Mirroring, as the window server lists it.
public struct IPhoneWindow: Equatable {
    public var pid: pid_t
    public var windowID: CGWindowID
    /// Global points, top-left origin.
    public var frame: CGRect
    /// The window's title, read through accessibility (the window server's
    /// name otherwise); nil when neither gives one.
    public var title: String?

    public init(pid: pid_t, windowID: CGWindowID, frame: CGRect, title: String? = nil) {
        self.pid = pid
        self.windowID = windowID
        self.frame = frame
        self.title = title
    }

    /// Titles of the window that shows the phone, by the Mac's language.
    /// Mirroring's other windows ("iPhone Mirroring Settings", …) are not
    /// it; an unknown title is not taken for it either.
    public static let phoneWindowTitles: Set<String> = ["iPhone Mirroring", "iPhone镜像"]

    /// Whether this is the window that shows the phone: its title is
    /// exactly one of `phoneWindowTitles`.
    ///
    /// Only the languages whose status pages `IPhoneConnection` recognises
    /// are listed. On a Mac in another language (French "Recopie de
    /// l’iPhone", German "iPhone-Synchronisierung") the phone window is not
    /// bound and every command fails with `no_phone_window`: a status page
    /// in that language would read as ready, and a tap could press
    /// Mirroring's own buttons. Add a language here only together with its
    /// status phrases and controls.
    public var isPhoneWindow: Bool {
        title.map(Self.phoneWindowTitles.contains) ?? false
    }
}

/// A capture of one window alone, with the frame it had when captured.
public struct IPhoneWindowCapture {
    public var image: CGImage
    public var windowID: CGWindowID
    public var frame: CGRect

    public init(image: CGImage, windowID: CGWindowID, frame: CGRect) {
        self.image = image
        self.windowID = windowID
        self.frame = frame
    }
}

public protocol IPhoneMirroringSystem {
    /// iPhone Mirroring's processes, oldest first.
    func mirroringPIDs() -> [pid_t]
    /// The agent screen's frame, or nil when there is no such screen.
    func screenFrame(named name: String) throws -> CGRect?
    /// The process's normal on-screen windows, front to back.
    func windows(pid: pid_t) -> [IPhoneWindow]
    /// Only `windowID`, captured on its own (ScreenCaptureKit
    /// desktopIndependentWindow, in the app), so a window covering it is
    /// not in the picture.
    func captureWindow(screen: String, pid: pid_t, windowID: CGWindowID) throws -> IPhoneWindowCapture
    /// One control request to the running app.
    func deliver(_ request: ControlRequest) throws -> ControlResponse
    /// Text recognised in the image, Simplified Chinese and English.
    func recognizedText(in image: CGImage) -> [String]
    /// The titles of iPhone Mirroring's own texts and buttons, read through
    /// accessibility. The phone's picture is not among them.
    /// `windowID`: only that window's; nil for all the process's windows.
    /// Another window of the app (its Settings) carries texts that are not
    /// the phone's state, such as "password or Touch ID is required".
    /// nil when they could not be read (no Accessibility permission, a read
    /// that failed, no window `windowID`), which is not the same as a window
    /// that has none: `[]`.
    func accessibilityLabels(pid: pid_t, windowID: CGWindowID?) -> [String]?
    /// Press the first button of the process whose title is in `titles`,
    /// in `windowID` only when given; the title pressed, or nil when there
    /// is none.
    func pressButton(titled titles: Set<String>, pid: pid_t, windowID: CGWindowID?) -> String?
    /// Ask the process to quit; false when the request was not delivered.
    func terminate(pid: pid_t) -> Bool
    func isRunning(pid: pid_t) -> Bool
    var now: Date { get }
    func sleep(_ seconds: TimeInterval)
    /// Where the phone's input barrier is kept for every process: raised
    /// when nobody knows what an input did, lowered by the next screenshot.
    var inputBarrier: HostFlag { get }
    /// Raised for every process when a reconnect presses Connect / Resume /
    /// Try Again, lowered only by a reconnect that reports the phone
    /// confirmed ready: input is refused while it is up, and while its
    /// record cannot be read.
    var reconnectGate: HostFlag { get }
    /// Whether some process is in a paste: holding the clipboard lease, or
    /// waiting out a phone that may still fetch (the pending mark). While it
    /// is, a screenshot shows a field in flux and lowers no barrier.
    var pasteInProgress: Bool { get }
    /// Runs `body` with no paste able to begin meanwhile (holding the
    /// clipboard lease), if none is under way; false, without running it,
    /// when one is.
    func whileNoPaste(_ body: () -> Void) -> Bool
    /// `body`'s result, run holding the clipboard lease with no paste
    /// pending, so none can start meanwhile; nil, without running it, when a
    /// paste holds the lease or one is pending.
    func withoutPaste<T>(_ body: () throws -> T) throws -> T?
}

/// Changes to a `HostFlag` made by one process at a time: an exclusive
/// `flock` on a file beside it, so reading it and changing it is one step
/// against every process that changes it this way. A reader that acts on
/// what it read (input sent only while the flag is down) holds it shared:
/// readers run side by side, never while a change is being made.
struct HostFlagLock {
    let url: URL
    let wait: TimeInterval

    init(for flag: HostFlag, wait: TimeInterval) {
        // Not the flag's own ".lock": HostFlag takes that one for each read
        // and change, which this lock's holder makes, and a second flock on
        // the same file from the same process waits for ever.
        url = flag.url.deletingLastPathComponent().appendingPathComponent(flag.url.lastPathComponent + ".gate.lock")
        self.wait = wait
    }

    /// Why `body` did not run.
    enum Failure: LocalizedError, Equatable {
        /// Another process held the lock all of `wait`.
        case busy(path: String)
        /// The caller gave up waiting (stopped, out of time) first.
        case gaveUp

        var errorDescription: String? {
            switch self {
            case .busy(let path): return "another process holds \(path)"
            case .gaveUp: return "gave up waiting for the lock"
            }
        }
    }

    /// Run `body` holding the lock, exclusive or `shared`; throws, without
    /// running it, when the lock cannot be had within `wait` (`.busy`), or
    /// as soon as `giveUp` says so while waiting (`.gaveUp`).
    func locked<T>(shared: Bool = false, giveUp: () -> Bool = { false }, _ body: () throws -> T) throws -> T {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let fd = open(url.path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        let end = Date().addingTimeInterval(wait)
        while flock(fd, (shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else { throw Failure.busy(path: url.path) }
            // Before the wait's own end: a caller stopped by then was
            // stopped, the lock was not merely busy.
            if giveUp() { throw Failure.gaveUp }
            guard Date() < end else { throw Failure.busy(path: url.path) }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}

// MARK: Observation

/// What a screenshot showed and where: input made from it is interpreted
/// in this window at this geometry, and refused once either has changed.
public struct IPhoneObservation: Equatable {
    public var pid: pid_t
    public var windowID: CGWindowID
    /// The window's frame at capture, in global points.
    public var frame: CGRect
    /// The pixels of the image handed out.
    public var pixelSize: CGSize
    public var geometryVersion: String
    public var capturedAt: Date

    public init(pid: pid_t, windowID: CGWindowID, frame: CGRect, pixelSize: CGSize, capturedAt: Date) {
        self.pid = pid
        self.windowID = windowID
        self.frame = frame
        self.pixelSize = pixelSize
        self.capturedAt = capturedAt
        geometryVersion = Self.geometryVersion(windowID: windowID, frame: frame, pixelSize: pixelSize)
    }

    /// A short hash of the window and its geometry: the same window at the
    /// same frame and image size gives the same version.
    public static func geometryVersion(windowID: CGWindowID, frame: CGRect, pixelSize: CGSize) -> String {
        func half(_ value: CGFloat) -> Int { Int((value * 2).rounded()) }
        let key = [Int(windowID), half(frame.minX), half(frame.minY), half(frame.width), half(frame.height),
                   Int(pixelSize.width.rounded()), Int(pixelSize.height.rounded())]
            .map(String.init).joined(separator: "|")
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325  // FNV-1a
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return String(format: "g%016llx", hash)
    }

    /// Frames equal to within half a point.
    public static func sameFrame(_ a: CGRect, _ b: CGRect) -> Bool {
        abs(a.minX - b.minX) <= 0.5 && abs(a.minY - b.minY) <= 0.5
            && abs(a.width - b.width) <= 0.5 && abs(a.height - b.height) <= 0.5
    }

    /// Overlap of more than a sliver: shadows and 1 pt borders do not count.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        let w = min(a.maxX, b.maxX) - max(a.minX, b.minX)
        let h = min(a.maxY, b.maxY) - max(a.minY, b.minY)
        return w > 1 && h > 1
    }
}

/// Why the adapter refused or could not finish. The description starts
/// with the code (and reason), so a caller that only sees text can branch
/// on it: `stale_observation (moved): …`.
public struct IPhoneError: LocalizedError, Equatable {
    public var code: String
    public var reason: String?
    public var message: String
    /// True when nothing reached the phone.
    public var notSent: Bool

    public init(_ code: String, reason: String? = nil, _ message: String, notSent: Bool = true) {
        self.code = code
        self.reason = reason
        self.message = message
        self.notSent = notSent
    }

    public var errorDescription: String? {
        code + (reason.map { " (\($0))" } ?? "") + ": " + message
    }

    static func stale(_ reason: String, _ message: String) -> IPhoneError {
        IPhoneError("stale_observation", reason: reason, message + "; take a new screenshot")
    }
}

// MARK: Connection state

/// What iPhone Mirroring shows, read from its window, never changed by
/// reading it.
public enum IPhoneConnectionState: String, CaseIterable {
    /// The phone's screen.
    case ready
    /// The phone is unlocked or its camera or microphone is in use; lock it.
    case phoneInUse
    /// Paused, interrupted, not found or failed; `iphone reconnect` may help.
    case disconnected
    /// The phone or this Mac must be unlocked, or Touch ID / the password given.
    case authRequired
    /// Connecting now; wait.
    case reconnecting
    /// Something only the user can fix: Bluetooth or Wi-Fi off, iCloud,
    /// setup, restrictions.
    case needsUser
    /// Not known: Mirroring's own texts could not be read through
    /// accessibility, or the picture shows a status phrase that nothing of
    /// Mirroring's own confirms (it may be a status page, or a phone app
    /// showing the same words). Treated as not ready: nothing is handed out
    /// or sent until a look shows the phone for certain.
    case uncertain

    /// The hint for this state as `label` shows it: the "iPhone in Use"
    /// page a lock ends names `iphone reconnect --phone-locked`; a camera or
    /// microphone in use, which a lock does not end, does not (#189).
    public func hint(shown label: String?) -> String {
        guard self == .phoneInUse else { return hint }
        if IPhoneConnection.endsOnLock(label) {
            return "the phone is in use; lock it and leave it near the Mac, then click Connect in the iPhone Mirroring "
                + "window or run `agentdesktop iphone reconnect --phone-locked`"
        }
        if let label, label.localizedCaseInsensitiveContains("camera") || label.contains("相机") {
            return "the phone's camera is in use; stop using it, then click Connect in the iPhone Mirroring window"
        }
        if let label, label.localizedCaseInsensitiveContains("microphone") || label.contains("麦克风") {
            return "the phone's microphone is in use; stop using it, then click Connect in the iPhone Mirroring window"
        }
        return hint
    }

    public var hint: String {
        switch self {
        case .ready: return "the phone's screen is showing"
        case .phoneInUse:
            return "the phone is in use; lock it, or stop using its camera or microphone, then click Connect in the "
                + "iPhone Mirroring window"
        case .disconnected: return "iPhone Mirroring is disconnected; run `agentdesktop iphone reconnect`"
        case .authRequired: return "unlock the iPhone or authenticate on the Mac (Touch ID or password)"
        case .reconnecting: return "iPhone Mirroring is connecting; wait and look again"
        case .needsUser: return "iPhone Mirroring needs the user (Bluetooth, Wi-Fi, iCloud or setup)"
        case .uncertain:
            return "cannot tell whether iPhone Mirroring shows the phone (its own texts could not be read, or the "
                + "picture shows a status phrase nothing confirms); look again, check Accessibility permission, "
                + "or look at the window"
        }
    }
}

public enum IPhoneConnection {
    /// The "iPhone in Use" page that locking the phone ends (once Connect is
    /// pressed), as against a camera or microphone in use, which a lock does
    /// not end.
    static let endsOnLockLabels: Set<String> = ["iPhone in Use", "iPhone使用中", "has ended due to iPhone use",
                                                "因iPhone被使用", "is no longer in use", "不再处于使用状态时连接"]

    static func endsOnLock(_ label: String?) -> Bool {
        guard let label else { return false }
        return endsOnLockLabels.contains(label)
    }

    /// Status pages of iPhone Mirroring, English and Simplified Chinese, as
    /// its ScreenContinuityUI strings give them. The first rule a text
    /// contains wins, so the specific ones come first ("正在解锁iPhone"
    /// contains "解锁iPhone").
    static let rules: [(String, IPhoneConnectionState)] = [
        // Phone in use. Camera and microphone first: their pages are not
        // ended by a lock, and must not be read as the plain "iPhone in Use"
        // when that phrase is also on them (#189 review).
        ("iPhone Camera in Use", .phoneInUse), ("iPhone相机使用中", .phoneInUse),
        ("iPhone Microphone in Use", .phoneInUse), ("iPhone麦克风使用中", .phoneInUse),
        ("iPhone in Use", .phoneInUse), ("iPhone使用中", .phoneInUse),
        ("has ended due to iPhone use", .phoneInUse), ("因iPhone被使用", .phoneInUse),
        ("is no longer in use", .phoneInUse), ("不再处于使用状态时连接", .phoneInUse),
        // Connecting.
        ("Unlocking", .reconnecting), ("正在解锁", .reconnecting),
        ("Connecting to", .reconnecting), ("正在连接", .reconnecting),
        ("Handshake in progress", .reconnecting), ("握手进行中", .reconnecting),
        // Unlock or authenticate.
        ("Unlock Your iPhone", .authRequired), ("Unlock iPhone", .authRequired), ("解锁iPhone", .authRequired),
        ("Waiting for unlock signal", .authRequired), ("解锁信号", .authRequired),
        ("iPhone Mirroring Is Locked", .authRequired), ("iPhone镜像已锁定", .authRequired),
        ("Mac Locked", .authRequired), ("Mac已锁定", .authRequired),
        ("password or Touch ID is required", .authRequired), ("需要macOS用户密码或触控ID", .authRequired),
        // Only the user can fix.
        ("Bluetooth Off", .needsUser), ("蓝牙已关闭", .needsUser),
        ("Wi-Fi Off", .needsUser), ("Wi-Fi已关闭", .needsUser),
        ("WLAN Off", .needsUser), ("无线局域网已关闭", .needsUser),
        ("iCloud Signed Out", .needsUser), ("iCloud已退出登录", .needsUser),
        ("No Mac Password", .needsUser), ("无Mac密码", .needsUser),
        ("iPhone Not Enabled", .needsUser), ("iPhone未启用", .needsUser),
        ("iPhone Changed", .needsUser), ("iPhone已更改", .needsUser),
        ("Welcome to iPhone Mirroring", .needsUser), ("欢迎使用iPhone镜像", .needsUser),
        ("iPhone Mirroring Restricted", .needsUser), ("iPhone镜像受限", .needsUser),
        ("iPhone Mirroring Not Supported", .needsUser), ("iPhone镜像不受支持", .needsUser),
        // Disconnected.
        ("Connection Paused", .disconnected), ("连接暂停", .disconnected),
        ("Connection Interrupted", .disconnected), ("连接中断", .disconnected),
        ("iPhone Not Found", .disconnected), ("未找到iPhone", .disconnected),
        ("Unable to Connect", .disconnected), ("无法连接iPhone", .disconnected),
        ("Timed out starting iPhone Mirroring", .disconnected), ("开始iPhone镜像超时", .disconnected),
        ("Timed Out", .disconnected), ("已超时", .disconnected),
    ]

    /// Buttons that ask Mirroring to connect again, as `iphone reconnect`
    /// presses them. "继续" is Resume (and also Continue); it is pressed only
    /// on a disconnected page.
    public static let reconnectButtons: Set<String> = ["Connect", "Try Again", "Resume", "连接", "重试", "继续"]

    /// Controls that only iPhone Mirroring's own status pages carry. Seen
    /// through accessibility in the phone's window, they show the window is
    /// a status page and not the phone: the phone's picture carries no
    /// accessibility elements at all.
    static let statusControls: Set<String> = reconnectButtons.union(["Cancel", "取消", "OK", "好"])

    /// The state the texts show, and the status text that says so; ready
    /// only when nothing suggests a status page. OCR spacing, case and
    /// hyphen variants do not matter.
    ///
    /// `texts` are accessibility texts of the phone's window: Mirroring's
    /// own, never the phone's (the phone's picture has no accessibility
    /// elements), so a status phrase in them counts wherever it appears.
    /// nil means they could not be read: then nothing is known and the
    /// state is `uncertain`, never ready.
    ///
    /// `ocr` texts come from the picture, which may be a status page or the
    /// phone's own screen. A status phrase anywhere in them counts as that
    /// state when one of the status page's own controls (`statusControls`)
    /// is among the accessibility texts. Without such a control it may be a
    /// phone app showing "Connecting to Wi-Fi", "Timed Out" or "Unlock
    /// iPhone", or a status page whose texts were not exposed: `uncertain`,
    /// so the window is refused rather than guessed ready.
    public static func classify(_ texts: [String]?, ocr: [String] = []) -> (state: IPhoneConnectionState, label: String?) {
        guard let texts else { return (.uncertain, nil) }
        let own = texts.map(normalize)
        let controls = Set(statusControls.map(normalize))
        let corroborated = own.contains(where: controls.contains)
        let seen = ocr.map(normalize)
        for (label, state) in rules {
            let key = normalize(label)
            if own.contains(where: { $0.contains(key) }) { return (state, label) }
        }
        for (label, state) in rules {
            let key = normalize(label)
            if seen.contains(where: { $0.contains(key) }) { return (corroborated ? state : .uncertain, label) }
        }
        // A status page's own control with no phrase read (its title drawn,
        // not exposed): still a status page, not the phone, whose picture
        // carries no accessibility elements at all. Its Try Again or Resume
        // must not take a tap meant for the phone.
        if corroborated, let control = texts.first(where: { controls.contains(normalize($0)) }) {
            return (.uncertain, control)
        }
        return (.ready, nil)
    }

    static func normalize(_ text: String) -> String {
        var out = ""
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) || scalar == "\u{00A0}" { continue }
            switch scalar {
            case "\u{2010}", "\u{2011}", "\u{2012}", "\u{2013}", "\u{2014}": out.append("-")
            case "\u{2019}": out.append("'")
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

// MARK: Connection lifecycle

/// Where a connection attempt stands, as `iphone reconnect` sees it:
/// disconnected → connecting → connected → verifying → ready. Only `ready`
/// lets reconnect report success and input continue after a press.
public enum IPhoneConnectionPhase: String {
    /// A status page that needs a press or the user, or nothing yet seen.
    case disconnected
    /// A button was pressed or Mirroring says it is connecting; the phone
    /// has not been seen since.
    case connecting
    /// The phone was seen once in this generation; nothing more is known
    /// (2026-10-09 F8: "ready" a moment after Resume, then "iPhone
    /// Mirroring Is Locked").
    case connected
    /// The phone has been seen more than once, spaced apart, with nothing
    /// else in between; not yet for long enough.
    case verifying
    /// The phone was seen `stableReadings` times in a row, at least
    /// `spacing` apart, in the same window, all in this generation.
    case ready
}

/// One look at the phone's window, stamped with the connection generation
/// current when the look began.
public struct IPhoneConnectionObservation: Equatable {
    public var generation: Int
    public var state: IPhoneConnectionState
    public var label: String?
    /// The window looked at; nil when the look failed.
    public var windowID: CGWindowID?
    /// When the look began.
    public var at: Date

    public init(generation: Int, state: IPhoneConnectionState, label: String? = nil,
                windowID: CGWindowID?, at: Date) {
        self.generation = generation
        self.state = state
        self.label = label
        self.windowID = windowID
        self.at = at
    }
}

/// Decides when a connection is ready from looks at the window, and only
/// from looks of the current generation. Every Connect / Resume / Try Again
/// press starts a new generation: a look that began before it, or that
/// belongs to an earlier one (a slow read, an earlier reconnect), is
/// dropped and changes nothing. Ready needs `stableReadings` ready looks in
/// a row, each at least `spacing` after the last counted one, of the same
/// window; any look that is not ready starts the count again.
public struct IPhoneConnectionTracker {
    public static let defaultStableReadings = 4
    public static let defaultSpacing: TimeInterval = 1

    public let stableReadings: Int
    public let spacing: TimeInterval

    public private(set) var generation = 0
    public private(set) var phase: IPhoneConnectionPhase = .disconnected
    /// When the current generation began; earlier looks do not count.
    public private(set) var since: Date = .distantPast
    /// True from a press until a reconnect reports ready (`confirm()`):
    /// input to the phone is refused meanwhile. Neither a later check
    /// without a press nor steady ready looks alone clear it: a reconnect
    /// that saw the phone but was held back (an input barrier, its timeout)
    /// leaves it up.
    public private(set) var awaitingConfirmation = false
    /// The last look counted in this generation.
    public private(set) var latest: IPhoneConnectionObservation?
    /// Ready looks counted in a row, and the window they were of.
    public private(set) var readyStreak = 0
    private var streakWindow: CGWindowID?
    private var lastReadyAt: Date?

    public init(stableReadings: Int = defaultStableReadings, spacing: TimeInterval = defaultSpacing) {
        self.stableReadings = max(1, stableReadings)
        self.spacing = spacing
    }

    /// Start a new generation at `now`, after a press (`pressed`) or for a
    /// fresh check; what was seen before counts no more.
    @discardableResult
    public mutating func begin(at now: Date, pressed: Bool) -> Int {
        generation += 1
        since = now
        if pressed { awaitingConfirmation = true }
        phase = pressed ? .connecting : .disconnected
        latest = nil
        resetStreak()
        return generation
    }

    /// Count `look` if it is of this generation; false when dropped.
    @discardableResult
    public mutating func record(_ look: IPhoneConnectionObservation) -> Bool {
        guard look.generation == generation, look.at >= since else { return false }
        if let latest, look.at < latest.at { return false }
        latest = look
        switch look.state {
        case .ready:
            guard let window = look.windowID else {
                resetStreak()
                phase = .connecting
                return true
            }
            if streakWindow != window {
                // Another window is another session: start over with it.
                resetStreak()
                streakWindow = window
            }
            if let last = lastReadyAt, look.at.timeIntervalSince(last) < spacing - 0.001 {
                // Too soon after the last counted look to say anything new.
                return true
            }
            readyStreak += 1
            lastReadyAt = look.at
            phase = readyStreak >= stableReadings ? .ready : (readyStreak == 1 ? .connected : .verifying)
        case .reconnecting, .uncertain:
            resetStreak()
            phase = .connecting
        case .disconnected, .phoneInUse, .authRequired, .needsUser:
            resetStreak()
            phase = .disconnected
        }
        return true
    }

    /// Whether the ready looks were of `windowID`.
    public func isReady(window windowID: CGWindowID?) -> Bool {
        phase == .ready && windowID != nil && streakWindow == windowID && latest?.state == .ready
    }

    /// Every condition for ready held and it was reported: input may go
    /// on. Only while the phase is ready.
    public mutating func confirm() {
        if phase == .ready { awaitingConfirmation = false }
    }

    private mutating func resetStreak() {
        readyStreak = 0
        streakWindow = nil
        lastReadyAt = nil
    }
}

// MARK: Images and files

public enum IPhoneFrames {
    /// A scratch path no other request uses, even in the same process.
    public static func scratchPath(_ tag: String = "capture") -> String {
        (NSTemporaryDirectory() as NSString)
            .appendingPathComponent("agentdesktop-iphone-\(tag)-\(UUID().uuidString).png")
    }

    /// Whether the image is one flat colour: a failed capture, the gray
    /// canvas of a screen composite or an undrawn window, never a phone.
    public static func isBlank(_ image: CGImage) -> Bool {
        let side = 32
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                          bytesPerRow: side * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard drawn else { return true }
        for channel in 0..<4 {
            var low = 255, high = 0
            for i in stride(from: channel, to: pixels.count, by: 4) {
                low = min(low, Int(pixels[i]))
                high = max(high, Int(pixels[i]))
            }
            if high - low > 3 { return false }
        }
        return true
    }
}

// MARK: Lifecycle

/// `iphone show` and `iphone hide`, kept apart from the CLI so their
/// outcomes can be tested.
public struct IPhoneLifecycle {
    public enum HideOutcome: String {
        /// Nothing to quit.
        case notRunning = "not_running"
        /// Asked to quit; not waited for.
        case exitRequested = "exit_requested"
        /// Gone: confirmed.
        case exited
        /// Asked, still running at the deadline.
        case timedOut = "timed_out"
        /// The quit request could not be delivered.
        case refused

        public var ok: Bool { self == .notRunning || self == .exitRequested || self == .exited }
    }

    public struct ShowOutcome {
        public var ok: Bool
        public var screenCreated: Bool
        /// "launched" or "moved".
        public var mirroring: String
        public var pid: pid_t?
        public var error: String?
    }

    public let system: IPhoneMirroringSystem
    public let bundleID: String

    public init(system: IPhoneMirroringSystem, bundleID: String = IPhoneAgentScreen.bundleID) {
        self.system = system
        self.bundleID = bundleID
    }

    /// Quit iPhone Mirroring and, unless `wait` is false, wait until it is
    /// gone or `timeout` passes.
    public func hide(wait: Bool = true, timeout: TimeInterval = 10) -> (outcome: HideOutcome, pids: [pid_t]) {
        let pids = system.mirroringPIDs()
        guard !pids.isEmpty else { return (.notRunning, []) }
        let asked = pids.map { system.terminate(pid: $0) }
        guard asked.contains(true) else { return (.refused, pids) }
        guard wait else { return (.exitRequested, pids) }
        let deadline = system.now.addingTimeInterval(timeout)
        while true {
            let left = pids.filter { system.isRunning(pid: $0) }
            if left.isEmpty { return (.exited, pids) }
            if system.now >= deadline { return (.timedOut, left) }
            system.sleep(0.2)
        }
    }

    /// Make the agent screen if there is none of that name, then put
    /// iPhone Mirroring on it. Repeating it makes no second screen: a create
    /// that fails because another `show` made the screen meanwhile counts as
    /// the screen being there.
    public func show(screen name: String, width: Int = 525, height: Int = 1001) throws -> ShowOutcome {
        var created = false
        if try system.screenFrame(named: name) == nil {
            var create = ControlRequest(command: .screenCreate)
            create.screen = name
            create.width = width
            create.height = height
            create.hiDPI = true
            create.idleTimeout = 0
            let response = try system.deliver(create)
            if response.ok {
                created = true
            } else if try system.screenFrame(named: name) == nil {
                return ShowOutcome(ok: false, screenCreated: false, mirroring: "none", pid: nil,
                                   error: response.error ?? "screen create failed")
            }
        }
        var place: ControlRequest
        let pid = system.mirroringPIDs().first
        if let pid {
            place = ControlRequest(command: .windowMove)
            place.pid = pid
        } else {
            place = ControlRequest(command: .appLaunch)
            place.bundleID = bundleID
        }
        place.screen = name
        place.fitScreen = true
        let response = try system.deliver(place)
        return ShowOutcome(ok: response.ok, screenCreated: created, mirroring: pid == nil ? "launched" : "moved",
                           pid: pid ?? response.pid, error: response.error)
    }
}

// MARK: Live system

/// The real thing: the app over its control socket, the window server,
/// accessibility and Vision.
public struct LiveIPhoneMirroringSystem: IPhoneMirroringSystem {
    public let bundleID: String
    /// The clipboard lease and pending mark every paste uses
    /// (`PasteTransaction`'s defaults); settable for tests.
    public var leaseURL: URL = ClipboardLease.defaultURL
    public var pendingMark: HostFlag = .named("clipboard.pending")

    /// One phone per Mac (iPhone Mirroring mirrors one at a time), so one
    /// barrier.
    /// Lowered only by a screenshot: an unreadable record stays up.
    public var inputBarrier: HostFlag { .named("iphone-input-barrier", unreadableExpires: false) }
    /// Lowered only by a reconnect that confirms the phone: an unreadable
    /// record stays up, as for the barrier.
    public var reconnectGate: HostFlag { .named("iphone-reconnect-unconfirmed", unreadableExpires: false) }

    public var pasteInProgress: Bool {
        if pendingMark.reason() != nil { return true }
        guard let lease = try? ClipboardLease.acquire(at: leaseURL, timeout: 0) else { return true }
        lease.release()
        return false
    }

    public func withoutPaste<T>(_ body: () throws -> T) throws -> T? {
        guard let lease = try? ClipboardLease.acquire(at: leaseURL, timeout: 0) else { return nil }
        defer { lease.release() }
        guard pendingMark.reason() == nil else { return nil }
        return try body()
    }

    public func whileNoPaste(_ body: () -> Void) -> Bool {
        guard let lease = try? ClipboardLease.acquire(at: leaseURL, timeout: 0) else { return false }
        defer { lease.release() }
        // Under the lease no paste can start; one that left a pending mark
        // is still under way.
        guard pendingMark.reason() == nil else { return false }
        body()
        return true
    }

    public init(bundleID: String = IPhoneAgentScreen.bundleID) {
        self.bundleID = bundleID
    }

    public func mirroringPIDs() -> [pid_t] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated }.map(\.processIdentifier)
    }

    public func screenFrame(named name: String) throws -> CGRect? {
        var request = ControlRequest(command: .screenList)
        request.screen = name
        let response = try sendControlRequest(request)
        guard response.ok else { throw IPhoneError("screen_list_failed", response.error ?? "screen list failed") }
        return response.screens?.first(where: { $0.name == name }).map { CGRect($0.frame) }
    }

    public func windows(pid: pid_t) -> [IPhoneWindow] {
        let titles = Self.accessibilityTitles(of: pid)
        return WindowMover.windows(ofPID: pid).map {
            IPhoneWindow(pid: $0.pid, windowID: $0.windowID, frame: $0.frame,
                         title: titles[$0.windowID] ?? ($0.title.isEmpty ? nil : $0.title))
        }
    }

    /// The titles of the process's windows through accessibility, by window.
    private static func accessibilityTitles(of pid: pid_t) -> [CGWindowID: String] {
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(AXUIElementCreateApplication(pid), kAXWindowsAttribute as CFString,
                                            &windows) == .success,
              let list = windows as? [AXUIElement] else { return [:] }
        var titles: [CGWindowID: String] = [:]
        for window in list {
            var title: AnyObject?
            guard let id = WindowMover.windowID(of: window),
                  AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title) == .success,
                  let text = title as? String, !text.isEmpty else { continue }
            titles[id] = text
        }
        return titles
    }

    public func captureWindow(screen: String, pid: pid_t, windowID: CGWindowID) throws -> IPhoneWindowCapture {
        let path = IPhoneFrames.scratchPath()
        defer { try? FileManager.default.removeItem(atPath: path) }
        var request = ControlRequest(command: .screenshot)
        request.screen = screen
        request.output = path
        request.windowsOnly = true
        request.pid = pid
        request.windowID = windowID
        let response = try sendControlRequest(request)
        guard response.ok else {
            throw IPhoneError("capture_failed", response.error ?? "the window screenshot failed")
        }
        // An app that predates single-window capture ignores the window and
        // returns the screen composite, which may show other windows.
        guard let window = response.window, window.windowID == windowID else {
            throw IPhoneError("capture_failed", reason: "app_too_old",
                              "Agent Desktop did not capture window \(windowID) alone; update Agent Desktop")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw IPhoneError("capture_failed", reason: "no_image", "the app reported a screenshot but wrote none")
        }
        return IPhoneWindowCapture(image: try Images.load(path), windowID: windowID, frame: CGRect(window.frame))
    }

    public func deliver(_ request: ControlRequest) throws -> ControlResponse {
        try sendControlRequest(request)
    }

    public func recognizedText(in image: CGImage) -> [String] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.usesLanguageCorrection = false
        // Status pages put their title and message in the middle.
        request.regionOfInterest = CGRect(x: 0, y: 0.2, width: 1, height: 0.6)
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    }

    public func accessibilityLabels(pid: pid_t, windowID: CGWindowID?) -> [String]? {
        Self.elements(of: pid, windowID: windowID)?.flatMap(\.labels)
    }

    public func pressButton(titled titles: Set<String>, pid: pid_t, windowID: CGWindowID?) -> String? {
        for element in Self.elements(of: pid, windowID: windowID) ?? [] where element.button {
            if let title = element.labels.first(where: titles.contains) {
                AXUIElementPerformAction(element.element, kAXPressAction as CFString)
                return title
            }
        }
        return nil
    }

    public func terminate(pid: pid_t) -> Bool {
        NSRunningApplication(processIdentifier: pid)?.terminate() ?? false
    }

    public func isRunning(pid: pid_t) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return false }
        return !app.isTerminated
    }

    public var now: Date { Date() }

    public func sleep(_ seconds: TimeInterval) {
        Thread.sleep(forTimeInterval: seconds)
    }

    private struct Element {
        let element: AXUIElement
        let button: Bool
        let labels: [String]
    }

    /// Texts and buttons of the process's windows. SwiftUI carries a
    /// button's text as its title or description, a text's as its value.
    /// nil when they could not be read: no Accessibility permission, the
    /// windows, a child list or an element's role, title, description or
    /// value could not be read, no window `windowID`, or more elements than
    /// are read. An attribute or child list the element does not have
    /// (`noValue`, `attributeUnsupported`) is not a failure.
    private static func elements(of pid: pid_t, windowID: CGWindowID?) -> [Element]? {
        guard AXIsProcessTrusted() else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windows: AnyObject?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              var list = windows as? [AXUIElement] else { return nil }
        if let windowID {
            list = list.filter { WindowMover.windowID(of: $0) == windowID }
            guard !list.isEmpty else { return nil }
        }
        var found: [Element] = []
        var failed = false
        func visit(_ element: AXUIElement, depth: Int) {
            guard !failed else { return }
            guard depth < 10, found.count < 200 else { failed = true; return }
            var children: AnyObject?
            switch AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &children) {
            case .success: break
            case .noValue, .attributeUnsupported: return
            default: failed = true; return
            }
            guard let list = children as? [AXUIElement] else { return }
            /// The attribute, nil when the element has none; a read that
            /// failed otherwise fails the whole read.
            func read(_ child: AXUIElement, _ attribute: String) -> AnyObject? {
                var value: AnyObject?
                switch AXUIElementCopyAttributeValue(child, attribute as CFString, &value) {
                case .success: return value
                case .noValue, .attributeUnsupported: return nil
                default: failed = true; return nil
                }
            }
            for child in list {
                let role = read(child, kAXRoleAttribute)
                let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute]
                    .compactMap { attribute -> String? in
                        (read(child, attribute) as? String).flatMap { $0.isEmpty ? nil : $0 }
                    }
                guard !failed else { return }
                let button = (role as? String) == kAXButtonRole
                if button || !labels.isEmpty { found.append(Element(element: child, button: button, labels: labels)) }
                if !button { visit(child, depth: depth + 1) }
            }
        }
        list.forEach { visit($0, depth: 0) }
        return failed ? nil : found
    }
}
