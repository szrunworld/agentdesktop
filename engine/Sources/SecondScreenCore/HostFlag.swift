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

    /// Raises the flag with `reason`, until `until` if given.
    public func raise(_ reason: String, until: Date? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
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
            lower()
            return nil
        }
        return record.reason
    }

    public func lower() {
        try? FileManager.default.removeItem(at: url)
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
        guard self.generation() == generation else { return }
        lower()
    }
}
