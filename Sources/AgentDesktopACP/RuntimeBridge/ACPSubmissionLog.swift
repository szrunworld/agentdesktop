import AgentDesktopProtocol
import CryptoKit
import Foundation

/// The bridge's only state: which Runtime requestId (and, once known, which
/// runId) an editor submission became, so that a retry after a lost answer
/// queries the Runtime instead of sending again. It is not a second request
/// ledger: whether a request ran is always read back from the Runtime's
/// ledger (`request.show`) and Run store (`run.show`).
///
/// One JSON file, mode 0600 in a 0700 directory, rewritten atomically. It
/// holds no prompt text or task input. Entries older than the Runtime
/// ledger's retention (7 days) are dropped at load.
public final class ACPSubmissionLog: @unchecked Sendable {
    public enum State: String, Sendable {
        /// Written before the request is sent; the answer is not known yet.
        case sending
        /// The Runtime answered with a Run.
        case accepted
        /// The Runtime answered with a refusal; nothing runs.
        case refused
    }

    public struct Entry: Equatable, Sendable {
        public var submissionKey: String
        public var requestId: String
        public var method: String
        public var state: State
        public var runId: String?
        public var refusalCode: String?
        /// Never persisted: a Runtime refusal message is free text that may
        /// echo a credential or another window's content (A4 finding F-1).
        /// Kept only in memory for the current process; always nil after a load.
        public var refusalMessage: String?
        public var updatedAt: String

        public init(submissionKey: String, requestId: String, method: String, state: State, runId: String? = nil,
                    refusalCode: String? = nil, refusalMessage: String? = nil, updatedAt: String) {
            self.submissionKey = submissionKey; self.requestId = requestId; self.method = method
            self.state = state; self.runId = runId; self.refusalCode = refusalCode
            self.refusalMessage = refusalMessage; self.updatedAt = updatedAt
        }
    }

    public static let retentionDays = 7
    public let path: String
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [String: Entry] = [:]
    /// Fault injection for tests only: the directory fsync after a rename fails.
    private let dirFsyncFault: Bool

    /// The default location beside the Runtime's own data.
    public static func defaultPath(home: String = NSHomeDirectory()) -> String {
        home + "/Library/Application Support/AgentDesktop/acp/submissions.json"
    }

    /// Loads `path`. An unreadable or corrupt file is an error, never an
    /// empty log: forgetting a record could make a retry send twice.
    public convenience init(path: String, now: @escaping @Sendable () -> Date = { Date() }) throws {
        try self.init(path: path, now: now, dirFsyncFault: false)
    }

