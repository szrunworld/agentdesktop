import Foundation
import SecondScreenCore

/// What this process is: the product host the user runs, or a side instance
/// started for testing a build. The role decides the control endpoint, the
/// display serial numbers and what the app shows.
///
/// The product endpoint is Agent Desktop's own, apart from 2ndscreen.app's
/// (`ControlProtocol.primarySocketURL`), so the engine's development host
/// can run beside the product on one Mac. The `2ndscreen` command reaches
/// the product through `SECONDSCREEN_SOCKET`, which the bundled
/// `agentdesktop` wrapper sets (scripts/bundle-app.sh).
///
/// Checking the endpoint before starting is not atomic ownership: two
/// product hosts started at once could both pass. Real ownership, with a
/// version handshake, comes with the shared coordinator (roadmap C02).
enum HostRole {
    /// The user's Agent Desktop: menu bar, primary virtual display, hot key.
    case product
    /// A copy run on its own socket to test a build: background only, no
    /// primary display, quits when idle.
    case sideInstance(socket: URL)

    static var current: HostRole {
        if let path = ProcessInfo.processInfo.environment["SECONDSCREEN_SOCKET"], !path.isEmpty {
            return .sideInstance(socket: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
        }
        return .product
    }

    static let productName = "Agent Desktop"
    static let bundleID = "com.agentdesktop.app"

    /// `~/Library/Application Support/AgentDesktop/control.sock`.
    static var productEndpoint: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDesktop", isDirectory: true)
            .appendingPathComponent("control.sock")
    }

    var endpoint: URL {
        switch self {
        case .product: return Self.productEndpoint
        case .sideInstance(let socket): return socket
        }
    }

    var isSideInstance: Bool {
        if case .sideInstance = self { return true }
        return false
    }

    /// Serial numbers keep this host's displays apart from 2ndscreen.app's
    /// (primary 1, agents from 100, side instances from 900) and vdisplay's
    /// (2): macOS remembers each serial's arrangement.
    var primaryDisplaySerial: UInt32 { 5 }
    var agentSerialBase: UInt32 { isSideInstance ? 950 : 500 }
}
