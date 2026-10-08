import Foundation
import Testing

/// The endpoint allowlist for the unit.run Real tests. A local copy of the
/// logic in #141's shared `ACPTestEndpointGuard` (not on main yet): the
/// endpoint must be an absolute path to a socket inside an existing directory
/// whose realpath(3) is under /tmp/adt-* (/private/tmp/adt-* on macOS), so a
/// /tmp/adt-* symlink to $HOME or a `..` path cannot reach the product
/// endpoint. Stricter than #141 in one point: the socket itself must not be a
/// symlink. Throws, so a failed check stops a test before it connects.
/// Switch to `ACPTestEndpointGuard` once #141 is on main.
enum URTestEndpointGuard {
    struct NotATestCopy: Error, CustomStringConvertible {
        let path: String
        var description: String { "refusing \(path): Real tests only connect to a test copy under /tmp/adt-*" }
    }

    /// The resolved socket path to connect to.
    static func check(_ raw: String) throws -> String {
        guard raw.hasPrefix("/") else { throw NotATestCopy(path: raw) }
        let dir = (raw as NSString).deletingLastPathComponent
        let name = (raw as NSString).lastPathComponent
        guard !name.isEmpty, name != ".", name != ".." else { throw NotATestCopy(path: raw) }
        guard let real = realpath(dir, nil) else { throw NotATestCopy(path: raw) }
        defer { free(real) }
        let resolvedDir = String(cString: real)
        guard (resolvedDir + "/").hasPrefix("/private/tmp/adt-") || (resolvedDir + "/").hasPrefix("/tmp/adt-") else {
            throw NotATestCopy(path: raw)
        }
        let resolved = resolvedDir + "/" + name
        var st = stat()
        if lstat(resolved, &st) == 0, (st.st_mode & S_IFMT) == S_IFLNK { throw NotATestCopy(path: raw) }
        return resolved
    }
}

// Layer: Mock (filesystem only, no Runtime).
@Suite("UR · Mock · Real-test endpoint guard", .serialized)
struct URTestEndpointGuardTests {
    private func makeTestCopy() throws -> URL {
        let u = URL(fileURLWithPath: "/tmp/adt-urtest-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }

    @Test("[Mock] guardAcceptsASocketInATestCopy") func guardAcceptsASocketInATestCopy() throws {
        let dir = try makeTestCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let resolved = try URTestEndpointGuard.check(dir.path + "/control.sock")
        #expect(resolved.hasSuffix("/control.sock"))
        #expect(resolved.contains("/tmp/adt-urtest-"))
    }

    @Test("[Mock] guardRefusesEscapes") func guardRefusesEscapes() throws {
        let dir = try makeTestCopy()
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        // A /tmp/adt-* symlink to $HOME.
        let link = "/tmp/adt-urtest-link-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: home)
        defer { try? FileManager.default.removeItem(atPath: link) }
        // A socket name that is itself a symlink out of the test copy.
        try FileManager.default.createSymbolicLink(atPath: dir.path + "/control.sock",
                                                   withDestinationPath: home + "/Library/Application Support/AgentDesktop/control.sock" as String)
        let product = home + "/Library/Application Support/AgentDesktop/control.sock"
        let homeRel = String(home.dropFirst())
        let appSock = "/Library/Application Support/AgentDesktop/control.sock"
        var bad: [String] = []
        bad.append(link + appSock)
        bad.append(dir.path + "/../../" + homeRel + appSock)
        bad.append("/tmp/adt-../" + homeRel + "/x.sock")
        bad.append(dir.path + "/control.sock")
        bad.append(product)
        bad.append("relative/adt-x.sock")
        bad.append("/tmp/adt-missing-" + UUID().uuidString + "/c.sock")
        bad.append(dir.path + "/..")
        for bad in bad {
            #expect(throws: URTestEndpointGuard.NotATestCopy.self, "accepted \(bad)") { try URTestEndpointGuard.check(bad) }
        }
    }
}
