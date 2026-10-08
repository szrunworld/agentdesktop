import AgentDesktopClient
import AgentDesktopProtocol
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

// MARK: Post-connect identity check (Kevin's TOCTOU requirement on #141)

extension ACPTestEndpointGuard {
    /// The path checks above can race with a swap between check and connect.
    /// After the handshake the Runtime states the endpoint it listens on; a
    /// product Runtime states its product path. Refuse unless that stated
    /// endpoint is itself inside an existing /tmp/adt-* directory.
    static func verify(statedEndpoint: String?) throws {
        guard let stated = statedEndpoint, stated.hasPrefix("/") else { throw NotATestCopy(path: statedEndpoint ?? "(no endpoint in handshake)") }
        let dir = (stated as NSString).deletingLastPathComponent
        guard let real = realpath(dir, nil) else { throw NotATestCopy(path: stated) }
        defer { free(real) }
        let resolved = String(cString: real) + "/"
        guard resolved.hasPrefix("/private/tmp/adt-") || resolved.hasPrefix("/tmp/adt-") else { throw NotATestCopy(path: stated) }
        for product in productSockets() where (product as NSString).deletingLastPathComponent == String(cString: real) {
            throw NotATestCopy(path: stated)
        }
    }
}

/// A RuntimeClient for Real tests that refuses to send anything except the
/// handshake until the Runtime's stated endpoint passed `verify`. On a failed
/// check the connection is closed and every later call throws.
final class ACPTestVerifiedClient: RuntimeClient, @unchecked Sendable {
    private let inner: RuntimeClient
    private var verified = false
    private var refused: Error?
    init(_ inner: RuntimeClient) { self.inner = inner }
    var endpoint: Endpoint { inner.endpoint }

    func handshake() throws -> RuntimeIdentity {
        if let refused { throw refused }
        let id = try inner.handshake()
        do { try ACPTestEndpointGuard.verify(statedEndpoint: id.endpoint) } catch { refused = error; inner.close(); throw error }
        verified = true
        return id
    }
    private func ensure() throws { if !verified { _ = try handshake() } }
    func call(_ request: RuntimeRequest) throws -> JSONValue { try ensure(); return try inner.call(request) }
    func subscribe(runId: String?, after: Int?) throws -> JSONValue { try ensure(); return try inner.subscribe(runId: runId, after: after) }
    func nextEvent() throws -> PushedEvent { try ensure(); return try inner.nextEvent() }
    func close() { inner.close() }
}
