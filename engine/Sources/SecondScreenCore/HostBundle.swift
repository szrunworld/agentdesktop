import AppKit

/// Bundle discovery shared by optional AgentDesktop resources. Discovery
/// never launches an app, installs tools, or starts a phone connection.
public enum HostBundle {
    public static let applicationBundleID = "com.agentdesktop.app"

    /// A bundled CLI may live in MacOS, Resources/bin, or Resources/libexec.
    public static func enclosingApp(of url: URL) -> URL? {
        var candidate = url.resolvingSymlinksInPath()
        for _ in 0..<5 {
            if candidate.pathExtension == "app" { return candidate }
            candidate = candidate.deletingLastPathComponent()
        }
        return nil
    }

    /// Discover only AgentDesktop as the resource owner. Missing resources
    /// remain unavailable until explicitly installed for this product.
    public static func runningAppBundles(
        lookup: (String) -> [URL] = { id in
            NSRunningApplication.runningApplications(withBundleIdentifier: id).compactMap(\.bundleURL)
        }
    ) -> [URL] {
        lookup(applicationBundleID)
    }

    /// A CLI inside an App stays with that App, even when a resource is absent.
    /// An unbundled development CLI may discover a running AgentDesktop host.
    public static func resourceDirectories(
        _ relativePath: String,
        containing executable: URL?,
        runningApps: () -> [URL] = { runningAppBundles() }
    ) -> [URL] {
        if let app = executable.flatMap(enclosingApp) {
            return [app.appendingPathComponent(relativePath)]
        }
        return runningApps().map { $0.appendingPathComponent(relativePath) }
    }
}
