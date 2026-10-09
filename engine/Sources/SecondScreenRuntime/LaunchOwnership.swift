import AppKit
import Darwin
import Foundation
import Security
import SecondScreenCore

/// Who an app on disk is: its code signature and version, read before it is
/// opened. A verification holds only for the exact identity it was made on.
public struct AppIdentity: Equatable, Sendable {
    public var bundleId: String
    /// The signing team (nil for Apple's own apps and unsigned code).
    public var teamId: String?
    /// The code signature's identifier.
    public var signingIdentifier: String
    /// CFBundleShortVersionString and CFBundleVersion.
    public var version: String
    public var build: String
    /// The code's designated requirement, as text: who signed it (for Apple's
    /// own apps "anchor apple"; for a team, its certificate chain). A copy
    /// re-signed by anyone else, even with every other field the same, has
    /// another requirement and does not match.
    public var designatedRequirement: String
    public init(bundleId: String, teamId: String?, signingIdentifier: String, version: String, build: String,
                designatedRequirement: String = "") {
        self.bundleId = bundleId
        self.teamId = teamId
        self.signingIdentifier = signingIdentifier
        self.version = version
        self.build = build
        self.designatedRequirement = designatedRequirement
    }

    /// Read from the bundle, with its signature checked. nil: unsigned, the
    /// signature does not verify, or the bundle cannot be read.
    public static func read(_ url: URL) -> AppIdentity? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { return nil }
        var code: SecStaticCode?
        // Strict, nested code included, for the architecture that will run.
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
              SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
        else { return nil }
        var requirement: SecRequirement?
        var requirementText: CFString?
        guard SecCodeCopyDesignatedRequirement(code, [], &requirement) == errSecSuccess, let requirement,
              SecRequirementCopyString(requirement, [], &requirementText) == errSecSuccess,
              let designated = requirementText as String?,
              // Ad-hoc code has no signer to pin: its requirement is only a hash.
              !designated.hasPrefix("cdhash")
        else { return nil }
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let dict = info as? [String: Any], let identifier = dict[kSecCodeInfoIdentifier as String] as? String
        else { return nil }
        return AppIdentity(bundleId: id, teamId: dict[kSecCodeInfoTeamIdentifier as String] as? String,
                           signingIdentifier: identifier,
                           version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
                           build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "",
                           designatedRequirement: designated)
    }
}

/// One app verified on a real machine to prove a launch: the identity it
/// was verified on and how. An update, a new signature or another team
/// voids it, and the app is refused until it is verified again.
public struct VerifiedApp: Equatable, Sendable {
    public var identity: AppIdentity
    /// The proof the verification established ("launch_token_env": the
    /// one-time token read back from the environment the kernel recorded).
    public var technique: String
    public var verifiedOn: String
    public init(identity: AppIdentity, technique: String, verifiedOn: String) {
        self.identity = identity
        self.technique = technique
        self.verifiedOn = verifiedOn
    }
}

/// A process an open returned: its pid, and the system's handle to it
/// (nil in tests). Quitting uses the handle, never a pid looked up again.
public struct LaunchedProcess: @unchecked Sendable, Equatable {
    public let pid: pid_t
    public let app: NSRunningApplication?
    public init(pid: pid_t, app: NSRunningApplication? = nil) {
        self.pid = pid
        self.app = app
    }
    public static func == (a: LaunchedProcess, b: LaunchedProcess) -> Bool { a.pid == b.pid && a.app === b.app }
}

