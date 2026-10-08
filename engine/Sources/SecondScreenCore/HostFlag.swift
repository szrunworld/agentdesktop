import Darwin
import Foundation

/// A small flag kept in a file only the user can open, so every agent
/// process on the Mac sees it, not just the one that raised it: the CLI
/// starts a new process per command, and a state held in memory would be
/// gone by the next one. It may carry an expiry, after which it reads as
/// lowered.
public struct HostFlag: Sendable {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// `~/Library/Caches/AgentDesktop/<name>`, beside the clipboard lock.
    public static func named(_ name: String) -> HostFlag {
        HostFlag(url: ClipboardLease.defaultURL.deletingLastPathComponent().appendingPathComponent(name))
    }

    private struct Record: Codable {
        var reason: String
        var until: Date?
        /// Which raising this is, so a reader can lower only the one it saw.
        var generation: String?
    }

    /// Every change of the flag (raising, and lowering a given raising)
    /// runs under an exclusive lock on a file beside it, so a check of which
    /// raising is up and its removal cannot interleave with another process
    /// raising a new one: that one would be deleted unseen.
    private func serialized<Value>(_ body: () throws -> Value) throws -> Value {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let lockPath = url.path + ".lock"
        let fd = open(lockPath, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(fd) }
        // Someone else's file, or not a plain file, is not ours to trust.
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_uid == getuid(), (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteNoPermission)
        }
        if info.st_mode & 0o077 != 0 { fchmod(fd, 0o600) }
        while flock(fd, LOCK_EX) != 0 {
            guard errno == EINTR else { throw CocoaError(.fileWriteUnknown) }
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    /// Raises the flag with `reason`, until `until` if given.
    public func raise(_ reason: String, until: Date? = nil) throws {
        try serialized { try raiseLocked(reason, until: until) }
    }

    private func raiseLocked(_ reason: String, until: Date?) throws {
        let directory = url.deletingLastPathComponent()
        let data = try JSONEncoder().encode(Record(reason: reason, until: until, generation: UUID().uuidString))
        // Written aside and renamed in, so a reader never sees half a record.
        let staging = directory.appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: staging.path, contents: data,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        guard rename(staging.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: staging)
            throw CocoaError(.fileWriteUnknown)
        }
    }

    /// The reason the flag is up, or nil when it is down or has expired.
    /// A record that cannot be read counts as up: the flag guards against
    /// harm, so doubt keeps it raised.
    public func reason(now: Date = Date()) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
            return "an unreadable record at \(url.path)"
        }
        if let until = record.until, until <= now {
            // Only this expired raising goes; a new one raised meanwhile stays.
            if let generation = record.generation { lower(ifStill: generation) }
            return nil
        }
        return record.reason
    }

    public func lower() {
        _ = try? serialized { try? FileManager.default.removeItem(at: url) }
    }

    /// The raising now in place, if the flag is up: pass it to
    /// `lower(ifStill:)` to lower that one and not a later one.
    public func generation(now: Date = Date()) -> String? {
        guard reason(now: now) != nil, let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return (try? JSONDecoder().decode(Record.self, from: data))?.generation ?? "unreadable"
    }

    /// Lowers the flag only if it is still the raising `generation` named;
    /// one raised since stays up.
    public func lower(ifStill generation: String) {
        _ = try? serialized {
            guard let data = FileManager.default.contents(atPath: url.path) else { return }
            let current = (try? JSONDecoder().decode(Record.self, from: data))?.generation ?? "unreadable"
            guard current == generation else { return }
            try? FileManager.default.removeItem(at: url)
        }
    }
}
