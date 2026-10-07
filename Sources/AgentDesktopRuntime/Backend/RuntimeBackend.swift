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
}