/// What a launch needs from the system, so the ownership rules can be
/// tested without starting, moving or binding real apps.
public struct AppLaunching: Sendable {
    /// Every process running now.
    public var runningPIDs: @Sendable () -> Set<pid_t>
    /// The processes of the app with this bundle ID running now.
    public var processes: @Sendable (String) -> Set<pid_t>
    /// The app's bundle ID and whether it allows one instance only.
    public var bundleInfo: @Sendable (URL) -> (id: String?, singleInstance: Bool)
    /// The frontmost app now.
    public var frontmost: @Sendable () -> pid_t?
    /// Open the app as a new instance without activating it, with
    /// `environment` added to the new process's environment.
    public var open: @Sendable (URL, [String: String]) async -> Result<LaunchedProcess, Error>
    /// The environment the kernel holds for a process (nil: unreadable).
    public var environment: @Sendable (pid_t) -> [String: String]?
    /// The bundle a running process was started from.
    public var bundleURL: @Sendable (pid_t) -> URL?
    /// Give the foreground back to `previous` for a few seconds whenever the
    /// process the open returned takes it.
    public var returnFocus: @Sendable (_ previous: pid_t, _ opened: LaunchedProcess) -> Void
    /// Quit a process this launch created (normal quit, forced after a
    /// second), through the handle the open returned. Only called once the
    /// launch token proved the process ours.
    public var quit: @Sendable (LaunchedProcess) async -> Void
    /// The app's signed identity on disk, read before it is opened.
    public var identity: @Sendable (URL) -> AppIdentity? = { AppIdentity.read($0) }
    /// The verifications in force. Only an app whose identity matches one
    /// exactly (bundle, team, signing identifier, version, build) is opened.
    public var verified: @Sendable () -> [VerifiedApp] = { LaunchOwnership.verifiedApps }
    /// Whether windows may be placed (the Accessibility permission).
    public var canPlaceWindows: @Sendable () -> Bool
    /// The process's first window, waiting up to the timeout.
    public var firstWindow: @Sendable (pid_t, TimeInterval) async -> WindowInfo?
    /// Move a window to a display; whether it moved.
    public var move: @Sendable (WindowInfo, CGDirectDisplayID, Bool) -> Bool
    /// Told when the launch binds the process to the agent screen.
    public var bound: @Sendable (pid_t) -> Void = { _ in }

    public static let system = AppLaunching(
        runningPIDs: { Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)) },
        processes: { Set(NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)) },
        bundleInfo: { url in
            let bundle = Bundle(url: url)
            let single = (bundle?.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool) ?? false
            return (bundle?.bundleIdentifier, single)
        },
        frontmost: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
        open: { url, environment in
            await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: url, configuration: LaunchOwnership.configuration(environment)) { app, error in
                    if let app {
                        continuation.resume(returning: .success(LaunchedProcess(pid: app.processIdentifier, app: app)))
                    } else {
                        continuation.resume(returning: .failure(error ?? CocoaError(.executableLoad)))
                    }
                }
            }
        },
        environment: { LaunchOwnership.kernelEnvironment(of: $0) },
        bundleURL: { NSRunningApplication(processIdentifier: $0)?.bundleURL },
        returnFocus: { previous, opened in
            DispatchQueue.main.async {
                guard let back = NSRunningApplication(processIdentifier: previous) else { return }
                let center = NSWorkspace.shared.notificationCenter
                let token = center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    if app?.processIdentifier == opened.pid { back.activate() }
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { center.removeObserver(token) }
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == opened.pid { back.activate() }
            }
        },
        quit: { opened in
            guard let app = opened.app, !app.isTerminated else { return }
            app.terminate()
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if !app.isTerminated { app.forceTerminate() }
        },
        canPlaceWindows: { WindowMover.isTrusted },
        firstWindow: { pid, timeout in
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if let window = WindowMover.windows(ofPID: pid).first { return window }
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            return nil
        },
        move: { window, display, fill in WindowMover.move(window, to: display, fill: fill) })
}

/// A launch owns only a process it can prove it created. Everything here
/// runs before any window is moved or bound: a refusal has no side effect on
/// the user's apps beyond what the system did when the app was opened, and
/// then the foreground is handed back.
public enum LaunchOwnership {
    /// The environment variable carrying a launch's one-time token.
    public static let tokenVariable = "AGENTDESKTOP_LAUNCH_TOKEN"

