import Darwin
import Foundation

/// The Mac's clipboard held by one process at a time. Every agent process
/// (each `agentdesktop` CLI, the app, a side instance) shares the user's one
/// general pasteboard, so a paste that writes it, presses ⌘V, waits for the
/// phone and puts the user's contents back must not interleave with
/// another: one agent's text would be pasted by the other, or "restored" as
/// the user's. A lock inside one process cannot see the others; this is an
/// exclusive `flock` on a file only the user can open, which the system
/// drops when the holder exits or crashes.
public final class ClipboardLease {
    public enum LeaseError: LocalizedError, Equatable {
        case busy(seconds: Double)
        case unavailable(String)

        public var errorDescription: String? {
            switch self {
            case .busy(let seconds):
                return "another agent has been using the clipboard for over \(Self.format(seconds)) s; "
                    + "nothing was pasted"
            case .unavailable(let why):
                return "cannot lock the clipboard (\(why)); nothing was pasted"
            }
        }

        private static func format(_ seconds: Double) -> String {
            seconds == seconds.rounded() ? String(Int(seconds)) : String(format: "%.1f", seconds)
        }
    }

    /// `~/Library/Caches/AgentDesktop/clipboard.lock`: per user, not per
    /// control socket, since side instances share the same pasteboard.
    public static var defaultURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AgentDesktop", isDirectory: true)
            .appendingPathComponent("clipboard.lock")
    }

    public let url: URL
    private var fd: Int32

    private init(url: URL, fd: Int32) {
        self.url = url
        self.fd = fd
    }

    deinit { release() }

    /// Waits up to `timeout` seconds for the clipboard.
    public static func acquire(at url: URL = defaultURL, timeout: TimeInterval) throws -> ClipboardLease {
        let directory = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw LeaseError.unavailable(error.localizedDescription)
        }
        let fd = open(url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw LeaseError.unavailable(String(cString: strerror(errno))) }
        // Someone else's file, or one left readable by others, is not ours to trust.
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw LeaseError.unavailable("\(url.path) is not a file of this user's")
        }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }

        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 { return ClipboardLease(url: url, fd: fd) }
            let error = errno
            guard error == EWOULDBLOCK || error == EINTR else {
                close(fd)
                throw LeaseError.unavailable(String(cString: strerror(error)))
            }
            if Date() >= deadline {
                close(fd)
                throw LeaseError.busy(seconds: timeout)
            }
            usleep(20_000)
        }
    }

    /// Lets the next process in. Also done on deinit and, by the system, on exit.
    public func release() {
        guard fd >= 0 else { return }
        flock(fd, LOCK_UN)
        close(fd)
        fd = -1
    }

    /// Runs `body` holding the clipboard.
    public static func with<Value>(at url: URL = defaultURL, timeout: TimeInterval,
                                   _ body: () throws -> Value) throws -> Value {
        let lease = try acquire(at: url, timeout: timeout)
        defer { lease.release() }
        return try body()
    }
}
