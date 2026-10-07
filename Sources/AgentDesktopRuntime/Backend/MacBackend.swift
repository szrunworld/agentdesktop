import AgentDesktopProtocol
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// Read-only macOS backend: permissions, running apps and windows.
public struct MacBackend: RuntimeBackend {
    public init() {}

    public var platform: Platform { .current }

    public func permissions() -> BackendPermissions {
        BackendPermissions(screenRecording: CGPreflightScreenCaptureAccess() ? .granted : .denied,
                           accessibility: AXIsProcessTrusted() ? .granted : .denied)
    }

    public func features() -> [String] {
        var f = ["apps.list", "windows.list"]
        if CGPreflightScreenCaptureAccess() { f.append("windows.titles") }
        return f
    }

    public func applications(includeBackground: Bool) -> [AppSummary] {
        NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated && (includeBackground || $0.activationPolicy == .regular) }
            .map { app in
                AppSummary(process: Self.identity(app.processIdentifier), bundleId: app.bundleIdentifier,
                           name: app.localizedName ?? app.bundleIdentifier ?? "pid \(app.processIdentifier)",
                           active: app.isActive, hidden: app.isHidden)
            }
            .sorted { ($0.name, $0.process.pid) < ($1.name, $1.process.pid) }
    }

    public func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary] {
        let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var identities: [Int32: (ProcessIdentity, String?)] = [:]
        var out: [WindowSummary] = []
        for entry in list {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let owner = entry[kCGWindowOwnerPID as String] as? Int32,
                  let number = entry[kCGWindowNumber as String] as? UInt32,
                  let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: bounds)
            else { continue }
            if let pid, owner != pid { continue }
            let onScreen = entry[kCGWindowIsOnscreen as String] as? Bool ?? false
            if !onScreen, !includeOffscreen { continue }
            let (identity, bundle) = identities[owner] ?? {
                let pair = (Self.identity(owner), NSRunningApplication(processIdentifier: owner)?.bundleIdentifier)
                identities[owner] = pair
                return pair
            }()
            if let bundleId, bundle != bundleId { continue }
            // Without Screen Recording the OS omits kCGWindowName.
            let title = entry[kCGWindowName as String] as? String
            out.append(WindowSummary(
                windowId: number, process: identity,
                appName: entry[kCGWindowOwnerName as String] as? String ?? "",
                bundleId: bundle, title: title,
                frame: Rect(x: frame.origin.x, y: frame.origin.y, width: frame.width, height: frame.height),
                onScreen: onScreen))
        }
        return out
    }

    /// pid plus the kernel's start time, so a reused pid is told apart.
    static func identity(_ pid: Int32) -> ProcessIdentity {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else {
            return ProcessIdentity(pid: pid, startedAt: nil)
        }
        let tv = info.kp_proc.p_starttime
        let date = Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1_000_000)
        return ProcessIdentity(pid: pid, startedAt: Timestamp.string(date))
    }
}
