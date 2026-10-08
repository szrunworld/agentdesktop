import AppKit
import Foundation
import SecondScreenCore

/// What a launch needs from the system, so the ownership rules can be
/// tested without starting real apps.
public struct AppLaunching: Sendable {
    /// Every process running now.
    public var runningPIDs: @Sendable () -> Set<pid_t>
    /// The processes of the app with this bundle ID running now.
    public var processes: @Sendable (String) -> Set<pid_t>
    /// The app's bundle ID and whether it allows one instance only.
    public var bundleInfo: @Sendable (URL) -> (id: String?, singleInstance: Bool)
    /// Open the app as a new instance without activating it.
    public var open: @Sendable (URL) async -> Result<pid_t, Error>
    /// The bundle a running process was started from.
    public var bundleURL: @Sendable (pid_t) -> URL?
    /// Quit a process this launch created (normal quit, forced after a
    /// second). Never called with a process the launch did not create.
    public var quit: @Sendable (pid_t) async -> Void
    /// Whether windows may be placed (the Accessibility permission).
    public var canPlaceWindows: @Sendable () -> Bool
    /// The process's first window, waiting up to the timeout.
    public var firstWindow: @Sendable (pid_t, TimeInterval) async -> WindowInfo?

    public static let system = AppLaunching(
        runningPIDs: { Set(NSWorkspace.shared.runningApplications.map(\.processIdentifier)) },
        processes: { Set(NSRunningApplication.runningApplications(withBundleIdentifier: $0).map(\.processIdentifier)) },
        bundleInfo: { url in
            let bundle = Bundle(url: url)
            let single = (bundle?.object(forInfoDictionaryKey: "LSMultipleInstancesProhibited") as? Bool) ?? false
            return (bundle?.bundleIdentifier, single)
        },
        open: { url in
            await withCheckedContinuation { continuation in
                NSWorkspace.shared.openApplication(at: url, configuration: LaunchOwnership.configuration()) { app, error in
                    if let app {
                        continuation.resume(returning: .success(app.processIdentifier))
                    } else {
                        continuation.resume(returning: .failure(error ?? CocoaError(.executableLoad)))
                    }
                }
            }
        },
        bundleURL: { NSRunningApplication(processIdentifier: $0)?.bundleURL },
        quit: { pid in
            guard let app = NSRunningApplication(processIdentifier: pid) else { return }
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
        })
}

/// A launch owns only a process it provably created. Everything here runs
/// before any window is moved or bound: a refusal has no side effect on the
/// user's apps.
public enum LaunchOwnership {
    /// Always a new instance: an app the user starts at the same moment
    /// keeps its own process, and the launch gets another.
    public static func configuration() -> NSWorkspace.OpenConfiguration {
        let c = NSWorkspace.OpenConfiguration()
        c.activates = false
        c.createsNewApplicationInstance = true
        return c
    }

    /// Open the app and return the process this launch created, or why it
    /// cannot be shown to be one.
    ///
    /// - An app without a bundle ID, or one that allows a single instance
    ///   (LSMultipleInstancesProhibited), may hand back the user's running
    ///   process: macOS gives no guarantee, so it is refused before opening.
    /// - Without `newInstance`, an app already running is refused (moving
    ///   the user's work needs an explicit second instance).
    /// - After opening, the process must not have been running before,
    ///   must come from the requested bundle, and must be the only new
    ///   process of that app; otherwise refused, and the process is left
    ///   alone (it may be the user's).
    public static func openOwnedProcess(_ url: URL, newInstance: Bool, using system: AppLaunching) async
        -> Result<pid_t, LaunchRefusal> {
        let info = system.bundleInfo(url)
        guard let id = info.id else {
            return .failure(LaunchRefusal("\(url.lastPathComponent) has no bundle ID; a new process cannot be told apart from a running one"))
        }
        guard !info.singleInstance else {
            return .failure(LaunchRefusal("\(id) allows one instance only; its windows are not moved automatically"))
        }
        if !newInstance, !system.processes(id).isEmpty {
            return .failure(LaunchRefusal("\(id) is already running; pass --new-instance, or use window move"))
        }
        let before = system.runningPIDs()
        let pid: pid_t
        switch await system.open(url) {
        case let .success(p): pid = p
        case let .failure(error): return .failure(LaunchRefusal("launch failed: \(error.localizedDescription)"))
        }
        guard isNewProcess(pid, runningBefore: before) else {
            return .failure(LaunchRefusal("the app handed back a process that was already running; nothing was moved"))
        }
        guard let started = system.bundleURL(pid), sameBundle(started, url) else {
            return .failure(LaunchRefusal("process \(pid) is not the requested app; nothing was moved"))
        }
        // The user may start the same app while it opens. Then two new
        // processes exist and which one this launch made cannot be shown:
        // refused. Exactly one new process, the one returned, is this
        // launch's (LaunchServices creates a new instance when asked, for
        // apps that do not prohibit it).
        guard system.processes(id).subtracting(before) == [pid] else {
            return .failure(LaunchRefusal("another instance of \(id) started at the same time; nothing was moved"))
        }
        return .success(pid)
    }

    /// Whether `pid` was not running before the launch.
    public static func isNewProcess(_ pid: pid_t, runningBefore: Set<pid_t>) -> Bool {
        pid > 0 && !runningBefore.contains(pid)
    }

    static func sameBundle(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

public struct LaunchRefusal: Error, Equatable, Sendable {
    public let message: String
    public init(_ message: String) { self.message = message }
}
