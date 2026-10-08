import AppKit
import Foundation
import SecondScreenCore

/// What this process is: the product host the user runs, or a side instance
/// started for testing a build. The role decides the control endpoint, the
/// display serial numbers and what the app shows.
///
/// Product and isolated test instances have explicit endpoints. The CLI uses
/// the product endpoint by default; tests set AGENTDESKTOP_SOCKET.
///
/// Checking the endpoint before starting is not atomic ownership: two
/// product hosts started at once could both pass. Real ownership, with a
/// version handshake, comes with the shared coordinator (roadmap C02).
enum HostRole {
    /// The user's Agent Desktop: main window, Dock icon and menu bar entry.
    case product
    /// A copy run on its own socket to test a build: background only (no
    /// Dock icon, no menu bar entry), quits when idle.
    case sideInstance(socket: URL)

    static var current: HostRole {
        if let path = ProcessInfo.processInfo.environment["AGENTDESKTOP_SOCKET"], !path.isEmpty {
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

    /// Where the Runtime API (agentdesktop.runtime/1) listens: beside the
    /// engine endpoint, `runtime.sock` for the product and
    /// `<socket>.runtime.sock` for a side instance. The `agentdesktop` CLI
    /// finds the product's on its own (AgentDesktopClient.EndpointResolver)
    /// and a side instance's through `--endpoint` or AGENTDESKTOP_ENDPOINT.
    var runtimeEndpoint: URL {
        switch self {
        case .product:
            return Self.productEndpoint.deletingLastPathComponent().appendingPathComponent("runtime.sock")
        case .sideInstance(let socket):
            return socket.deletingPathExtension().appendingPathExtension("runtime.sock")
        }
    }

    /// Real GUI input by model-driven runs is off until switched on:
    /// `defaults write com.agentdesktop.app guiExecution -bool true`, or
    /// AGENTDESKTOP_GUI_EXECUTION=1 for a side instance under test.
    var guiExecutionEnabled: Bool {
        switch self {
        case .product: return UserDefaults.standard.bool(forKey: "guiExecution")
        case .sideInstance: return ProcessInfo.processInfo.environment["AGENTDESKTOP_GUI_EXECUTION"] == "1"
        }
    }

    /// The Runtime's request ledger and artifacts.
    var runtimeRecordsDirectory: URL {
        switch self {
        case .product:
            return Self.productEndpoint.deletingLastPathComponent().appendingPathComponent("runtime", isDirectory: true)
        case .sideInstance(let socket):
            return socket.deletingPathExtension().appendingPathExtension("runtime")
        }
    }

    /// Where the AI service keeps API keys. The product uses the login
    /// Keychain. A test copy never does: it would share (and could
    /// overwrite) the product's items, and a rebuilt, re-signed copy would
    /// stop on a Keychain prompt for items an earlier build created. Its
    /// keys live as 0600 files in its own records directory instead.
    enum CredentialBackend: Equatable {
        case keychain
        case files(directory: URL)
    }

    var credentialBackend: CredentialBackend {
        switch self {
        case .product: return .keychain
        case .sideInstance: return .files(directory: runtimeRecordsDirectory.appendingPathComponent("test-credentials"))
        }
    }

    /// A test copy normally shows no window. For acceptance screenshots it
    /// can be asked to show the main window without activating, on one of
    /// its own virtual displays: AGENTDESKTOP_MAIN_WINDOW=1 and optionally
    /// AGENTDESKTOP_MAIN_WINDOW_DISPLAY=<CGDirectDisplayID>. The product
    /// ignores both.
    struct TestWindowRequest: Equatable {
        var displayID: CGDirectDisplayID?
    }

    var mainWindowForTest: TestWindowRequest? {
        mainWindowForTest(environment: ProcessInfo.processInfo.environment)
    }

    func mainWindowForTest(environment env: [String: String]) -> TestWindowRequest? {
        guard isSideInstance, env["AGENTDESKTOP_MAIN_WINDOW"] == "1" else { return nil }
        return TestWindowRequest(displayID: env["AGENTDESKTOP_MAIN_WINDOW_DISPLAY"].flatMap { UInt32($0) })
    }

    /// A test copy without a main window quits straight away; with
    /// AGENTDESKTOP_TEST_QUIT_DIALOG=1 it asks like the product, so the
    /// quit dialog can be accepted on its own. The product ignores it.
    var quitDialogForTest: Bool {
        isSideInstance && ProcessInfo.processInfo.environment["AGENTDESKTOP_TEST_QUIT_DIALOG"] == "1"
    }

    /// Regular (Dock icon, main window) for the product; accessory for a
    /// test copy.
    var activationPolicy: NSApplication.ActivationPolicy { isSideInstance ? .accessory : .regular }

    var isSideInstance: Bool {
        if case .sideInstance = self { return true }
        return false
    }

    /// Product and test instances use distinct display serial ranges.
    var primaryDisplaySerial: UInt32 { 5 }
    var agentSerialBase: UInt32 { isSideInstance ? 950 : 500 }
}
