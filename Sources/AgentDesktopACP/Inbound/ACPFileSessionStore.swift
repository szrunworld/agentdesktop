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
    /// Whether the migration finished (tests read it).
    private(set) var migrated = false
    /// Set once a failed append could not be rolled back for certain; no
    /// further log lines are written by this store (fail closed).
    private var migrationLogUnusable = false
    /// Whether this store has seen the log's directory entry synced.
    private var logDirDurable = false

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
        // An error here may be outcome 2 (written, not known durable): the
        // stored revision may already be the new one, so a blind retry with
        // the old revision would conflict rather than write twice.
        do { try writeAtomically(data, to: target) } catch is WriteUncertain {
            throw ACPFileSessionStoreError.io("write uncertain: not known durable")
        }
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
        // An error may be outcome 2 (appended, not known durable); callers
        // treat history as best effort and do not retry.
        do { try writeAtomically(data, to: historyURL(sessionId)) } catch is WriteUncertain {
            throw ACPFileSessionStoreError.io("write uncertain: not known durable")
        }
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
        // Kevin 2026-10-09: if the log cannot tell us whether it is safe to
        // go on, stop and wait for a person. A file whose last record is
        // `uncertain`, or a lone `intent` (its outcome was never recorded),
        // is never processed automatically, and while any such file exists
        // the migration is never complete (Codex on #141).
        guard let blocked = filesAwaitingAPersonInLog() else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var failed = !blocked.isEmpty
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
                // The block key is the session id; it must be the one in the
                // file name too, else a record could miss its file. A mismatch
                // is left alone for a person (like reads, which refuse it).
                guard name == "\(r.acpSessionId).history.json", (try? Self.checkId(r.acpSessionId)) != nil else { failed = true; continue }
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
                guard name == "\(r.acpSessionId).json", (try? Self.checkId(r.acpSessionId)) != nil else { failed = true; continue }
                entry = MigrationLogEntry(at: Self.now(), file: "binding", sessionId: r.acpSessionId, entries: 0)
                entry.titleReset = r.title != "对话"
                r.title = "对话"
                r.format = 2
                guard let encoded = try? encoder.encode(r) else { failed = true; continue }
                out = encoded
            }
            if blocked.contains(entry.file + "/" + entry.sessionId) { failed = true; continue }
            // The log line is written (and synced) before the file changes:
            // no log, no rewrite, so the audit trail is never missing a file.
            // Kevin 2026-10-09: if the intent cannot be written, the whole
            // migration stops at once; no rewrite of this or any later file.
            guard appendMigrationLog([entry]) else { failed = true; break }
            // Kevin 2026-10-09: an ordinary file failure is isolated (later
            // files go on, the whole is never marked done); a failure that
            // makes the log untrustworthy stops the whole migration.
            do {
                try writeAtomically(out, to: url)
                entry.status = "completed"
            } catch is WriteUncertain {
                // Outcome 2: renamed, durability unknown. Never retried
                // automatically; left for a person.
                entry.status = "uncertain"
                entry.error = "dir_fsync"
                failed = true
            } catch {
                entry.status = "failed"
                entry.error = Self.errorCode(error)
                failed = true
            }
            entry.at = Self.now()
            guard appendMigrationLog([entry]) else { failed = true; break }
        }
        migrated = !failed
    }

    /// One migrated file: counts and an error code, never any text. Each
    /// rewrite is logged twice: `intent` before (with the counts), then
    /// `completed`, `failed` or `uncertain` after. An `intent` with no later `completed`
    /// for the same file means the rewrite did not complete (Codex on #141:
    /// a lone pre-write entry must never read as success). Only tests read
    /// this log; no product, cleanup, recovery or audit code does.
    struct MigrationLogEntry: Codable, Equatable {
        var status = "intent"
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
    /// How many log appends were attempted (tests check that a failed intent
    /// stops the migration).
    private(set) var migrationLogAttempts = 0
    /// Fault injection for tests only: return true to make append number n
    /// (1-based) fail, or to make the directory fsync after a rename fail.
    var logAppendFaultForTesting: ((Int) -> Bool)?
    var dirFsyncFaultForTesting: ((String) -> Bool)?
    /// Fault injection for tests only: the directory fsync after creating
    /// the migration log fails.
    var logDirFsyncFaultForTesting = false

    /// Files ("history/<id>" or "binding/<id>") whose latest log record is
    /// `uncertain` or a lone `intent`: their outcome is unknown and they wait
    /// for a person. nil when the log exists but cannot be read or a line
    /// cannot be understood: then the migration must not run. A trailing
    /// half line is the append guard's business (no further appends).
    static let knownStatuses: Set<String> = ["intent", "completed", "failed", "uncertain"]

    /// The fields a migration-log record may have, exactly those of
    /// `MigrationLogEntry`; the first five are required.
    static let requiredLogFields: Set<String> = ["status", "at", "file", "sessionId", "entries"]
    static let allowedLogFields: Set<String> = requiredLogFields
        .union(["userScrubbed", "agentChanged", "agentKept", "titleReset", "error"])

    /// One log line checked as a whole (Kevin 2026-10-09, one rule instead
    /// of a patch per corruption): a JSON object; all required fields; no
    /// field outside `MigrationLogEntry`; right types; `status` one of four,
    /// `file` history or binding, `sessionId` a valid session id, `at` a
    /// timestamp, counts >= 0, `error` only with failed or uncertain. nil
    /// for anything else (then the migration does not start).
    static func validLogRecord(_ raw: Data) -> (status: String, file: String, sessionId: String)? {
        guard !raw.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: raw) as? [String: Any],
              requiredLogFields.isSubset(of: object.keys), allowedLogFields.isSuperset(of: object.keys),
              let status = object["status"] as? String, knownStatuses.contains(status),
              let file = object["file"] as? String, file == "history" || file == "binding",
              let sessionId = object["sessionId"] as? String, (try? checkId(sessionId)) != nil,
              let at = object["at"] as? String, timestamp(at) != nil
        else { return nil }
        for key in ["entries", "userScrubbed", "agentChanged", "agentKept"] {
            guard let value = object[key] else {
                if key == "entries" { return nil }
                continue
            }
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
                  n.doubleValue >= 0, n.doubleValue == n.doubleValue.rounded(.towardZero) else { return nil }
        }
        if let t = object["titleReset"] {
            guard let n = t as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        }
        if let e = object["error"] {
            guard e is String, status == "failed" || status == "uncertain" else { return nil }
        }
        return (status, file, sessionId)
    }

    private static func timestamp(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.date(from: s)
    }

    private func filesAwaitingAPersonInLog() -> Set<String>? {
        let url = directory.appendingPathComponent(Self.migrationLogName)
        let data: Data
        switch Self.readNoFollow(url) {
        case let .success(d): data = d
        case .failure(.gone): return []
        case .failure: return nil
        }
        var latest: [String: String] = [:]
        // The piece after the final newline is always empty; without a final
        // newline the last piece is a half line, which the append guard
        // handles. Every other piece must be a valid record; blank lines
        // included, anything else stops the migration (Kevin 2026-10-09).
        var lines = data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if !lines.isEmpty { lines.removeLast() }
        for raw in lines {
            guard let record = Self.validLogRecord(Data(raw)) else { return nil }
            latest[record.file + "/" + record.sessionId] = record.status
        }
        return Set(latest.filter { $0.value == "uncertain" || $0.value == "intent" }.keys)
    }

    private func appendMigrationLog(_ entries: [MigrationLogEntry]) -> Bool {
        guard !entries.isEmpty else { return true }
        migrationLogAttempts += 1
        if logAppendFaultForTesting?(migrationLogAttempts) == true { return false }
        guard !migrationLogUnusable else { return false }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lines = Data()
        for e in entries {
            guard let d = try? encoder.encode(e) else { return false }
            lines += d + Data("\n".utf8)
        }
        let logPath = directory.appendingPathComponent(Self.migrationLogName).path
        let fd = open(logPath, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        // All lines or none (Codex on #141). Called with the directory lock
        // held, so no other writer. A file that does not end with a complete
        // line (a crash mid-write, or a rollback that did not stick) is never
        // appended to: the migration stays pending instead.
        let start = lseek(fd, 0, SEEK_END)
        guard start >= 0 else { return false }
        if start > 0 {
            var last: UInt8 = 0
            let rfd = open(directory.appendingPathComponent(Self.migrationLogName).path, O_RDONLY | O_NOFOLLOW)
            guard rfd >= 0 else { return false }
            let n = pread(rfd, &last, 1, start - 1)
            close(rfd)
            guard n == 1, last == UInt8(ascii: "\n") else { return false }
        }
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
            // Cut back to where it was and make that durable; if either step
            // fails, this store writes no more log lines.
            if ftruncate(fd, start) != 0 || fsync(fd) != 0 { migrationLogUnusable = true }
            return false
        }
        // The log's directory entry must be durable before any line counts
        // as written (Codex on #141): otherwise a rewrite could survive a
        // power loss while its log vanished. Whether this store or an
        // earlier one created the file is not known for sure (an earlier
        // sync may have failed after creating it), so every store syncs the
        // directory after its first successful append, retrying until it
        // succeeds (b9). Not durable means the append failed.
        if !logDirDurable {
            let dfd = open(directory.path, O_RDONLY | O_DIRECTORY)
            let synced = dfd >= 0 && !logDirFsyncFaultForTesting && fsync(dfd) == 0
            if dfd >= 0 { close(dfd) }
            guard synced else {
                // Reported as failed, so the line must not stay either (else
                // it would read as a lone intent and block an untouched file).
                if ftruncate(fd, start) != 0 || fsync(fd) != 0 { migrationLogUnusable = true }
                return false
            }
            logDirDurable = true
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
        // Only a regular file: reading a directory through FileHandle raises
        // an Objective-C exception instead of returning an error.
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { close(fd); return .failure(.failed) }
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
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ACPFileSessionStoreError.io("not a regular file")
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
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw ACPFileSessionStoreError.io("not a regular file")
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

    /// Replace `target` with `data`: temp file (0600, fsync), rename, then
    /// fsync of the directory. Three outcomes (Kevin 2026-10-09):
    /// 1. Throws before the rename — nothing was written; safe to retry.
    /// 2. Throws after the rename (directory open or fsync failed) — the new content
    ///    is in place but not known to be durable; the result is uncertain:
    ///    callers must not retry automatically against the old revision.
    /// 3. Returns — written and durable.
    /// Outcome 2 below: written (renamed) but not known to be durable.
    struct WriteUncertain: Error {}

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
        // Outcome 2 if this fails: written, durability unknown (see above).
        // Make the rename itself durable before anyone records it as completed
        // (Codex on #141: a synced "completed" log line must not outlive an
        // unsynced rename after a power loss).
        let dfd = open(directory.path, O_RDONLY | O_DIRECTORY)
        // Every failure after the rename is outcome 2 (Codex on #141): the
        // replacement happened but is not known to be durable.
        guard dfd >= 0 else { throw WriteUncertain() }
        defer { close(dfd) }
        guard dirFsyncFaultForTesting?(target.lastPathComponent) != true, fsync(dfd) == 0 else { throw WriteUncertain() }
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
