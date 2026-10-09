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

    static func blockedAppError(notSent: Bool = true) -> RuntimeError {
        RuntimeError("permission_denied",
                     "iPhone Mirroring is not controlled through desktop methods: input to it reaches the phone without the iPhone protections. It stays refused until the iPhone device session is accepted",
                     phase: .handler, notSent: notSent,
                     details: .obj([("reason", .string("iphone_mirroring_blocked"))]))
    }
}
