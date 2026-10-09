import AgentDesktopProtocol
import Foundation

/// #139: iPhone Mirroring is an ordinary macOS app, but input to its window
/// reaches the phone. Driven through the general desktop methods it would
/// skip every iPhone-only protection (paste transaction, clipboard restore,
/// cross-process input blocking, state checks, G2's limits on sensitive and
/// unattended input). Until the iPhone device session (G1) is accepted, it
/// is refused for every caller, the owner included: not launched, not
/// bound, not observed, and sent nothing.
///
/// Fail closed: a process whose app cannot be identified is treated as if
/// it might be iPhone Mirroring. Only the one request is refused; nothing
/// is remembered, and the next request identifies the process again.
extension RuntimeService {
    /// Lowercased: bundle ids compare without case.
    static let blockedBundleIds: Set<String> = ["com.apple.screencontinuity"]

    static func isBlocked(bundleId: String?) -> Bool {
        guard let bundleId else { return false }
        return blockedBundleIds.contains(bundleId.lowercased())
    }

    /// What a path says about the app it belongs to.
    enum BundleAtPath: Equatable {
        /// Inside the .app with this bundle id.
        case bundle(String)
        /// In no .app at all.
        case none
        /// Inside a .app whose bundle id cannot be read.
        case unreadable
    }

    /// The app at `path`: the .app itself or any file in it, symlinks
    /// resolved. The innermost .app counts (an app's helper is its own app).
    static func bundle(atPath path: String) -> BundleAtPath {
        var url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        while url.pathComponents.count > 1 {
            if url.pathExtension.lowercased() == "app" {
                guard let id = Bundle(url: url)?.bundleIdentifier else { return .unreadable }
                return .bundle(id)
            }
            url.deleteLastPathComponent()
        }
        return .none
    }

    enum MirroringCheck: Equatable {
        case mirroring, other, unverified
    }

    /// Whether the process is iPhone Mirroring: by the running-app list
    /// first, then by the bundle its executable is in. Either one naming it
    /// is enough. Not iPhone Mirroring only when one of them positively
    /// names something else; when neither can tell, unverified.
    func mirroringCheck(_ pid: Int32) -> MirroringCheck {
        let listed = backend.applications(includeBackground: true).first { $0.process.pid == pid }?.bundleId
        if Self.isBlocked(bundleId: listed) { return .mirroring }
        let onDisk = backend.executablePath(pid).map(Self.bundle(atPath:))
        if case let .bundle(id) = onDisk, Self.isBlocked(bundleId: id) { return .mirroring }
        if listed != nil { return .other }
        switch onDisk {
        case .bundle?, BundleAtPath.none?: return .other
        case .unreadable?, nil: return .unverified
        }
    }

    /// Throws unless the process is known not to be iPhone Mirroring.
    func refuseMirroring(_ pid: Int32, notSent: Bool = true) throws {
        switch mirroringCheck(pid) {
        case .other: return
        case .mirroring: throw Self.blockedAppError(notSent: notSent)
        case .unverified: throw Self.blockedAppError(notSent: notSent, unverified: true)
        }
    }

    /// `unverified`: the app could not be identified, so it could be iPhone
    /// Mirroring. `launched` and `quitRequested` only for a launch found to
    /// be it (or unidentified) afterwards: the process, and whether it was
    /// asked to quit (a request, not proof that it exited).
    static func blockedAppError(notSent: Bool = true, unverified: Bool = false,
                                launched: ProcessIdentity? = nil, quitRequested: Bool = false) -> RuntimeError {
        var details: [(String, JSONValue)] = [("reason", .string("iphone_mirroring_blocked")),
                                              ("identity", .string(unverified ? "unverified" : "iphone_mirroring"))]
        var message = unverified
            ? "the app of this process cannot be identified right now, so it cannot be told apart from iPhone Mirroring; nothing was done. Try again: the next request checks it anew"
            : "iPhone Mirroring is not controlled through desktop methods: input to it reaches the phone without the iPhone protections. It stays refused until the iPhone device session is accepted"
        if let launched {
            details += [("process", launched.json), ("quitRequested", .bool(quitRequested))]
            message += quitRequested ? "; this launch had started it and it was asked to quit"
                : "; it could not be asked to quit and is not this Desktop's app"
        }
        return RuntimeError("permission_denied", message, phase: .handler, notSent: notSent, details: .obj(details))
    }
}
