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
        return raw
    }
}