    /// Apps verified on a real machine to carry the launch token into the
    /// environment the kernel records, when opened through LaunchServices.
    /// Empty until each is verified: Apple's own apps never qualify (macOS
    /// hides their environment), and some third-party apps (Google Chrome)
    /// rewrite theirs. An app not on the list is refused before it is
    /// opened, so no unowned window is ever left on the user's screen.
    public static let verifiedApps: [VerifiedApp] = []

    /// The verification that holds for this identity, if any.
    public static func verification(for identity: AppIdentity, in list: [VerifiedApp]) -> VerifiedApp? {
        list.first { $0.identity == identity && $0.technique == "launch_token_env" }
    }

    /// Always a new instance, never activated, not added to recent items,
    /// never prompting the user, carrying `environment`.
    public static func configuration(_ environment: [String: String] = [:]) -> NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.addsToRecentItems = false
        c.promptsUserIfNeeded = false
        c.createsNewApplicationInstance = true
        c.environment = environment
        return c
    }

    /// Open the app and return the process this launch created, or why it
    /// cannot be proved to be one.
    ///
    /// Refused before opening:
    /// - an app without a bundle ID, or one that allows a single instance
    ///   (LSMultipleInstancesProhibited);
    /// - an app that is already running, whatever `newInstance` says: apps
    ///   such as browsers and editors hand a new instance's request to the
    ///   user's running one, which then opens a window on the user's screen.
    ///   (`newInstance` is kept for the protocol; no app is on a list of
    ///   apps verified to isolate a second instance yet.)
    ///
    /// - an app whose signed identity (bundle, team, signing identifier,
    ///   version, build) matches no verification in `verifiedApps`: only
    ///   those are known to carry the token, so no other app, and no other
    ///   build of a verified app, is ever opened.
    ///
    /// Refused after opening (foreground handed back, nothing moved, bound
    /// or quit):
    /// - the process does not carry this launch's one-time token in its
    ///   environment (unreadable counts as not carrying it);
    /// - it ran before the launch, it is not the requested bundle, or another
    ///   instance of the app appeared at the same time.
    public static func openOwnedProcess(_ url: URL, newInstance: Bool, using system: AppLaunching,
                                        token: String = UUID().uuidString) async -> Result<LaunchedProcess, LaunchRefusal> {
        let info = system.bundleInfo(url)
        guard let id = info.id else {
            return .failure(LaunchRefusal("\(url.lastPathComponent) has no bundle ID; a new process cannot be told apart from a running one",
                                          reason: "launch_unprovable"))
        }
        guard !info.singleInstance else {
            return .failure(LaunchRefusal("\(id) allows one instance only; its windows are not moved automatically",
                                          reason: "launch_unprovable"))
        }
        // Checking a signature reads the whole app from disk: off the main
        // actor, so a large app never holds up the engine's main thread.
        let readIdentity = system.identity
        let identity = await Task.detached { readIdentity(url) }.value
        guard let identity, identity.bundleId == id else {
            return .failure(LaunchRefusal("\(id) has no valid code signature; it was not opened", reason: "launch_unprovable"))
        }
        let verifications = system.verified()
        guard verification(for: identity, in: verifications) != nil else {
            if verifications.isEmpty {
                return .failure(LaunchRefusal("no app is configured to be launched: none has been verified to prove a launch; \(id) was not opened",
                                              reason: "no_launch_apps_configured"))
            }
            let known = verifications.contains { $0.identity.bundleId == id }
            return .failure(LaunchRefusal(known
                ? "\(id) \(identity.version) (\(identity.build)) is not the build that was verified to prove a launch; verify it again before it can be opened"
                : "\(id) is not on the list of apps verified to prove a launch; it was not opened",
                reason: "launch_not_verified"))
        }
        guard system.processes(id).isEmpty else {
            return .failure(LaunchRefusal("\(id) is already running; an app the user has open is not launched again for an agent",
                                          reason: "app_already_running"))
        }
        let before = system.runningPIDs()
        let previous = system.frontmost()
        func refuseAfterOpening(_ opened: LaunchedProcess?, _ message: String) -> Result<LaunchedProcess, LaunchRefusal> {
            if let previous, let opened { system.returnFocus(previous, opened) }
            return .failure(LaunchRefusal(message + " (the app was opened; its process was left as it is)", opened: true,
                                          reason: "launch_refused_after_open"))
        }
        let opened: LaunchedProcess
        switch await system.open(url, [tokenVariable: token]) {
        case let .success(p): opened = p
        case let .failure(error): return refuseAfterOpening(nil, "launch failed: \(error.localizedDescription)")
        }
        let pid = opened.pid
        guard system.environment(pid)?[tokenVariable] == token else {
            return refuseAfterOpening(opened, "process \(pid) does not carry this launch's token; nothing was moved")
        }
        guard isNewProcess(pid, runningBefore: before) else {
            return refuseAfterOpening(opened, "the app handed back a process that was already running; nothing was moved")
        }
        guard let started = system.bundleURL(pid), sameBundle(started, url) else {
            return refuseAfterOpening(opened, "process \(pid) is not the requested app; nothing was moved")
        }
        // The user may start the same app while it opens: then which window
        // is whose is not certain, so nothing is moved.
        guard system.processes(id) == [pid] else {
            return refuseAfterOpening(opened, "another instance of \(id) started at the same time; nothing was moved")
        }
        return .success(opened)
    }

    /// Whether `pid` was not running before the launch.
    public static func isNewProcess(_ pid: pid_t, runningBefore: Set<pid_t>) -> Bool {
        pid > 0 && !runningBefore.contains(pid)
    }

    static func sameBundle(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// The environment of a process as KERN_PROCARGS2 returns it: the kernel
    /// copies it from the process's own memory, which the process may
    /// rewrite (Google Chrome shows none). What makes the proof hold is that
    /// the token is random and new for each launch: a process that ran
    /// before, or was started by anyone else, cannot know it.
    public static func kernelEnvironment(of pid: pid_t) -> [String: String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        return parseProcArgs(Array(buffer.prefix(size)))
    }

    /// Parse a KERN_PROCARGS2 buffer: argc, the executable path, padding,
    /// argc arguments, then the environment, each NUL-terminated. Anything
    /// that does not parse (short buffer, negative argc, fewer strings than
    /// argc) is nil, and nil is a refusal: the parser never guesses. An
    /// empty argv[0] is skipped as padding, which shifts the reading by one
    /// string and so also ends in a refusal, never in a false match.
    static func parseProcArgs(_ b: [UInt8]) -> [String: String]? {
        guard b.count >= 4 else { return nil }
        let argc = Int(b.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc >= 0 else { return nil }
        var i = 4
        func string() -> String? {
            guard i < b.count else { return nil }
            let start = i
            while i < b.count, b[i] != 0 { i += 1 }
            let s = String(decoding: b[start..<i], as: UTF8.self)
            i += 1
            return s
        }
        guard string() != nil else { return nil }          // executable path
        while i < b.count, b[i] == 0 { i += 1 }            // padding
        for _ in 0..<argc { guard string() != nil else { return nil } }
        var env: [String: String] = [:]
        while let s = string(), !s.isEmpty {
            guard let eq = s.firstIndex(of: "=") else { continue }
            env[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return env
    }
}

public struct LaunchRefusal: Error, Equatable, Sendable {
    public let message: String
    /// The app was opened before the refusal (the system may have woken it).
    public let opened: Bool
    /// Machine-readable reason, for refusals a client should tell apart.
    public let reason: String?
    public init(_ message: String, opened: Bool = false, reason: String? = nil) {
        self.message = message
        self.opened = opened
        self.reason = reason
    }
}
