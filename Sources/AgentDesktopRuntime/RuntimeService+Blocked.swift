import AgentDesktopProtocol
import Foundation

/// #139: iPhone Mirroring is an ordinary macOS app, but input to its window
/// reaches the phone. Driven through the general desktop methods it would
/// skip every iPhone-only protection (paste transaction, clipboard restore,
/// cross-process input blocking, state checks, G2's limits on sensitive and
/// unattended input). Until the iPhone device session (G1) is accepted, it
/// is refused for every caller, the owner included: not launched, not
/// bound, not observed, and sent nothing.
extension RuntimeService {
    /// Lowercased: bundle ids compare without case.
    static let blockedBundleIds: Set<String> = ["com.apple.screencontinuity"]

    static func isBlocked(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return blockedBundleIds.contains(bundleId.lowercased())
    }

    /// The bundle id of the app at `path`: the .app itself or any file in it.
    static func bundleId(atPath path: String) -> String? {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            if url.pathExtension == "app", let id = Bundle(url: url)?.bundleIdentifier { return id }
            url.deleteLastPathComponent()
        }
        return nil
    }

    func runningBundleId(_ pid: Int32) -> String? {
        backend.applications(includeBackground: true).first { $0.process.pid == pid }?.bundleId
    }

    /// `launched` and `quit` only for a launch found to be it afterwards:
    /// the process, and whether it was quit (only one this launch provably
    /// started is).
    static func blockedAppError(notSent: Bool = true, launched: ProcessIdentity? = nil, quit: Bool = false) -> RuntimeError {
        var details: [(String, JSONValue)] = [("reason", .string("iphone_mirroring_blocked"))]
        var message = "iPhone Mirroring is not controlled through desktop methods: input to it reaches the phone without the iPhone protections. It stays refused until the iPhone device session is accepted"
        if let launched {
            details += [("process", launched.json), ("quit", .bool(quit))]
            message += quit ? "; the launch had started it and it was quit"
                : "; it could not be proven that this launch started it, so it was left running"
        }
        return RuntimeError("permission_denied", message, phase: .handler, notSent: notSent, details: .obj(details))
    }
}
