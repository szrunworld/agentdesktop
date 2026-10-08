import Foundation

/// One line of a session's visible conversation, kept so `session/load`
/// can replay it. Text is redacted (`ACPRedactor`) before it is stored.
public struct ACPSessionManagerHistoryEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case user, agent }
    public var kind: Kind
    public var text: String
    /// The Run this line announced, so a replay can put the Run's events
    /// right after it.
    public var runId: String?
    public var at: String
    public init(kind: Kind, text: String, runId: String? = nil, at: String) {
        self.kind = kind; self.text = text; self.runId = runId; self.at = at
    }
}

/// Conversation history beside the binding (lane S; not part of the frozen
/// `ACPSessionStore`). A store without it simply has no text to replay.
public protocol ACPSessionManagerHistoryStore: AnyObject, Sendable {
    /// Append in order. Fails when the session has no binding.
    func appendHistory(sessionId: String, _ entries: [ACPSessionManagerHistoryEntry]) throws
    func history(sessionId: String) throws -> [ACPSessionManagerHistoryEntry]
}

public enum ACPFileSessionStoreError: Error, Equatable, Sendable {
    /// `binding.revision` was not the stored revision + 1.
    case conflict(sessionId: String, stored: Int, attempted: Int)
    case invalidSessionId
    case io(String)
}

/// ACP session bindings as one JSON file per session (docs/acp/README.md
/// §3, lane S). Directory 0700, files 0600, atomic replace, a revision
/// check on every save. It stores what the server hands it: ids, cursors,
/// options and a title the projector already redacted. Never Run state.
public final class ACPFileSessionStore: ACPSessionStore, ACPSessionManagerHistoryStore, @unchecked Sendable {
    /// Oldest entries are dropped beyond this many.
    public static let historyLimit = 1000

    public let directory: URL
    private let lock = NSLock()

