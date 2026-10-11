import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

/// `agentdesktop-acp-dev request-window` (#246, Kevin's ruling: option A).
/// `unit.run` needs the bridge to hold a window grant for the window bound
/// on the Desktop; this asks for one explicitly, as the bridge itself (its
/// own credential, profile `acp`), through `hub.windows.request`. The user
/// approves it in the Agent Desktop confirmation window with Touch ID.
/// Never done while a task is being submitted, never retried.
///
/// Before a grant the bridge cannot see which window is bound
/// (`desktop.show` hides it), so it names the app (and optionally the
/// window); the confirmation shows the exact window. Afterwards it checks
/// that the granted window is the one bound on the Desktop, and says so
/// when it is not: such a grant cannot be used by `unit.run`, and the user
/// withdraws it in the main window (nothing is revoked or retried here).
public enum ACPWindowRequest {
    /// Exactly what `unit.run` checks on the bound window.
    public static let permissions = ["observe", "act"]

    /// How long to wait for the reply to hub.windows.request: the Runtime
    /// answers only once the user has decided, sending nothing meanwhile.
    /// Confirmations take turns (ConfirmationGate admits up to 3, maxWaiting)
    /// and each one's 120 s deadline (RuntimeService.confirmationTimeout)
    /// starts only on its turn, so this request may wait for two others and
    /// then its own: 3 × 120 s, plus a margin. A shorter wait would report a
    /// lost connection while the request is still queued or shown, and a
    /// later approval would still grant (2ndscreen-69 and Codex on #268).
    public static let confirmationTimeout: Double = 120
    public static let confirmationsAdmitted: Double = 3
    public static let replyTimeout: Double = confirmationsAdmitted * confirmationTimeout + 30

    /// The bridge's connection for this request: its own credential, and a
    /// reply timeout that outlasts the user's decision.
    public static func client(endpoint: Endpoint, credential: ClientCredential) -> SocketRuntimeClient {
        ACPPairing.pairedClient(endpoint: endpoint, credential: credential, timeout: replyTimeout)
    }

    public enum Outcome: Equatable, Sendable {
        /// Granted, and it is the Desktop's bound window.
        case granted(windowGrantId: String, expiresAt: String?)
        /// Granted, but not for the window bound on the Desktop (or the
        /// Desktop has no bound window): `unit.run` will refuse it.
        case notTheBoundWindow(windowGrantId: String)
    }

    public static func params(desktopId: String, bundleId: String, windowId: Int?, durationSeconds: Int?) -> JSONValue {
        var m: [(String, JSONValue)] = [("desktopId", .string(desktopId)), ("bundleId", .string(bundleId))]
        if let windowId { m.append(("windowId", .int(windowId))) }
        m.append(("permissions", .array(permissions.map { .string($0) })))
        if let durationSeconds { m.append(("durationSeconds", .int(durationSeconds))) }
        return .obj(m)
    }

    /// Over `client` (connected with the bridge's credential). Runtime
    /// errors (user_denied, window_not_grantable, pairing_required, …) are
    /// thrown as they come.
    public static func request(client: any RuntimeClient, desktopId: String, bundleId: String, windowId: Int? = nil,
                               durationSeconds: Int? = nil, notice: (String) -> Void) throws -> Outcome {
        _ = try client.handshake()
        notice("asking for a window of \(bundleId) on desktop \(desktopId) — confirm it in the Agent Desktop window")
        let grant = try client.call(RuntimeRequest(.windowsRequest, params: params(desktopId: desktopId, bundleId: bundleId,
                                                                                 windowId: windowId, durationSeconds: durationSeconds)))
        guard let grantId = grant["windowGrantId"]?.stringValue, let window = grant["window"] else {
            throw RuntimeError("execution_failed", "hub.windows.request answered without a window grant", phase: .handler)
        }
        let desktop = try client.call(RuntimeRequest(.desktopShow, params: .obj([("desktopId", .string(desktopId))])))
        guard let binding = desktop["binding"], binding != .null,
              let boundWindow = binding["windowId"]?.intValue, let grantedWindow = window["windowId"]?.intValue,
              let boundProcess = binding["process"], let grantedProcess = window["process"],
              boundProcess != .null, boundWindow == grantedWindow, boundProcess == grantedProcess else {
            return .notTheBoundWindow(windowGrantId: grantId)
        }
        return .granted(windowGrantId: grantId, expiresAt: grant["expiresAt"]?.stringValue)
    }
}
