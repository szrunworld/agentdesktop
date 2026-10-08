import Foundation

/// The one allowlist for every ACP Real-Runtime test: the endpoint must be a
/// socket inside an existing test-copy directory under /tmp/adt-*. The
/// directory is resolved with realpath(3) first, so a /tmp/adt-* symlink or
/// a `..` path cannot point the test at the product endpoint. Throws, never
/// just records an issue, so a failed check stops the test before it connects.
enum ACPTestEndpointGuard {
    struct NotATestCopy: Error, CustomStringConvertible {
        let path: String
        var description: String { "refusing \(path): Real tests only connect to a test copy under /tmp/adt-*" }
    }

    static func check(_ raw: String) throws -> String {
        guard raw.hasPrefix("/") else { throw NotATestCopy(path: raw) }
        let dir = (raw as NSString).deletingLastPathComponent
        guard let real = realpath(dir, nil) else { throw NotATestCopy(path: raw) }
        defer { free(real) }
        let resolved = String(cString: real) + "/"
        guard resolved.hasPrefix("/private/tmp/adt-") || resolved.hasPrefix("/tmp/adt-") else { throw NotATestCopy(path: raw) }
        // The socket itself: not a symlink, not a hard link, and not the same
        // file as any socket of the product (Codex review P1 on #141: a hard
        // link to the product runtime.sock inside /tmp/adt-* passed the
        // directory check because /tmp and $HOME share a volume).
        var st = stat()
        if lstat(raw, &st) == 0 {
            if (st.st_mode & S_IFMT) == S_IFLNK { throw NotATestCopy(path: raw) }
            if st.st_nlink > 1 { throw NotATestCopy(path: raw) }
            for product in productSockets() {
                var p = stat()
                if stat(product, &p) == 0, p.st_dev == st.st_dev, p.st_ino == st.st_ino { throw NotATestCopy(path: raw) }
            }
        }
        return raw
    }

    /// Every entry of the product's data directory (real and $HOME-based),
    /// so a renamed or future product socket is covered too.
    static func productSockets() -> [String] {
        var homes = [NSHomeDirectory()]
        if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir { homes.append(String(cString: dir)) }
        var out: [String] = []
        for home in Set(homes) {
            let dir = home + "/Library/Application Support/AgentDesktop"
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? [] { out.append(dir + "/" + name) }
        }
        return out
    }
}
