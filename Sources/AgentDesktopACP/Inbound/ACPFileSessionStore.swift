import Foundation

/// One line of a session's visible conversation, kept so `session/load`
/// can replay it. Text is redacted (`ACPRedactor`) before it is stored.
public struct ACPSessionManagerHistoryEntry: Equatable, Sendable {
    public enum Kind: String, Sendable { case user, agent }
    /// What is stored for a user's words: never the text.
    public static let userInputPlaceholder = "（此处为用户输入，内容不保存）"
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
    private var migrated = false

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
        try migrateLegacy()
        guard let b = try read(fileURL(sessionId)) else { return nil }
        // A file renamed onto another id is not that session.
        return b.acpSessionId == sessionId ? b : nil
    }

    public func list(principalId: String) throws -> [ACPSessionBinding] {
        lock.lock(); defer { lock.unlock() }
        try migrateLegacy()
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
        try migrateLegacy()
        try ensureDirectory()
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }

        let target = fileURL(binding.acpSessionId)
        try refuseOverwritingLegacy(target)
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
        try migrateLegacy()
        try ensureDirectory()
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }
        guard try read(fileURL(sessionId))?.acpSessionId == sessionId else {
            throw ACPFileSessionStoreError.io("no binding for history")
        }
        try refuseOverwritingLegacy(historyURL(sessionId))
        var record = try readHistory(sessionId) ?? HistoryRecord(acpSessionId: sessionId, revision: 0, entries: [])
        record.entries += entries.map {
            HistoryRecord.Entry(kind: $0.kind.rawValue,
                                text: $0.kind == .user ? ACPSessionManagerHistoryEntry.userInputPlaceholder
                                                       : ACPRedactor.redact($0.text),
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
        try migrateLegacy()
        return (try readHistory(sessionId)?.entries ?? []).compactMap { e in
            guard let kind = ACPSessionManagerHistoryEntry.Kind(rawValue: e.kind) else { return nil }
            return ACPSessionManagerHistoryEntry(kind: kind, text: e.text, runId: e.runId, at: e.at)
        }
    }

    /// Files written before format 2 could hold user text (prompt lines,
    /// titles built from them, agent lines that echoed input or Runtime
    /// questions). Once per store, under the directory lock, every such file
    /// is rewritten in place: user lines become the placeholder, agent lines
    /// lose only their echoes (`ACPHistoryScrub`; status, results and Run
    /// ids stay), titles become "对话". Revisions are unchanged. Each file's
    /// counts or error go to `migration-log.jsonl` (never any text). A file
    /// that fails stays format 1 and is scrubbed in memory whenever read;
    /// the next store retries it. Called with `lock` held.
    ///
    /// Rewriting replaces the current file only. Earlier contents may still
    /// exist in snapshots, backups or freed disk blocks: this is not a
    /// secure erase, and nothing here may claim it is.
    private func migrateLegacy() throws {
        guard !migrated else { return }
        guard FileManager.default.fileExists(atPath: directory.path) else { migrated = true; return }
        let lockFd = open(directory.appendingPathComponent(".lock").path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard lockFd >= 0 else { throw ACPFileSessionStoreError.io("lock open errno \(errno)") }
        defer { close(lockFd) }
        guard flock(lockFd, LOCK_EX) == 0 else { throw ACPFileSessionStoreError.io("flock errno \(errno)") }
        defer { flock(lockFd, LOCK_UN) }
        // Any doubt leaves the migration pending, so a later call retries;
        // meanwhile reads scrub format-1 files in memory (Codex on #141).
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var failed = false
        for name in names.sorted() where name.hasSuffix(".json") && !name.hasPrefix(".") {
            let url = directory.appendingPathComponent(name)
            let data: Data
            switch Self.readNoFollow(url) {
            case let .success(d): data = d
            case .failure(.gone): continue
            case .failure: failed = true; continue
            }
            var entry: MigrationLogEntry
            let out: Data
            if name.hasSuffix(".history.json") {
                guard var r = try? JSONDecoder().decode(HistoryRecord.self, from: data), r.format < 2 else { continue }
                // Only a binding that is really absent means "no Runs"; any
                // other read failure would clear every status line for good.
                let runIds: Set<String>
                do { runIds = Set(try read(fileURL(r.acpSessionId))?.runIds ?? []) } catch { failed = true; continue }
                entry = MigrationLogEntry(at: Self.now(), file: "history", sessionId: r.acpSessionId, entries: r.entries.count)
                r = Self.scrubbed(r, runIds: runIds, stats: &entry)
                guard let encoded = try? encoder.encode(r) else { failed = true; continue }
                out = encoded
            } else {
                guard var r = try? JSONDecoder().decode(Record.self, from: data), r.format < 2 else { continue }
                entry = MigrationLogEntry(at: Self.now(), file: "binding", sessionId: r.acpSessionId, entries: 0)
                entry.titleReset = r.title != "对话"
                r.title = "对话"
                r.format = 2
                guard let encoded = try? encoder.encode(r) else { failed = true; continue }
                out = encoded
            }
            // The log line is written (and synced) before the file changes:
            // no log, no rewrite, so the audit trail is never missing a file.
            guard appendMigrationLog([entry]) else { failed = true; continue }
            do {
                try writeAtomically(out, to: url)
            } catch {
                entry.error = Self.errorCode(error)
                _ = appendMigrationLog([entry])
                failed = true
            }
        }
        migrated = !failed
    }

    /// One migrated file: counts and an error code, never any text.
    struct MigrationLogEntry: Codable, Equatable {
        var at: String
        var file: String
        var sessionId: String
        var entries: Int
        var userScrubbed = 0
        var agentChanged = 0
        var agentKept = 0
        var titleReset = false
        var error: String?
        init(at: String, file: String, sessionId: String, entries: Int) {
            self.at = at; self.file = file; self.sessionId = sessionId; self.entries = entries
        }
    }

    public static let migrationLogName = "migration-log.jsonl"

    /// Append whole lines and fsync; false on any failure or short write.
    private func appendMigrationLog(_ entries: [MigrationLogEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines = Data()
        for e in entries {
            guard let d = try? encoder.encode(e) else { return false }
            lines += d + Data("\n".utf8)
        }
        let fd = open(directory.appendingPathComponent(Self.migrationLogName).path,
                      O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // All lines or none: on a short or failed write, cut the file back to
        // where it was, so a retry never appends after a half line (Codex on
        // #141). Called with the directory lock held, so no other writer.
        let start = lseek(fd, 0, SEEK_END)
        guard start >= 0 else { return false }
        let ok = lines.withUnsafeBytes { raw -> Bool in
            var offset = 0
            while offset < raw.count {
                let n = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        guard ok, fsync(fd) == 0 else {
            _ = ftruncate(fd, start)
            return false
        }
        return true
    }

    private static func scrubbed(_ r: HistoryRecord, runIds: Set<String>, stats: inout MigrationLogEntry) -> HistoryRecord {
        var r = r
        r.entries = r.entries.map { e in
            if e.kind == ACPSessionManagerHistoryEntry.Kind.user.rawValue {
                stats.userScrubbed += 1
                return .init(kind: e.kind, text: ACPSessionManagerHistoryEntry.userInputPlaceholder, runId: e.runId, at: e.at)
            }
            let (text, outcome) = ACPHistoryScrub.legacyAgent(e.text, runIds: runIds)
            if outcome == .changed { stats.agentChanged += 1 } else { stats.agentKept += 1 }
            return .init(kind: e.kind, text: text, runId: e.runId, at: e.at)
        }
        r.format = 2
        return r
    }

    private static func errorCode(_ error: Error) -> String {
        if case let ACPFileSessionStoreError.io(code) = error { return code }
        return "encode"
    }

    private static func now() -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.string(from: Date())
    }

    enum ReadFailure: Error { case gone, failed }

    private static func readNoFollow(_ url: URL) -> Result<Data, ReadFailure> {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { return .failure(errno == ENOENT ? .gone : .failed) }
        return .success(FileHandle(fileDescriptor: fd, closeOnDealloc: true).readDataToEndOfFile())
    }

    /// While the migration is pending, a format-1 file is only ever changed
    /// by the migration itself, which logs first; a normal write would
    /// replace it without its audit entry (Codex on #141). Called with the
    /// directory lock held.
    private func refuseOverwritingLegacy(_ url: URL) throws {
        guard !migrated, case let .success(data) = Self.readNoFollow(url) else { return }
        struct Format: Decodable { var format: Int? }
        if let f = try? JSONDecoder().decode(Format.self, from: data), (f.format ?? 1) < 2 {
            throw ACPFileSessionStoreError.io("legacy file awaiting migration")
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
        // A format-1 file the migration could not rewrite: never served as is.
        guard r.format < 2 else { return r }
        var ignored = MigrationLogEntry(at: "", file: "history", sessionId: id, entries: 0)
        return Self.scrubbed(r, runIds: Set((try? read(fileURL(id)))??.runIds ?? []), stats: &ignored)
    }

    private struct HistoryRecord: Codable {
        struct Entry: Codable { var kind: String; var text: String; var runId: String?; var at: String }
        /// 2: user lines are placeholders and agent lines carry no echo.
        var format = 2
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
            var r = try JSONDecoder().decode(Record.self, from: data)
            if r.format < 2 { r.title = "对话" } // not yet migrated: never shown as stored
            return r.binding
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
        /// 2: the title is a command name or "对话", never user text.
        var format = 2
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
