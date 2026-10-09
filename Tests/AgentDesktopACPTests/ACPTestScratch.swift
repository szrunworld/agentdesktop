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
