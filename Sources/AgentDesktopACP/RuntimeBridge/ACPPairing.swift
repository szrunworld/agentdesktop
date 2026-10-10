import AgentDesktopClient
import AgentDesktopProtocol
import Foundation

/// The bridge pairs as itself (A4; docs/security/a4-identity.md: the ACP
/// bridge is an external app that pairs through the trusted confirmation
/// window and keeps its own credential). Run by the same executable that
/// later serves the editor, so the window shows the bridge's own code
/// identity, and the keychain item, whose access list trusts only the
/// program that created it, is readable when serving without a prompt.
///
/// Same flow as `agentdesktop agents pair`: an unpaired connection asks to
/// pair, shows the short code, and polls on that same connection (only it
/// can collect the credential) until the user answers in the window.
public enum ACPPairing {
    /// The keychain profile the bridge serves with.
    public static let profile = "acp"

    /// What the bridge needs (RuntimeService.capabilityOf): `unit.run` to
    /// submit a task, `run` to show, cancel and follow the Runs it started,
    /// and `observe` and `act` because A6's executor acts as the Run's
    /// principal, so each observe and act inside the Run passes the bridge's
    /// own grant. No `desktop.manage`: the bridge creates no Desktop,
    /// launches no app and binds no window (#246).
    public static let capabilities = ["observe", "act", "unit.run", "run"]

    /// `--desktops`: Desktop ids the user created in the Agent Desktop main
    /// window, comma separated. Never `created` (the bridge creates none, and
    /// its meaning is not widened, #246); nil unless every id looks like one.
    public static func desktopIds(_ text: String) -> [String]? {
        let ids = text.split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        guard !ids.isEmpty, ids.allSatisfy({ !$0.isEmpty && $0 != "created" && $0.unicodeScalars.allSatisfy(allowed.contains) }) else {
            return nil
        }
        return ids
    }

    /// The grant to request: the capabilities above on exactly the Desktops
    /// named, plus the apps whose windows the bridge may later ask the user
    /// for (bundle ids; none by default).
    public static func grant(desktops: [String], apps: [String] = [], durationSeconds: Int? = nil) -> JSONValue {
        var m: [(String, JSONValue)] = [("capabilities", .array(capabilities.map { .string($0) })),
                                        ("desktops", .array(desktops.map { .string($0) })),
                                        ("apps", .array(apps.map { .string($0) }))]
        if let durationSeconds { m.append(("durationSeconds", .int(durationSeconds))) }
        return .obj(m)
    }

    /// `--duration` as `agentdesktop agents pair` reads it: a number with
    /// d, h, m or s (8h, 30m, 7d), between 1 second and 7 days (the
    /// Runtime's longest grant). Nil when it is not one.
    public static func durationSeconds(_ text: String) -> Int? {
        let units: [(String, Double)] = [("d", 86400), ("h", 3600), ("m", 60), ("s", 1)]
        guard let (suffix, scale) = units.first(where: { text.hasSuffix($0.0) }), let v = Double(text.dropLast(suffix.count)), v > 0 else {
            return nil
        }
        // Checked before it becomes an Int, so 1e309s cannot trap.
        let seconds = v * scale
        guard seconds.isFinite, seconds >= 1, seconds <= 7 * 86400 else { return nil }
        return Int(seconds)
    }

    /// An unpaired connection to `endpoint`, named like the serving bridge.
    public static func unpairedClient(endpoint: Endpoint) -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: endpoint, info: ClientInfo(name: "agentdesktop-acp", version: RuntimeAPI.productVersion),
                            timeout: 10, credential: nil)
    }

    /// A connection as the paired bridge (its own credential), named like
    /// the serving bridge.
    public static func pairedClient(endpoint: Endpoint, credential: ClientCredential) -> SocketRuntimeClient {
        SocketRuntimeClient(endpoint: endpoint, info: ClientInfo(name: "agentdesktop-acp", version: RuntimeAPI.productVersion),
                            timeout: 10, credential: credential)
    }

    public enum Outcome: Equatable, Sendable {
        /// Approved; the credential is in the store under `profile`.
        case paired(clientId: String, grant: JSONValue)
        /// The user denied it, or the request expired, in the window.
        case refused(pairingId: String, state: String)
        /// No answer before the timeout; nothing was stored.
        case timedOut(pairingId: String)
    }

    /// Pair over `client` (an unpaired connection) and keep the credential
    /// in `store` under `profile` for `endpoint`. Runtime errors are thrown
    /// as they come (pairing_busy, pairing_cooldown, …), never retried.
    public static func pair(client: any RuntimeClient, store: any CredentialStore, endpoint: String,
                            name: String, grant: JSONValue, timeout: Double, pollInterval: Double = 1,
                            now: () -> Date = Date.init, sleep: (Double) -> Void = { Thread.sleep(forTimeInterval: $0) },
                            notice: (String) -> Void) throws -> Outcome {
        _ = try client.handshake()
        let started = try client.call(RuntimeRequest(.pairingStart, params: .obj([("agentName", .string(name)), ("requested", grant)])))
        let pairingId = started["pairingId"]?.stringValue ?? ""
        notice("pairing \(pairingId): code \(started["shortCode"]?.stringValue ?? "?") — confirm it in the Agent Desktop window")
        let deadline = now().addingTimeInterval(timeout)
        while true {
            let status = try client.call(RuntimeRequest(.pairingStatus, params: .obj([("pairingId", .string(pairingId))])))
            switch status["state"]?.stringValue {
            case "approved":
                guard let c = status["credential"], let id = c["clientId"]?.stringValue, let token = c["token"]?.stringValue else {
                    throw RuntimeError("execution_failed", "approved, but the credential was already collected", phase: .handler)
                }
                try store.save(ClientCredential(clientId: id, token: token), endpoint: endpoint, profile: profile)
                return .paired(clientId: id, grant: status["grant"] ?? .null)
            case let state? where state == "denied" || state == "expired":
                return .refused(pairingId: pairingId, state: state)
            default:
                if now() >= deadline { return .timedOut(pairingId: pairingId) }
                sleep(pollInterval)
            }
        }
    }
}