    /// `~/Library/Application Support/AgentDesktop/acp/sessions`. Not
    /// created until the first save. Tests pass a temporary directory.
    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AgentDesktop/acp/sessions", isDirectory: true)
    }

    public init(directory: URL = ACPFileSessionStore.defaultDirectory()) {
        self.directory = directory
    }

    public func load(sessionId: String) throws -> ACPSessionBinding? {
        try Self.checkId(sessionId)
        lock.lock(); defer { lock.unlock() }
        guard let b = try read(fileURL(sessionId)) else { return nil }
        // A file renamed onto another id is not that session.
        return b.acpSessionId == sessionId ? b : nil
    }

    public func list(principalId: String) throws -> [ACPSessionBinding] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        var out: [ACPSessionBinding] = []
        for name in names where name.hasSuffix(".json") && !name.hasSuffix(".history.json") && !name.hasPrefix(".") {
            // A damaged file must not hide the others.
            guard let b = try? read(directory.appendingPathComponent(name)) else { continue }
            if b.principalId == principalId, name == "\(b.acpSessionId).json" { out.append(b) }
        }
        return out.sorted { ($0.updatedAt, $0.acpSessionId) > ($1.updatedAt, $1.acpSessionId) }
    }

    public func save(_ binding: ACPSessionBinding) throws {
        try Self.checkId(binding.acpSessionId)
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }

        let target = fileURL(binding.acpSessionId)
        let stored = try read(target)?.revision ?? 0
        guard binding.revision == stored + 1 else {
            throw ACPFileSessionStoreError.conflict(sessionId: binding.acpSessionId, stored: stored,
                                                    attempted: binding.revision)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data: Data
        do { data = try encoder.encode(Record(binding)) } catch { throw ACPFileSessionStoreError.io("encode") }
        try writeAtomically(data, to: target)
    }

    /// Forget a closed session. Missing is not an error.
    public func remove(sessionId: String) throws {
        try Self.checkId(sessionId)
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }
        for url in [fileURL(sessionId), historyURL(sessionId)] where unlink(url.path) != 0 && errno != ENOENT {
            throw ACPFileSessionStoreError.io("unlink errno \(errno)")
        }
    }

    // MARK: History

    /// Read-modify-write under the directory lock, atomic replace, 0600.
    /// Every text passes `ACPRedactor` here as well, so nothing unredacted
    /// reaches the disk whatever the caller did.
    public func appendHistory(sessionId: String, _ entries: [ACPSessionManagerHistoryEntry]) throws {
        try Self.checkId(sessionId)
        guard !entries.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        try ensureDirectory()
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }
        guard try read(fileURL(sessionId))?.acpSessionId == sessionId else {
            throw ACPFileSessionStoreError.io("no binding for history")
        }
        var record = try readHistory(sessionId) ?? HistoryRecord(acpSessionId: sessionId, revision: 0, entries: [])
        record.entries += entries.map {
            HistoryRecord.Entry(kind: $0.kind.rawValue, text: ACPRedactor.redact($0.text),
                                runId: $0.runId, at: $0.at)
        }
        if record.entries.count > Self.historyLimit { record.entries.removeFirst(record.entries.count - Self.historyLimit) }
        record.revision += 1
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do { data = try encoder.encode(record) } catch { throw ACPFileSessionStoreError.io("encode") }
        try writeAtomically(data, to: historyURL(sessionId))
    }

    public func history(sessionId: String) throws -> [ACPSessionManagerHistoryEntry] {
        try Self.checkId(sessionId)
        lock.lock(); defer { lock.unlock() }
        return (try readHistory(sessionId)?.entries ?? []).compactMap { e in
            guard let kind = ACPSessionManagerHistoryEntry.Kind(rawValue: e.kind) else { return nil }
            return ACPSessionManagerHistoryEntry(kind: kind, text: e.text, runId: e.runId, at: e.at)
        }
    }

    private func historyURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).history.json") }

    private func readHistory(_ id: String) throws -> HistoryRecord? {
        let fd = open(historyURL(id).path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ACPFileSessionStoreError.io("open errno \(errno)")
        }
        let data = FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile()
        guard let r = try? JSONDecoder().decode(HistoryRecord.self, from: data), r.acpSessionId == id else {
            throw ACPFileSessionStoreError.io("decode history")
        }
        return r
    }

    private struct HistoryRecord: Codable {
        struct Entry: Codable { var kind: String; var text: String; var runId: String?; var at: String }
        var format = 1
        var acpSessionId: String
        var revision: Int
        var entries: [Entry]
        init(acpSessionId: String, revision: Int, entries: [Entry]) {
            self.acpSessionId = acpSessionId; self.revision = revision; self.entries = entries
        }
    }

    // MARK: Files

    static func checkId(_ id: String) throws {
        guard (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A)
                  || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F }) else {
            throw ACPFileSessionStoreError.invalidSessionId
        }
    }

    private func fileURL(_ id: String) -> URL { directory.appendingPathComponent("\(id).json") }

    private func ensureDirectory() throws {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            throw ACPFileSessionStoreError.io("mkdir")
        }
        guard chmod(directory.path, 0o700) == 0 else { throw ACPFileSessionStoreError.io("chmod dir errno \(errno)") }
    }

    private func read(_ url: URL) throws -> ACPSessionBinding? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw ACPFileSessionStoreError.io("open errno \(errno)")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        let data = handle.readDataToEndOfFile()
        do {
            return try JSONDecoder().decode(Record.self, from: data).binding
        } catch {
            throw ACPFileSessionStoreError.io("decode")
        }
    }

    private func writeAtomically(_ data: Data, to target: URL) throws {
        let tmp = directory.appendingPathComponent(".\(UUID().uuidString).tmp")
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ACPFileSessionStoreError.io("create errno \(errno)") }
        var ok = fchmod(fd, 0o600) == 0
        if ok {
            ok = data.withUnsafeBytes { raw -> Bool in
                var offset = 0
                while offset < raw.count {
                    let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { return false }
                    offset += n
                }
                return true
            }
        }
        if ok { ok = fsync(fd) == 0 }
        close(fd)
        guard ok, rename(tmp.path, target.path) == 0 else {
            unlink(tmp.path)
            throw ACPFileSessionStoreError.io("write")
        }
    }

    // MARK: Format

    private struct Record: Codable {
        struct Option: Codable { var id, name, value: String; var choices: [String] }
        var format = 1
        var acpSessionId, principalId, clientId, cwd, title: String
        var runIds: [String]
        var lastCursor: [String: Int]
        var options: [Option]
        var createdAt, updatedAt: String
        var revision: Int
        var pendingSubmissionKey: String?

        init(_ b: ACPSessionBinding) {
            acpSessionId = b.acpSessionId; principalId = b.principalId; clientId = b.clientId
            cwd = b.cwd; title = b.title; runIds = b.runIds; lastCursor = b.lastCursor
            options = b.options.map { Option(id: $0.id, name: $0.name, value: $0.value, choices: $0.choices) }
            createdAt = b.createdAt; updatedAt = b.updatedAt; revision = b.revision
            pendingSubmissionKey = b.pendingSubmissionKey
        }

        var binding: ACPSessionBinding {
            ACPSessionBinding(acpSessionId: acpSessionId, principalId: principalId, clientId: clientId, cwd: cwd,
                              title: title, runIds: runIds, lastCursor: lastCursor,
                              options: options.map { ACPConfigOption(id: $0.id, name: $0.name, value: $0.value,
                                                                      choices: $0.choices) },
                              createdAt: createdAt, updatedAt: updatedAt, revision: revision,
                              pendingSubmissionKey: pendingSubmissionKey)
        }
    }
}