    /// Internal: tests inject a failing directory fsync.
    init(path: String, now: @escaping @Sendable () -> Date = { Date() }, dirFsyncFault: Bool) throws {
        self.path = path
        self.now = now
        self.dirFsyncFault = dirFsyncFault
        let dir = (path as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard FileManager.default.fileExists(atPath: path) else { return }
        chmod(path, 0o600)
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let v = try StrictJSON.parse(data)
        guard v["version"]?.intValue == 1, let list = v["entries"]?.arrayValue else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path])
        }
        let cutoff = now().addingTimeInterval(-Double(Self.retentionDays) * 86400)
        // A file written before the F-1 fix may still hold refusal messages
        // or unlisted codes in clear text: rewrite it once, right away.
        var scrub = false
        for item in list {
            guard let key = item["submissionKey"]?.stringValue, let rid = item["requestId"]?.stringValue,
                  let method = item["method"]?.stringValue,
                  let state = item["state"]?.stringValue.flatMap(State.init(rawValue:)),
                  let at = item["updatedAt"]?.stringValue
            else { throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: path]) }
            // Check sensitive fields before the retention skip, and rewrite
            // the file whenever an entry is dropped, so nothing expired stays
            // on disk either (Codex review P1 on #141).
            if item["refusalMessage"] != nil { scrub = true }
            let rawCode = item["refusalCode"]?.stringValue
            let code = rawCode.map(ACPRedactor.errorCode)
            if rawCode != code { scrub = true }
            if let d = Self.date(at), d < cutoff { scrub = true; continue }
            entries[key] = Entry(submissionKey: key, requestId: rid, method: method, state: state,
                                 runId: item["runId"]?.stringValue, refusalCode: code,
                                 refusalMessage: nil, updatedAt: at)
        }
        if scrub { try persist() }
    }

    public func entry(_ submissionKey: String) -> Entry? {
        lock.lock(); defer { lock.unlock() }
        return entries[submissionKey]
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return entries.count
    }

    /// Insert or replace, then persist before returning.
    public func record(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        var e = entry
        e.updatedAt = Self.stamp(now())
        let previous = entries[e.submissionKey]
        entries[e.submissionKey] = e
        // If only the directory fsync failed, the file may already hold the
        // new entry while memory rolls back; the caller sees an error and the
        // next successful persist rewrites the file from memory. No sensitive
        // text is involved: refusal messages are never stored (b9, #141).
        do { try persist() } catch {
            entries[e.submissionKey] = previous
            throw error
        }
    }

    /// Forget a submission; only when it is certain nothing reached the Runtime.
    public func remove(_ submissionKey: String) throws {
        lock.lock(); defer { lock.unlock() }
        let previous = entries.removeValue(forKey: submissionKey)
        // Same as `record`: a failed directory fsync may leave the file
        // without the entry while memory keeps it; the next persist rewrites it.
        do { try persist() } catch {
            entries[submissionKey] = previous
            throw error
        }
    }

    public func stampNow() -> String { Self.stamp(now()) }

    /// The Runtime requestId for a submission: stable for the same caller
    /// and submissionKey, different for any other key, valid as an `Id`.
    public static func requestId(principalId: String, submissionKey: String) -> String {
        let digest = SHA256.hash(data: Data("acp-submission/v1\n\(principalId)\n\(submissionKey)".utf8))
        return "acp-sub-" + digest.prefix(24).map { String(format: "%02x", $0) }.joined()
    }

    private func persist() throws {
        let list = entries.values.sorted { $0.submissionKey < $1.submissionKey }.map { e -> JSONValue in
            var m: [(String, JSONValue)] = [("submissionKey", .string(e.submissionKey)), ("requestId", .string(e.requestId)),
                                            ("method", .string(e.method)), ("state", .string(e.state.rawValue)),
                                            ("updatedAt", .string(e.updatedAt))]
            if let r = e.runId { m.append(("runId", .string(r))) }
            // Only catalogued error codes reach disk (anything else becomes unlisted_error).
            if let c = e.refusalCode { m.append(("refusalCode", .string(ACPRedactor.errorCode(c)))) }
            return .obj(m)
        }
        let body = JSONValue.obj([("version", .int(1)), ("entries", .array(list))]).encodedData()
        let tmp = path + ".tmp-\(getpid())"
        unlink(tmp)
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var ok = body.withUnsafeBytes { raw -> Bool in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress! + off, raw.count - off)
                if n < 0 { if errno == EINTR { continue }; return false }
                off += n
            }
            return true
        }
        ok = ok && fsync(fd) == 0
        close(fd)
        guard ok, rename(tmp, path) == 0 else {
            let code = errno
            unlink(tmp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        // The rename is only durable once the directory is (Codex on #141):
        // after a scrub, a power loss must not bring back the old file with
        // its sensitive text. Not durable is an error.
        let dir = (path as NSString).deletingLastPathComponent
        let dfd = open(dir.isEmpty ? "." : dir, O_RDONLY | O_DIRECTORY)
        guard dfd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(dfd) }
        guard !dirFsyncFault, fsync(dfd) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }

    private static func stamp(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    /// Accepts timestamps with or without fractional seconds. An entry whose
    /// time cannot be read is kept (dropping it could allow a resend), but
    /// its sensitive fields are still scrubbed on load.
    private static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
