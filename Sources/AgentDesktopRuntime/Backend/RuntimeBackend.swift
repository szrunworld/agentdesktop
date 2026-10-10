import AgentDesktopProtocol
import Foundation

/// What the platform can tell and do. The Runtime is the only caller; the
/// macOS implementation is `MacBackend`, tests use a fixed one.
public protocol RuntimeBackend: Sendable {
    var platform: Platform { get }
    func permissions() -> BackendPermissions
    /// Backend features in effect now, e.g. "windows.titles" only with the
    /// Screen Recording grant.
    func features() -> [String]
    func applications(includeBackground: Bool) -> [AppSummary]
    /// Normal (layer 0) windows, front to back, of one process or app when
    /// asked; on-screen ones unless `includeOffscreen`.
    func windows(pid: Int32?, bundleId: String?, includeOffscreen: Bool) -> [WindowSummary]
    /// pid plus start time; nil start time when the process is gone.
    func processIdentity(_ pid: Int32) -> ProcessIdentity
    /// The file the process runs, as the kernel has it; nil when it cannot
    /// be read (gone, or not allowed). Used to identify an app that the
    /// running-app list does not show (#139).
    func executablePath(_ pid: Int32) -> String?
}

public extension RuntimeBackend {
    /// No path known: an app the list does not show is then unidentified.
    func executablePath(_ pid: Int32) -> String? { nil }
}
