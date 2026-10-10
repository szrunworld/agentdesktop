import Darwin
import Foundation

/// A small flag kept in a file only the user can open, so every agent
/// process on the Mac sees it, not just the one that raised it: the CLI
/// starts a new process per command, and a state held in memory would be
/// gone by the next one. It may carry an expiry, after which it reads as
/// lowered.
public struct HostFlag: Sendable {
    public let url: URL
    /// Runs between reading an expired record and dropping it: tests use it
    /// to raise the flag again in that gap.
    var beforeDropping: (@Sendable () -> Void)?
    /// How long a record that cannot be read still counts as raised.
    public static let unreadableLifetime: TimeInterval = 600

    /// Whether an unreadable record is dropped after `unreadableLifetime`.
    /// Off for a flag that only something seen may lower: time does not say
    /// whether an input landed (Codex on #127).
    public var unreadableExpires: Bool

    public init(url: URL, unreadableExpires: Bool = true) {
        self.url = url
        self.unreadableExpires = unreadableExpires
    }

    /// `~/Library/Caches/AgentDesktop/<name>`, beside the clipboard lock.
    public static func named(_ name: String, unreadableExpires: Bool = true) -> HostFlag {
        HostFlag(url: ClipboardLease.defaultURL.deletingLastPathComponent().appendingPathComponent(name),
                 unreadableExpires: unreadableExpires)
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
        // Dropping an expired record races a new raising: when the record
        // changed before it could be dropped, read the new one.
        for _ in 0..<3 {
            if case .settled(let reason) = read(now: now) { return reason }
        }
        // Doubt keeps it up.
        return "a record at \(url.path) that could not be settled"
    }

    private enum Reading {
        /// The reason the flag is up, or nil when it is down.
        case settled(String?)
        /// A stale record could not be dropped: another replaced it first.
        case changed
    }

    private func read(now: Date) -> Reading {
        guard let data = FileManager.default.contents(atPath: url.path) else { return .settled(nil) }
        guard let record = try? JSONDecoder().decode(Record.self, from: data) else {
            // Doubt keeps it up, but not for ever: an unreadable record older
            // than `unreadableLifetime` is dropped, so a corrupt file cannot
            // block every agent until someone deletes it by hand.
            let written = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            if unreadableExpires, let written, now.timeIntervalSince(written) > Self.unreadableLifetime {
                return lower(ifStill: "unreadable") ? .settled(nil) : .changed
            }
            return .settled("an unreadable record at \(url.path)")
        }
        if let until = record.until, until <= now {
            // Only this expired raising goes; a new one raised meanwhile stays.
            guard let generation = record.generation else { return .settled(nil) }
            beforeDropping?()
            return lower(ifStill: generation) ? .settled(nil) : .changed
        }
        return .settled(record.reason)
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
    /// Returns false when another raising is in place, or the flag could
    /// not be checked, and so may still be up.
    @discardableResult
    public func lower(ifStill generation: String) -> Bool {
        (try? serialized { () -> Bool in
            guard let data = FileManager.default.contents(atPath: url.path) else { return true }
            let current = (try? JSONDecoder().decode(Record.self, from: data))?.generation ?? "unreadable"
            guard current == generation else { return false }
            try? FileManager.default.removeItem(at: url)
            return !FileManager.default.fileExists(atPath: url.path)
        }) ?? false
    }
}
