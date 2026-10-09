import Darwin
import Foundation

/// One scratch root per test process, `$TMPDIR/acp-tests-<pid>-<uuid>`.
/// Every ACP test directory lives under it, and the root is removed when
/// the process exits, so a test that forgets its own cleanup leaves
/// nothing behind (12k+ rtest-* and similar were found in $TMPDIR, 2026-10-09).
/// A run that was killed leaves its root; the next run removes roots of
/// this exact scheme whose process is gone. Nothing outside the scheme is
/// ever touched.
enum ACPTestScratch {
    static let prefix = "acp-tests-"

    static let root: URL = {
        let tmp = FileManager.default.temporaryDirectory
        sweepStale(in: tmp)
        let url = tmp.appendingPathComponent("\(prefix)\(getpid())-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        atexit { ACPTestScratch.removeRoot() }
        return url
    }()

    /// A fresh, not yet created, path under the root.
    static func dir(_ name: String) -> URL {
        root.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    /// A fresh, not yet created, test directory directly under /tmp, where
    /// Real-test sockets must live (`/tmp/adt-<kind>-<pid>-<id>`). Removed
    /// by the test itself; if the process was killed first, a later run's
    /// `sweepStaleTmp` removes it (Codex on #141).
    static func tmp(_ kind: String) -> String {
        sweepStaleTmp()
        return "/tmp/adt-\(kind)-\(getpid())-\(UUID().uuidString.prefix(8))"
    }

    private static let sweptTmp: Void = {
        _ = sweep(tmp: "/private/tmp", table: ACPTestPinnedTransport.unixSocketTable, now: Date())
    }()

    /// Remove this scheme's directories in `tmp` only when all of these hold
    /// (Kevin's cleanup rules; b9, seventh review): the creating test
    /// process is gone; no process has a socket bound inside the directory
    /// (an orphaned child Runtime of a killed test may still serve there),
    /// with an unreadable socket table meaning "keep everything"; nothing in
    /// it changed for two hours; it is a plain directory of this user.
    /// Returns the names removed.
    @discardableResult
    static func sweep(tmp: String, table: () -> [(pid: pid_t, name: String)]?, now: Date) -> [String] {
        let me = getpid()
        let stale = ((try? FileManager.default.contentsOfDirectory(atPath: tmp)) ?? []).filter { name in
            guard let pid = schemePid(name), pid > 0, pid != me else { return false }
            return kill(pid, 0) != 0 && errno == ESRCH
        }
        guard !stale.isEmpty, let rows = table() else { return [] }
        var removed: [String] = []
        for name in stale {
            let dir = ACPTestPinnedTransport.normalised(tmp + "/" + name + "/x")
            let prefix = (dir as NSString).deletingLastPathComponent + "/"
            guard !rows.contains(where: { $0.name.hasPrefix(prefix) }) else { continue }
            guard let newest = newestChange(tmp + "/" + name), now.timeIntervalSince(newest) > 2 * 3600 else { continue }
            if removeIfOwned(tmp + "/" + name) { removed.append(name) }
        }
        return removed
    }

    /// Latest modification time (mtime) of the directory itself and of the
    /// entries directly in it; deeper levels are NOT scanned (Kevin
    /// 2026-10-09: no recursive scan in this round, to avoid symlink and
    /// traversal races). Never follows symlinks; nil if anything cannot be
    /// read (then it is kept). Known limit: a change two or more levels down
    /// (e.g. a child Runtime writing into `side.runtime/`) is not seen; the
    /// socket check is what protects a directory a process still serves.
    private static func newestChange(_ path: String) -> Date? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        var newest = st.st_mtimespec.tv_sec
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return nil }
        for n in names {
            var s = stat()
            guard lstat(path + "/" + n, &s) == 0 else { return nil }
            newest = max(newest, s.st_mtimespec.tv_sec)
        }
        return Date(timeIntervalSince1970: TimeInterval(newest))
    }
    /// The pid in `adt-<kind>-<pid>-<id>`, where kind is acp, ptest or
    /// curtest-<letters> and id is 6–8 letters or digits; nil otherwise.
    static func schemePid(_ name: String) -> pid_t? {
        let parts = name.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
        let kindLength: Int
        switch true {
        case parts.count == 4 && (parts[1] == "acp" || parts[1] == "ptest"): kindLength = 1
        case parts.count == 5 && parts[1] == "curtest" && !parts[2].isEmpty
            && parts[2].unicodeScalars.allSatisfy({ ("a"..."z").contains($0) }): kindLength = 2
        default: return nil
        }
        guard parts[0] == "adt" else { return nil }
        let pidPart = parts[1 + kindLength], id = parts[2 + kindLength]
        guard !pidPart.isEmpty, pidPart.unicodeScalars.allSatisfy({ ("0"..."9").contains($0) }),
              (6...8).contains(id.count),
              id.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) })
        else { return nil }
        return pid_t(pidPart)
    }

    /// Once per process: test directories under /tmp left by runs whose
    /// process is gone (see `sweep` for every condition).
    static func sweepStaleTmp() { _ = sweptTmp }

    private static func removeIfOwned(_ path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR, st.st_uid == getuid() else { return false }
        return (try? FileManager.default.removeItem(atPath: path)) != nil
    }

    private static func removeRoot() {
        try? FileManager.default.removeItem(at: root)
    }

    /// Roots of earlier runs whose process no longer exists.
    private static func sweepStale(in tmp: URL) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let dash = rest.firstIndex(of: "-"), let pid = pid_t(rest[..<dash]), pid > 0,
                  UUID(uuidString: String(rest[rest.index(after: dash)...])) != nil else { continue }
            if kill(pid, 0) != 0 && errno == ESRCH {
                try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
            }
        }
    }
}
