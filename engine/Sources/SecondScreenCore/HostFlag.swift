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
    }

    /// Raises the flag with `reason`, until `until` if given.
    public func raise(_ reason: String, until: Date? = nil) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let data = try JSONEncoder().encode(Record(reason: reason, until: until))
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
}
